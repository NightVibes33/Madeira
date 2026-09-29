# SteamOS-iOS mobile readiness audit

## Implemented

- Shipping root auto-starts the real Windows Steam path.
- The native loader dismisses as soon as either DXMT frames or substantial Steam CEF/GDI surface presents begin, so it cannot sit over an already-rendering Steam client.
- JIT is mandatory; executable generated ARM64 is probed before Windows runtime.
- The StikDebug handoff has a bounded 120-second attach wait; failure returns to a visible Retry state instead of spinning forever.
- Local Apple MTLDevice is mandatory; gameplay is local Metal, not remote.
- iPhone/iPad safe-area/aspect-aware presentation.
- Foreground recovery re-attaches the window-level controller host and forces the
  live Metal/touch placeholder to recompute presentation geometry after iOS restores the scene.
- 60/120-Hz host presentation intent follows device capability.
- Full-screen touch defaults ON and is independent from controller visibility.
- Direct Touch maps screen coordinates through the same guest transform.
- Mouse/Trackpad supports move, click, drag, two-finger scroll/right-click.
- Relative mouse-look supports FPS camera control.
- Three-finger tap opens native Steam Settings.
- Steam Settings -> Show On-Screen Keyboard handles Steam login/Guard/search/text entry.
- Optional controller overlay defaults OFF.
- Steam Settings owns enable/edit/reset.
- Default layout: LS/RS, exactly one L3/R3 pair, D-pad, ABXY, LB/RB, LT/RT, View/Menu/Guide.
- Saved pre-v2 layouts migrate once to add missing L3/R3 and de-duplicate accidental extra L3/R3 entries without overwriting other positions/remaps.
- Drag, pinch/resize, delete, add and keyboard/controller remapping.
- Editing/resetting does not change the persistent controller-overlay ON/OFF preference.
- Portrait remains click-through if edit mode is armed; the controller editor itself is landscape-only.
- UIKit multitouch/cancellation for controller controls.
- Physical GameController hotplug and touch+physical XInput merge.
- Software keyboard and hardware input plumbing retained.
- AVAudioSession + RemoteIO/CoreAudio retained.
- FPS/present/memory HUD and ProMotion support retained.

## Still not Steam-Link-class complete

- CoreMotion gyro aiming.
- L4/L5/R4/R5 rear-button equivalents.
- radial/virtual menus and multi-action macros.
- per-game native controller profiles keyed from real Steam child AppID.
- per-control opacity/dead-zone/sensitivity UI.
- full automatic thermal governor using ProcessInfo thermal state.

## Device proof still required

CI/source review cannot prove the BOOTABLE ALPHA. It still requires an actual
iPhone/iPad run proving Steam login/Guard/library/download, a Steam-launched
local game, recurring Metal frames, audio, full-screen touch, physical/touch
controller input, rotation/background recovery and clean return to Steam.


## Touchscreen discriminator

Full-screen touch works with the controller overlay OFF. **Direct Touch is
currently implemented as absolute Windows mouse-compatible input**
(left-down/move/up) mapped through the displayed guest surface. It is suitable
for Steam navigation, taps, drags, launchers, and mouse-driven games.

It is not yet a native multi-contact Windows `WM_TOUCH`/`WM_POINTER`
implementation. The optional virtual controller is true multi-touch and can
hold multiple sticks/buttons/triggers simultaneously.


## CI-enforced shipping contract

`tools/verify-mobile-product.py` is the source-level mobile shipping
discriminator. The Windows foundation workflow fails if any of these regress:

- the product root stops auto-starting Steam;
- JIT/Metal/JIT-pool failures stop producing a visible Retry state;
- the StikDebug handoff loses its bounded timeout;
- Steam CEF/GDI surface readiness stops dismissing the native loading state;
- old Madeira setup copy becomes user-facing again;
- JIT or the local Apple `MTLDevice` stops being mandatory;
- full-screen touch becomes dependent on the optional controller overlay;
- the controller overlay stops defaulting OFF or stops being Settings-owned;
- the overlay/window begins trapping portrait or overlay-OFF touches;
- the stock XInput layout loses or duplicates LS/RS/L3/R3/ABXY/D-pad/triggers;
- saved-layout v2 migration loses its non-destructive L3/R3 normalization;
- physical GameController hotplug/XInput or touch+physical merge disappears;
- the software-keyboard path needed by Steam login/Guard/search disappears;
- iPhone/iPad orientation/full-screen metadata regresses;
- foreground lifecycle recovery stops re-attaching/re-framing the Metal/touch/controller hosts;
- AVAudioSession/RemoteIO or local Metal/JIT plumbing disappears.

This is a source/CI discriminator, not a substitute for on-device BOOTABLE
ALPHA proof.
