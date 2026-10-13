#!/bin/bash
# Builds Cyclop.app without Xcode: SwiftPM produces the binary, this script
# assembles the bundle around it and signs it — ad-hoc by default, with a
# Developer ID when CODESIGN_IDENTITY names one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Cyclop.app"
source "$ROOT/Scripts/sdk.sh"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version" 2>/dev/null || echo 0.1.0)"

# Эхоподавитель для вкладки «Встречи»: нативная библиотека и её модель. Без cmake
# сборка останавливается; CYCLOP_SKIP_LOCALVQE=1 собирает бандл без них (CI), и
# тогда встречи расшифровываются по сырым дорожкам.
if [ "${CYCLOP_SKIP_LOCALVQE:-}" != "1" ]; then
    echo "==> LocalVQE"
    "$ROOT/Scripts/build-localvqe.sh"
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/Cyclop"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cyclop"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Cyclop</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>ru</string></array>
    <key>CFBundleDisplayName</key><string>Cyclop</string>
    <key>CFBundleIdentifier</key><string>com.cyclop.app</string>
    <key>CFBundleExecutable</key><string>Cyclop</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSMicrophoneUsageDescription</key><string>Cyclop records your microphone during a meeting to write its transcript.</string>
    <key>NSAudioCaptureUsageDescription</key><string>Cyclop records system audio during a meeting so the other side of the call is in the transcript.</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

LOCALVQE="$ROOT/.build/localvqe"
if [ "${CYCLOP_SKIP_LOCALVQE:-}" != "1" ]; then
    mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources/Models" "$APP/Contents/Resources/Licenses"
    cp "$LOCALVQE/lib/liblocalvqe.dylib" "$APP/Contents/Frameworks/"
    cp "$LOCALVQE"/model/*.gguf "$APP/Contents/Resources/Models/"
    cp "$LOCALVQE"/licenses/* "$APP/Contents/Resources/Licenses/"
fi

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Таблицы строк кладутся прямо в бандл, а не через ресурсы SwiftPM: бандл здесь
# собирается вручную, и .lproj рядом с исполняемым файлом — то, где их ищет сама
# macOS. Язык она выбирает потом сама, по списку предпочитаемых у пользователя.
echo "==> локализации"
for lproj in "$ROOT"/Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$APP/Contents/Resources/"
    echo "    $(basename "$lproj")"
done

# Подпись. Кем — решает CODESIGN_IDENTITY: «-» — ad-hoc; «Developer ID
# Application: …» — настоящая, с hardened runtime и отметкой времени, как для
# релиза. Пусто — берётся самоподписанный «Cyclop Local», если он есть в связке
# (разрешения на микрофон и звук системы привязаны к подписи и переживают
# пересборку), иначе ad-hoc. Ключ и сертификат в скрипте не живут, они в связке
# ключей того, кто выпускает, или в секретах раннера (см. docs/signing.md).
LOCAL_IDENTITY="Cyclop Local"
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    if security find-identity -v -p codesigning | grep -q "\"$LOCAL_IDENTITY\""; then
        IDENTITY="$LOCAL_IDENTITY"
    else
        IDENTITY="-"
    fi
fi
if [ "$IDENTITY" = "-" ]; then
    echo "==> ad-hoc signing: разрешения на микрофон и звук системы не переживут пересборку (docs/signing.md)"
elif [ "$IDENTITY" = "$LOCAL_IDENTITY" ]; then
    echo "==> signing as $IDENTITY (без hardened runtime)"
else
    echo "==> signing as $IDENTITY"
fi

# Расширенные атрибуты снимаются первыми. iCloud вешает на файлы
# com.apple.FinderInfo, а codesign отказывается подписывать что-либо с ним —
# «resource fork, Finder information, or similar detritus not allowed». Папка
# «Рабочий стол» синхронизируется с iCloud у многих по умолчанию, так что клон
# репозитория там перестает подписываться, стоило его туда перенести.
xattr -cr "$APP"

# Hardened runtime — только с настоящей подписью: ad-hoc-сборке он ничего не
# даёт, нотаризовать её всё равно нельзя.
#
# Ошибка не глушится и не понижается до предупреждения. Раньше отказ печатал
# мягкую строку и возвращал ноль: скрипт доходил до «done», а в build лежал
# бандл, про который codesign говорит «code object is not signed at all».
# Заметить это можно было только по возвращающимся запросам TCC — то есть у
# того, кто уже поставил приложение.
# Библиотека подписывается раньше бандла, тем же ключом.
DYLIB="$APP/Contents/Frameworks/liblocalvqe.dylib"
if [ "$IDENTITY" = "-" ] || [ "$IDENTITY" = "$LOCAL_IDENTITY" ]; then
    [ -f "$DYLIB" ] && codesign --force --sign "$IDENTITY" "$DYLIB"
    codesign --force --sign "$IDENTITY" "$APP"
else
    [ -f "$DYLIB" ] && codesign --force --timestamp --options runtime --sign "$IDENTITY" "$DYLIB"
    # Под hardened runtime микрофон без этого права молчит, без запроса.
    codesign --force --timestamp --options runtime \
        --entitlements "$ROOT/Resources/Cyclop.entitlements" --sign "$IDENTITY" "$APP"
fi || {
    echo "!!! codesign не смог подписать бандл — см. вывод выше" >&2
    exit 1
}
codesign --verify --strict --deep "$APP" || {
    echo "!!! подпись не прошла проверку" >&2
    exit 1
}

echo "==> done: $APP"
