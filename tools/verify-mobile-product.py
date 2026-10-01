#!/usr/bin/env python3
"""Static shipping-contract checks for the SteamIOS mobile product surface."""

from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]
CONTENT = (ROOT / "app/Madeira/ContentView.swift").read_text()
APP = (ROOT / "app/Madeira/MadeiraApp.swift").read_text()
GAMEPAD = (ROOT / "app/Madeira/GamepadInput.swift").read_text()
TOUCH = (ROOT / "app/Madeira/TouchGamepad.swift").read_text()
WINE = (ROOT / "app/Madeira/WineProcessBridge.m").read_text()
SIGNAL = (ROOT / "build/ntdll-unix/signal_arm64_ios.c").read_text()
VIRTUAL = (ROOT / "build/ntdll-unix/virtual_ios.c").read_text()
LAUNCHER = (ROOT / "build/steamios-launcher/steamios-launcher.c").read_text()
CLEAN_BUILD = (ROOT / "build/steamos-ios/build-clean-app.sh").read_text()
STIK = (ROOT / "app/Madeira/StikJITHelper.swift").read_text()
JIT = (ROOT / "app/Madeira/JITAllocator.c").read_text()
LOGSTORE = (ROOT / "app/Madeira/LogStore.swift").read_text()
WINIOS_H = (ROOT / "app/Madeira/Winios/Winios.h").read_text()
WINIOS_M = (ROOT / "app/Madeira/Winios/Winios.m").read_text()
INFO = plistlib.loads((ROOT / "app/Madeira/Info.plist").read_bytes())

def require(needle: str, haystack: str, label: str) -> None:
    if needle not in haystack:
        raise SystemExit(f"MOBILE_CONTRACT_FAIL: missing {label}: {needle}")

def forbid(needle: str, haystack: str, label: str) -> None:
    if needle in haystack:
        raise SystemExit(f"MOBILE_CONTRACT_FAIL: forbidden {label}: {needle}")

# Shipping root is Steam, not the old Madeira diagnostics/tooling surface.
require("struct SteamIOSApp: App", APP, "SteamIOS app root")
require("var body: some View {\n        steamProductBody", CONTENT, "Steam-only ContentView root")
require("startSteamAutomatically()", CONTENT, "automatic Steam startup")
require("if case .failed(let message) = productState", CONTENT, "failure-only startup overlay")
forbid('return "Starting Steam"', CONTENT, "visible Starting Steam interstitial")
forbid('return "Launching Steam"', CONTENT, "visible Launching Steam interstitial")
require('setenv("MADEIRA_EXE", "steamios-launcher.exe", 1)', CONTENT,
        "windowless Steam bootstrap")
require("CreateProcessW", LAUNCHER, "native Windows launcher process creation")
require("services.exe", LAUNCHER, "hidden Wine services prerequisite")
require("-bigpicture", LAUNCHER, "Steam Big Picture launch")
require(".steamios-steam-launched", LAUNCHER, "Steam launch marker")
require("bash build/steamios-launcher/build.sh", CLEAN_BUILD, "launcher clean-build step")
forbid("steam-launch.bat", CONTENT, "cmd/batch Steam wrapper")
require("winios_set_product_visible(0)", CONTENT, "hidden Wine compositor during startup")
require("winios_set_product_visible(steamSettingsPresented ? 0 : 1)", CONTENT,
        "Steam compositor reveal gate")
require("let presentation = convert(gameRect(), to: w)", CONTENT,
        "shared Metal/compositor safe-area rectangle")
require("void winios_set_product_visible(int visible);", WINIOS_H,
        "compositor visibility API")
require("[x18-xzr-recover] ml1137", SIGNAL, "malformed x18/XZR trampoline recovery")
require("ml1138: MOV XZR, X18 is a semantic no-op", VIRTUAL,
        "x18 patcher register-31 generation fix")
