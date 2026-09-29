import SwiftUI
import UIKit
import QuartzCore
import Metal
import os.log

extension Notification.Name {
    static let steamOSSettingsRequested = Notification.Name("SteamOS-iOS.SettingsRequested")
}

/// Shared logical-resolution and presentation policy for Windows Steam/games.
private enum SteamOSDisplayProfile {
    static func preferredDesktopSize() -> (width: Int, height: Int) {
        let native = UIScreen.main.nativeBounds.size
        let longEdge = max(native.width, native.height)
        let shortEdge = max(min(native.width, native.height), 1)
        let aspect = longEdge / shortEdge

        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let height = isPad ? 900 : 720
        let minWidth = isPad ? 1024 : 1152
        let maxWidth = isPad ? 1440 : 1600
        var width = Int((CGFloat(height) * aspect).rounded())
        width = min(max(width, minWidth), maxWidth)
        width = ((width + 7) / 8) * 8
        return (width, height)
    }

    static func defaultGuestSize() -> CGSize {
        let d = preferredDesktopSize()
        return CGSize(width: d.width, height: d.height)
    }

    static func activeGuestSize() -> CGSize {
        let fallback = defaultGuestSize()
        func envDimension(_ name: String, fallback: CGFloat) -> CGFloat {
            guard let raw = getenv(name),
                  let parsed = Double(String(cString: raw)),
                  parsed >= 64 else { return fallback }
            return CGFloat(parsed)
        }
        return CGSize(
            width: envDimension("MADEIRA_SCREEN_W", fallback: fallback.width),
            height: envDimension("MADEIRA_SCREEN_H", fallback: fallback.height)
        )
    }
}


/// Product runtime gate: Steam/game execution is local-only and requires both
/// executable JIT capability and a real Apple Metal device.
private enum SteamOSRuntimeGate {
    private static var executableJITProven = false

    static func validate(log: LogStore) -> Bool {
        guard jit_check_debugged() else {
            log.log("[JIT] NOT READY — attach StikDebug/JIT before launching Steam or a game.", level: .error)
            return false
        }

        // CS_DEBUGGED alone is not enough. Prove that this process can write
        // generated ARM64 code through the RW alias and execute it through the
        // RX alias. jit_test_execute() must return the sentinel value 42.
        if !executableJITProven {
            let probe = jit_test_execute()
            guard probe == 42 else {
                log.log("[JIT] EXECUTION PROBE FAILED (result \(probe)) — refusing to start Wine/FEX.", level: .error)
                return false
            }
            executableJITProven = true
        }

        guard let gpu = MTLCreateSystemDefaultDevice() else {
            log.log("[METAL] NO LOCAL GPU — refusing to start the Windows runtime.", level: .error)
            return false
        }

        // The product path is always local. Madeira's historical remote-Metal
        // research transport must never become the execution engine.
        unsetenv("DXMT_REMOTE_METAL")
        unsetenv("RMETAL_TOKEN")
        unsetenv("DXMT_REMOTE_BATCH")
        setenv("STEAMOS_IOS_LOCAL_METAL", "1", 1)

        let maxTG = gpu.maxThreadsPerThreadgroup
        log.log("[JIT] READY — executable probe returned 42.", level: .success)
        log.log("[METAL] LOCAL GPU READY — \(gpu.name), max threads/group "
                + "\(maxTG.width)x\(maxTG.height)x\(maxTG.depth)", level: .success)

        // Rebind the process-lifetime presentation layer to the verified local
        // device. DXMT/D3D12 still own drawable contents and drawableSize.
        MetalHostView.shared.metalLayer.device = gpu
        return true
    }
}


// 2026-07-03 window-hosted Metal layer.
//
// The presenting CAMetalLayer must NOT be a SwiftUI-hosted view's backing
// layer: on iOS 26/27, SwiftUI's hosting intermittently routes such layers
// through an indirect/snapshot path where direct Metal presentations are
// silently dropped — presented drawables complete with presentedTime==0
// (measured), the screen freezes on stale content, and only full-tree
// re-renders (screenshots) reveal new frames. Which path a given run gets
// appeared random — the "sometimes rendering starts at present #9,
// sometimes never" lottery.
//
// So the layer now lives in MetalHostView, a raw UIView added directly to
// the UIWindow (classic game setup, no SwiftUI management). The SwiftUI-
// hosted MetalBackedView remains as a transparent layout placeholder that
// tracks geometry and handles touch input. The host view sits on top of
// the window but has interaction disabled, so touches fall through to the
// SwiftUI hierarchy (and thus to the placeholder's touch handlers).

/// Raw window-level host for the presenting CAMetalLayer.
final class MetalHostView: UIView {
    // Process-lifetime singleton. The CAMetalLayer is registered with DXMT's
    // swapchain exactly once; if the host were recreated on view teardown
    // (rotation, re-attach) DXMT would keep presenting to the DEAD layer —
    // black surface both ways (2026-07-05 landscape regression). One host,
    // one layer, forever; only its FRAME is re-parented/resized.
    static let shared = MetalHostView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

