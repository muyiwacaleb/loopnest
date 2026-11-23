# Installing LoopNest

## Requirements
- A Mac with **macOS 14.4 or newer** (Apple silicon or Intel for the driver; the app is built for the architecture of the Mac that builds it).
- **No third-party dependencies.** LoopNest only uses frameworks that ship with macOS (CoreAudio, AVFoundation, AudioToolbox, CoreMIDI, Accelerate, ServiceManagement).
- To build from source you need Apple's free **Command Line Tools** (`xcode-select --install`). Full Xcode is not required.
- Optional add-ons: Node.js 18+ for the Bitfocus Companion module; the Elgato Stream Deck app for the Stream Deck plug-in.

## Option A: the disk image (easiest)
1. Get `LoopNest-<version>.dmg` (build it with `Package.command`, see below, or download it from a release).
2. Open it and drag **LoopNest** into **Applications**.
3. First launch: right-click LoopNest, choose **Open**, then **Open** again. The app is ad-hoc signed, not notarized, so macOS asks once.
4. Allow **Microphone** and **System Audio Recording** when asked (System Settings > Privacy & Security). Quit and reopen LoopNest once afterwards.
5. Install the virtual audio driver from inside the app (Stream page, or Routing > New Virtual Device > Install Driver). It asks for your Mac password and restarts macOS audio for a few seconds. This copies `LoopNestDriver.driver` to `/Library/Audio/Plug-Ins/HAL/` and writes `/Library/Application Support/LoopNest/devices.plist`.
6. In OBS, Zoom, Teams, etc. choose **LoopNest Stream** or **LoopNest Meeting** as the microphone.

## Option B: build from source
```
git clone <this repository>
cd loopnest
./Build.command        # builds build/LoopNest.app (also double-clickable in Finder)
./Package.command      # builds and writes dist/LoopNest-<version>.dmg plus a .sha256 file
./Test.command         # runs the built-in self-tests (34 checks)
```
`Build.command` compiles the Swift app with `swift build -c release`, compiles the C driver with `clang` (universal arm64 + x86_64), builds the icon, creates the `.app` bundle and signs it ad-hoc with a fixed designated requirement (`identifier "com.loopnest.app"`) so macOS keeps granted permissions across rebuilds.

## Signing and notarizing for distribution
For a copy that opens without the right-click step you need an Apple Developer ID:
1. `codesign --force --options runtime --entitlements Resources/LoopNest.entitlements --sign "Developer ID Application: YOUR NAME (TEAMID)" build/LoopNest.app` (sign the driver inside `Contents/Resources/LoopNestDriver.driver` first).
2. Zip or dmg it, then `xcrun notarytool submit <file> --apple-id ... --team-id ... --wait`, then `xcrun stapler staple`.
A third-party audio driver also needs the user to approve it once; macOS Audio Server plug-ins in `/Library/Audio/Plug-Ins/HAL` do not need a kernel extension.

## Uninstalling
LoopNest > Settings > remove the virtual audio driver (asks for your password), then delete LoopNest from Applications. Settings live in `~/Library/Preferences/com.loopnest.app.plist` and `~/Library/Application Support/LoopNest/`.