require("if (rd == 31)", VIRTUAL, "x18 patcher must never emit an SP-based TSD load for XZR")
FEX_LOCK_PATCH = (ROOT / "tools/patches/fex-arm64ec-interval-lock.patch").read_text()
require("ml1140: NEVER call NtProtectVirtualMemory while holding", FEX_LOCK_PATCH,
        "FEX invalidation tracker must not hold its mutex across NtProtectVirtualMemory")
require("[iOS-xlock] ml1140", FEX_LOCK_PATCH, "FEX unlocked-protection diagnostic")
require("fex-arm64ec-interval-lock.patch",
        (ROOT / "build/fex-arm64ec/build.sh").read_text(), "ARM64EC FEX lock patch application")
require(".steamios-runtime-ready-v1", WINE, "constant-time seeded-prefix marker")
require("[prefix-fast] ml1141 READY", WINE, "constant-time prefix fast path")
require("[prefix-clone] ml1142", WINE, "APFS-cloned first-install Steam materialization")
require("copyItemAtPath:bundleSteam toPath:steamDir", WINE,
        "Foundation clone-on-copy Steam materialization")
require("STEAMIOS_EXPANDED_STEAM_STAGE_OK", CLEAN_BUILD,
        "expanded Steam app-resource staging")
require("STEAMIOS_PACKAGED_EXPANDED_STEAM_OK", CLEAN_BUILD,
        "expanded Steam packaging gate")
require("STEAMIOS_PACKAGED_FAST_PREFIX_OK", CLEAN_BUILD,
        "lightweight prefix packaging gate")
forbid("STEAMIOS_PREFIX_FULL_STEAM_OK", CLEAN_BUILD,
       "legacy full-Steam-in-prefix packaging")
for legacy in (
    "Install Madeira via SideStore or Xcode",
    "Reinstall Madeira with the same IPA",
    "assign the 'universal' JIT script to Madeira",
    "Launch Madeira and tap 'Test JIT'",
    "Madeira is a proof-of-concept",
):
    forbid(legacy, CONTENT, "legacy Madeira user-facing copy")

# JIT and local Apple GPU are mandatory.
require("jit_check_debugged()", CONTENT, "JIT capability gate")
require("let probe = jit_test_execute_strategy2()", CONTENT, "debugger-owned executable JIT probe")
require("guard probe == 42", CONTENT, "JIT sentinel")
require("MTLCreateSystemDefaultDevice()", CONTENT, "local Metal device")
require('setenv("STEAMOS_IOS_LOCAL_METAL", "1", 1)', CONTENT, "local Metal invariant")
if re.search(r'(?m)^\s*setenv\("DXMT_REMOTE_METAL"', CONTENT):
    raise SystemExit("MOBILE_CONTRACT_FAIL: remote Metal enable present")
if re.search(r'(?m)^\s*setenv\("RMETAL_TOKEN"', CONTENT):
    raise SystemExit("MOBILE_CONTRACT_FAIL: remote Metal token present")
require('setenv("WINE_IOS_JIT_RX"', CONTENT, "real Wine JIT RX pool")
require('setenv("WINE_IOS_JIT_RW"', CONTENT, "real Wine JIT RW pool")
require('setenv("WINE_IOS_JIT_SIZE"', CONTENT, "real Wine JIT pool size")
require("JIT attach timed out after", STIK, "bounded JIT attach timeout")
require("func allocateDebuggerRXFromReservation", STIK, "debugger-owned JIT pool allocation")
require("func validateRXRange", STIK, "JIT RX protection validation")
require("pre-remap RX validation", STIK, "pre-remap JIT RX validation")
require("post-alias RX validation", STIK, "post-alias JIT RX validation")
require('components.scheme = "stikdebug"', STIK, "official StikDebug URL scheme")
require('URLQueryItem(name: "bundle-id"', STIK, "StikDebug bundle targeting")
require('URLQueryItem(name: "pid"', STIK, "StikDebug PID targeting")
require('URLQueryItem(name: "script-data"', STIK, "developer-defined StikDebug script")
require("private static var resolvedScriptBase64: String?", STIK, "single bundled JIT script source")
forbid("private static let scriptBase64", STIK, "stale embedded JIT script duplicate")
require('checkAppEntitlement("get-task-allow")', STIK, "host get-task-allow preflight")
require("jit_check_debugged() && isDebuggerAttached()", STIK, "live debugger readiness")
require("__attribute__((noinline, optnone, naked))", JIT, "universal naked BRK ABI")
if "stikdebug" not in INFO.get("LSApplicationQueriesSchemes", []):
    raise SystemExit("MOBILE_CONTRACT_FAIL: missing official StikDebug URL query scheme")