    override class var layerClass: AnyClass { return CAMetalLayer.self }
    var metalLayer: CAMetalLayer { return layer as! CAMetalLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        GamepadEventClaim.install(on: self)
        isUserInteractionEnabled = false   // touches fall through to SwiftUI
        backgroundColor = .black
        contentScaleFactor = UIScreen.main.scale
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        // 2026-07-03 MeloNX trick: displaySyncEnabled is macOS-public but
        // exists as PRIVATE API on iOS. Disabling it takes our presents out
        // of the display-sync scheduling machinery — the thing that has been
        // silently dropping them (presentedTime==0 on all but occasional
        // frames) at our sub-1Hz game present cadence. MeloNX (shipping
        // Switch emulator) sets exactly this pair on its layer.
        let syncSel = NSSelectorFromString("setDisplaySyncEnabled:")
        if metalLayer.responds(to: syncSel) {
            metalLayer.perform(syncSel, with: NSNumber(value: false))
            LogStore.shared.log("MetalLayer: displaySyncEnabled=false (private API, MeloNX pattern)")
        }
        /* ml651: was hardcoded 60, which contradicted everything around it —
         * FPSOverlay asks the display link for CAFrameRateRange(preferred: 120)
         * while this declared the surface a 60Hz one. Track the screen instead.
         *
         * ⚠️ HYPOTHESIS, NOT A DIAGNOSIS. displaySyncEnabled=false directly above
         * takes our presents out of display-sync scheduling, so this nominal
         * value may well be inert. It is one line and it removes a genuine
         * contradiction; if the A/B shows nothing, the cap is elsewhere and we
         * have eliminated it rather than argued about it. */
        let fpsSel = NSSelectorFromString("setNominalFramesPerSecond:")
        if metalLayer.responds(to: fpsSel) {
            let hz = UIScreen.main.maximumFramesPerSecond
            metalLayer.perform(fpsSel, with: hz as NSNumber)
            LogStore.shared.log("MetalLayer: ml651 nominalFPS=\(hz) (was hardcoded 60; "
                                + "display link asks preferred=120)")
        }
        UIApplication.shared.isIdleTimerDisabled = true
        // Set once so DXMT's swapchain setup never blocks on a zero-sized
        // layer. After this, DXMT's setProps is the ONLY drawableSize
        // writer — per-layout rewrites from the app were a second writer
        // fighting it (pool churn on every SwiftUI layout pass).
        metalLayer.drawableSize = CGSize(width: 800, height: 600)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// SwiftUI-hosted placeholder: geometry + touch input only.
final class MetalBackedView: UIView {
    private static var layerRegistered = false

    // Hardware keyboard bridge: the view becomes first responder so the iOS
    // software keyboard appears, and each typed character is forwarded to
    // Wine as a virtual-key sequence (winios_post_key → send_hardware_message
    // → WM_KEYDOWN/WM_CHAR). Lets the user type into Windows dialogs (e.g.
    // Run) directly instead of relying on the browse list.
    static weak var keyboardTarget: MetalBackedView?
    override var canBecomeFirstResponder: Bool { true }
    static func toggleKeyboard() {
        guard let v = keyboardTarget else { return }
        if v.isFirstResponder { v.resignFirstResponder() }
        else { v.becomeFirstResponder() }
    }

    /// Mobile lifecycle repair: after background/foreground transitions UIKit
    /// can restore the window before it has issued a fresh layout pass to the
    /// raw Metal host. Force the live placeholder to recompute the exact
    /// aspect-fit frame used by both presentation and touchscreen mapping.
    @MainActor
    static func refreshPresentationGeometry() {
        guard let v = keyboardTarget else { return }
        v.setNeedsLayout()
        v.layoutIfNeeded()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        GamepadEventClaim.install(on: self)
        // Multi-touch REQUIRED: with it off, a fast double-tap's second
        // touch (landing before the first lift is processed) is silently
        // swallowed — drag-arm never fired (2026-07-06). Two-finger
        // scroll/right-click need it too.
        self.isMultipleTouchEnabled = true
        self.isUserInteractionEnabled = true
        self.backgroundColor = .clear
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        GamepadEventClaim.install(on: self)
    }

    // Visibility-stall postmortem (2026-07-03): the intermittent "presents
    // count but the screen stays black until a bg/fg or screenshot" state
    // was probed exhaustively — drawable leaks, present pacing, panel idle,
    // SwiftUI hosting, display-sync, CADisplayLink, transaction nudges and
    // view re-attach kicks were all eliminated (none changed it; only true
    // scene-level lifecycle events land pending frames, ~1-2 each). The one
    // robust correlate is present cadence: 60 FPS content always displays,
    // ~1 FPS content mostly doesn't. Resolution path: raise game FPS (perf
    // work), with a steady-rate re-present in DXMT as fallback insurance.

    /// Aspect-fit the current Windows guest surface into the actual iOS/iPadOS
    /// view. SteamOS-iOS no longer assumes the old 1024×768 Madeira test
    /// surface: MADEIRA_SCREEN_W/H describe the active Windows desktop/game
    /// target and the CAMetalLayer frame follows that aspect on every layout.
    private func guestSize() -> CGSize {
        SteamOSDisplayProfile.activeGuestSize()
    }

    private func gameRect() -> CGRect {
        let guest = guestSize()

        var container = bounds
        if let window, bounds.height >= window.bounds.height * 0.80 {
            let insets = window.safeAreaInsets
            container = bounds.inset(by: UIEdgeInsets(
                top: insets.top, left: insets.left,
                bottom: insets.bottom, right: insets.right))
        }

        let scale = min(container.width / guest.width,
                        container.height / guest.height)
        let w = guest.width * scale
        let h = guest.height * scale
        return CGRect(x: container.midX - w / 2,
                      y: container.midY - h / 2,
                      width: max(w, 1), height: max(h, 1))
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let w = window else { return }   // detach: leave the host be
        MetalBackedView.keyboardTarget = self  // keyboard button targets the live view
        // SwiftUI ancestors attach gesture recognizers that can delay or
        // cancel raw touch delivery (double-tap timing is exactly what
        // they punish). Defuse them for our subtree.
        var v: UIView? = self
        while let s = v {
            s.gestureRecognizers?.forEach {
                $0.cancelsTouchesInView = false
                $0.delaysTouchesBegan = false
                $0.delaysTouchesEnded = false
            }
            v = s.superview
        }
        let host = MetalHostView.shared
        if host.superview !== w {
            host.removeFromSuperview()
            w.addSubview(host)
        }
        host.frame = convert(gameRect(), to: w)
        // S2 desktop mode: the winios compositor renders the wine virtual
        // desktop aspect-fit inside THIS placeholder's area, exactly like
        // the games' Metal layer — never over the whole phone screen.
        let full = convert(bounds, to: w)
        winios_set_compositor_frame(full.minX, full.minY, full.width, full.height)
        if !Self.layerRegistered {
            Self.layerRegistered = true
            madeira_display_set_layer(host.metalLayer)
            LogStore.shared.log("MetalLayer registered with DXMT shim (window-hosted singleton)", level: .success)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let w = window {
            MetalHostView.shared.frame = convert(gameRect(), to: w)
            let full = convert(bounds, to: w)
            winios_set_compositor_frame(full.minX, full.minY, full.width, full.height)
        }
    }

    // Map touch points through the SAME aspect-fit rectangle used by Metal.
    // This keeps clicks/trackpad input pixel-aligned on wide iPhones and 4:3
    // iPads instead of applying the old fixed 1024×768 transform.
    private func mapTouch(_ touch: UITouch) -> (Int32, Int32) {
        let p = touch.location(in: self)
        let r = gameRect()
        let guest = guestSize()
        let maxX = max(Int32(guest.width) - 1, 0)
        let maxY = max(Int32(guest.height) - 1, 0)
        let x = Int32(min(max((p.x - r.minX) * guest.width / r.width, 0), guest.width - 1))
        let y = Int32(min(max((p.y - r.minY) * guest.height / r.height, 0), guest.height - 1))
        return (min(x, maxX), min(y, maxY))
    }

    // ==================================================================
    // S2 desktop mode: trackpad-style pointer.
    //   one finger move       — cursor moves relative (like a laptop pad)
    //   single tap            — left click
    //   double tap            — double click (two rapid clicks)
    //   double tap + hold     — drag (button held while moving), lift = drop
    //   two-finger drag       — scroll wheel
    //   two-finger tap        — right click
    // Cursor position lives here (desktop px); wine + the rendered arrow
    // follow via winios_pointer / winios_cursor_move.
    // ==================================================================
    private static var cursor: CGPoint = {
        let s = SteamOSDisplayProfile.defaultGuestSize()
        return CGPoint(x: s.width / 2, y: s.height / 2)
    }()
    private var lastPanPoint = CGPoint.zero
    private var touchStartPoint = CGPoint.zero
    private var touchStartTime: TimeInterval = 0
    private var movedBeyondSlop = false
    private var dragActive = false
    private var dragTouch: UITouch?          // the finger that owns the drag
    private var touchGeneration = 0          // invalidates pending long-press timers
    private var twoFingerActive = false
    private var twoFingerMoved = false
    private var twoFingerStartTime: TimeInterval = 0
    private var lastTwoFingerY: CGFloat = 0
    private var scrollAccum: CGFloat = 0
    // ml641: relative motion is scaled by a float sensitivity, so the integer
    // delta we hand to wine loses a fraction every event. At low sensitivity
    // that truncation is the whole signal — carry the remainder or slow drags
    // simply do nothing.
    private var relCarryX: CGFloat = 0
    private var relCarryY: CGFloat = 0
    private weak var directTouchOwner: UITouch?
    private var settingsGestureActive = false

    private let F_MOVE: UInt32 = 0x1, F_LDOWN: UInt32 = 0x2, F_LUP: UInt32 = 0x4
    private let F_RDOWN: UInt32 = 0x8, F_RUP: UInt32 = 0x10
    private let F_WHEEL: UInt32 = 0x800, F_ABS: UInt32 = 0x8000

    private var desktopMode: Bool {
        guard let v = getenv("MADEIRA_DESKTOP") else { return false }
        return v.pointee == 49  // '1'
    }
    private func envInt(_ name: String, _ def: Int) -> Int {
        guard let v = getenv(name), let i = Int(String(cString: v)) else { return def }
        return i
    }
    private func postPointer(_ flags: UInt32, data: Int32 = 0) {
        winios_pointer(Int32(Self.cursor.x), Int32(Self.cursor.y), flags, UInt32(bitPattern: data))
    }
    private func avgPoint(_ touches: [UITouch]) -> CGPoint {
        var x: CGFloat = 0, y: CGFloat = 0
        for t in touches { let p = t.location(in: self); x += p.x; y += p.y }
        let n = CGFloat(max(touches.count, 1))
        return CGPoint(x: x / n, y: y / n)
    }
    private func activeTouches(_ event: UIEvent?) -> [UITouch] {
        (event?.allTouches ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let active = activeTouches(event)

        // Three-finger tap opens SteamOS-iOS settings with no permanent HUD
        // button. Cancel any primary Windows touch first so the gesture cannot
        // leave a stuck pointer/button in Steam or a running game.
        if active.count >= 3 {
            settingsGestureActive = true
            touchGeneration += 1
            if let owner = directTouchOwner {
                let (x, y) = mapTouch(owner)
                winios_post_touch_up(x, y)
                directTouchOwner = nil
            }
            if dragActive { postPointer(F_LUP); dragActive = false; dragTouch = nil }
            twoFingerActive = false
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .steamOSSettingsRequested, object: nil)
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }

        guard InputSettings.shared.touchScreenEnabled else { return }

        // Direct Touch is literal finger-to-Windows-surface input. The current
        // winios bridge exposes one absolute Windows pointer, so keep a stable
        // primary finger while other fingers remain available to the separate
        // virtual-controller UIWindow.
        if InputSettings.shared.directTouch || !desktopMode {
            guard directTouchOwner == nil, let t = touches.first else { return }
            directTouchOwner = t
            let (x, y) = mapTouch(t)
            winios_post_touch_down(x, y)
            return
        }
        let now = Date().timeIntervalSinceReferenceDate
        touchGeneration += 1
        if active.count >= 2 {
            twoFingerActive = true
            twoFingerMoved = false
            twoFingerStartTime = now
            lastTwoFingerY = avgPoint(active).y
            scrollAccum = 0
            // a drag started by the first finger stays active; harmless
            return
        }
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        touchStartPoint = p
        lastPanPoint = p
        touchStartTime = now
        movedBeyondSlop = false
        relCarryX = 0; relCarryY = 0   // ml641: never carry motion across a lift
        // long-press → drag: hold still for 0.5s, haptic confirms, then move
        // the window; release drops. (Replaced double-tap-hold — it raced
        // Windows' double-click detection: wine saw WM_LBUTTONDBLCLK.)
        let gen = touchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.touchGeneration == gen, !self.dragActive,
                  !self.movedBeyondSlop, !self.twoFingerActive,
                  // ml643: in mouse-look the finger is the CAMERA, not a pointer.
                  // Holding still to line up a shot must not press the mouse.
                  !InputSettings.shared.relative else { return }
            self.dragActive = true
            self.dragTouch = t
            self.postPointer(self.F_LDOWN)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            fputs("[trackpad] long-press drag armed\n", stderr)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if settingsGestureActive { return }
        guard InputSettings.shared.touchScreenEnabled else { return }

        if InputSettings.shared.directTouch || !desktopMode {
            guard let t = directTouchOwner, touches.contains(t) else { return }
            let (x, y) = mapTouch(t)
            winios_post_touch_move(x, y)
            return
        }
        let active = activeTouches(event)
        if twoFingerActive {
            guard active.count >= 2 else { return }
            let avg = avgPoint(active)
            let dy = avg.y - lastTwoFingerY
            lastTwoFingerY = avg.y
            if abs(dy) > 2 { twoFingerMoved = true }
            scrollAccum += dy
            // 14pt of finger travel = one wheel notch. ml641 flipped the sign:
            // on a touchscreen the content follows the finger, so dragging UP
            // scrolls DOWN through the document. It was mouse-wheel sense before.
            while scrollAccum <= -14 { scrollAccum += 14; postPointer(F_WHEEL, data: -120) }
            while scrollAccum >= 14 { scrollAccum -= 14; postPointer(F_WHEEL, data: 120) }
            return
        }
        let t: UITouch
        if dragActive, let d = dragTouch {
            guard touches.contains(d) else { return }  // only the old tap finger moved
            t = d
        } else {
            guard let f = touches.first else { return }
            t = f
        }
        let p = t.location(in: self)
        let dx = p.x - lastPanPoint.x, dy = p.y - lastPanPoint.y
        lastPanPoint = p
        if hypot(p.x - touchStartPoint.x, p.y - touchStartPoint.y) > 10 { movedBeyondSlop = true }

        /* ml641 RELATIVE (mouse-look) MODE.
         *
         * Absolute input is what made the camera spin. We post a POSITION; wine
         * turns it into the delta the game reads as
         *     x - desktop_shm->cursor.x            (queue_ios.c:2290)
         * A game that locks the cursor calls ClipCursor, and update_desktop_cursor_pos
         * then CLAMPS desktop_shm->cursor into that rect, pinning it. Our own
         * Self.cursor keeps wandering across the full 1024x768, so the subtraction
         * yields (wandering - pinned): a huge delta that never converges and is
         * re-sent on every event. Spin rate depends on WHERE the finger is, not how
         * fast it moves.
         *
         * Posting device motion instead makes that impossible to reproduce: wine
         * computes cursor.x + dx, so the delta is exactly dx no matter what the
         * game does to the cursor. No F_ABS, and Self.cursor is deliberately not
         * touched — in this mode it has no meaning.
         *
         * Sign follows PUBG/Fortnite: drag right -> view turns right -> the world
         * slides left, so a target to the RIGHT of the crosshair is pulled onto it
         * by dragging RIGHT. That is the same sign as a mouse. Negate both terms
         * for content-drag (finger-follows-world) feel. */
        if InputSettings.shared.relative {
            let sens = CGFloat(InputSettings.shared.sensRel)
            relCarryX += dx * sens
            relCarryY += dy * sens
            let ix = Int32(max(-30000, min(30000, relCarryX)))
            let iy = Int32(max(-30000, min(30000, relCarryY)))
            relCarryX -= CGFloat(ix)
            relCarryY -= CGFloat(iy)
            if ix != 0 || iy != 0 { winios_pointer(ix, iy, F_MOVE, 0) }
            return
        }

        let sens = CGFloat(InputSettings.shared.sensAbs)   // desktop px per view pt
        let fallback = SteamOSDisplayProfile.defaultGuestSize()
        let maxX = CGFloat(envInt("MADEIRA_SCREEN_W", Int(fallback.width)) - 1)
        let maxY = CGFloat(envInt("MADEIRA_SCREEN_H", Int(fallback.height)) - 1)
        Self.cursor.x = min(max(Self.cursor.x + dx * sens, 0), maxX)
        Self.cursor.y = min(max(Self.cursor.y + dy * sens, 0), maxY)
        postPointer(F_MOVE | F_ABS)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if settingsGestureActive {
            if activeTouches(event).isEmpty { settingsGestureActive = false }
            return
        }
        guard InputSettings.shared.touchScreenEnabled else { return }

        if InputSettings.shared.directTouch || !desktopMode {
            guard let t = directTouchOwner, touches.contains(t) else { return }
            let (x, y) = mapTouch(t)
            winios_post_touch_up(x, y)
            directTouchOwner = nil
            return
        }
        let now = Date().timeIntervalSinceReferenceDate
        if twoFingerActive {
            if activeTouches(event).isEmpty {
                if !twoFingerMoved && now - twoFingerStartTime < 0.40
                    && !InputSettings.shared.relative {   // ml643: see touchesBegan
                    postPointer(F_RDOWN)
                    postPointer(F_RUP)
                }
                twoFingerActive = false
            }
            return
        }
        touchGeneration += 1   // cancel any pending long-press
        if dragActive {
            if let d = dragTouch, !touches.contains(d) {
                fputs("[trackpad] ended: non-drag finger up (drag continues)\n", stderr)
                return
            }
            fputs("[trackpad] ended: drag drop\n", stderr)
            postPointer(F_LUP)
            dragActive = false
            dragTouch = nil
            return
        }
        // stationary release before the 0.5s drag threshold = click.
        // ml643: NOT in relative mode — every small aim adjustment would fire the
        // weapon. Left/right click are on-screen buttons there instead.
        if !movedBeyondSlop && now - touchStartTime < 0.5 && !InputSettings.shared.relative {
            fputs("[trackpad] ended: click\n", stderr)
            postPointer(F_LDOWN)
            postPointer(F_LUP)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if settingsGestureActive {
            settingsGestureActive = false
            directTouchOwner = nil
            return
        }
        guard InputSettings.shared.touchScreenEnabled else {
            directTouchOwner = nil
            return
        }

        if InputSettings.shared.directTouch || !desktopMode {
            if let t = directTouchOwner {
                let (x, y) = mapTouch(t)
                winios_post_touch_up(x, y)
            }
            directTouchOwner = nil
            return
        }
        fputs("[trackpad] CANCELLED (dragActive=\(dragActive))\n", stderr)
        touchGeneration += 1
        if dragActive { postPointer(F_LUP); dragActive = false }
        dragTouch = nil
        twoFingerActive = false
    }
}

/// Arrow-key button with press/hold/release semantics. DragGesture with
/// zero minimum distance fires onChanged at touch-down (key down once)
/// and onEnded at lift (key up) — unlike Button, which only taps.
struct HoldKeyView: View {
    let label: String
    let vk: Int32
    var big = false   // landscape D-pad: thumb-sized
    @State private var isDown = false

    var body: some View {
        Text(label)
            .font(.system(size: big ? 22 : 14, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .frame(minWidth: big ? 56 : 34, minHeight: big ? 56 : 30)
            .background(Color.white.opacity(isDown ? 0.35 : 0.15))
            .cornerRadius(big ? 12 : 6)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isDown {
                            isDown = true
                            winios_post_key(vk, 1)
                        }
                    }
                    .onEnded { _ in
                        isDown = false
                        winios_post_key(vk, 0)
                    }
            )
    }
}

/// Shared state for the expanded thumbstick pad. The pad cannot be drawn by
/// SwiftUI in place: the game surface is a raw window-level UIView
/// (MetalHostView.shared) sitting ABOVE the entire SwiftUI hierarchy, so a
/// SwiftUI pad centred on the key row gets sliced off wherever it overlaps —
/// no zIndex can fix that, because zIndex only orders siblings *within*
/// SwiftUI. So the pad is hosted in the window too, added after (and thus
/// above) the Metal view, and driven from the SwiftUI button through this.
final class JoystickPadState: ObservableObject {
    static let shared = JoystickPadState()
    @Published var held = false
    @Published var dir: Int = -1
    @Published var center: CGPoint = .zero      // window coordinates
    /// ml641: driven by the pointer panel. The pad is NOT a sibling of the key
    /// row — it lives in its own UIWindow one level up (that is the whole point
    /// of this class), so the row's .transition(.opacity) cannot reach it and it
    /// stayed visible while every other button faded. It has to fade itself.
    @Published var hidden = false
}

/// Window-level host for the pad. Transparent and non-interactive: the
/// SwiftUI button keeps the gesture, this only draws.
enum JoystickPadHost {
    /// Own UIWindow, one level above the app's. Being a sibling subview of
    /// MetalHostView is NOT enough: that view re-adds itself to the window on
    /// every didMoveToWindow (rotation, re-attach) and DXMT/CoreAnimation can
    /// reorder around it, so any subview ordering we impose is only true until
    /// the next layout. A higher windowLevel cannot be undone by anything
    /// inside the app window, so the pad is unconditionally on top.
    ///
    /// Deliberately NOT solved by changing the game surface: the CAMetalLayer
    /// is window-level precisely because SwiftUI hosting silently dropped
    /// presents on iOS 26/27 (see MetalHostView) — that is a rendering
    /// correctness fix and must not be traded away for z-ordering.
    private static var overlay: PassthroughWindow?

    static func attach(to scene: UIWindowScene) {
        if overlay == nil {
            let w = PassthroughWindow(windowScene: scene)
            w.windowLevel = .normal + 100
            w.backgroundColor = .clear
            w.isHidden = false                 // never becomes key: see PassthroughWindow
            let host = UIHostingController(rootView: JoystickPadOverlay())
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            w.rootViewController = host
            overlay = w
        }
        overlay?.frame = scene.coordinateSpace.bounds
    }
}

/// Transparent, fully click-through window: hitTest always returns nil, so
/// touches fall through to the app window underneath and the pad can never
/// steal input from the game surface or the SwiftUI controls.
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// The expanded pad, drawn in window space at the button's location.
struct JoystickPadOverlay: View {
    @ObservedObject private var s = JoystickPadState.shared

    var body: some View {
        GeometryReader { _ in
            // THE one and only joystick face — idle ring and expanded pad are
            // the same view, never two that swap. That identity is what makes
            // it seamless: the diameter and the knob offset are plain animated
            // properties, so releasing lets the knob spring back to centre and
            // keep wiggling after the ring has already shrunk. Two faces
            // cross-fading (one in the button, one here) cannot do that — the
            // wiggle dies with the copy that gets faded out.
            //
            // Fixed-size box at a CONSTANT offset. Deliberately not
            // .position() + .transition(.scale): .position expands the view to
            // fill the parent (so a .center anchor means mid-screen), and an
            // offset that changes in the same transaction as `held` gets
            // animated too — which is what made the pad fly in from the top.
            // Here the only animatable quantities belong to the face itself.
            JoystickFace(held: s.held, dir: s.dir)
                .frame(width: JoystickFace.padRadius * 2,
                       height: JoystickFace.padRadius * 2)
                .offset(x: s.center.x - JoystickFace.padRadius,
                        y: s.center.y - JoystickFace.padRadius)
                .opacity(s.center == .zero ? 0 : 1)
        }
        // MUST ignore the safe area. s.center comes from the button's .global
        // frame, which is measured from the WINDOW origin; without this the
        // overlay's hosting view is inset by the safe area, the offset above
        // is measured from below the status bar, and the pad lands ~59pt too
        // low — roughly one pad radius, which is exactly why it appeared to
        // sit under the game strip instead of centred on the button.
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .opacity(s.hidden ? 0 : 1)
        .animation(.easeInOut(duration: 0.28), value: s.hidden)
        .animation(.spring(response: 0.32, dampingFraction: 0.62), value: s.held)
        .animation(.spring(response: 0.22, dampingFraction: 0.58), value: s.dir)
    }
}

/// The joystick face itself, shared by the in-row idle ring and the expanded
/// window-level pad so both look identical and animate the same way.
struct JoystickFace: View {
    var held: Bool
    var dir: Int
    /// ml646: the portrait pad grows out of a key-sized ring when you hold it.
    /// An overlay stick is a PERMANENT control — it must be full size at rest
    /// with only the knob moving, so size is decoupled from press here rather
    /// than faked by passing held:true (which would also kill the knob travel
    /// and the press styling).
    var alwaysExpanded = false
    private var expanded: Bool { held || alwaysExpanded }

    static let idleDiameter: CGFloat = 22
    static let padRadius: CGFloat = 58
    private var idleDiameter: CGFloat { Self.idleDiameter }
    private var padRadius: CGFloat { Self.padRadius }
    private let knobTravelRatio: CGFloat = 0.30

    @ViewBuilder private var interior: some View {
        if #available(iOS 26.0, *) {
            Circle().fill(.clear).glassEffect(.regular, in: Circle())
        } else {
            Circle().fill(.ultraThinMaterial)
        }
    }

    private func knobOffset(_ d: CGFloat) -> CGSize {
        guard dir >= 0, expanded else { return .zero }
        let travel = d * knobTravelRatio
        let a = Double(dir) * 45.0 * .pi / 180.0
        return CGSize(width: travel * CGFloat(sin(a)), height: -travel * CGFloat(cos(a)))
    }

    var body: some View {
        let d = expanded ? padRadius * 2 : idleDiameter
        return ZStack {
            interior
            Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: expanded ? 2 : 1.5)
            Circle()
                .fill(Color.white)
                .frame(width: d * 0.42, height: d * 0.42)
                .overlay(
                    // Roundness cue. It reads at key size but turns into a
                    // smudge on the big pad, so it fades out as the ring
                    // springs open rather than scaling up with it.
                    Circle()
                        .trim(from: 0.55, to: 0.70)
                        .stroke(Color.black.opacity(0.38),
                                style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                        .padding(d * 0.075)
                        .opacity(expanded ? 0 : 1)
                )
                .offset(knobOffset(d))
        }
        .frame(width: d, height: d)
    }
}

/// On-screen thumbstick. Idle it is a key-sized ring with a white knob;
/// press and hold and it expands into a pad you can steer. Travel snaps to
/// eight d-pad directions, each mapped to the arrow keys Windows games
/// already understand — diagonals simply hold two keys at once — so this
/// needs no new input path: it posts through the same winios_post_key queue
/// as the key buttons, and key state is edge-triggered (only the keys that
/// actually changed are sent on each snap).
///
/// The pad expands DOWNWARD. It must never grow up into the game strip:
/// that surface is a raw window-level UIView (MetalHostView.shared) drawn
/// over SwiftUI, so anything overlapping it is simply covered.
struct JoystickKeyView: View {
    @State private var held = false
    @State private var dir: Int = -1        // -1 = centred, else 0=up then clockwise
    @State private var center: CGPoint = .zero
    @State private var hosted = false       // overlay window up: it draws the face

    private let deadzone: CGFloat = 14      // pt of travel before a direction registers

    private let vkUp: Int32 = 0x26, vkRight: Int32 = 0x27
    private let vkDown: Int32 = 0x28, vkLeft: Int32 = 0x25

    private func keys(for d: Int) -> [Int32] {
        switch d {
        case 0: return [vkUp]
        case 1: return [vkUp, vkRight]
        case 2: return [vkRight]
        case 3: return [vkDown, vkRight]
        case 4: return [vkDown]
        case 5: return [vkDown, vkLeft]
        case 6: return [vkLeft]
        case 7: return [vkUp, vkLeft]
        default: return []
        }
    }

    /// Release what is no longer held, press what newly is — never a blanket
    /// release/re-press, which would make a held direction stutter as the
    /// thumb wanders inside one sector.
    private func apply(_ next: Int) {
        guard next != dir else { return }
        let old = Set(keys(for: dir)), new = Set(keys(for: next))
        for vk in old.subtracting(new) { winios_post_key(vk, 0) }
        for vk in new.subtracting(old) { winios_post_key(vk, 1) }
        dir = next
        JoystickPadState.shared.dir = next
    }

    private func snap(_ t: CGSize) -> Int {
        let d = (t.width * t.width + t.height * t.height).squareRoot()
        if d < deadzone { return -1 }
        // Screen y grows downward; measure clockwise from "up".
        var a = atan2(t.width, -t.height) * 180 / .pi
        if a < 0 { a += 360 }
        return Int((a + 22.5) / 45.0) % 8
    }

    var body: some View {
        // The idle ring lives in the row (inset inside the 34x30 button so it
        // has breathing room). The EXPANDED pad is drawn by the window-level
        // host at this same centre — see JoystickPadState — so it springs out
        // of the button in place and is never clipped by the game surface.
        Color.clear
            .frame(width: 34, height: 30)
            .background(Color.white.opacity(held ? 0.30 : 0.15))
            .cornerRadius(6)
            .overlay { if !hosted { JoystickFace(held: false, dir: -1) } }
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear {
                        center = CGPoint(x: geo.frame(in: .global).midX,
                                         y: geo.frame(in: .global).midY)
                        JoystickPadState.shared.center = center
                        if let scene = UIApplication.shared.connectedScenes
                            .compactMap({ $0 as? UIWindowScene }).first {
                            JoystickPadHost.attach(to: scene)
                            hosted = true
                        }
                    }
                    .onChange(of: geo.frame(in: .global)) { _, f in
                        center = CGPoint(x: f.midX, y: f.midY)
                        JoystickPadState.shared.center = center
                    }
                }
            )
            .animation(.spring(response: 0.32, dampingFraction: 0.62), value: held)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !held {
                            held = true
                            if let scene = UIApplication.shared.connectedScenes
                                .compactMap({ $0 as? UIWindowScene }).first {
                                JoystickPadHost.attach(to: scene)
                            }
                            JoystickPadState.shared.center = center
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                                JoystickPadState.shared.held = true
                            }
                        }
                        apply(snap(g.translation))
                    }
                    .onEnded { _ in
                        apply(-1)                        // releases every held arrow
                        held = false
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                            JoystickPadState.shared.held = false
                        }
                    }
            )
    }
}

