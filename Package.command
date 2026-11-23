#!/bin/bash
# Double-click to build LoopNest and wrap it in an installable disk image: dist/LoopNest-<version>.dmg
# The disk image holds LoopNest.app (with the virtual audio driver inside it), a shortcut to Applications,
# and a short read-me. LoopNest has no third-party dependencies: it only uses frameworks that ship with macOS 14.4+.
cd "$(dirname "$0")" || exit 1
set -e
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
echo "=== Packaging LoopNest $VERSION ==="
LOOPNEST_NONINTERACTIVE=1 ./Build.command
APP="build/LoopNest.app"
[ -d "$APP" ] || { echo "Build did not produce $APP"; read -n 1 -s -r -p "Press any key to close..."; exit 1; }
codesign --verify --deep "$APP" && echo "-> App signature OK"
STAGE="$(mktemp -d)/LoopNest"
mkdir -p "$STAGE" dist
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
LoopNest - install
1. Drag LoopNest into Applications.
2. Open it. If macOS says it cannot verify the developer, right-click LoopNest, choose Open, then Open again.
   (This build is not notarized by Apple. See docs/INSTALL.md in the source for signing your own copy.)
3. Allow Microphone and System Audio Recording when macOS asks, then quit and reopen LoopNest once.
4. For the virtual devices (LoopNest Stream, LoopNest Meeting, your own): open LoopNest, go to the Stream page,
   press the install button. It asks for your Mac password and restarts macOS audio for a few seconds.
5. In OBS, Zoom or any app, pick "LoopNest Stream" (or "LoopNest Meeting") as the microphone.

Needs macOS 14.4 or newer. Nothing else to install.
To remove: LoopNest > Settings > remove the virtual audio driver, then delete LoopNest from Applications.
TXT
DMG="dist/LoopNest-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "LoopNest $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo ""
echo "Done: $(pwd)/$DMG"
open -R "$DMG"
read -n 1 -s -r -p "Press any key to close..."
