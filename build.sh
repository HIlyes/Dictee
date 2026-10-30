#!/bin/bash
# Compile Dictée et produit Dictee.app (signature ad hoc, usage perso)
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=Dictee.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Dictee "$APP/Contents/MacOS/Dictee"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Dictée</string>
    <key>CFBundleDisplayName</key><string>Dictée</string>
    <key>CFBundleIdentifier</key><string>perso.dictee</string>
    <key>CFBundleExecutable</key><string>Dictee</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.6.2</string>
    <key>CFBundleVersion</key><string>8</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Dictée écoute le micro pendant que tu maintiens le raccourci, pour transcrire ta voix en local.</string>
</dict>
</plist>
PLIST
# Signature avec le certificat perso du trousseau : macOS reconnaît l'app au certificat,
# pas à son empreinte, donc l'autorisation d'accessibilité survit aux recompilations.
# Sans ce certificat, signature ad hoc (il faudra réautoriser après chaque compilation).
IDENTITY=$(security find-identity -p codesigning | awk '/"Dictee Signature Perso"/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"

# Installation dans ~/Applications (remplace la version précédente)
pkill -x Dictee || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/$APP"
ditto "$APP" "$HOME/Applications/$APP"
echo "Installé : $HOME/Applications/$APP"