forbid("stikjit://enable-jit", STIK, "legacy StikJIT URL launch")
forbid("func prepareExactPool", STIK, "obsolete in-place JIT placeholder blessing")
require('productState = .failed("Local JIT/Metal runtime validation failed.', CONTENT,
        "visible runtime-gate failure")
require('let jitFailure = "Executable JIT pool setup failed after JIT attached.', CONTENT,
        "visible JIT-pool failure")
require('reason: "Executable JIT pool allocation failed"', CONTENT,
        "JIT-pool diagnostic report")

# Full-screen touch works without the optional virtual controller.
require("@Published var touchScreenEnabled = true", CONTENT, "touchscreen default ON")
require("@Published var directTouch = true", CONTENT, "direct touch default ON")
require("@Published var controllerOverlayEnabled = false", CONTENT, "controller overlay default OFF")
touch_begin = CONTENT.split("override func touchesBegan", 1)[1].split("override func touchesMoved", 1)[0]
require("guard InputSettings.shared.touchScreenEnabled else { return }", touch_begin, "touchscreen runtime gate")
require("InputSettings.shared.directTouch", touch_begin, "direct-touch path")
forbid("controllerOverlayEnabled", touch_begin, "controller dependency in raw touchscreen path")
require("active.count >= 3", touch_begin, "three-finger Settings gesture")
require("NotificationCenter.default.post(name: .steamOSSettingsRequested", touch_begin, "Settings gesture dispatch")

# Controller overlay is Settings-owned and click-through when OFF.
require('Toggle("Show Controller Overlay"', CONTENT, "Settings overlay toggle")
require("guard InputSettings.shared.controllerOverlayEnabled else { return false }", CONTENT, "overlay OFF click-through")
require("if input.controllerOverlayEnabled || m.editing", CONTENT, "overlay render policy")
require("landscape && input.controllerOverlayEnabled && !m.editing", CONTENT, "touch XInput activation policy")
require("guard bounds.width > bounds.height else { return nil }", CONTENT, "portrait click-through")
settings = CONTENT.split("struct SteamSettingsView: View", 1)[1].split("// ============================================================================\n// ml643", 1)[0]
require('Button("Edit Controller Layout")', settings, "controller editor entry")
require('Button("Reset Layout")', settings, "controller reset")
edit_block = settings.split('Button("Edit Controller Layout")', 1)[1].split('Button("Reset Layout")', 1)[0]
forbid("controllerOverlayEnabled = true", edit_block, "editor forcing overlay ON")

# Stock touch XInput layout + saved-layout migration.
default = CONTENT.split("private static func defaultLayout()", 1)[1].split("private static func migrateLayout", 1)[0]
for name in ("LS","RS","L3","R3","A","B","X","Y","D↑","D↓","D←","D→","LB","LT","RT","RB","View","Guide","Menu"):
    count = default.count(f'.pad("{name}")')
    if count != 1:
        raise SystemExit(f"MOBILE_CONTRACT_FAIL: stock layout {name} count={count}, expected 1")
require("currentLayoutVersion = 2", CONTENT, "layout migration version")
require('normalizeThumbClick("L3"', CONTENT, "L3 migration")
require('normalizeThumbClick("R3"', CONTENT, "R3 migration")
require("later deliberate user deletion remains respected", CONTENT, "non-destructive migration contract")

