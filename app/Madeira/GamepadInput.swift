import Foundation
// GameController supports background handler queues but lacks Sendable annotations.
@preconcurrency import GameController
@preconcurrency import CoreHaptics
import UIKit
import SwiftUI


private final class SteamIOSControllerHaptics: @unchecked Sendable {
    private let queue = DispatchQueue(label: "steamios.controller.haptics", qos: .userInteractive)
    private let engine: CHHapticEngine
    private var player: CHHapticPatternPlayer?
    private var playing = false
    private var lastMagnitude: UInt16 = 0

    init?(controller: GCController) {
        guard let haptics = controller.haptics else { return nil }
        let locality: GCHapticsLocality =
            haptics.supportedLocalities.contains(.handles) ? .handles : .default
        guard let engine = haptics.createEngine(withLocality: locality) else { return nil }
        do { try engine.start() } catch { return nil }
        self.engine = engine
        engine.stoppedHandler = { [weak self] _ in
            self?.queue.async {
                self?.player = nil
                self?.playing = false
            }
        }
        engine.resetHandler = { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.player = nil
                self.playing = false
                try? self.engine.start()
            }
        }
    }

    func setMotors(left: UInt16, right: UInt16) {
        let magnitude = max(left, right)
        queue.async { [weak self] in self?.apply(magnitude) }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.player?.stop(atTime: CHHapticTimeImmediate)
            self.player = nil
            self.playing = false
            self.lastMagnitude = 0
        }
    }

    private func apply(_ magnitude: UInt16) {
        guard magnitude != lastMagnitude else { return }
        lastMagnitude = magnitude
        if player == nil && magnitude > 0 {
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1)],
                relativeTime: 0,
                duration: TimeInterval(Double(GCHapticDurationInfinite))
            )
            guard let pattern = try? CHHapticPattern(events: [event], parameters: []),
                  let newPlayer = try? engine.makePlayer(with: pattern) else { return }
            player = newPlayer
        }
        guard let player else { return }
        let parameter = CHHapticDynamicParameter(
            parameterID: .hapticIntensityControl,
            value: Float(magnitude) / Float(UInt16.max),
            relativeTime: 0
        )
        try? player.sendParameters([parameter], atTime: CHHapticTimeImmediate)
        if !playing {
            try? player.start(atTime: CHHapticTimeImmediate)
            playing = true
        }
    }
}

/// ml1930: physical and touch controller snapshots share the same serial publisher.
/// Slot/profile/timer state belongs exclusively to `queue`. The app lifecycle
/// and observer registration belong to the main actor. Guest readers use the
/// C snapshot lock; no Swift objects cross into Wine.
final class GamepadInput: @unchecked Sendable {
    static let shared = GamepadInput()
    @MainActor static let enabled: Bool = {
        let value = MadeiraConfig.get("env.MADEIRA_XINPUT")
            ?? ProcessInfo.processInfo.environment["MADEIRA_XINPUT"]
        return value != "0"
    }()

    @MainActor static let touchEnabled: Bool = {
        let value = MadeiraConfig.get("env.MADEIRA_TOUCH_XINPUT")
            ?? ProcessInfo.processInfo.environment["MADEIRA_TOUCH_XINPUT"]
        return enabled && value != "0"
    }()

    @MainActor func configureTouch(controls: Set<UUID>) {
        let allowed = Self.touchEnabled ? controls : []
        queue.async { [self] in touchState.configure(allowed); sample() }
    }

    @MainActor func touch(owner: UUID, control: UUID, value: GamepadSample?) {
        guard Self.touchEnabled else { return }
        queue.async { [self] in
            guard active || value == nil else { return }
            touchState.update(owner: owner, control: control, value: value)
            sample()
        }
    }