// SwiftUI wrapper around the placeholder view.
// iOS software-keyboard → Wine key events. Each character is mapped to a
// US-layout virtual-key (+ shift where needed) and posted as a down/up pair;
// the message queue's ToUnicode then produces the right WM_CHAR. Paths need
// the full symbol set (":" "\" "-" "." "_"), so the table is comprehensive.
extension MetalBackedView: UIKeyInput {
    var hasText: Bool { false }

    // US-keyboard VK + shift for a character. Returns nil for chars we can't map.
    private static func vkForChar(_ ch: Character) -> (Int32, Bool)? {
        if ch == "\n" || ch == "\r" { return (0x0D, false) }   // VK_RETURN
        if ch == "\t" { return (0x09, false) }                 // VK_TAB
        if ch == " " { return (0x20, false) }                  // VK_SPACE
        if ch.isLetter, let up = ch.uppercased().first?.asciiValue, up >= 0x41, up <= 0x5A {
            return (Int32(up), ch.isUppercase)                 // VK_A..VK_Z
        }
        if let a = ch.asciiValue, a >= 0x30, a <= 0x39 {
            return (Int32(a), false)                           // VK_0..VK_9 (unshifted)
        }
        let table: [Character: (Int32, Bool)] = [
            "!": (0x31, true), "@": (0x32, true), "#": (0x33, true), "$": (0x34, true),
            "%": (0x35, true), "^": (0x36, true), "&": (0x37, true), "*": (0x38, true),
            "(": (0x39, true), ")": (0x30, true),
            "-": (0xBD, false), "_": (0xBD, true),
            "=": (0xBB, false), "+": (0xBB, true),
            "[": (0xDB, false), "{": (0xDB, true),
            "]": (0xDD, false), "}": (0xDD, true),
            "\\": (0xDC, false), "|": (0xDC, true),
            ";": (0xBA, false), ":": (0xBA, true),
            "'": (0xDE, false), "\"": (0xDE, true),
            ",": (0xBC, false), "<": (0xBC, true),
            ".": (0xBE, false), ">": (0xBE, true),
            "/": (0xBF, false), "?": (0xBF, true),
            "`": (0xC0, false), "~": (0xC0, true),
        ]
        return table[ch]
    }

    func insertText(_ text: String) {
        for ch in text {
            guard let (vk, shift) = MetalBackedView.vkForChar(ch) else { continue }
            if shift { winios_post_key(0x10, 1) }   // VK_SHIFT down
            winios_post_key(vk, 1)
            winios_post_key(vk, 0)
            if shift { winios_post_key(0x10, 0) }    // VK_SHIFT up
        }
    }

    func deleteBackward() {
        winios_post_key(0x08, 1)   // VK_BACK down
        winios_post_key(0x08, 0)
    }

    // Traits: keep iOS from rewriting path characters.
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
}

/// Pointer settings, persisted to the app container.
///
/// ml641. Two independent sensitivities, because the two modes mean different
/// things and a single slider would fight itself:
///   • absolute  — trackpad gain, desktop px per view pt. This IS the old
///     hardcoded `sens = 2.0`, so the default reproduces today's desktop feel
///     exactly.
///   • relative  — mouse counts per view pt for mouse-look. What the right value
///     is depends on the GAME's own sensitivity and FOV, which we cannot see, so
///     it has to be calibrated by hand once. See the comment in touchesMoved.
///
/// Stored as JSON in Documents/ rather than UserDefaults: that is the container
/// we already know survives reinstall (verified), and it can be pulled and
/// edited with the same devicectl command we use for the log.
final class InputSettings: ObservableObject {
    static let shared = InputSettings()

    @Published var relative: Bool  = false { didSet { save() } }
    @Published var sensAbs:  Double = 2.0  { didSet { save() } }
    @Published var sensRel:  Double = 2.0  { didSet { save() } }

    /// Product input policy. Full-screen touch remains usable even when the
    /// virtual controller overlay is hidden. Direct mode maps finger position
    /// to the Windows surface; trackpad mode preserves Madeira's mouse-look /
    /// scroll / right-click gestures.
    @Published var touchScreenEnabled = true { didSet { save() } }
    @Published var directTouch = true        { didSet { save() } }
    @Published var controllerOverlayEnabled = false { didSet { save() } }

    /// ml649: heavy diagnostics. Default OFF so the shipped default is the fast
    /// path; flip it on only when a run needs to be explainable.
    @Published var diagnostics = false { didSet { madeira_set_diag_enabled(diagnostics ? 1 : 0); save() } }

    /// didSet fires for assignments made in init() because the properties are
    /// already initialised by then; without this the first launch would write
    /// the defaults back over a file it had only half-read.
    private var loading = false

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("madeira-input.json")
    }

    private init() {
        loading = true
        if let d = try? Data(contentsOf: Self.url),
           let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            relative = j["relative"] as? Bool   ?? false
            sensAbs  = j["sensAbs"]  as? Double ?? 2.0
            sensRel  = j["sensRel"]  as? Double ?? 2.0
            touchScreenEnabled = j["touchScreenEnabled"] as? Bool ?? true
            directTouch = j["directTouch"] as? Bool ?? true
            controllerOverlayEnabled = j["controllerOverlayEnabled"] as? Bool ?? false
            diagnostics = j["diagnostics"] as? Bool ?? false
        }
        loading = false
        madeira_set_diag_enabled(diagnostics ? 1 : 0)   // push the restored value down
    }

    private func save() {
        guard !loading else { return }
        let j: [String: Any] = [
            "relative": relative,
            "sensAbs": sensAbs,
            "sensRel": sensRel,
            "touchScreenEnabled": touchScreenEnabled,
            "directTouch": directTouch,
            "controllerOverlayEnabled": controllerOverlayEnabled,
            "diagnostics": diagnostics
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: j) else { return }
        try? d.write(to: Self.url, options: .atomic)
    }
}

