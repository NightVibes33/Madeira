# SteamOS-iOS bootable alpha gates

A build is a **BOOTABLE ALPHA** only when every item below is proven on-device.

- [ ] IPA launches
- [ ] Steam is the first interactive UI; Madeira diagnostics shell is not shown
- [ ] JIT READY: generated executable code returns 42
- [ ] executable JIT pool allocates successfully
- [ ] local Apple GPU / MTLDevice READY
- [ ] remote Metal transport is disabled
- [ ] FEX x64 READY
- [ ] Wine ARM64EC READY
- [ ] Wine WoW64/x86 READY
- [ ] official Valve SteamSetup.exe downloads on first run
- [ ] official Windows Steam installs into the app-owned Wine prefix
- [ ] real Windows Steam starts
- [ ] steamwebhelper / CEF renders
- [ ] Steam login works
- [ ] Steam Guard works
- [ ] library populates
- [ ] owned Windows game downloads
- [ ] PLAY launches the game locally
- [ ] game renders through Metal
- [ ] aspect-correct iPhone/iPad safe-area presentation works
- [ ] audio works
- [ ] physical controller works
- [ ] direct touchscreen works with controller overlay OFF
- [ ] optional on-screen controller can be enabled in Steam Settings
- [ ] default XInput touch layout works, including exactly one L3/R3 pair
- [ ] controller editor persists layout
- [ ] editing/resetting preserves controller-overlay ON/OFF preference
- [ ] game exits back to Steam

## First game rule

Use a lightweight D3D11 Windows title first. The first playable-title milestone must exercise:

`Steam -> game.exe -> Wine/FEX -> D3D11/DXGI -> DXMT -> Metal`.

D3D12 work proceeds after that path is repeatable.