# Physical controllers + touch share the Windows XInput state.
require("GCControllerDidConnect", GAMEPAD, "controller hotplug connect")
require("GCControllerDidDisconnect", GAMEPAD, "controller hotplug disconnect")
require("leftThumbstickButton, 0x0040", GAMEPAD, "physical L3 mapping")
require("rightThumbstickButton, 0x0080", GAMEPAD, "physical R3 mapping")
require("GamepadSample.merge(physical: physical, touch: touchState.sample)", GAMEPAD, "physical/touch merge")
require("isMultipleTouchEnabled = true", TOUCH, "virtual controller multitouch")

# Steam login/text path.
require('Button("Show On-Screen Keyboard")', CONTENT, "software keyboard Settings action")
require("MetalBackedView.toggleKeyboard()", CONTENT, "keyboard bridge")
require("canBecomeFirstResponder", CONTENT, "UIKit keyboard responder")
require("winios_post_key", CONTENT, "Windows key bridge")

# iPhone/iPad packaging + orientation contract.
if INFO.get("CFBundleDisplayName") != "SteamIOS":
    raise SystemExit("MOBILE_CONTRACT_FAIL: CFBundleDisplayName is not SteamIOS")
if INFO.get("UIFileSharingEnabled") is not True:
    raise SystemExit("MOBILE_CONTRACT_FAIL: UIFileSharingEnabled must expose Documents in Files")
if INFO.get("LSSupportsOpeningDocumentsInPlace") is not True:
    raise SystemExit("MOBILE_CONTRACT_FAIL: LSSupportsOpeningDocumentsInPlace must be true")
require('appendingPathComponent("SteamIOS Crash Logs"', LOGSTORE, "Files-visible crash log directory")
require("recoverPreviousSessionIfNeeded", LOGSTORE, "unexpected-termination recovery")
require("writeDiagnosticReport", LOGSTORE, "explicit runtime diagnostic reports")
require("NSSetUncaughtExceptionHandler", APP, "uncaught Objective-C exception capture")
if INFO.get("UIRequiresFullScreen") is not True:
    raise SystemExit("MOBILE_CONTRACT_FAIL: UIRequiresFullScreen must be true")
caps = INFO.get("UIRequiredDeviceCapabilities", [])
if "arm64" not in caps:
    raise SystemExit("MOBILE_CONTRACT_FAIL: arm64 capability missing")
for key in ("UISupportedInterfaceOrientations", "UISupportedInterfaceOrientations~ipad"):
    vals = set(INFO.get(key, []))
    required = {
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    }
    if not required.issubset(vals):
        raise SystemExit(f"MOBILE_CONTRACT_FAIL: {key} missing phone/tablet orientations")
require("let height = isPad ? 900 : 720", CONTENT, "device-aware guest resolution")
require("window.safeAreaInsets", CONTENT, "safe-area presentation")
require("winios_get_surface_present_count()", CONTENT, "Steam/CEF compositor readiness")
require("winios_get_surface_present_count", WINIOS_H, "Steam/CEF readiness declaration")
require("g_visible_surface_present_count", WINIOS_M, "Steam/CEF compositor readiness counter")
require("UIApplication.didBecomeActiveNotification", CONTENT, "foreground lifecycle recovery")
require("MetalBackedView.refreshPresentationGeometry()", CONTENT, "Metal/touch geometry recovery")
require("TouchControlsHost.attach()", CONTENT, "controller overlay scene re-attach")

# Local audio path remains wired.
require("AVAudioSessionCategoryPlayback", WINE, "AVAudioSession playback category")
require("setActive:YES", WINE, "AVAudioSession activation")
if not (ROOT / "build/ntdll-unix/audio_null_ios.c").is_file():
    raise SystemExit("MOBILE_CONTRACT_FAIL: iOS RemoteIO audio driver missing")

print("STEAMIOS_MOBILE_SHIPPING_CONTRACT_OK")