struct MadeiraMetalView: UIViewRepresentable {
    func makeUIView(context: Context) -> MetalBackedView {
        return MetalBackedView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    }
    func updateUIView(_ uiView: MetalBackedView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var logStore = LogStore.shared
    @State private var jitStatus: JITStatus = .unknown
    @State private var entitlements: EntitlementStatus?
    @State private var debuggerAttached = isDebuggerAttached()
    @ObservedObject private var input = InputSettings.shared
    @State private var pointerPanel = false
    @State private var steamSettingsPresented = false
    @State private var didStartSteamProduct = false
    @State private var presentBaseline = 0
    @State private var compositorBaseline: UInt64 = 0
    @State private var productState: ProductState = .startingJIT
    @Namespace private var pointerNS

    private enum ProductState: Equatable {
        case startingJIT
        case installingSteam
        case launchingSteam
        case running
        case failed(String)
    }

    enum JITStatus {
        case unknown
        case testing
        case available
        case mappingOnly
        case unavailable
    }

    var body: some View {
        steamProductBody
            .onAppear {
                jit_install_trap_handler()
                TouchControlsHost.attach()
                startSteamAutomatically()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIDevice.orientationDidChangeNotification)) { _ in
                TouchControlsHost.attach()
                MetalBackedView.refreshPresentationGeometry()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification)) { _ in
                // Re-attach window-level overlays and re-run the Metal/touch
                // geometry transform after iOS restores the scene.
                TouchControlsHost.attach()
                MetalBackedView.refreshPresentationGeometry()
                if productState == .running && !steamSettingsPresented {
                    MetalHostView.shared.alpha = 1
                    MetalHostView.shared.isHidden = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .steamOSSettingsRequested)) { _ in
                steamSettingsPresented = true
            }
            .sheet(isPresented: $steamSettingsPresented) {
                SteamSettingsView()
            }
            .onChange(of: steamSettingsPresented) { _, shown in
                // MetalHostView is intentionally window-hosted above SwiftUI.
                // Hide it while native settings are presented so the sheet can
                // never be visually trapped underneath the game surface.
                MetalHostView.shared.isHidden = shown
                TouchControlsHost.setHidden(shown)
                if !shown && productState == .running {
                    MetalHostView.shared.isHidden = false
                }
            }
            .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
                guard productState == .launchingSteam else { return }
                let dxmtReady = Int(madeira_get_present_count()) > presentBaseline
                let steamSurfaceReady = winios_get_surface_present_count() > compositorBaseline
                if dxmtReady || steamSurfaceReady {
                    productState = .running
                    MetalHostView.shared.isHidden = steamSettingsPresented
                    UIView.animate(withDuration: 0.20) {
                        MetalHostView.shared.alpha = 1
                    }
                }
            }
    }

    /// Shipping product root. Users see Steam startup/Steam itself, never the
    /// Madeira diagnostics launcher. Engineering controls remain compiled below
    /// for development but are not reachable through the normal root view.
    private var steamProductBody: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MadeiraMetalView().ignoresSafeArea()

            if productState != .running {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text(productStatusTitle)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(productStatusDetail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.68))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)

                    if case .failed = productState {
                        Button("Retry") {
                            didStartSteamProduct = false
                            startSteamAutomatically()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(24)
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
    }

    private var productStatusTitle: String {
        switch productState {
        case .startingJIT: return "Starting Steam"
        case .installingSteam: return "Installing Steam"
        case .launchingSteam: return "Launching Steam"
        case .running: return ""
        case .failed: return "Steam could not start"
        }
    }

    private var productStatusDetail: String {
        switch productState {
        case .startingJIT:
            return "Preparing local x86/x64 JIT execution. StikDebug may open once."
        case .installingSteam:
            return "Downloading and installing Valve's Windows Steam client."
        case .launchingSteam:
            return "Starting Steam locally through Wine, FEX and Metal."
        case .running:
            return ""
        case .failed(let message):
            return message
        }
    }

    @MainActor
    private func startSteamAutomatically() {
        guard !didStartSteamProduct else { return }
        didStartSteamProduct = true
        productState = .startingJIT
        presentBaseline = Int(madeira_get_present_count())
        compositorBaseline = winios_get_surface_present_count()
        MetalHostView.shared.alpha = 0
        MetalHostView.shared.isHidden = false

        if jit_check_debugged() {
            launchSteamProductRuntime()
            return
        }

        StikJITHelper.enableJIT { success in
            DispatchQueue.main.async {
                if success {
                    self.launchSteamProductRuntime()
                } else {
                    self.productState = .failed(
                        "JIT is required for local Windows execution. Install/open StikDebug and retry.")
                }
            }
        }
    }

    @MainActor
    private func launchSteamProductRuntime() {
        unsetenv("MADEIRA_STEAM_APP_PATH")
        unsetenv("MADEIRA_STEAM_APP_ID")

        guard SteamOSRuntimeGate.validate(log: logStore) else {
            productState = .failed("Local JIT/Metal runtime validation failed. Re-enable JIT and retry.")
            return
        }

        let steamSize = preferredSteamDesktopSize()
        let deskW = steamSize.width
        let deskH = steamSize.height
        logStore.log("Steam auto-start display target: \(deskW)x\(deskH)")

        if !steamIsInstalled() {
            productState = .installingSteam
            Task { @MainActor in
                await bootstrapSteamFirstRun(deskW: deskW, deskH: deskH)
                if case .failed = self.productState { return }
                self.productState = .launchingSteam
            }
            return
        }

        guard prepareSteamLaunch() else {
            productState = .failed("The installed Steam runtime could not be prepared.")
            return
        }
        configureSteamProductRuntime(batch: "steam-launch.bat", deskW: deskW, deskH: deskH)
        productState = .launchingSteam
        runWineFullSequence()
    }

    /// Portrait: classic tooling layout — header, badges, 240pt game strip,
    /// key row, action buttons, log console.
    private var portraitBody: some View {
        VStack(spacing: 0) {
            // Readouts sit ABOVE the game strip, closest to the surface they
            // describe: entitlement indicators, then the present/FPS readout,
            // then the surface itself. (Only the KEY row stays below — it is
            // input, not instrumentation.)
            //
            // NOTE: the surface is a raw window-level view positioned over the
            // placeholder (MetalHostView.shared), so SwiftUI content laid "on
            // top" of the strip is covered — these rows must be siblings above
            // it, never overlays on it.
            if let ents = entitlements {
                entitlementBadges(ents)
            }
            HStack(spacing: 6) {
                FPSOverlay()
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            MadeiraMetalView()
                .frame(height: 240)
                .background(Color.black)
                .onAppear { TouchControlsHost.attach() }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIDevice.orientationDidChangeNotification)) { _ in
                    TouchControlsHost.attach()   // re-frame to the new bounds
                }
            HStack(spacing: 6) {
                if pointerPanel {
                    // The cursor button has slid to the leftmost slot and become
                    // the close control; matchedGeometryEffect animates the slide.
                    pointerToggleButton
                    pointerModeToggle
                    pointerSensSlider
                } else {
                    Group {
                        keyButton("⏎", vk: 0x0D)   // VK_RETURN
                        keyButton("␣", vk: 0x20)   // VK_SPACE
                        keyButton("Esc", vk: 0x1B) // VK_ESCAPE
                        Button { MetalBackedView.toggleKeyboard() } label: {
                            Text("⌨").font(.system(size: 20))
                                .frame(minWidth: 40, minHeight: 32)
                                .background(Color.secondary.opacity(0.25))
                                .cornerRadius(6)
                        }
                        JoystickKeyView()
                    }
                    .transition(.opacity)
                    pointerToggleButton
                    diagToggleButton
                    Spacer()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            // The expanded pad overflows this row; without a raised zIndex the
            // later VStack siblings (action buttons, log) would draw over it.
            .zIndex(10)
            Divider()
            actionButtons
            Divider()
            logConsole
        }
    }

    /// Landscape game/Steam mode. The placeholder fills the physical display;
    /// MetalBackedView then aspect-fits the ACTIVE guest resolution. On a wide
    /// iPhone the Windows surface is wide, so it fills the panel. On iPad the
    /// chosen desktop is naturally close to 4:3. Touch controls live in their
    /// own transparent UIWindow above the Metal host and use normalized
    /// coordinates, so the same controller profile survives device changes.
    private var landscapeBody: some View {
        ZStack {
            Color.black
            MadeiraMetalView()
        }
        .ignoresSafeArea()
        .background(Color.black)
    }

    /// Hold-to-press key: VK down on touch, VK up on release — for keys
    /// games treat as held (arrows). Same winios queue as keyButton.
    private func holdKeyButton(_ label: String, vk: Int32, big: Bool = false) -> some View {
        HoldKeyView(label: label, vk: vk, big: big)
    }

    /// Small on-screen key: posts VK down, then up 60ms later, through the
    /// winios input queue (same path as touch→mouse).
    // ml641 pointer panel ------------------------------------------------
    private var pointerToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.28)) { pointerPanel.toggle() }
            // The window-level pad fades itself; see JoystickPadState.hidden.
            JoystickPadState.shared.hidden = pointerPanel
        } label: {
            Image(systemName: pointerPanel ? "xmark" : "cursorarrow")
                .font(.system(size: 17, weight: .medium))
                .frame(minWidth: 40, minHeight: 32)
                .background(Color.secondary.opacity(0.25))
                .cornerRadius(6)
        }
        .matchedGeometryEffect(id: "pointerBtn", in: pointerNS)
    }

    /// ml649: heavy diagnostics on/off, live. Stroke icon, dimmed when quiet —
    /// same visual language as the controls-visibility button.
    private var diagToggleButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            input.diagnostics.toggle()
        } label: {
            Image(systemName: "ladybug")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.white.opacity(input.diagnostics ? 1.0 : 0.35))
                .frame(minWidth: 40, minHeight: 32)
                .background(Color.secondary.opacity(0.25))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private var pointerModeToggle: some View {
        Button {
            input.relative.toggle()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Text(input.relative ? "Relative" : "Absolute")
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 82, minHeight: 32)
                .background((input.relative ? Color.accentColor : Color.secondary).opacity(0.28))
                .cornerRadius(6)
        }
        .transition(.opacity)
    }

    /// One slider bound to whichever mode is live, so the two values are edited
    /// independently and both persist.
    private var pointerSensSlider: some View {
        HStack(spacing: 8) {
            Slider(value: input.relative ? $input.sensRel : $input.sensAbs, in: 0.10...8.0)
            Text(String(format: "%.2f", input.relative ? input.sensRel : input.sensAbs))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    /// ml896: NOT a Button. A Button's press highlight is an implicit animation,
    /// and SwiftUI renders animations on its AsyncRenderer thread, which needs a
    /// CAPresentationModifierGroup, whose shared memory comes from a tagged
    /// purgable vm_allocate that fails once a game is running (three crash
    /// reports, all in commitAsyncValues force-unwrapping that nil). HoldKeyView
    /// changes only a colour with no animation, so it stays on the main-thread
    /// render path the rest of this UI already uses for minutes without harm.
    /// Down at touch, up at lift, which is also the correct key semantics.
    private func keyButton(_ label: String, vk: Int32) -> some View {
        HoldKeyView(label: label, vk: vk)
    }

    private func entitlementBadges(_ ents: EntitlementStatus) -> some View {
        HStack(spacing: 8) {
            // Live debugger/JIT state, not the (macOS-only, never granted on
            // iOS) allow-jit entitlement the old badge checked.
            entitlementBadge("JIT", granted: debuggerAttached)
            entitlementBadge("Memory+", granted: ents.increasedMemory)
            entitlementBadge("64-bit VA", granted: ents.extendedVA)
            Spacer()
            // Device model rides in this row (the old standalone statusHeader
            // row above it spent ~50pt of vertical space on nothing else).
            VStack(alignment: .trailing, spacing: 0) {
                Text("Device")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(deviceInfo)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            debuggerAttached = isDebuggerAttached()
        }
    }

    private func entitlementBadge(_ label: String, granted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(granted ? .green : .orange)
                .font(.caption2)
            Text(label)
                .font(.caption2)
                .foregroundColor(granted ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(granted ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
        )
    }

    private func logEntitlementStatus() {
        guard let ents = entitlements else { return }
        logStore.log("Checking entitlements...")
        logStore.log("  allow-jit: \(ents.jitAllowed)", level: ents.jitAllowed ? .success : .error)
        logStore.log("  increased-memory-limit: \(ents.increasedMemory)", level: ents.increasedMemory ? .success : .debug)
        logStore.log("  extended-virtual-addressing: \(ents.extendedVA)", level: ents.extendedVA ? .success : .debug)
        if !ents.extendedVA {
            logStore.log("  Tip: Use GetMoreRam to inject extended-virtual-addressing", level: .info)
        }
    }


    /// Choose a performance-oriented Windows desktop that matches the physical
    /// device aspect instead of forcing 4:3 everywhere. iPhone uses a 720-line
    /// render target; iPad uses 900 lines. Both are deliberately below native
    /// panel resolution so Steam/CEF and games do not pay Retina-resolution GPU
    /// and memory cost just to fill the display.
    private func preferredSteamDesktopSize() -> (width: Int, height: Int) {
        SteamOSDisplayProfile.preferredDesktopSize()
    }

    private var actionButtons: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Button("Enable JIT") {
                    enableJITViaStikDebug()
                }
                .buttonStyle(.borderedProminent)

                Button("Steam Settings") {
                    steamSettingsPresented = true
                }
                .buttonStyle(.bordered)

                Button("Steam") {
                    // Real Steam owns AppID/game identity for every child it launches.
                    // Clear any host-only standalone regression override before entering
                    // the Steam client path.
                    unsetenv("MADEIRA_STEAM_APP_PATH")
                    unsetenv("MADEIRA_STEAM_APP_ID")

                    // Steam S3 first boot: virtual desktop (Steam needs a
                    // window manager) + services.exe (SCM → rpcss for Steam's
                    // COM, the chain proven in the rpcss milestone) + steam.exe
                    // itself, all launched by C:\steam-launch.bat (pushed to
                    // the prefix). Batch avoids quote-escaping hell; combase's
                    // 5s OpenSCManager retry covers the services-vs-steam race.
                    // First run: download Valve's official Windows SteamSetup.exe
                    // into C:\ and execute it through Madeira's shipped WoW64 path
                    // (wow64.dll + wow64win.dll + xtajit.dll). Later runs launch
                    // the installed Steam client directly. CEF remains jitless
                    // until its runtime-x86 JIT path is stable under FEX.
                    let steamSize = preferredSteamDesktopSize()
                    let deskW = steamSize.width, deskH = steamSize.height
                    logStore.log("Steam display target: \(deskW)x\(deskH) for \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")")
                    if !steamIsInstalled() {
                        Task { @MainActor in
                            await bootstrapSteamFirstRun(deskW: deskW, deskH: deskH)
                        }
                        return
                    }
                    // Installed path: regenerate C:\steam-launch.bat and launch
                    // Steam inside the existing Madeira/Wine pseudo-process model.
                    guard prepareSteamLaunch() else { return }
                    configureSteamProductRuntime(batch: "steam-launch.bat",
                                                 deskW: deskW, deskH: deskH)
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button("Wine Virtual Desktop") {
                    // S3-pre R2v2: raw rpcss.exe CANNOT run standalone —
                    // its wmain unconditionally StartServiceCtrlDispatcherW's
                    // (rpcss_main.c:282), which RPCs back to the SCM; without
                    // services.exe it raised + wedged in
                    // service_run_main_thread, and explorer's
                    // CoRegisterClassObject wedged behind it (seq-3680 run).
                    // Proper bootstrap: explorer's cmdline child = services.exe
                    // (SCM host, windows-subsystem = no console). It creates
                    // \pipe\svcctl early, runs auto-start services (MountMgr/
                    // Eventlog/NDIS/nsiproxy/PlugPlay — winedevice/plugplay
                    // are bundled; failures tolerated), and combase's
                    // start_rpcss then demand-starts RpcSs through the SCM
                    // with a 30s start-pending wait → rpcss runs as services'
                    // child (3-deep tree, proven depth) with a proper
                    // dispatcher connection → epmapper up → real COM.
                    // Known risk: if shellwindows_init beats services.exe's
                    // RPC_Init, OpenSCManager fails → watch whether that
                    // fails fast or hits the RaiseException→CS wedge again.
                    // ml1127: `desktop-size = WxH` in madeira.cfg; 960x540 otherwise.
                    var deskW = 960, deskH = 540
                    if let txt = MadeiraConfig.get("desktop-size") {
                        let p = txt.lowercased().split(separator: "x").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                        if p.count == 2, p[0] >= 640, p[1] >= 360, p[0] <= 3840, p[1] <= 2160 { deskW = p[0]; deskH = p[1] }
                    }
                    setenv("MADEIRA_EXE", "explorer.exe", 1)
                    setenv("MADEIRA_ARGS",
                           "/desktop=shell,\(deskW)x\(deskH) C:\\windows\\system32\\services.exe", 1)
                    setenv("MADEIRA_DESKTOP", "1", 1)
                    setenv("MADEIRA_SCREEN_W", String(deskW), 1)
                    setenv("MADEIRA_SCREEN_H", String(deskH), 1)
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.mint)

                // ml741: Stray (UE4). Launch the shipping binary DIRECTLY rather
                // than Stray.exe -- the launcher builds its child's command line
                // itself and passed only "Hk_project", so Unreal picked its
                // default RHI. That default is DX12 for this title and we only
                // implement D3D11, which is why the first run sat on an
                // unsignalled event for 97s at startup instead of failing loudly.
                //
                // Args are overridable at runtime from Documents/madeira-args.txt
                // so UE4 flags can be tried without a rebuild; the string below is
                // the default when that file is absent.
                Button("Stray (UE4, -dx11)") {
                    setenv("MADEIRA_EXE",
                           "C:\\Program Files\\Stray\\Hk_project\\Binaries\\Win64\\Stray-Win64-Shipping.exe", 1)
                    var args = "Hk_project -dx11 -windowed"
                    if let txt = MadeiraConfig.get("args") {
                        let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !v.isEmpty { args = v }
                    }
                    setenv("MADEIRA_ARGS", args, 1)
                    unsetenv("MADEIRA_DESKTOP")
                    logStore.log("Stray: args = \(args)")
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                // Valley of the Ancient (UE5). Like Stray, the LAUNCHER builds its
                // own child command line and passes only the project name, so any
                // flag we want has to go on the shipping binary directly. Measured
                // from a real run: AncientGame.exe spawns
                //   AncientGame-Win64-Shipping.exe ValleyoftheAncient
                // and nothing else, which is why the launcher is skipped here.
                //
                // Flags come from Documents/madeira-valley-args.txt so a UE switch
                // can be tried without rebuilding and reinstalling. The default
                // carries -ansimalloc because the first two runs both died with
                //   FMallocBinned2 Attempt to free an unrecognized block 885560000
                // at the same address, before any RHI work. Selecting a different
                // allocator says whether that is Binned2's own bookkeeping or a
                // genuine bad free; delete the flag to reproduce the fatal.
                Button("Valley of the Ancient (UE5)") {
                    setenv("MADEIRA_EXE",
                           "C:\\Program Files\\Valley of the Ancient - DX12\\ValleyoftheAncient\\Binaries\\Win64\\AncientGame-Win64-Shipping.exe", 1)
                    var args = "ValleyoftheAncient -windowed -ansimalloc"
                    if let txt = MadeiraConfig.get("valley-args") {
                        let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !v.isEmpty { args = v }
                    }
                    setenv("MADEIRA_ARGS", args, 1)
                    unsetenv("MADEIRA_DESKTOP")
                    logStore.log("Valley: args = \(args)")
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.mint)

                Button("Thumper (standalone)") {
                    // Game lives at Documents/wine/drive_c/Program Files/Thumper/.
                    // This standalone regression path needs the title identity that the
                    // real Steam client would normally provide to its child process.
                    // WineProcessBridge consumes these overrides once and clears them.
                    setenv("MADEIRA_STEAM_APP_PATH", "C:\\Program Files\\Thumper", 1)
                    setenv("MADEIRA_STEAM_APP_ID", "356400", 1)
                    setenv("MADEIRA_EXE",
                           "C:\\Program Files\\Thumper\\THUMPER_win10.exe", 1)
                    unsetenv("MADEIRA_ARGS")
                    unsetenv("MADEIRA_DESKTOP")
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)

                Button("x64 DX11 cube") {
                    setenv("MADEIRA_EXE", "cube-x64.exe", 1)
                    unsetenv("MADEIRA_ARGS")
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)

                // madeira-d3d12 M2: an x86-64 guest driving the ARM64EC D3D12
                // runtime. Creates device/queue/allocator/list/fence, records
                // and closes an empty list, executes it, signals a fence and
                // wakes an event waiter, plus the refusal cases. Prints a build
                // marker naming which architecture it actually reached, which
                // states the loader question as evidence rather than assumption.
                // The visible one: an x86-64 Windows program drawing a rotating
                // cube through our D3D12 interfaces and presenting into the
                // host window. Shaders are still matched fixtures rather than
                // runtime-converted DXIL, which the window title states.
                Button("D3D12 cube") {
                    setenv("MADEIRA_EXE", "d3d12-cube-x64.exe", 1)
                    unsetenv("MADEIRA_ARGS")
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)

                Button("D3D12 M2 ABI") {
                    setenv("MADEIRA_EXE", "d3d12-m2-x64.exe", 1)
                    unsetenv("MADEIRA_ARGS")
                    unsetenv("MADEIRA_DESKTOP")
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)

                // ml731c: one-second check of the Windows clock contract
                // (GetTickCount64 / system time / unbiased interrupt time /
                // QueryPerformanceCounter). Verifying this by hand previously
                // cost a five-minute game run plus a control-log comparison,
                // and the game is too unstable to serve as a measuring tool.
                // Each clock is checked separately so a partial failure names
                // itself: QPC passing alone is the shared-page signature.
                Button("x64 clock test") {
                    setenv("MADEIRA_EXE", "clocktest-x64.exe", 1)
                    unsetenv("MADEIRA_ARGS")
                    unsetenv("MADEIRA_DESKTOP")
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)

                // ml1131: per-call cost of the imports the game's critical threads
                // live in (GetLastError, QPC, SetEvent, critical sections, heap,
                // event ping-pong, contended sections). Results in the log and in
                // C:\calltest.txt.
                Button("x64 call cost") {
                    setenv("MADEIRA_EXE", "calltest-x64.exe", 1)
                    unsetenv("MADEIRA_ARGS")
                    unsetenv("MADEIRA_DESKTOP")
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)

                Button("arm64 DX11 cube") {
                    runTriangleTest()
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Button("Clear Log") {
                    logStore.clear()
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding()
        }
    }

    private func runTriangleTest() {
        logStore.log("D3D11 triangle test: full sequence", level: .info)
        // Reuse the existing full Wine sequence but target triangle.exe.
        // WineProcessBridge has the program baked in for now — to flip it
        // requires a signature change. For this iteration we rely on the
        // build's WineProcessBridge.m pointing at triangle.exe.
        runWineFullSequence()
    }

    private var logConsole: some View {
        let entries = logStore.entries.sorted(by: { $0.lastTimestamp > $1.lastTimestamp })
        return List(entries) { entry in
            HStack(alignment: .top, spacing: 8) {
                // Timestamp of LAST occurrence
                Text(timeString(entry.lastTimestamp))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 64, alignment: .leading)
                // Level chip
                Text(entry.level.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(colorForLevel(entry.level))
                    .frame(width: 28, alignment: .leading)
                // Last raw message (the most recent line that matched this signature)
                Text(entry.lastRaw)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                // Count badge (only if count > 1)
                if entry.count > 1 {
                    Text("×\(entry.count)")
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                        .foregroundColor(.secondary)
                }
            }
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        }
        .listStyle(.plain)
    }

    // ml540: ONE formatter for the whole app, built once on first use.
    //
    // This used to construct a fresh DateFormatter on every call — once per log
    // row per body evaluation — and each new instance opens ICU underneath
    // (udat_open -> SimpleDateFormat::initialize). That is not just wasteful,
    // it is where ml539 died: after Wine's main thread exited, ICU ran
    // _platform_strcmp on a pointer into that dead thread's stack (x0 sat 0x68C
    // below its recorded tsd_base) and took the whole app down. A single
    // long-lived formatter does the ICU open ONCE, at first log render, long
    // before Wine exists.
    private static let hhmmss: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // Main-thread only (SwiftUI body evaluation) — DateFormatter is not safe to
    // share across threads.
    private func timeString(_ date: Date) -> String {
        ContentView.hhmmss.string(from: date)
    }

    private var statusColor: Color {
        switch jitStatus {
        case .unknown: return .gray
        case .testing: return .yellow
        case .available: return .green
        case .mappingOnly: return .orange
        case .unavailable: return .red
        }
    }

    private var statusText: String {
        switch jitStatus {
        case .unknown: return "Not tested"
        case .testing: return "Testing..."
        case .available: return "Available"
        case .mappingOnly: return "Needs debugger"
        case .unavailable: return "Unavailable"
        }
    }

    private var deviceInfo: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        return machine
    }

    private func colorForLevel(_ level: LogStore.LogEntry.Level) -> Color {
        switch level {
        case .info: return .blue
        case .success: return .green
        case .error: return .red
        case .debug: return .gray
        }
    }

    private func runJITTest() {
        jitStatus = .testing
        logStore.log("Starting JIT test...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = jit_test_execute()

            DispatchQueue.main.async {
                switch result {
                case 42:
                    jitStatus = .available
                    logStore.log("JIT is fully functional!", level: .success)
                case -2:
                    jitStatus = .unavailable
                    logStore.log("CS_DEBUGGED not set. Use StikDebug to enable JIT for this app.", level: .error)
                    DispatchQueue.global(qos: .userInitiated).async {
                        let mappingOk = jit_test_mapping()
                        DispatchQueue.main.async {
                            if mappingOk {
                                jitStatus = .mappingOnly
                                logStore.log("Dual mapping works. Enable JIT via StikDebug to unlock execution.", level: .success)
                            }
                        }
                    }
                case -3:
                    jitStatus = .unavailable
                    logStore.log("Fault loop detected — try 'Test JIT (Alt)' for debugger-allocated memory", level: .error)
                default:
                    jitStatus = .unavailable
                    logStore.log("JIT test failed with result: \(result)", level: .error)
                }
            }
        }
    }

    private func runJITTestStrategy2() {
        jitStatus = .testing
        logStore.log("Starting JIT test (Strategy 2: debugger-allocated RX)...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = jit_test_execute_strategy2()

            DispatchQueue.main.async {
                switch result {
                case 42:
                    jitStatus = .available
                    logStore.log("JIT is fully functional (strategy 2)!", level: .success)
                case -2:
                    jitStatus = .unavailable
                    logStore.log("CS_DEBUGGED not set. Use StikDebug to enable JIT.", level: .error)
                case -3:
                    jitStatus = .unavailable
                    logStore.log("Fault loop — debugger-allocated pages also rejected", level: .error)
                default:
                    jitStatus = .unavailable
                    logStore.log("Strategy 2 failed with result: \(result)", level: .error)
                }
            }
        }
    }

    private func enableJITViaStikDebug() {
        jitStatus = .testing
        logStore.log("Requesting JIT via StikDebug URL scheme...")

        StikJITHelper.enableJIT { success in
            if success {
                jitStatus = .available
                logStore.log("JIT enabled! Debugger attached.", level: .success)
            } else {
                jitStatus = .unavailable
                logStore.log("Failed to enable JIT via StikDebug", level: .error)
            }
        }
    }

    /// Full sequence: allocate JIT pool, start wineserver, start Wine.
    /// Debugger stays attached during PE loading so mprotect_exec can use BRK
    /// to prepare code pages. Detach happens after Wine finishes + recovery.
    private func runWineFullSequence() {
        guard SteamOSRuntimeGate.validate(log: logStore) else {
            productState = .failed("Local JIT/Metal runtime validation failed before Windows launch.")
            return
        }
        /* ml1095: one config file. Written once from any legacy madeira-*.txt. */
        MadeiraConfig.migrateLegacy { self.logStore.log($0) }
        MadeiraConfig.deleteLegacyFiles { self.logStore.log($0) }   /* ml1096: the old files go once the cfg exists */
        if MadeiraConfig.present {
            let cfg = MadeiraConfig.all().sorted { $0.key < $1.key }
            logStore.log("madeira.cfg: " + (cfg.isEmpty ? "(empty)" : cfg.map { "\($0.key)=\($0.value)" }.joined(separator: " ")))
        } else {
            logStore.log("madeira.cfg absent: legacy madeira-*.txt files apply")
        }

        logStore.log("Running full Wine sequence...")

        // Start a main thread heartbeat to diagnose hang
        var heartbeatCount = 0
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            heartbeatCount += 1
            os_log("[HEARTBEAT] main thread alive #%d", heartbeatCount)
        }

        // Pause UI flushing — prevents ALL SwiftUI re-renders during Wine execution,
        // so zero main thread hang time accumulates while debugger is attached
        logStore.uiPaused = true

        // Suppress os_log from wineserver — hundreds of messages/sec cause os_log buffer
        // contention that blocks the main thread RunLoop, triggering iOS hang detection
        ws_log_quiet = 1

        DispatchQueue.global(qos: .userInitiated).async {
            // Step 1: Allocate JIT pool (BRK suspends entire process)
            // 128 MB was enough for cube but Thumper exhausts it (more PE
            // copies + larger FEX block cache). Desktop mode holds the
            // session's aarch64 image set AND every child's x64 set AND the
            // FEX code buffers in ONE pool: Thumper-under-desktop hit 199MB
            // of image copies alone (2026-07-06), leaving the FEX tail carve
            // colliding with the head. 384 MB fits both plus slack; the pool
            // is dual-map + NO_FOOTPRINT so unwritten pages cost nothing.
            //
            // 2026-07-10 (Steam S3): 384 MB is VIRTUAL-exhausted by Steam's
            // pseudo-process fan-out — steam.exe + services + rpcss + cmd +
            // conhost + steamerrorreporter64 each copy their whole DLL set
            // (owner-keyed, no .text sharing yet) → 138 image copies hit
            // ~365 MB and the crash reporter's ntdll can't fit → the load
            // fails and execution BUS-faults on the un-committed image. Since
            // the pool is jetsam-exempt + demand-committed (unwritten pages
            // cost nothing), raising the VIRTUAL cap is a cheap, safe unblock.
            // 640 MB clears the current fan-out with headroom to reach the
            // ole32 delay-load (FEX riprel probe) and beyond. The real fix for
            // the PHYSICAL duplication is .text sharing (deferred project).
            //
            // 2026-07-10 pm (task #34 / CEF): 896 MB — libcef.dll's 212MB
            // pool copy EXHAUSTED 640 (bump 412MB + no contiguous 212MB →
            // libcef load degraded → init CHECK). Pure-x64 skip-copy was
            // trialed and reverted (broke x18-trampoline layout, ml68);
            // until skip-copy or .text sharing lands, buy headroom. Virtual
            // is jetsam-exempt; the copy itself is ~212MB real RSS when
            // written.
            // 2026-08-01 (ml364): 1152 MB — ml363 died at MSM depth on pool
            // EXHAUSTION (bump 858MB, freelist 0, tail-reserve 64MB) when
            // Chrome's in-proc GPU thread requested a doubled 32MB EC code
            // buffer; the fallback landed non-executable in the guest band and
            // FEX scribbled through a garbage CodeBuffer. NOTE the jetsam
            // ledger note above is STALE: the pool was never exempt and
            // arrives FULLY DIRTY from StikDebug's TXM blessing writes, so
            // this +256MB costs +256MB of the 4096MB budget up front. The
            // ml362/ml363 footprint work (peak 3804→3190) is what pays for
            // it. The real fix for both sides is still .text sharing.
            // 2026-08-01 (ml367): back to 896 MB. ml364 needed 1152 because the
            // shipped PE DLLs carried DWARF debug sections (llvm-mingw links
            // -Wl,-debug:dwarf) and the pool copies the ENTIRE image, so 42% of
            // every copy was debug info with no runtime purpose. Stripping them
            // (llvm-strip --strip-debug over the bundle) drops projected peak
            // pool use 894 -> ~653 MB, so 896 restores the ml364-equivalent
            // headroom (~243 MB) while returning 256 MB of footprint — the pool
            // is dirty from birth, so its SIZE is what costs, not its usage.
            // KEEP ios_usable_va_floor PAIRED: 896MB -> 0x7038000000.
            // 2026-08-02 (ml421): 1024 MB. ml420 (post-#69-fix, deepest run yet:
            // cycle 41) refilled the stripped 896 pool anyway — head 768MB of
            // copies + 176MB tail of EC code buffers collided; the doubled 32MB
            // GPU-thread buffer was refused and the ml361/ml363 ClearCache
            // wild-write returned (now also honestly REFUSED unix-side,
            // rev=ml421). +128MB is the depth lever that fits under jetsam:
            // ml420 peaked 3837 phys; 3837+128=3965 < 4096. Tight — if jetsam
            // returns, the durable fix is .text sharing, not more pool.
            // 2026-08-02 (ml423): BACK to 896. Jetsam DID return — ml422 died a
            // silent EXC_RESOURCE kill at 2.5min (peak 3904, log stops mid-line),
            // exactly the predicted cost of the +128MB dirty-at-birth pool.
            // ml421's honest EC_CODE refusal makes pool exhaustion GRACEFUL now
            // (ctor halving, worst case one thread's 0xdead fault) while jetsam
            // kills the whole app — 896 + graceful degradation strictly beats
            // 1024 + jetsam roulette. Durable fix remains .text sharing.
            // KEEP ios_usable_va_floor PAIRED: 896MB -> 0x7038000000.
            // 2026-08-03 (ml458): STAY at 896 — growth is closed for good.
            // jetsam killed 1024 twice (ml422 peak 3904) and the no-footprint
            // exemption is unreachable: all four (entry-flags, owner) variants
            // return kr=4, and the plain ones expose why — the named entry
            // covers 16KB of the 896MB object, i.e. the kernel wants an entry
            // naming the WHOLE object, which we can never build over memory
            // whose object StikDebug created. Pool stays dirty-from-birth and
            // jetsam-counted, so SIZE is the cost and 896 is the ceiling.
            // ⛔ ml457 re-trialed pure-x64 skip-copy (already dead per ml68
            // above) and it failed again for a different reason: x64 guest
            // RIPs ARE pool-copy aliases, so the copy is the execution
            // substrate — steam.exe died in seconds. Do not try a third time.
            // The remaining levers are USE-side: the 276MB of duplicate copies
            // (.text sharing) and the 214MB tail of EC code buffers.
            // ml668: RUNTIME-SELECTABLE. 896 stays the default and the only
            // value proven for Steam/CEF. 384 is the direct-game experiment:
            // the last good Book of the Dead run used ~139MB of head + ~48MB
            // of tail, so 384 leaves ~197MB of observed slack while returning
            // ~512MB of footprint -- and the pool is dirty from birth, so its
            // SIZE is the cost, not its usage. The VA floor is no longer a
            // hand-paired constant (ml668 derives it from the pool actually
            // allocated), so changing this is now a one-line change.
            // Override lives in Documents/madeira-pool.txt (a bare number of MB)
            // so it can be swapped between runs without a rebuild, and deleting
            // the file reverts to the proven default. Clamped to sane values --
            // a typo here would otherwise move the VA floor with it.
            var poolSizeMB = 896
            if let txt = MadeiraConfig.get("pool"),
               let mb = Int(txt.trimmingCharacters(in: .whitespacesAndNewlines)),
               mb >= 256, mb <= 1152 {
                poolSizeMB = mb
                logStore.log("JIT pool overridden to \(mb)MB via madeira.cfg pool")
            }
            // ml694: W^X A/B switch. Documents/madeira-wx.txt containing "0"
            // disables page demotion for the SAME binary, so the on/off
            // comparison needs one rebuild, not two. The previous gate read
            // container paths that can never exist, so it silently forced
            // ENABLED and no A/B was actually possible.
            if let txt = MadeiraConfig.get("wx") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("MADEIRA_WX", v, 1)
                logStore.log("W^X override: MADEIRA_WX=\(v) via madeira.cfg wx")
            }

            // ml727: wine-mono backpatcher bridge A/B. Documents/madeira-mono-bridge.txt
            // == "1" sets MADEIRA_WINEMONO_BRIDGE, which arms FEX's Mono code-patching
            // optimisation for wine-mono (recognised since ml712 but activation left
            // opt-in because the bridge reclassifies an XCHG from a true atomic exchange
            // into an alias-directed plain write).
            //
            // Worth arming here: the dominant fault site emits SWPAL, which is exactly
            // what FEX generates for a guest XCHG, and the patching XCHGs sit inside
            // libmono -- so the bridge's "RIP must lie inside Mono" test should pass.
            if let txt = MadeiraConfig.get("mono-bridge") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_WINEMONO_BRIDGE", v, 1)
                    logStore.log("Mono bridge: MADEIRA_WINEMONO_BRIDGE=\(v) via madeira.cfg mono-bridge")
                }
            }

            // ml716: syscall-frame context A/B. Documents/madeira-ctx-frame.txt == "1"
            // makes ios_fill_thread_context() report a thread parked inside a syscall
            // using its saved Wine syscall frame (TEB+0x378) instead of the Mach-O
            // registers it happens to be executing. Off by default; native code reads
            // only the environment variable.
            if let txt = MadeiraConfig.get("ctx-frame") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_CTX_FRAME", v, 1)
                    logStore.log("Context source: MADEIRA_CTX_FRAME=\(v) via madeira.cfg ctx-frame")
                }
            }

            // ml744: DXMT options passthrough. Documents/madeira-dxmt.txt is copied
            // verbatim into DXMT_CONFIG, which the renderer's config parser reads as
            // inline "key=value" lines, so options can be tried without a rebuild.
            // d3d11.mipClampBC=N is the one that matters for memory: this GPU cannot
            // sample BC, so those textures are expanded to uncompressed and cost 2-8x
            // their shipped size.
            if let txt = MadeiraConfig.get("dxmt") {
                let v = txt.replacingOccurrences(of: ";", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)   /* ml1095: "a=b;c=d" on one line */
                if !v.isEmpty {
                    setenv("DXMT_CONFIG", v, 1)
                    logStore.log("DXMT config: \(v) via madeira.cfg dxmt")
                }
            }

            // D3D9 frontend for 32-bit programs. The i386 d3d9.dll is DXMT's thin
            // shim; unset (the default) or "emulated", it forwards every export to
            // d3d9-emulated.dll, DXMT's D3D9 frontend built for i386 and translated
            // by FEX like the program. "native" makes the shim bind its unix side
            // and run the frontend as native ARM64 code in libdxmt_combined.a.
            // Only the i386 shim reads MADEIRA_D3D9; 64-bit programs are unaffected.
            if let txt = MadeiraConfig.get("d3d9") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_D3D9", v, 1)
                    logStore.log("D3D9 frontend: MADEIRA_D3D9=\(v) via madeira.cfg d3d9")
                }
            }

            // ml734: Theorafile call tracer. Documents/madeira-tf-trace.txt == "1"
            // redirects libtheorafile's tf_* exports through wrappers in
            // tftrace-x64.dll that call the original and report the RETURN
            // value. The intro decodes and plays, the stream reaches a clean
            // end of file, the decoder stops reading -- and the game never
            // leaves VideoContext. File EOF is not decoder EOS, and a call
            // count cannot tell "tf_eos returns false forever" from "it returns
            // true and the managed side ignores it". Only the return value can.
            if let txt = MadeiraConfig.get("tf-trace") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_TF_TRACE", v, 1)
                    logStore.log("Theorafile tracer: MADEIRA_TF_TRACE=\(v) via madeira.cfg tf-trace")
                }
            }

            // ml731: Windows shared-data clock A/B. Documents/madeira-usd-time.txt == "1"
            // makes wineserver update KUSER_SHARED_DATA's SystemTime, InterruptTime
            // and TickCount again. Without it those stay frozen at their init values,
            // so GetTickCount/Environment.TickCount/DateTime.UtcNow never advance and
            // every time-gated transition in a managed game waits forever while the
            // renderer keeps drawing. Opt-in only because the old code claimed the
            // write faulted; this should become unconditional once proven.
            if let txt = MadeiraConfig.get("usd-time") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_USD_TIME", v, 1)
                    logStore.log("Shared-data clock: MADEIRA_USD_TIME=\(v) via madeira.cfg usd-time")
                }
            }

            // ml730: REAL thread suspension A/B. Documents/madeira-real-suspend.txt == "1"
            // makes a Wine suspend actually stop the Mach thread and keep it stopped
            // until the matching resume, instead of only snapshotting its registers
            // and bumping a counter while the target keeps running.
            //
            // Off by default and reversible on purpose: wineserver is a thread inside
            // this same Mach process and shares the allocator with the guest, so truly
            // freezing a thread that holds the malloc lock or FEX's CodeInvalidationMutex
            // can deadlock whoever suspended it. Windows apps tolerate preemptive suspend
            // because the suspender does not share their heap; here it does.
            if let txt = MadeiraConfig.get("real-suspend") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_REAL_SUSPEND", v, 1)
                    logStore.log("Thread suspension: MADEIRA_REAL_SUSPEND=\(v) via madeira.cfg real-suspend")
                }
            }

            // ml713: Mono suspend-policy A/B. Documents/madeira-mono-suspend.txt
            // containing "preemptive" (or "coop"/"hybrid") sets MONO_THREADS_SUSPEND
            // for wine-mono, so the comparison needs no rebuild.
            //
            // EXPERIMENT, NOT A FIX, and deliberately not a default. Marvel Cosmic
            // Invasion deadlocks with one thread owning a Mono critical section while
            // looping on mono_lls_find/usleep waiting for a thread-info record, and six
            // threads queued behind that section. Preemptive suspend would sidestep the
            // handshake -- but it needs SuspendThread + GetThreadContext to yield a
            // coherent x86-64 context for a guest thread stopped anywhere, including
            // mid-JIT-block, and that path has never been exercised under FEX. It may
            // trade a deadlock for a worse failure. If it does get in-game, that is NOT
            // evidence for any particular theory of the deadlock.
            if let txt = MadeiraConfig.get("mono-suspend") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MONO_THREADS_SUSPEND", v, 1)
                    logStore.log("Mono suspend policy: MONO_THREADS_SUSPEND=\(v) via madeira.cfg mono-suspend")
                }
            }

            winios_phase("pool-alloc-begin")
            logStore.log("Allocating \(poolSizeMB)MB JIT pool (BRK will suspend process)...")
            let t0 = CFAbsoluteTimeGetCurrent()
            let pool = StikJITHelper.allocatePool(poolSize: poolSizeMB * 1024 * 1024)
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            winios_phase("pool-ready")
            logStore.log("BRK suspension lasted \(String(format: "%.2f", elapsed))s")

            // Arena carver self-test. Documents/madeira-arena-test.txt holds
            // "churn:N", "ramp:N" or "random:N". Deliberately a SEPARATE file
            // from madeira-arena.txt: a test that only runs when the feature is
            // enabled cannot be used to decide whether to enable it.
            if let txt = MadeiraConfig.get("arena-test") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_ARENA_TEST", v, 1)
                    logStore.log("arena carver self-test: \(v)", level: .success)
                }
            }

            // ml787: deterministic call-ret allocation failure injection.
            // Documents/madeira-fexfail.txt holds "reserve:N" or "commit:N".
            // The containment path it exercises only occurs naturally when a
            // title exhausts the emulator's address band, and only the reserve
            // half occurs at all -- an untested cleanup path is an assumption,
            // so this makes both reproducible on demand. Absent the file
            // nothing is injected.
            if let txt = MadeiraConfig.get("fexfail") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_FEX_FAIL_CALLRET", v, 1)
                    logStore.log("call-ret failure injection: \(v) via madeira.cfg fexfail", level: .error)
                }
            }

            // SteamOS-iOS product invariant: graphics execute on this iPhone/iPad.
            // Clear Madeira's historical remote-Metal research variables even if a
            // legacy madeira.cfg still contains remote transport keys.
            unsetenv("DXMT_REMOTE_METAL")
            unsetenv("RMETAL_TOKEN")
            unsetenv("DXMT_REMOTE_BATCH")
            setenv("STEAMOS_IOS_LOCAL_METAL", "1", 1)
            logStore.log("[METAL] local-only renderer enforced", level: .success)

            // madeira-d3d12: M1 shader-converter gate, in-app.
            // Documents/madeira-d3d12.txt == "1" runs the same canary that
            // passes standalone on macOS and over SSH on this device, but from
            // inside Madeira -- which is the only way to test bundling, signing
            // and dlopen under the app's own sandbox. Results go to the log.
            // Reports its decision either way. A gate that stays silent when it
            // declines to run is indistinguishable from one that never executed,
            // which cost a device run to work out.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let raw = MadeiraConfig.get("d3d12")   /* ml1095 */
                let val = raw ?? ""
                if val == "1" {
                    let dir = Bundle.main.bundlePath + "/d3d12"
                    let dylib = dir + "/libmetalirconverter.dylib"
                    let haveDylib = FileManager.default.fileExists(atPath: dylib)
                    let transcript = d.appendingPathComponent("madeira-d3d12-canary.log").path
                    logStore.log("madeira-d3d12: running the M1 canary in-app (dylib present: \(haveDylib))", level: .info)
                    let fails = madeira_d3d12_canary_run_log(
                        dir, dylib, nil, transcript,
                        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?")
                    if fails == 0 {
                        logStore.log("madeira-d3d12: M1 canary PASSED in-app (transcript: madeira-d3d12-canary.log)", level: .success)
                    } else {
                        logStore.log("madeira-d3d12: M1 canary FAILED (\(fails) checks)", level: .error)
                    }
                } else {
                    logStore.log("madeira-d3d12: gate off (madeira.cfg d3d12 \(raw == nil ? "unset" : "= '\(val)'"))", level: .debug)
                }
            }

            // ml761: top-level API census. Documents/madeira-apicensus.txt == "1"
            // counts every call across the PE->unix winemetal boundary and
            // classifies each as producer, consumer, lifetime, query, sync,
            // presentation or bulk-memory. Needed because a packed command
            // batch carries GUEST handles -- raw pointer casts, meaningless on
            // another machine -- so every handle producer and consumer has to
            // be redirected together.
            if let txt = MadeiraConfig.get("apicensus") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("DXMT_API_CENSUS", v, 1)
                logStore.log("API census: DXMT_API_CENSUS=\(v) via madeira.cfg apicensus")
            }

            // ml760: shadow-pack mode. Documents/madeira-shadow.txt == "1" packs
            // and validates every real render batch into the remote wire format,
            // then discards it and renders locally as normal. Exercises the
            // packer against live traffic where being wrong costs nothing. The
            // check that matters is packed counts equalling census counts: a
            // silently skipped command would otherwise surface as a subtly wrong
            // frame on another machine.
            if let txt = MadeiraConfig.get("shadow") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("DXMT_SHADOW_PACK", v, 1)
                logStore.log("shadow pack: DXMT_SHADOW_PACK=\(v) via madeira.cfg shadow")
            }

            // ml758: wmtcmd census. Documents/madeira-census.txt == "1" counts
            // which of the 59 render/compute/blit command types a workload
            // actually emits, and how large their sidecar data gets. Needed
            // before serialising wmtcmd_* for the remote Metal transport --
            // building a schema for all 59 on speculation would be weeks of
            // work for commands no title may ever issue.
            if let txt = MadeiraConfig.get("census") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("DXMT_CMD_CENSUS", v, 1)
                logStore.log("wmtcmd census: DXMT_CMD_CENSUS=\(v) via madeira.cfg census")
            }

            // ml757: FEX arena placeholder. Documents/madeira-arena.txt == "1"
            // makes Wine reserve FEX's host arena before any PE loads. OFF by
            // default: FEX still selects its own band, and on hardware that
            // band IS the reservation, so enabling it starves FEX and kills
            // x64 before the first window. Proven correct on the research VM
            // (8GB held, 0 of 123 guest images inside it) -- turn on only once
            // FEX consumes WINE_IOS_FEX_ARENA_BASE/SIZE instead of choosing.
            if let txt = MadeiraConfig.get("arena") {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("MADEIRA_FEX_ARENA", v, 1)
                logStore.log("FEX arena placeholder: MADEIRA_FEX_ARENA=\(v) via madeira.cfg arena")
            }

            // ml748: W^X A/B probe. Documents/madeira-wxprobe.txt == "1" runs it.
            // Loading xtajit64.dll faults writing its .rdata on the jailbroken
            // research VM and not on this phone, with CS_DEBUGGED live in both,
            // so attachment is not the variable. Either the VM is stricter than
            // real hardware (its patchVmMapProtect() was removed, and that is
            // what forces W to stick on file-backed pages), or hardware masks a
            // genuine bug and the loader must stop holding RWX over image pages.
            // Reasoning cannot separate those; the SAME build reporting on both
            // machines can. Runs here because it needs the real container, the
            // real sandbox and a live cs_wx_enabled map -- a standalone binary
            // over SSH already answered this wrongly once.
            if let txt = MadeiraConfig.get("wxprobe"),
               txt.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                logStore.log("W^X probe armed via madeira.cfg wxprobe", level: .success)
                jit_wx_probe()
            }

            if let pool = pool {
                logStore.log("JIT pool: RX=\(String(format: "%p", Int(bitPattern: pool.rx))), RW=\(String(format: "%p", Int(bitPattern: pool.rw))), size=\(pool.size / 1024 / 1024)MB", level: .success)
                setenv("WINE_IOS_JIT_RX", String(format: "%lx", Int(bitPattern: pool.rx)), 1)
                setenv("WINE_IOS_JIT_RW", String(format: "%lx", Int(bitPattern: pool.rw)), 1)
                setenv("WINE_IOS_JIT_SIZE", String(format: "%lx", pool.size), 1)
            } else {
                // ml596: ABORT. "Continuing without it" produced ml595 — a run that
                // looked like an ARM64EC/optimizer regression but was only Wine
                // executing with no JIT pool, and it cost a diagnostic cycle plus a
                // wrong conclusion I wrote into the source. A run without the pool can
                // only manufacture misleading secondary crashes, so refuse to start one.
                logStore.log("JIT pool allocation FAILED — not starting Wine.", level: .error)
                logStore.log("  All placements landed in the forbidden guest 64G window.", level: .info)
                logStore.log("  Force-quit and relaunch: placement is chosen by the kernel", level: .info)
                logStore.log("  and depends on current memory layout, so a fresh process", level: .info)
                logStore.log("  usually lands somewhere valid.", level: .info)
                DispatchQueue.main.async {
                    self.productState = .failed("Executable JIT memory pool allocation failed. Force-quit and retry.")
                }
                logStore.uiPaused = false
                return
            }

            // Step 1b (ml524, #67): DETACH THE DEBUGGER NOW, while the VM map is small.
            //
            // Every ~54s whole-app stall coincides with StikDebug DEPARTING — clean
            // exit(0) and jetsam-kill alike (12:07:43 exit(0) -> GAP 54.0s at 12:07:49;
            // 12:13:58 cpulimit kill -> GAP 53.8s starting 64ms BEFORE the kill log).
            // Departure is the trigger; the manner of death is irrelevant. StikDebug
            // burns its 48s-CPU-per-60s budget in ~52s every single run, so an
            // UNCONTROLLED departure mid-game is guaranteed. Detaching here pays the
            // cost ONCE, at a moment we choose, before anything is on screen.
            //
            // Why it may also be CHEAPER here: on attach the kernel unnests the DYLD
            // shared region in OUR map ("increases system memory footprint until the
            // target exits"), so teardown plausibly scales with VM-map complexity —
            // and right now the map is a fraction of what it becomes under Steam
            // (91 threads / 2512MB). The [early-detach] timing below tests exactly that.
            //
            // Safe NOW and not before: ml522/ml523 made US the task-level Mach handler
            // for bad-access + bad-instruction + breakpoint, so the fault backstop that
            // used to require a live debugger (madeira-jit.js: "NEVER detach here ... every
            // later escalated fault parks its thread forever", the ml345 wedge) is ours.
            // And all executable memory already comes from the pool granted above —
            // virtual_ios.c copies every PE .text into it rather than mprotecting,
            // because iOS/TXM blocks mprotect(PROT_EXEC) outright.
            //
            // ORDERING MATTERS: our task-port claim installs at wine's first thread
            // setup, which is AFTER this point, so this BRK still reaches StikDebug.
            // Flip to false to A/B against the old attached-for-the-whole-run behaviour.
            let earlyDetach = true
            if earlyDetach, pool != nil {
                let dt0 = CFAbsoluteTimeGetCurrent()
                StikJITHelper.detachDebugger()
                let dms = (CFAbsoluteTimeGetCurrent() - dt0) * 1000.0
                logStore.log(String(format: "[early-detach] rev=ml524 took %.0f ms", dms),
                             level: dms > 5000 ? .error : .success)
            } else if !earlyDetach {
                logStore.log("[early-detach] rev=ml524 DISABLED — debugger stays attached all run")
            }

            winios_phase("detach-done")

            // Step 2: Start wineserver
            self.startWineserver()
            winios_phase("wineserver-up")

            // Step 3: Start Wine (debugger still attached for PE loading BRK calls)
            Thread.sleep(forTimeInterval: 2.0)
            winios_phase("wine-start")
            self.startWineProcess()

            // Step 4: Wait for Wine to finish instead of fixed timer
            // Poll wine_process_is_running() — it clears when __wine_main returns
            // For real games this never returns (message loop runs forever), so
            // the cap is what matters. After detach, the dual-mapped JIT pool
            // keeps existing blocks executable; only NEW BRK-based compiles
            // fail.
            //
            // 2026-05-13 first-frame: Thumper splash renders at ~50s but JIT is
            // STILL compiling new FMOD blocks 3M log lines later — audio init
            // is huge (~14k unique RIPs in fmod64.dll alone). Bumped to 300s
            // to let FMOD finish init before debugger detach; otherwise main
            // game loop never engages because Present is gated on audio ready.
            logStore.log("Waiting for Wine to finish PE loading...")
            // 2026-07-03 early detach: attached-mode runs the whole guest
            // ~2x slower (measured 1.2s → 0.74s per present at detach) and
            // on iOS 27 presented frames only reliably reach glass after
            // detach. Post-detach is safe now: trap-mode JIT writes go via
            // the Mach emulator (no debugger), pool pages are pre-executable
            // (dual map), page0 runs once on the first thread, and a
            // post-detach compile was observed working (real_compiles
            // 7093→7094, no faults). So: detach once the game is actually
            // presenting (present #2 = first post-splash frame) plus a
            // settle window, instead of waiting out the full 1200s cap.
            let maxWait = 1200.0  // hard safety cap (unchanged)
            // 2026-07-03 second iteration: detach on present #1 (splash shown)
            // instead of #2. The 3-minute splash-hold is the game loading —
            // running it detached should roughly halve it. Riskier than #2
            // (thousands of load-time compiles + worker-thread spawns happen
            // post-detach) but all known dependencies are covered: trap-mode
            // writes, pre-executable pool, page0 once-guard.
            let settleAfterFirstPresent = 20.0
            var presentingSince: CFAbsoluteTime? = nil
            let pollStart = CFAbsoluteTimeGetCurrent()
            var lastHeartbeat = CFAbsoluteTimeGetCurrent()
            while wine_process_is_running() != 0 {
                Thread.sleep(forTimeInterval: 0.25)
                let now = CFAbsoluteTimeGetCurrent()
                // Diagnostic heartbeat: 2026-07-03's detach-at-#1 run never
                // triggered despite presents visibly counting — log what this
                // loop actually observes so that can't happen silently again.
                if now - lastHeartbeat > 30 {
                    lastHeartbeat = now
                    logStore.log("detach-wait: presents=\(madeira_get_present_count()) running=\(wine_process_is_running()) elapsed=\(Int(now - pollStart))s")
                }
                // Task #25: the present heuristic is meaningless in desktop
                // mode — ANY child presenting (cube, a game window) trips it
                // mid-session, and later program launches still need the
                // attached-debugger facilities. Desktop sessions stay
                // attached until the desktop exits (or the safety cap).
                let isDesktopSession = getenv("MADEIRA_DESKTOP").map { $0.pointee == 49 } ?? false
                if !isDesktopSession {
                    if presentingSince == nil && madeira_get_present_count() >= 1 {
                        presentingSince = now
                        logStore.log("Game is presenting (#1, splash) — early detach in \(Int(settleAfterFirstPresent))s")
                    }
                    if let t = presentingSince, now - t > settleAfterFirstPresent {
                        logStore.log("Early detach: game presenting and settled", level: .success)
                        break
                    }
                }
                if now - pollStart > maxWait {
                    logStore.log("Wine still running after \(Int(maxWait))s, proceeding with detach", level: .error)
                    break
                }
            }
            let wineElapsed = CFAbsoluteTimeGetCurrent() - pollStart
            logStore.log("Wine finished after \(String(format: "%.1f", wineElapsed))s")

            // Step 5: Resume UI + os_log, give main thread time to recover before detach
            DispatchQueue.main.async {
                ws_log_quiet = 0
                logStore.uiPaused = false
            }
            Thread.sleep(forTimeInterval: 2.0)

            // Step 6: Detach debugger — main thread should have zero accumulated hang time
            logStore.log("Detaching debugger...")
            StikJITHelper.detachDebugger()

            DispatchQueue.main.async { heartbeat.invalidate() }
        }
    }

    /// Resolve the installed Steam directory in the app-owned Wine prefix.
    /// The first-run bootstrap installs the official Windows client into the
    /// normal 32-bit Program Files tree, but the 64-bit tree remains accepted.
    private func steamInstallLocation() -> (win: String, unix: String)? {
        let fm = FileManager.default
        let prefix = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("wine").path
        let candidates = [
            ("C:\\Program Files (x86)\\Steam", "\(prefix)/drive_c/Program Files (x86)/Steam"),
            ("C:\\Program Files\\Steam",       "\(prefix)/drive_c/Program Files/Steam"),
        ]
        return candidates.first(where: { fm.fileExists(atPath: "\($0.1)/steam.exe") })
    }

    private func steamIsInstalled() -> Bool {
        steamInstallLocation() != nil
    }

    /// Configure the normal Steam product session.
    ///
    /// Research probes stay opt-in through dedicated diagnostics controls; the
    /// ordinary Steam button must not enable frame dumps, source watches, IR
    /// capture, socket tracing, or optimizer experiments.
    private func configureSteamProductRuntime(batch: String, deskW: Int, deskH: Int) {
        let clear = [
            "MADEIRA_STEAM_APP_PATH", "MADEIRA_STEAM_APP_ID",
            "MADEIRA_SOCK_WIRE", "FEX_O0", "MADEIRA_NO_DFE", "MADEIRA_IR_TOPO",
            "MADEIRA_IRCAP_RVA", "MADEIRA_IRCAP_MODULE",
            "MADEIRA_DUMP_SURFACES", "MADEIRA_SURF_SEQ",
            "MADEIRA_DEAD_RELEASE", "MADEIRA_SRCWATCH", "MADEIRA_SRCWATCH_ROWS"
        ]
        for name in clear { unsetenv(name) }

        setenv("MADEIRA_EXE", "explorer.exe", 1)
        setenv("MADEIRA_ARGS",
               "/desktop=shell,\(deskW)x\(deskH) cmd /c C:\\\(batch)", 1)
        setenv("MADEIRA_DESKTOP", "1", 1)
        setenv("MADEIRA_SCREEN_W", String(deskW), 1)
        setenv("MADEIRA_SCREEN_H", String(deskH), 1)
        setenv("STEAMOS_IOS_TOUCHSCREEN", "1", 1)

        // This means V8/CEF jitless, NOT FEX jitless. FEX x86/x64 translation
        // still requires the executable JIT gate and the large StikJIT pool.
        setenv("MADEIRA_JITLESS", "1", 1)
    }

    /// First-run Windows Steam bootstrap.
    ///
    /// Valve's current Windows installer is a 32-bit PE. The frozen Madeira
    /// baseline now ships the WoW64/FEX chain required to execute it, so the old
    /// "copy a CrossOver Steam folder" requirement is obsolete.
    @MainActor
    private func bootstrapSteamFirstRun(deskW: Int, deskH: Int) async {
        guard SteamOSRuntimeGate.validate(log: logStore) else {
            productState = .failed("Local JIT/Metal runtime validation failed before Steam installation.")
            return
        }

        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let prefixURL = docs.appendingPathComponent("wine", isDirectory: true)
        let driveC = prefixURL.appendingPathComponent("drive_c", isDirectory: true)
        let setupURL = driveC.appendingPathComponent("SteamSetup.exe")
        let bootstrapBAT = driveC.appendingPathComponent("steam-bootstrap.bat")

        guard let officialURL = URL(string: "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe") else {
            logStore.log("Internal error: invalid Steam installer URL", level: .error)
            productState = .failed("The Steam installer URL is invalid.")
            return
        }

        do {
            try fm.createDirectory(at: prefixURL, withIntermediateDirectories: true)
            prefixURL.path.withCString { madeira_seed_prefix_if_needed($0) }
            guard fm.fileExists(atPath: driveC.path) else {
                throw NSError(domain: "SteamBootstrap", code: 1,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Wine prefix bootstrap did not create drive_c"])
            }

            logStore.log("Steam first run: downloading Valve SteamSetup.exe...")
            let (data, response) = try await URLSession.shared.data(from: officialURL)

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw NSError(domain: "SteamBootstrap", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "Steam download HTTP \(http.statusCode)"])
            }

            guard data.count >= 1_000_000,
                  data[data.startIndex] == 0x4d,
                  data[data.index(after: data.startIndex)] == 0x5a else {
                throw NSError(domain: "SteamBootstrap", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Downloaded SteamSetup.exe is not a valid PE payload"])
            }

            try data.write(to: setupURL, options: .atomic)
            logStore.log("SteamSetup.exe ready (\(data.count) bytes)", level: .success)

            let bat = """
            @echo off\r
            C:\\SteamSetup.exe /S\r
            if not exist "C:\\Program Files (x86)\\Steam\\steam.exe" exit /b 2\r
            start "" "C:\\windows\\system32\\services.exe"\r
            cd /d "C:\\Program Files (x86)\\Steam"\r
            rem CEF stays software-rasterized during bring-up; games still use local DXMT/D3D12 -> Metal.\r
            "C:\\Program Files (x86)\\Steam\\steam.exe" -no-cef-sandbox -cef-disable-gpu -console -nocrashmonitor -cef-disable-features=SegmentationPlatform,OptimizationTargetPrediction,OptimizationHints\r
            """
            try bat.write(to: bootstrapBAT, atomically: true, encoding: .utf8)

            // Install + launch in the same Madeira/Wine session. SteamSetup.exe
            // enters WoW64; the installed x64 helpers continue through FEX.
            configureSteamProductRuntime(batch: "steam-bootstrap.bat",
                                         deskW: deskW, deskH: deskH)

            logStore.log("Launching official Steam installer through Wine WoW64 + FEX...", level: .success)
            runWineFullSequence()
        } catch {
            logStore.log("Steam first-run bootstrap failed: \(error.localizedDescription)", level: .error)
            productState = .failed("Steam installation failed: \(error.localizedDescription)")
        }
    }

    /// Locate an installed Steam client and regenerate the stable launch batch.
    private func prepareSteamLaunch() -> Bool {
        guard let (winDir, _) = steamInstallLocation() else {
            logStore.log("Steam is not installed yet; first-run bootstrap is required.", level: .error)
            return false
        }

        let fm = FileManager.default
        let prefix = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("wine").path

        let bat = """
        @echo off\r
        rem Generated by SteamOS-iOS — rewritten every launch.\r
        start "" "C:\\windows\\system32\\services.exe"\r
        cd /d "\(winDir)"\r
        rem CEF stays software-rasterized during bring-up; games still use local DXMT/D3D12 -> Metal.\r
        "\(winDir)\\steam.exe" -no-cef-sandbox -cef-disable-gpu -console -nocrashmonitor -cef-disable-features=SegmentationPlatform,OptimizationTargetPrediction,OptimizationHints\r
        """

        let batPath = "\(prefix)/drive_c/steam-launch.bat"
        do {
            try bat.write(toFile: batPath, atomically: true, encoding: .utf8)
        } catch {
            logStore.log("Could not write steam-launch.bat: \(error.localizedDescription)", level: .error)
            return false
        }
        logStore.log("Steam found at \(winDir)", level: .success)
        return true
    }

    private func startWineserver() {
        logStore.log("Starting wineserver...")

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let winePrefixPath = documentsPath.appendingPathComponent("wine").path

        logStore.log("Wine prefix: \(winePrefixPath)")

        let result = wineserver_start(winePrefixPath)
        if result == 0 {
            logStore.log("Wineserver thread launched successfully", level: .success)
        } else {
            logStore.log("Failed to start wineserver (error: \(result))", level: .error)
        }
    }

    private func startWineProcess() {
        logStore.log("Starting Wine process...")

        if wineserver_is_running() == 0 {
            logStore.log("Wineserver not running! Start it first.", level: .error)
            return
        }

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let winePrefixPath = documentsPath.appendingPathComponent("wine").path

        // Call synchronously — caller already waited for wineserver to be ready
        let result = wine_process_start(winePrefixPath)
        if result == 0 {
            logStore.log("Wine process thread launched", level: .success)
        } else {
            logStore.log("Failed to start Wine process (error: \(result))", level: .error)
        }
    }

    private func testDualMapping() {
        logStore.log("Testing dual-mapped memory properties...")

        DispatchQueue.global(qos: .userInitiated).async {
            testDualMappingImpl()
        }
    }

    private func testDualMappingImpl() {
        logStore.log("Creating 64KB dual-mapped region...")

        guard let region = jit_region_create(65536) else {
            logStore.log("Failed to create dual-mapped region", level: .error)
            return
        }

        let rwPtr = jit_region_rw_ptr(region)
        let rxPtr = jit_region_rx_ptr(region)
        let size = jit_region_size(region)

        logStore.log("Region created: size=\(size)")
        logStore.log("  RW ptr: \(String(format: "%p", Int(bitPattern: rwPtr)))")
        logStore.log("  RX ptr: \(String(format: "%p", Int(bitPattern: rxPtr)))")

        // Test 1: Write to RW, verify readable from RX
        let testPattern: UInt32 = 0xDEADBEEF
        rwPtr?.assumingMemoryBound(to: UInt32.self).pointee = testPattern
        let readBack = rxPtr?.assumingMemoryBound(to: UInt32.self).pointee

        if readBack == testPattern {
            logStore.log("Dual mapping verified: write to RW visible from RX", level: .success)
        } else {
            logStore.log("Dual mapping FAILED: wrote \(String(format: "0x%X", testPattern)), read \(String(format: "0x%X", readBack ?? 0))", level: .error)
        }

        // Test 2: Verify RW and RX are at different virtual addresses
        if rwPtr != rxPtr {
            logStore.log("Distinct virtual addresses confirmed (RW != RX)", level: .success)
        } else {
            logStore.log("WARNING: RW and RX are at the same address", level: .error)
        }

        jit_region_destroy(region)
        logStore.log("Region destroyed. Dual mapping test complete.")
    }
}

