#!/bin/bash
# ./build.sh           self-check, then build build/Juggle.app (Apple silicon + Intel)
# ./build.sh install   also replace /Applications/Juggle.app and start it
# ./build.sh zip       also make build/Juggle.zip for a GitHub release
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

swiftc Sources/Logic.swift Tests/main.swift -o build/selfcheck  # no -O, so asserts run
build/selfcheck

[[ -f Resources/AppIcon.icns ]] || Tools/make-icon.sh

APP=build/Juggle.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
for arch in arm64 x86_64; do
    swiftc -O -parse-as-library -target $arch-apple-macos15.0 Sources/Logic.swift Sources/App.swift -o build/Juggle-$arch
done
lipo -create build/Juggle-arm64 build/Juggle-x86_64 -output "$APP/Contents/MacOS/Juggle"
rm build/Juggle-arm64 build/Juggle-x86_64
codesign --force --sign - "$APP"  # ad-hoc: no paid Developer ID, see README for first launch
echo "Built $APP"

case "${1:-}" in
install)
    pkill -x Juggle || true
    rm -rf /Applications/Juggle.app
    cp -R "$APP" /Applications/
    open /Applications/Juggle.app
    echo "Installed and started /Applications/Juggle.app" ;;
zip)
    rm -f build/Juggle.zip
    ditto -c -k --keepParent "$APP" build/Juggle.zip
    echo "Made build/Juggle.zip" ;;
esac
