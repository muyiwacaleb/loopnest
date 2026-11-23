#!/bin/bash
# Double-click this file to build LoopNest.app. No Xcode project needed — just the free
# Command Line Tools, which this script offers to install if they're missing.
cd "$(dirname "$0")" || exit 1
set -e
set -o pipefail

echo "=== LoopNest builder ==="

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  echo "Apple's Command Line Tools are required. A window will open to install them."
  echo "When the install finishes, double-click Build.command again."
  xcode-select --install || true
  read -n 1 -s -r -p "Press any key to close..."
  exit 1
fi

{ echo "xcode-select: $(xcode-select -p)"; swift --version 2>&1; ls /Applications | grep -i xcode || true; } > env.log 2>&1
APP="build/LoopNest.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "-> Compiling the app (first build takes a minute or two)..."
swift build -c release 2>&1 | tee build.log | grep -E 'error|warning: unre|Compiling|Build' | tail -n 40 || { echo; echo 'BUILD FAILED - details saved to build.log'; read -n 1 -s -r -p 'Press any key to close...'; exit 1; }
BIN="$(swift build -c release --show-bin-path)/LoopNest"
cp "$BIN" "$APP/Contents/MacOS/LoopNest"
cp Resources/Info.plist "$APP/Contents/Info.plist"
echo "-> Making the app icon..."
ICS="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICS"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz Resources/AppIcon.png --out "$ICS/icon_${sz}x${sz}.png" >/dev/null
  sips -z $((sz*2)) $((sz*2)) Resources/AppIcon.png --out "$ICS/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICS" -o "$APP/Contents/Resources/AppIcon.icns" || true

echo "-> Compiling the virtual audio driver..."
DRV="$APP/Contents/Resources/LoopNestDriver.driver"
mkdir -p "$DRV/Contents/MacOS"
cp Driver/Info.plist "$DRV/Contents/Info.plist"
clang -bundle -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
  -framework CoreFoundation -framework CoreAudio \
  -o "$DRV/Contents/MacOS/LoopNestDriver" Driver/LoopNestDriver.c

echo "-> Signing..."
IDENT="LoopNest Local Signing"
if ! security find-identity -p codesigning 2>/dev/null | grep -q "$IDENT"; then
  echo "   Creating a one-time local signing certificate so macOS remembers LoopNest's permissions..."
  TMPC="$(mktemp -d)"
  printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=%s\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' "$IDENT" > "$TMPC/c.cnf"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMPC/k.pem" -out "$TMPC/c.pem" -days 3650 -config "$TMPC/c.cnf" >/dev/null 2>&1 || true
  openssl pkcs12 -export -inkey "$TMPC/k.pem" -in "$TMPC/c.pem" -out "$TMPC/c.p12" -passout pass:loopnest >/dev/null 2>&1 || true
  security import "$TMPC/c.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P loopnest -T /usr/bin/codesign >/dev/null 2>&1 || true
fi
SIGN="-"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENT"; then SIGN="$IDENT"; fi
echo "   Signing identity: $SIGN"
codesign --force --sign - "$DRV"
# With no certificate (ad-hoc signing) macOS would see every rebuild as a new app and ask for the microphone and
# system-audio permissions again. A fixed "designated requirement" based on the app's identifier keeps them.
REQ='designated => identifier "com.loopnest.app"'
if [ "$SIGN" = "-" ]; then
  codesign --force --sign - -r="$REQ" --entitlements Resources/LoopNest.entitlements "$APP"
else
  codesign --force --sign "$SIGN" --entitlements Resources/LoopNest.entitlements "$APP" 2>/dev/null || codesign --force --sign - -r="$REQ" --entitlements Resources/LoopNest.entitlements "$APP"
fi
xattr -cr "$APP" 2>/dev/null || true

echo ""
echo "Done: $(pwd)/$APP"
if [ -z "$LOOPNEST_NONINTERACTIVE" ]; then
  open -R "$APP"
  open "$APP"
  read -n 1 -s -r -p "Press any key to close..."
fi