struct SetupGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {   /* ml658: see the note on the main body */
            List {
                Section("Requirements") {
                    guideRow(
                        icon: "cpu",
                        title: "JIT Compilation",
                        detail: "Required for x86/x64 translation. On iOS 27, use StikDebug to grant executable JIT memory before Steam or game launch; SteamOS-iOS verifies JIT before starting the runtime."
                    )
                    guideRow(
                        icon: "memorychip",
                        title: "Increased Memory Limit",
                        detail: "Raises the Jetsam memory threshold. Included in the app entitlements. If not detected, use GetMoreRam to inject it."
                    )
                    guideRow(
                        icon: "arrow.up.left.and.arrow.down.right",
                        title: "Extended Virtual Addressing",
                        detail: "Expands virtual address space to ~64GB. Required for large games. Must be injected via GetMoreRam (free accounts can't provision this)."
                    )
                }

                Section("Setup Steps") {
                    stepRow(number: 1, text: "Install SteamOS-iOS via SideStore or Xcode")
                    stepRow(number: 2, text: "Install GetMoreRam and run it to inject memory entitlements into your App ID")
                    stepRow(number: 3, text: "Reinstall SteamOS-iOS with the same IPA to apply injected entitlements")
                    stepRow(number: 4, text: "In StikDebug, assign the 'universal' JIT script to SteamOS-iOS and launch it")
                    stepRow(number: 5, text: "Launch SteamOS-iOS; Steam starts automatically after JIT is ready")
                }

                Section("About") {
                    Text("SteamOS-iOS runs the real Windows Steam client and supported Windows games locally through Wine, FEX and Metal.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Setup Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func guideRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.medium)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption).fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}

// ============================================================================
// SteamOS-iOS native Steam Settings
// ============================================================================
struct SteamSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var input = InputSettings.shared
    @ObservedObject private var controls = TouchControlsModel.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Touchscreen") {
                    Toggle("Full-screen Touch", isOn: $input.touchScreenEnabled)

                    Picker("Touch Mode", selection: $input.directTouch) {
                        Text("Direct Touch").tag(true)
                        Text("Mouse / Trackpad").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!input.touchScreenEnabled)

                    Text(input.directTouch
                         ? "Direct Touch maps your finger to the same aspect-correct Windows surface shown on screen."
                         : "Mouse / Trackpad enables relative mouse-look, two-finger scrolling, right-click, and drag gestures.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Controller Overlay") {
                    Toggle("Show Controller Overlay", isOn: Binding(
                        get: { input.controllerOverlayEnabled },
                        set: { enabled in
                            if enabled { controls.ensureDefaultLayout() }
                            input.controllerOverlayEnabled = enabled
                            if !enabled {
                                controls.editing = false
                                controls.selected = nil
                            }
                        }
                    ))

                    HStack {
                        Button("Edit Controller Layout") {
                            controls.ensureDefaultLayout()
                            // Transient edit mode is independent from the
                            // persistent gameplay overlay visibility setting.
                            controls.editing = true
                            controls.selected = nil
                            dismiss()
                        }

                        Button("Reset Layout") {
                            // Reset only geometry/mappings. Do not surprise the
                            // user by turning the gameplay overlay back on.
                            controls.resetDefaultLayout()
                        }
                    }

                    Text("Optional. Editing/resetting does not enable it. Turning it off removes the controller only; full-screen Direct Touch / Mouse-Trackpad input and physical controllers remain available. Rotate to landscape to edit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Keyboard") {
                    Button("Show On-Screen Keyboard") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            MetalBackedView.toggleKeyboard()
                        }
                    }
                    Text("Use this for Steam sign-in, Steam Guard, search, chat, and games that need text input.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Pointer") {
                    Toggle("Relative Mouse / Mouse-look", isOn: $input.relative)
                        .disabled(input.directTouch || !input.touchScreenEnabled)
                    LabeledContent("Absolute sensitivity") {
                        Text(String(format: "%.2f", input.sensAbs))
                            .monospacedDigit()
                    }
                    Slider(value: $input.sensAbs, in: 0.10...8.0)
                        .disabled(input.directTouch || !input.touchScreenEnabled)

                    LabeledContent("Relative sensitivity") {
                        Text(String(format: "%.2f", input.sensRel))
                            .monospacedDigit()
                    }
                    Slider(value: $input.sensRel, in: 0.10...8.0)
                        .disabled(input.directTouch || !input.touchScreenEnabled)
                }
            }
            .navigationTitle("Steam Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// ============================================================================
// ml643 — LANDSCAPE TOUCH CONTROLS (pass 1: overlay, editor, persistence)
//
// This is the L2 layer from reference_swiftui_liquid_glass_ux_layers.md: glass
// elements composited over the game canvas, repositionable.
//
// 🔑 Everything here MUST live in its own UIWindow. MetalHostView is a raw
// window-level UIView above the whole SwiftUI hierarchy, so a control drawn in
// the normal content tree gets sliced off wherever it overlaps the game surface
// — and zIndex cannot fix that, because zIndex only orders siblings *within*
// SwiftUI. Same reason JoystickPadHost exists; see its comment.
// ============================================================================

/// What a control does when pressed. Codable with associated values so the
/// whole layout round-trips through JSON.
enum ControlAction: Codable, Equatable, Hashable {
    case none
    case key(Int32)          // Windows virtual-key code
    case mouseLeft
    case mouseRight
    case joystickWASD        // renders as a stick, posts W/A/S/D
    case joystickArrows      // renders as a stick, posts the arrow keys
    case keyboardToggle      // raises the iOS keyboard, as in portrait
    case pad(String)         // ml1930: touch gamepad action, preserving saved layout names.

    /// The four keys a stick drives, up/right/down/left. nil for non-sticks.
    var stickKeys: [Int32]? {
        switch self {
        case .joystickWASD:   return [0x57, 0x44, 0x53, 0x41]   // W D S A
        case .joystickArrows: return [0x26, 0x27, 0x28, 0x25]   // up right down left
        default: return nil
        }
    }
    var isPad: Bool { if case .pad = self { return true }; return false }
    var padName: String? { if case .pad(let name) = self { return name }; return nil }
    var isPadStick: Bool { padName == "LS" || padName == "RS" }

    var label: String {
        switch self {
        case .none:            return "—"
        case .mouseLeft:       return "L"
        case .mouseRight:      return "R"
        case .keyboardToggle:  return "⌨"
        case .joystickWASD:    return "WASD"
        case .joystickArrows:  return "↕"
        case .pad(let n):      return n
        case .key(let vk):     return ControlAction.keyLabel(vk)
        }
    }

    /// Minimal for pass 1 — the full VK table arrives with the mapping panel.
    static func keyLabel(_ vk: Int32) -> String {
        switch vk {
        case 0x0D: return "⏎"
        case 0x20: return "␣"
        case 0x1B: return "Esc"
        case 0x09: return "⇥"
        case 0x10: return "⇧"
        case 0x11: return "Ctl"
        case 0x12: return "Alt"
        case 0x25: return "←"
        case 0x26: return "↑"
        case 0x27: return "→"
        case 0x28: return "↓"
        default:
            if vk >= 0x30, vk <= 0x5A, let u = UnicodeScalar(UInt32(vk)) {
                return String(Character(u))
            }
            return String(format: "%02X", vk)
        }
    }
}

/// One on-screen control.
///
/// Position is NORMALISED (0–1 of the screen), never points: the device gets
/// rotated and the logical surface can change size, and a layout stored in
/// absolute coordinates scatters the first time either happens.
struct TouchControl: Codable, Identifiable, Equatable {
    var id = UUID()
    var nx: Double = 0.5
    var ny: Double = 0.5
    var scale: Double = 1.0
    var action: ControlAction = .mouseLeft   // usable the moment it is created
}

final class TouchControlsModel: ObservableObject {
    static let shared = TouchControlsModel()
    static let baseDiameter: CGFloat = 64

    @Published var controls: [TouchControl] = [] { didSet { save() } }
    @Published var visible = false              { didSet { save() } }
    @Published var editing = false              // transient, never persisted
    @Published var selected: UUID?              // transient

    private var loading = false
    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("madeira-controls.json")
    }

    private static let currentLayoutVersion = 2

    private struct Saved: Codable {
        var controls: [TouchControl]
        var visible: Bool
        var layoutVersion: Int?
    }

    private init() {
        loading = true
        if let d = try? Data(contentsOf: Self.url),
           let s = try? JSONDecoder().decode(Saved.self, from: d) {
            controls = Self.migrateLayout(
                s.controls.isEmpty ? Self.defaultLayout() : s.controls,
                from: s.layoutVersion ?? 1)
            visible = false
        } else {
            controls = Self.defaultLayout()
            visible = false
        }
        loading = false
        save()
    }

    private static func defaultLayout() -> [TouchControl] {
        func c(_ x: Double, _ y: Double, _ scale: Double, _ action: ControlAction) -> TouchControl {
            TouchControl(nx: x, ny: y, scale: scale, action: action)
        }
        return [
            c(0.15, 0.70, 1.65, .pad("LS")),
            c(0.70, 0.70, 1.55, .pad("RS")),
            c(0.25, 0.84, 0.78, .pad("L3")),
            c(0.72, 0.84, 0.78, .pad("R3")),
            c(0.89, 0.68, 1.00, .pad("A")),
            c(0.94, 0.57, 1.00, .pad("B")),
            c(0.84, 0.57, 1.00, .pad("X")),
            c(0.89, 0.46, 1.00, .pad("Y")),
            c(0.08, 0.49, 0.86, .pad("D↑")),
            c(0.08, 0.63, 0.86, .pad("D↓")),
            c(0.03, 0.56, 0.86, .pad("D←")),
            c(0.13, 0.56, 0.86, .pad("D→")),
            c(0.13, 0.16, 0.92, .pad("LB")),
            c(0.22, 0.13, 0.92, .pad("LT")),
            c(0.78, 0.13, 0.92, .pad("RT")),
            c(0.87, 0.16, 0.92, .pad("RB")),
            c(0.43, 0.16, 0.78, .pad("View")),
            c(0.50, 0.11, 0.78, .pad("Guide")),
            c(0.57, 0.16, 0.78, .pad("Menu"))
        ]
    }

    private static func migrateLayout(_ input: [TouchControl], from version: Int) -> [TouchControl] {
        guard version < currentLayoutVersion else { return input }
        var migrated = input

        func normalizeThumbClick(_ name: String, x: Double) {
            var keptOne = false
            migrated.removeAll { control in
                guard control.action.padName == name else { return false }
                if !keptOne {
                    keptOne = true
                    return false
                }
                return true
            }
            if !keptOne {
                migrated.append(TouchControl(nx: x, ny: 0.84, scale: 0.78, action: .pad(name)))
            }
        }

        // v2 completes and de-duplicates old saved layouts without replacing
        // any other user positions/remaps. After migration the version is
        // persisted, so later deliberate user deletion remains respected.
        normalizeThumbClick("L3", x: 0.25)
        normalizeThumbClick("R3", x: 0.72)
        return migrated
    }

    private func save() {
        guard !loading else { return }
        guard let d = try? JSONEncoder().encode(
            Saved(controls: controls, visible: visible,
                  layoutVersion: Self.currentLayoutVersion))
        else { return }
        try? d.write(to: Self.url, options: .atomic)
    }

    func ensureDefaultLayout() {
        if controls.isEmpty { controls = Self.defaultLayout() }
    }

    func resetDefaultLayout() {
        controls = Self.defaultLayout()
        selected = nil
    }

    func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return controls.firstIndex { $0.id == id }
    }

    /// ml644: does this WINDOW point land on something interactive?
    ///
    /// Hit-test geometrically, never by walking the UIView hierarchy. SwiftUI
    /// does not back each Button with its own UIView — the entire overlay is one
    /// _UIHostingView and taps are routed by SwiftUI's own gesture machinery. So
    /// `super.hitTest` returns that same hosting view for EVERY point, buttons
    /// included, and ml643's "is it the root view?" test therefore rejected every
    /// touch in the window. Nothing responded, and edit mode — whose branch
    /// captured everything — could never be entered to mask it.
    func hitsInteractive(_ p: CGPoint, in bounds: CGRect) -> Bool {
        guard InputSettings.shared.controllerOverlayEnabled else { return false }
        // Done/Add exist only while editing. Normal gameplay has NO overlay
        // chrome; Steam Settings is opened with the three-finger gesture.
        if editing {
            let barW: CGFloat = 2 * 44 + 10
            if CGRect(x: bounds.midX - barW / 2 - 10, y: 0,
                      width: barW + 20, height: 68).contains(p) { return true }
        }
        for c in controls {
            let r = Self.baseDiameter * CGFloat(c.scale) / 2
            let cx = CGFloat(c.nx) * bounds.width
            let cy = CGFloat(c.ny) * bounds.height
            if hypot(p.x - cx, p.y - cy) <= r { return true }
        }
        return false
    }
}

/// Click-through EXCEPT where a control actually is.
///
/// PassthroughWindow (the joystick pad's) returns nil unconditionally because it
/// only ever draws. This one has to take input, so it discriminates: a hit that
/// lands on the hosting root view means empty space, and empty space belongs to
/// the game underneath — mouse-look must keep working between the buttons.
final class ControlsWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let m = TouchControlsModel.shared
        // The controller/editor is landscape-only. Portrait draws nothing here,
        // so the transparent UIWindow must NEVER trap Steam's touchscreen.
        guard bounds.width > bounds.height else { return nil }
        // Edit mode owns the landscape screen: drags and the scale pinch must not
        // leak through and swing the camera while controls are being arranged.
        if m.editing { return super.hitTest(point, with: event) }
        guard m.hitsInteractive(point, in: bounds) else { return nil }
        return super.hitTest(point, with: event)
    }
}