    private let queue = DispatchQueue(label: "madeira.gamepad", qos: .userInteractive)
    private var controllers = [GCController?](repeating: nil, count: 4)
    private var profiles = [GCExtendedGamepad?](repeating: nil, count: 4)
    private var haptics = [SteamIOSControllerHaptics?](repeating: nil, count: 4)
    private var vibrationPackets = [UInt32](repeating: 0, count: 4)
    private var timer: DispatchSourceTimer?
    private var active = false
    private var touchState = TouchGamepadState()
    @MainActor private var observers: [NSObjectProtocol] = []
    @MainActor private var started = false
    @MainActor private var wirelessDiscoveryStarted = false

    @MainActor func start() {
        guard !started else { return }
        started = true
        LogStore.shared.log("[xinput] ml1920 physical controllers enabled=\(Self.enabled ? 1 : 0)")
        LogStore.shared.log("[touch-xinput] ml1930 enabled=\(Self.touchEnabled ? 1 : 0)")
        guard Self.enabled else { return }
        if !wirelessDiscoveryStarted {
            wirelessDiscoveryStarted = true
            LogStore.shared.log("[xinput] wireless/Bluetooth controller discovery started")
            GCController.startWirelessControllerDiscovery {
                fputs("[xinput] wireless/Bluetooth controller discovery completed\n", stderr)
            }
        }
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshControllers() }
            })
        }
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.setActive(false)
            })
        }
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshControllers() }
            self?.setActive(true)
        })
        refreshControllers()
        setActive(UIApplication.shared.applicationState == .active)
    }

    @MainActor private func refreshControllers() {
        // Capture the live profile on main. Re-fetching extendedGamepad on the
        // polling queue yielded stale axes on devices tested in the fork.
        let live = GCController.controllers().compactMap { controller -> (GCController, GCExtendedGamepad)? in
            guard let profile = controller.extendedGamepad else { return nil }
            controller.handlerQueue = queue
            return (controller, profile)
        }
        queue.async { [self] in
            for i in controllers.indices {
                guard let old = controllers[i], !live.contains(where: { $0.0 === old }) else { continue }
                profiles[i]?.valueChangedHandler = nil
                haptics[i]?.stop()
                haptics[i] = nil
                vibrationPackets[i] = 0
                controllers[i] = nil
                profiles[i] = nil
                fputs("[xinput] ml1920 slot=\(i) disconnected\n", stderr)
            }
            for (controller, profile) in live {
                guard !controllers.contains(where: { $0 === controller }),
                      let i = controllers.firstIndex(where: { $0 == nil }) else { continue }
                controllers[i] = controller
                profiles[i] = profile
                haptics[i] = SteamIOSControllerHaptics(controller: controller)
                profile.valueChangedHandler = { [weak self] _, _ in
                    // Explicit queue hop also serializes callbacks already in flight
                    // when a controller is disconnected or the app resigns active.
                    self?.queue.async { [weak self] in self?.sample() }
                }
                let transport = controller.isAttachedToDevice ? "attached" : "wireless/Bluetooth"
                let name = controller.vendorName ?? controller.productCategory
                fputs("[xinput] ml1920 slot=\(i) connected transport=\(transport) name=\(name) haptics=\(haptics[i] != nil ? 1 : 0)\n", stderr)
            }
            updateTimer()
            sample()
        }
    }

    private func setActive(_ value: Bool) {
        queue.async { [self] in
            active = value
            if !value {
                touchState.clear()
                for haptic in haptics { haptic?.setMotors(left: 0, right: 0) }
            }
            updateTimer()
            sample()
        }
    }

    private func updateTimer() {
        let needed = active && profiles.contains(where: { $0 != nil })
        if !needed { timer?.cancel(); timer = nil; return }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in self?.sample() }
        timer = source
        source.resume()
    }

    // XInput leaves dead zones to the game. Preserve the complete signed range.
    static func axis(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        let clamped = max(-1, min(1, value))
        return Int16((clamped * (clamped < 0 ? 32768 : 32767)).rounded())
    }
    static func trigger(_ value: Float) -> UInt8 {
        guard value.isFinite else { return 0 }
        return UInt8((max(0, min(1, value)) * 255).rounded())
    }

    private func sample() {
        for i in profiles.indices {
            let pad = profiles[i]
            let touchConnected = i == 0 && touchState.connected
            guard pad != nil || touchConnected else {
                winios_gamepad_set_state(Int32(i), nil)
                continue
            }
            var state = winios_gamepad()
            state.connected = 1
            // Keep the connected identity, but release all controls while the
            // app is inactive. A delayed callback cannot republish a held key.
            if active, let pad {
                let buttons: [(GCControllerButtonInput?, UInt16)] = [
                    (pad.dpad.up, 0x0001), (pad.dpad.down, 0x0002),
                    (pad.dpad.left, 0x0004), (pad.dpad.right, 0x0008),
                    (pad.buttonMenu, 0x0010), (pad.buttonOptions, 0x0020),
                    (pad.leftThumbstickButton, 0x0040), (pad.rightThumbstickButton, 0x0080),
                    (pad.leftShoulder, 0x0100), (pad.rightShoulder, 0x0200),
                    (pad.buttonHome, 0x0400), (pad.buttonA, 0x1000),
                    (pad.buttonB, 0x2000), (pad.buttonX, 0x4000), (pad.buttonY, 0x8000)
                ]
                for (button, mask) in buttons where button?.isPressed == true { state.buttons |= mask }
                state.left_trigger = Self.trigger(pad.leftTrigger.value)
                state.right_trigger = Self.trigger(pad.rightTrigger.value)
                state.lx = Self.axis(pad.leftThumbstick.xAxis.value)
                state.ly = Self.axis(pad.leftThumbstick.yAxis.value)
                state.rx = Self.axis(pad.rightThumbstick.xAxis.value)
                state.ry = Self.axis(pad.rightThumbstick.yAxis.value)
                state.has_haptics = haptics[i] == nil ? 0 : 1
                if pad.controller?.isAttachedToDevice == true {
                    state.battery_type = 1
                    state.battery_level = 3
                } else if let battery = pad.controller?.battery {
                    state.battery_type = 0xff
                    let level = max(0, min(1, battery.batteryLevel))
                    state.battery_level = level <= 0.05 ? 0 : (level < 0.25 ? 1 : (level < 0.70 ? 2 : 3))
                } else {
                    state.battery_type = 0xff
                    state.battery_level = 0
                }
            }
            if active && touchConnected {
                let physical = GamepadSample(buttons: state.buttons,
                    lt: state.left_trigger, rt: state.right_trigger,
                    lx: state.lx, ly: state.ly, rx: state.rx, ry: state.ry)
                let merged = GamepadSample.merge(physical: physical, touch: touchState.sample)
                state.buttons = merged.buttons
                state.left_trigger = merged.lt; state.right_trigger = merged.rt
                state.lx = merged.lx; state.ly = merged.ly; state.rx = merged.rx; state.ry = merged.ry
            }
            winios_gamepad_set_state(Int32(i), &state)
            if pad != nil {
                var vibration = winios_vibration()
                if winios_gamepad_get_vibration(Int32(i), &vibration) != 0,
                   vibration.packet != vibrationPackets[i] {
                    vibrationPackets[i] = vibration.packet
                    haptics[i]?.setMotors(left: vibration.left_motor, right: vibration.right_motor)
                }
            }
        }
    }
}

/// iOS 18 otherwise routes stick input into UIKit/SwiftUI focus navigation.
struct ClaimGamepadEvents: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), GamepadInput.enabled {
            content.handlesGameControllerEvents(matching: .gamepad)
        } else { content }
    }
}

enum GamepadEventClaim {
    @MainActor static func install(on view: UIView) {
        guard GamepadInput.enabled else { return }
        if #available(iOS 18.0, *) {
            guard !view.interactions.contains(where: { $0 is GCEventInteraction }) else { return }
            let interaction = GCEventInteraction()
            interaction.handledEventTypes = .gamepad
            view.addInteraction(interaction)
        }
    }
}
