#!/bin/bash
# Сборка T8LMouse.app. Нужны только Command Line Tools: xcode-select --install
# Использование:  ./build.sh           — собрать в папку build/
#                 ./build.sh install   — собрать и скопировать в /Applications
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Не найден компилятор Swift. Установите инструменты командой:  xcode-select --install"
    exit 1
fi

ARCH="${ARCH:-$(uname -m)}"  # arm64 на M1/M2/M3
APP="build/T8LMouse.app"

echo "==> Сборка для ${ARCH}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun -sdk macosx swiftc -O -swift-version 5 \
    -target "${ARCH}-apple-macos12.0" \
    -framework IOKit -framework AppKit -framework SwiftUI -framework ApplicationServices \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/T8LMouse"

cp Info.plist "$APP/Contents/Info.plist"

# Иконка: Resources/AppIcon.png -> AppIcon.icns
if [[ -f Resources/AppIcon.png ]] && command -v iconutil >/dev/null; then
    ICONSET="build/AppIcon.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "(предупреждение: не удалось подписать — обычно не страшно)"

echo "==> Готово: $APP"

if [[ "${1:-}" == "ci" ]]; then
    exit 0
elif [[ "${1:-}" == "install" ]]; then
    rm -rf "/Applications/T8LMouse.app"
    cp -R "$APP" /Applications/
    echo "==> Установлено в /Applications/T8LMouse.app"
    open "/Applications/T8LMouse.app"
else
    open "$APP"
fi