enum TouchControlsHost {
    private static var window: ControlsWindow?
    private static var productHidden = false

    static func setHidden(_ hidden: Bool) {
        productHidden = hidden
        window?.isHidden = hidden
    }

    static func attach() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                        ?? scenes.first else { return }
        if window == nil {
            // ml644: orientationDidChangeNotification is NOT posted unless
            // generation has been switched on, so without this the overlay would
            // keep a portrait-sized frame after the first rotation.
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            let w = ControlsWindow(windowScene: scene)
            // Above the joystick pad's +100. A higher windowLevel is the only
            // ordering nothing inside the app window can undo.
            w.windowLevel = .normal + 101
            w.backgroundColor = .clear
            w.isHidden = productHidden // deliberately never made key
            let host = UIHostingController(rootView: TouchControlsOverlay())
            host.view.backgroundColor = .clear
            w.rootViewController = host
            window = w
        }
        window?.frame = scene.coordinateSpace.bounds
        fputs("[controls] ml644 overlay attached frame=\(window?.frame ?? .zero) " +
              "controls=\(TouchControlsModel.shared.controls.count)\n", stderr)
    }
}

struct TouchControlsOverlay: View {
    @ObservedObject private var m = TouchControlsModel.shared
    @ObservedObject private var input = InputSettings.shared
    @State private var pinchBase: Double?

