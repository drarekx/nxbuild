#!/bin/zsh
# Compila NXBuild y lo empaqueta como "NX Build.app".
#   ./make_app.sh                          → ../NX Build.app (copia de desarrollo, junto a build_ipa.command)
#   OUT=build ZIP=1 VERSION=1.2.0 ./make_app.sh   → build/NX Build.app + build/NXBuild.zip (lo que hace el workflow de versiones)
# VERSION: por defecto, la última etiqueta v* de git (sin la v), o 0.0.0 sin etiquetas.
set -euo pipefail
HERE="${0:A:h}"
cd "$HERE"

if [[ -z "${VERSION:-}" ]]; then
    VERSION=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo v0.0.0)
    VERSION=${VERSION#v}
fi
BUILD=${BUILD:-1}
OUT=${OUT:-$HERE/..}
mkdir -p "$OUT"
OUT=${OUT:A}

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/NXBuild"

APP="$OUT/NX Build.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NXBuild"
cp "$HERE/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"   # swift Tools/make_icon.swift lo regenera
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>NX Build</string>
  <key>CFBundleDisplayName</key><string>NX Build</string>
  <key>CFBundleIdentifier</key><string>com.egluu.nxbuild</string>
  <key>CFBundleExecutable</key><string>NXBuild</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>NX Build se conecta a tu servidor Filebox de la red local para ver la colección y descargar los juegos.</string>
  <key>NSAppTransportSecurity</key><dict>
    <key>NSAllowsLocalNetworking</key><true/>
    <key>NSAllowsArbitraryLoads</key><true/>
  </dict>
  <key>CFBundleDevelopmentRegion</key><string>es</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"

if [[ -n "${ZIP:-}" ]]; then
    (cd "$OUT" && rm -f NXBuild.zip NXBuild.zip.sha256 \
        && ditto -c -k --norsrc --noextattr --keepParent "NX Build.app" NXBuild.zip \
        && shasum -a 256 NXBuild.zip | awk '{print $1}' > NXBuild.zip.sha256)
    echo "Listo: $APP ($VERSION) y $OUT/NXBuild.zip"
else
    echo "Listo: $APP ($VERSION)"
fi
