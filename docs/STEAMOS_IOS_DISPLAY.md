# SteamOS-iOS display contract

Date: 2026-09-28

## Pipeline

```text
Windows Steam / game
  -> Wine ARM64EC/WoW64 + FEX
  -> DXMT or D3D12 backend
  -> Metal drawable
  -> raw UIWindow-hosted CAMetalLayer
  -> iPhone / iPad screen
```

## Logical desktop sizing

SteamOS-iOS deliberately does not default PC software to Retina/native panel
resolution. The default is performance-oriented and follows the physical screen
aspect:

- iPhone: 720 px logical height, width derived from native aspect, clamped
  1152...1600, aligned to 8 px.
- iPad: 900 px logical height, width derived from native aspect, clamped
  1024...1440, aligned to 8 px.

For reference, a 19.5:9 iPhone is approximately 1568x720. A 4:3 iPad is
1200x900. Wider/squarer iPads resolve to a nearby width such as ~1296x900.

These values are written to `MADEIRA_SCREEN_W` and `MADEIRA_SCREEN_H`.

## On-screen fit

The native host aspect-fits the active Windows resolution. It never stretches
the image to whatever UIKit rectangle happens to exist.

In full-screen landscape mode the fitted rectangle also respects the window
safe area, preventing Windows controls from being hidden under the Dynamic
Island, rounded corners, or other unsafe regions.

If a game selects a different resolution, the same fit logic applies.

## Metal ownership

DXMT / the graphics backend owns `CAMetalLayer.drawableSize`. Swift/UIKit only
moves/resizes the layer's frame in screen points. This avoids the historical
two-writer bug where layout passes fought the guest swapchain.

## Touch coordinates

Touch uses the identical fitted rectangle:

```text
UIKit point
 -> fitted Metal-frame-local point
 -> normalize
 -> multiply by active guest width/height
 -> Windows pointer/touch coordinate
```

Letterbox/pillarbox areas therefore do not offset or scale Windows input.

## Native controls

The touch controller/editor, keyboard affordance, performance HUD, and future
quick-access UI live in native overlays above Metal. They do not consume guest
render resolution and are not drawn into the game's framebuffer.


## Local GPU requirement

The presentation path is backed by the device's local Apple GPU. Launch is
refused if `MTLCreateSystemDefaultDevice()` cannot produce a Metal device.
SteamOS-iOS clears Madeira's historical remote-Metal transport variables before
Windows execution and CI rejects code that re-enables them from the Swift
product path.

D3D11 gameplay therefore follows:

`game.exe -> Wine/FEX -> D3D11/DXGI -> DXMT -> local MTLDevice -> CAMetalLayer`.

D3D12 follows the retained Madeira D3D12-to-Metal path until capability
measurements justify adding another backend.


## Touch modes

Touch input and the on-screen controller are deliberately independent.

- **Direct touchscreen (default ON):** finger position maps to Windows touch
  coordinates through the exact Metal aspect-fit transform.
- **Trackpad/mouse-look:** available by disabling Direct Touch in Steam Settings;
  keeps the existing relative/absolute pointer semantics.
- **Controller overlay (default OFF):** optional XInput overlay in its own
  transparent UIWindow. It does not need to be visible for touchscreen input.

Three-finger tap opens Steam Settings without consuming permanent screen space.