    var body: some View {
        GeometryReader { geo in
            // Landscape only; portrait keeps the existing key row and joystick.
            let landscape = geo.size.width > geo.size.height
            ZStack(alignment: .top) {
                if landscape {
                    if input.controllerOverlayEnabled || m.editing {
                        ForEach(m.controls) { c in
                            TouchControlButton(control: c, screen: geo.size)
                        }
                    }
                    if m.editing { topBar }
                    if m.editing, let i = m.index(of: m.selected) {
                        MappingPanel(control: m.controls[i], screen: geo.size)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(scalePinch, including: m.editing ? .all : .subviews)
            .onAppear { configureGamepad(landscape: landscape) }
            .onChange(of: geo.size) { _, _ in configureGamepad(landscape: landscape) }
            .onChange(of: m.controls) { _, _ in configureGamepad(landscape: landscape) }
            .onChange(of: input.controllerOverlayEnabled) { _, enabled in
                if !enabled {
                    m.editing = false
                    m.selected = nil
                }
                configureGamepad(landscape: landscape)
            }
            .onChange(of: m.editing) { _, _ in configureGamepad(landscape: landscape) }
            .onDisappear { GamepadInput.shared.configureTouch(controls: []) }
        }
        .ignoresSafeArea()
    }

    private func configureGamepad(landscape: Bool) {
        let ids = landscape && input.controllerOverlayEnabled && !m.editing
            ? m.controls.filter { $0.action.padName.map(TouchPadAction.supported) ?? false }.map(\.id) : []
        GamepadInput.shared.configureTouch(controls: Set(ids))
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            glassButton("checkmark") {
                m.editing = false
                m.selected = nil
            }
            glassButton("plus") {
                var c = TouchControl()
                c.nx = 0.5 + Double(m.controls.count % 3) * 0.06
                c.ny = 0.5 + Double(m.controls.count % 2) * 0.06
                m.controls.append(c)
                m.selected = c.id
            }
        }
        .padding(.top, 10)
        .animation(.easeInOut(duration: 0.22), value: m.editing)
    }

    /// Pinch anywhere scales the SELECTED control. With nothing selected it does
    /// nothing rather than guessing which one you meant.
    private var scalePinch: some Gesture {
        MagnificationGesture()
            .onChanged { v in
                guard m.editing, let i = m.index(of: m.selected) else { return }
                if pinchBase == nil { pinchBase = m.controls[i].scale }
                m.controls[i].scale = min(max((pinchBase ?? 1) * Double(v), 0.5), 3.0)
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func glassButton(_ system: String, dim: Bool = false,
                             _ action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.22)) { action() }
        } label: {
            // Stroke only — never a .fill variant.
            Image(systemName: system)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.white.opacity(dim ? 0.35 : 1.0))
                .frame(width: 44, height: 44)
                .background(GlassShape(circle: true))
        }
        .buttonStyle(.plain)
    }
}

