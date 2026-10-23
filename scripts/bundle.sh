#!/bin/bash
# Сборка «Magic Hub.app» (универсальная: Apple Silicon + Intel) и архива для раздачи.
# Запуск на Mac с Xcode 16+:  ./scripts/bundle.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ARCHS="${ARCHS:---arch arm64 --arch x86_64}"

echo "==> Сборка ($ARCHS)"
swift build -c release $ARCHS --product MagicHub
swift build -c release $ARCHS --product MediaRemoteBridge
BIN_DIR="$(swift build -c release $ARCHS --show-bin-path)"

APP="build/Magic Hub.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/MagicHub" "$APP/Contents/MacOS/MagicHub"
cp "$BIN_DIR/libMediaRemoteBridge.dylib" "$APP/Contents/Resources/"
cp Resources/mediaremote.pl "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

echo "==> Иконка"
swift scripts/make_icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Подпись: постоянным сертификатом (SIGN_IDENTITY), чтобы macOS не сбрасывала выданные
# разрешения после каждого обновления; без него — ad-hoc.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
echo "==> Подпись (${SIGN_IDENTITY})"
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/libMediaRemoteBridge.dylib"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep "$APP"
codesign -d -r- "$APP" 2>&1 | tail -1

echo "==> Архив"
(cd build && ditto -c -k --sequesterRsrc --keepParent "Magic Hub.app" "MagicHub.zip")
echo "Готово: build/Magic Hub.app и build/MagicHub.zip"
