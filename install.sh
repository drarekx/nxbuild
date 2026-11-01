#!/bin/bash
# Instalador de NX Build.
#   Repositorio público:  curl -fsSL https://raw.githubusercontent.com/drarekx/nxbuild/main/install.sh | bash
#   Repositorio privado:  gh api repos/drarekx/nxbuild/contents/install.sh -H "Accept: application/vnd.github.raw" | bash
# Con el repositorio privado la descarga va por gh (con tu sesión: gh auth login).
# Opciones (después de `bash -s --`):
#   --version 1.2.0   instala esa versión en vez de la última
set -euo pipefail

REPO="drarekx/nxbuild"
ASSET="NXBuild.zip"
TAG=""
while (( $# )); do
    case "$1" in
        --version) TAG="v${2#v}"; shift 2 ;;
        *) shift ;;
    esac
done

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
fail() { printf "\033[31mError:\033[0m %s\n" "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "NX Build solo funciona en macOS."
[[ "$(uname -m)" == "arm64" ]] || fail "NX Build necesita un Mac con Apple Silicon."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 15 )) || fail "NX Build necesita macOS 15 (Sequoia) o posterior. Tienes $(sw_vers -productVersion)."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bold "Descargando NX Build${TAG:+ $TAG}…"
if [[ -n "$TAG" ]]; then
    url="https://github.com/$REPO/releases/download/$TAG/$ASSET"
else
    url="https://github.com/$REPO/releases/latest/download/$ASSET"
fi
if ! curl -fsL "$url" -o "$tmp/$ASSET" 2>/dev/null || ! curl -fsL "$url.sha256" -o "$tmp/$ASSET.sha256" 2>/dev/null; then
    # Repositorio privado: por gh con la sesión del usuario.
    gh=""
    for c in /opt/homebrew/bin/gh /usr/local/bin/gh "$(command -v gh 2>/dev/null || true)"; do
        [[ -n "$c" && -x "$c" ]] && { gh="$c"; break; }
    done
    [[ -n "$gh" ]] || fail "No se pudo descargar $url. Si el repositorio es privado, instala gh (brew install gh) e inicia sesión (gh auth login)."
    "$gh" auth status >/dev/null 2>&1 || fail "gh no tiene sesión iniciada: ejecuta gh auth login y vuelve a probar."
    rm -f "$tmp/$ASSET" "$tmp/$ASSET.sha256"
    "$gh" release download ${TAG:+"$TAG"} --repo "$REPO" --pattern "$ASSET" --pattern "$ASSET.sha256" --dir "$tmp" \
        || fail "gh no pudo descargar la versión${TAG:+ $TAG} de $REPO."
fi

expected=$(awk '{print $1}' "$tmp/$ASSET.sha256")
actual=$(shasum -a 256 "$tmp/$ASSET" | awk '{print $1}')
[[ -n "$expected" && "$expected" == "$actual" ]] || fail "La descarga no coincide con su huella SHA-256. No se ha instalado nada."

ditto -x -k "$tmp/$ASSET" "$tmp"
[[ -d "$tmp/NX Build.app" ]] || fail "El archivo descargado no contiene NX Build.app"

# Cerrar una copia abierta para poder sustituirla (si hay una build en marcha, la app pide confirmación).
if pgrep -f "NX Build.app/Contents/MacOS/NXBuild" >/dev/null; then
    bold "Cerrando NX Build…"
    osascript -e 'tell application id "com.egluu.nxbuild" to quit' 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "NX Build.app/Contents/MacOS/NXBuild" >/dev/null || break
        sleep 1
    done
    pgrep -f "NX Build.app/Contents/MacOS/NXBuild" >/dev/null && fail "NX Build sigue abierta (¿una build en marcha?). Ciérrala y vuelve a ejecutar el instalador."
fi

dest="/Applications"
if [[ ! -w "$dest" ]]; then
    dest="$HOME/Applications"
    mkdir -p "$dest"
fi
rm -rf "$dest/NX Build.app"
mv "$tmp/NX Build.app" "$dest/"
# La app no está notarizada (firma ad hoc): sin el aviso de Gatekeeper para esta copia.
xattr -dr com.apple.quarantine "$dest/NX Build.app" 2>/dev/null || true
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$dest/NX Build.app/Contents/Info.plist" 2>/dev/null || echo "?")
bold "Instalada NX Build $version en $dest/NX Build.app"

open "$dest/NX Build.app"
echo
echo "NX Build necesita el repositorio nxnative y sus herramientas (Xcode, Python, Homebrew…)."
echo "Ábrela y mira Dependencias (⇧⌘D): comprueba lo que falta y lo instala."
echo "Las siguientes versiones se instalan desde la propia app (NX Build › Buscar actualizaciones…)."