/// Shared glass backing, with the pre-26 fallback the codebase already uses.
struct GlassShape: View {
    var circle = false
    var body: some View {
        if #available(iOS 26.0, *) {
            if circle { Circle().fill(.clear).glassEffect(.regular, in: Circle()) }
            else { RoundedRectangle(cornerRadius: 18).fill(.clear)
                     .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18)) }
        } else {
            if circle { Circle().fill(.ultraThinMaterial) }
            else { RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial) }
        }
    }
}

struct TouchControlButton: View {
    let control: TouchControl
    let screen: CGSize
    @ObservedObject private var m = TouchControlsModel.shared
    @State private var isDown = false
    @State private var dragBase: CGPoint?
    @State private var stickDir: Int = -1
    @State private var padVector = CGSize.zero

    private var diameter: CGFloat { TouchControlsModel.baseDiameter * CGFloat(control.scale) }
    private var isStick: Bool { control.action.stickKeys != nil || control.action.isPadStick }
    private var isSelected: Bool { m.editing && m.selected == control.id }

    var body: some View {
        ZStack {
            if control.action.isPadStick {
                GlassShape(circle: true)
                Circle().fill(.white.opacity(isDown ? 0.55 : 0.25))
                    .frame(width: diameter * 0.42, height: diameter * 0.42)
                    .offset(x: padVector.width * diameter * 0.29, y: padVector.height * diameter * 0.29)
                Text(control.action.label).font(.caption).foregroundStyle(.white.opacity(0.8))
            } else if control.action.stickKeys != nil {
                // Reuse the portrait pad's face so both look and animate the
                // same; scale it to whatever size this control was pinched to.
                JoystickFace(held: isDown, dir: stickDir, alwaysExpanded: true)
                    .frame(width: JoystickFace.padRadius * 2,
                           height: JoystickFace.padRadius * 2)
                    .scaleEffect(diameter / (JoystickFace.padRadius * 2))
            } else {
                GlassShape(circle: true)
                Text(control.action.label)
                    .font(.system(size: diameter * (control.action.label.count > 2 ? 0.22 : 0.34),
                                  weight: .medium))
                    .foregroundStyle(.white.opacity(isDown ? 1.0 : 0.85))
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay(Circle().stroke(.white.opacity(isSelected ? 0.95
                                                : (isStick ? 0 : 0.28)),
                                 lineWidth: isSelected ? 2 : 1))
        // A stick must not shrink under the thumb; only round buttons do that.
        .scaleEffect(!isStick && isDown ? 0.92 : 1.0)
        // ml890: no press animation. Pressing the on-screen Enter key killed the
        // whole process with a SwiftUI trap on com.apple.SwiftUI.AsyncRenderer
        // (DisplayList.ViewUpdater.ViewCache.commitAsyncValues) while this
        // glass control animated its press; the state change now applies at once.
        // ml646: the springy knob, same curve as the portrait pad overlay.
        .animation(.spring(response: 0.22, dampingFraction: 0.58), value: stickDir)
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    m.controls.removeAll { $0.id == control.id }
                    m.selected = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.red.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .offset(x: 8, y: -8)
            }
        }
        .overlay {
            if let action = control.action.padName, !m.editing {
                TouchPadSurface(control: control.id, action: action) { vector, down in
                    padVector = vector; isDown = down
                }
            }
        }
        .onDisappear { if control.action.isPad { padVector = .zero; isDown = false } }
        .onChange(of: m.editing) { _, _ in if control.action.isPad { padVector = .zero; isDown = false } }
        .onChange(of: screen) { _, _ in if control.action.isPad { padVector = .zero; isDown = false } }
        .onChange(of: control.action) { old, new in
            if old.isPad || new.isPad { padVector = .zero; isDown = false }
        }
        .position(x: CGFloat(control.nx) * screen.width,
                  y: CGFloat(control.ny) * screen.height)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if m.editing {
                        m.selected = control.id
                        guard let i = m.index(of: control.id) else { return }
                        if dragBase == nil { dragBase = CGPoint(x: control.nx, y: control.ny) }
                        let b = dragBase ?? .zero
                        m.controls[i].nx = min(max(b.x + Double(v.translation.width  / screen.width),  0.03), 0.97)
                        m.controls[i].ny = min(max(b.y + Double(v.translation.height / screen.height), 0.03), 0.97)
                    } else if let q = control.action.stickKeys {
                        isDown = true
                        applyStick(snap(v.translation), q)
                    } else if !isDown {
                        isDown = true
                        press(true)
                    }
                }
                .onEnded { _ in
                    dragBase = nil
                    if let q = control.action.stickKeys {
                        applyStick(-1, q)          // release every held direction
                        isDown = false
                    } else if isDown {
                        isDown = false
                        press(false)
                    }
                },
            including: control.action.isPad && !m.editing ? .subviews : .all
        )
    }

    /// 8-way snap. Screen y grows downward, so measure clockwise from "up".
    private func snap(_ t: CGSize) -> Int {
        let d = (t.width * t.width + t.height * t.height).squareRoot()
        if d < diameter * 0.22 { return -1 }        // deadzone scales with the control
        var a = atan2(t.width, -t.height) * 180 / .pi
        if a < 0 { a += 360 }
        return Int((a + 22.5) / 45.0) % 8
    }

    private func stickKeys(_ d: Int, _ q: [Int32]) -> [Int32] {
        switch d {
        case 0: return [q[0]]
        case 1: return [q[0], q[1]]
        case 2: return [q[1]]
        case 3: return [q[2], q[1]]
        case 4: return [q[2]]
        case 5: return [q[2], q[3]]
        case 6: return [q[3]]
        case 7: return [q[0], q[3]]
        default: return []
        }
    }

    /// Release what is no longer held, press what newly is. A blanket
    /// release/re-press would make a held direction stutter as the thumb
    /// wanders inside one sector.
    private func applyStick(_ next: Int, _ q: [Int32]) {
        guard next != stickDir else { return }
        let old = Set(stickKeys(stickDir, q)), new = Set(stickKeys(next, q))
        for vk in old.subtracting(new) { winios_post_key(vk, 0) }
        for vk in new.subtracting(old) { winios_post_key(vk, 1) }
        if stickDir == -1, next != -1 { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        stickDir = next
    }

    /// Haptic on the DOWN edge only — a held movement key would otherwise buzz
    /// continuously for as long as you walk.
    private func press(_ down: Bool) {
        if down { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        switch control.action {
        case .key(let vk):
            winios_post_key(vk, down ? 1 : 0)
        case .mouseLeft:
            winios_pointer(0, 0, down ? 0x0002 : 0x0004, 0)   // LEFTDOWN / LEFTUP
        case .mouseRight:
            winios_pointer(0, 0, down ? 0x0008 : 0x0010, 0)   // RIGHTDOWN / RIGHTUP
        case .keyboardToggle:
            if down { MetalBackedView.toggleKeyboard() }
        case .none, .joystickWASD, .joystickArrows:
            break                                              // sticks drive themselves
        case .pad:
            break     // TouchPadSurface owns pad presses and cancellation.
        }
    }
}

/// ml645 — the mapping panel. Shown for the selected control in edit mode.
struct MappingPanel: View {
    let control: TouchControl
    let screen: CGSize
    @ObservedObject private var m = TouchControlsModel.shared
    @State private var tab = 0                    // 0 keyboard, 1 controller


    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabButton(0, "keyboard")
                tabButton(1, "gamecontroller")
            }
            Rectangle().fill(.white.opacity(0.15)).frame(height: 1)
            ScrollView {
                (tab == 0 ? AnyView(keyboardTab) : AnyView(controllerTab))
                    .padding(10)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .background(GlassShape())
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.18), lineWidth: 1))
        .position(layout.center)
    }

    private struct Placement { var center: CGPoint; var size: CGSize }

    /// ml646: the panel must NEVER sit under the control it is editing.
    ///
    /// The old version only tried below/above and then clamped, which on a
    /// 390pt-tall landscape phone silently put the panel right on top of any
    /// control near the middle: 240 of panel + 64 of control + gaps does not fit
    /// in 390 either way, so the clamp was the only thing deciding placement.
    ///
    /// Try each side in turn, at shrinking sizes, and take the first that fits
    /// on the screen along the axis it separates on. Clamping the OTHER axis is
    /// then always safe — below/above are separated vertically, so no horizontal
    /// clamp can reintroduce an overlap, and vice versa.
    private var layout: Placement {
        let cx = CGFloat(control.nx) * screen.width
        let cy = CGFloat(control.ny) * screen.height
        let r  = TouchControlsModel.baseDiameter * CGFloat(control.scale) / 2
        let gap: CGFloat = 14, edge: CGFloat = 8

        for size in [CGSize(width: 340, height: 236),
                     CGSize(width: 300, height: 196),
                     CGSize(width: 264, height: 164)] {
            let clampX = min(max(cx, size.width  / 2 + edge), screen.width  - size.width  / 2 - edge)
            let clampY = min(max(cy, size.height / 2 + edge), screen.height - size.height / 2 - edge)
            if cy + r + gap + size.height <= screen.height - edge {
                return Placement(center: CGPoint(x: clampX, y: cy + r + gap + size.height / 2), size: size)
            }
            if cy - r - gap - size.height >= edge {
                return Placement(center: CGPoint(x: clampX, y: cy - r - gap - size.height / 2), size: size)
            }
            if cx + r + gap + size.width <= screen.width - edge {
                return Placement(center: CGPoint(x: cx + r + gap + size.width / 2, y: clampY), size: size)
            }
            if cx - r - gap - size.width >= edge {
                return Placement(center: CGPoint(x: cx - r - gap - size.width / 2, y: clampY), size: size)
            }
        }
        // Nothing fits alongside — smallest panel, corner furthest from the
        // control, so it still cannot cover it.
        let size = CGSize(width: 264, height: 164)
        return Placement(
            center: CGPoint(x: cx < screen.width  / 2 ? screen.width  - size.width  / 2 - edge
                                                      : size.width  / 2 + edge,
                            y: cy < screen.height / 2 ? screen.height - size.height / 2 - edge
                                                      : size.height / 2 + edge),
            size: size)
    }

    private func tabButton(_ i: Int, _ icon: String) -> some View {
        Button { tab = i } label: {
            Image(systemName: icon)                       // stroke, not filled
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white.opacity(tab == i ? 1.0 : 0.38))
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.plain)
    }

    // ---- catalogues ----
    private var letters: [(String, ControlAction)] {
        (0x41...0x5A).map { (String(UnicodeScalar(UInt8($0))), ControlAction.key(Int32($0))) }
    }
    private var digits: [(String, ControlAction)] {
        (0x30...0x39).map { (String(UnicodeScalar(UInt8($0))), ControlAction.key(Int32($0))) }
    }
    private var fkeys: [(String, ControlAction)] {
        (0...11).map { ("F\($0 + 1)", ControlAction.key(Int32(0x70 + $0))) }
    }
    private var numpad: [(String, ControlAction)] {
        (0...9).map { ("N\($0)", ControlAction.key(Int32(0x60 + $0))) }
        + [("N*", .key(0x6A)), ("N+", .key(0x6B)), ("N−", .key(0x6D)),
           ("N.", .key(0x6E)), ("N/", .key(0x6F))]
    }

    private var keyboardTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Pointer, sticks & special", [
                ("L click", .mouseLeft), ("R click", .mouseRight),
                ("WASD", .joystickWASD), ("Arrows", .joystickArrows),
                ("Keyboard", .keyboardToggle), ("None", .none),
            ])
            section("Letters", letters)
            section("Numbers", digits)
            section("Function", fkeys)
            section("Modifiers & editing", [
                ("Esc", .key(0x1B)), ("Tab", .key(0x09)), ("Caps", .key(0x14)),
                ("Shift", .key(0x10)), ("Ctrl", .key(0x11)), ("Alt", .key(0x12)),
                ("Space", .key(0x20)), ("Enter", .key(0x0D)), ("Bksp", .key(0x08)),
                ("Win", .key(0x5B)),
            ])
            section("Navigation", [
                ("←", .key(0x25)), ("↑", .key(0x26)), ("→", .key(0x27)), ("↓", .key(0x28)),
                ("Ins", .key(0x2D)), ("Del", .key(0x2E)), ("Home", .key(0x24)),
                ("End", .key(0x23)), ("PgUp", .key(0x21)), ("PgDn", .key(0x22)),
            ])
            section("Symbols", [
                ("-", .key(0xBD)), ("=", .key(0xBB)), ("[", .key(0xDB)), ("]", .key(0xDD)),
                ("\\", .key(0xDC)), (";", .key(0xBA)), ("'", .key(0xDE)), (",", .key(0xBC)),
                (".", .key(0xBE)), ("/", .key(0xBF)), ("`", .key(0xC0)),
            ])
            section("Numpad", numpad)
        }
    }

    private var controllerTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Controller controls feed XInput player 1. LS and RS are analogue sticks; "
                 + "LT and RT are full-press triggers. Touch and physical controls can be used together.")
                .font(.system(size: 11))
                .foregroundStyle(.orange.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
            section("Face", [("A", .pad("A")), ("B", .pad("B")), ("X", .pad("X")), ("Y", .pad("Y"))])
            section("D-pad", [("D↑", .pad("D↑")), ("D↓", .pad("D↓")),
                              ("D←", .pad("D←")), ("D→", .pad("D→"))])
            section("Bumpers & triggers", [("LB", .pad("LB")), ("RB", .pad("RB")),
                                           ("LT", .pad("LT")), ("RT", .pad("RT"))])
            section("Sticks", [("LS", .pad("LS")), ("RS", .pad("RS")),
                               ("L3", .pad("L3")), ("R3", .pad("R3"))])
            section("System", [("Menu", .pad("Menu")), ("View", .pad("View")),
                               ("Guide", .pad("Guide"))])
        }
    }

    private func section(_ title: String, _ items: [(String, ControlAction)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 6)], spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    chip(it.0, it.1)
                }
            }
        }
    }

    private func chip(_ label: String, _ action: ControlAction) -> some View {
        let on = control.action == action
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if let i = m.index(of: control.id) { m.controls[i].action = action }
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .foregroundStyle(.white.opacity(action.isPad ? 0.55 : 1.0))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(.white.opacity(on ? 0.36 : 0.12)))
        }
        .buttonStyle(.plain)
    }
}
