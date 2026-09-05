#!/bin/sh
# Builds spec.app: a universal binary plus the Z80 library it dlopen()s.
#
# The emulator has no link-time dependency on Z80 - Z80.pas resolves it at
# runtime through dlopen - so there is no @rpath to fix up. What the bundle
# does need is for the dylib to sit in Contents/Frameworks, which is both
# where LoadLibZ80 looks and where codesign and notarytool expect nested code
# to be. Anywhere else and the signature will not seal it.
#
# The dylib stays a dylib on purpose: the Z80 library is LGPL v3, and loading
# it dynamically is what keeps the emulator's own MIT terms uncomplicated.
set -eu

cd "$(dirname "$0")"

APP=spec.app
CONTENTS=$APP/Contents
SIGN_ID=${SIGN_ID:--}   # ad-hoc by default; a Developer ID name for a release

if [ "${1:-}" != "--no-compile" ]; then
  lazbuild --build-mode=Release --cpu=aarch64 --os=darwin spec.lpi
  mv spec spec-arm
  lazbuild --build-mode=Release --cpu=x86_64 --os=darwin spec.lpi
  mv spec spec-intel
fi

lipo -create spec-arm spec-intel -output spec

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Frameworks"

cp spec "$CONTENTS/MacOS/spec"
cp lib/libZ80.dylib "$CONTENTS/Frameworks/libZ80.dylib"
chmod 755 "$CONTENTS/MacOS/spec" "$CONTENTS/Frameworks/libZ80.dylib"

printf 'APPL????' > "$CONTENTS/PkgInfo"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>English</string>
  <key>CFBundleExecutable</key>
  <string>spec</string>
  <key>CFBundleName</key>
  <string>spec</string>
  <key>CFBundleIdentifier</key>
  <string>org.olatov.spec</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleSignature</key>
  <string>spec</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CSResourcesFileMapped</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>CFBundleTypeName</key>
      <string>ZX Spectrum snapshot or tape</string>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>z80</string>
        <string>tap</string>
        <string>wav</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Nested code is signed innermost-first: the dylib on its own, then the
# bundle, which seals the dylib's signature into CodeResources.
codesign --force --sign "$SIGN_ID" "$CONTENTS/Frameworks/libZ80.dylib"
codesign --force --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"

echo "built $APP ($(lipo -archs spec))"
