#!/bin/bash
#
# Interactive installer for AASX Package Explorer on Linux (via Wine).
# Downloads the release from GitHub, installs dependencies (Wine + .NET
# Desktop Runtime 8) and sets up a dedicated Wine prefix to run the app.
#
# Repository: https://github.com/eclipse-aaspe/package-explorer

set -euo pipefail

REPO="eclipse-aaspe/package-explorer"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
DOTNET_DESKTOP_RUNTIME_URL="https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe"

INSTALL_DIR="${AASX_INSTALL_DIR:-$HOME/Apps/AasxPackageExplorer}"
WINEPREFIX_DIR="${AASX_WINEPREFIX:-$HOME/.wine-aasx}"
SCRATCH_DIR="$(mktemp -d)"

C_RESET="\033[0m"; C_BOLD="\033[1m"; C_GREEN="\033[32m"; C_YELLOW="\033[33m"; C_RED="\033[31m"; C_CYAN="\033[36m"

log()  { echo -e "${C_CYAN}==>${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}✔${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}⚠${C_RESET} $*"; }
err()  { echo -e "${C_RED}✘${C_RESET} $*" >&2; }

cleanup() { rm -rf "$SCRATCH_DIR"; }
trap cleanup EXIT

confirm() {
    # confirm "question" [default: Y]
    local prompt="$1" default="${2:-Y}" reply
    if [[ "$default" == "Y" ]]; then
        read -r -p "$prompt [Y/n] " reply
        reply="${reply:-Y}"
    else
        read -r -p "$prompt [y/N] " reply
        reply="${reply:-N}"
    fi
    [[ "$reply" =~ ^[Yy]$ ]]
}

require_cmd() { command -v "$1" >/dev/null 2>&1; }

DESKTOP_FILE="$HOME/.local/share/applications/aasx-package-explorer.desktop"
ICON_PNG="$HOME/.local/share/icons/hicolor/256x256/apps/aasx-package-explorer.png"
MANIFEST_FILE="$INSTALL_DIR/.install-manifest"

do_uninstall() {
    echo -e "${C_BOLD}AASX Package Explorer uninstaller${C_RESET}"
    echo

    # The manifest records the real paths used at install time (INSTALL_DIR,
    # WINEPREFIX_DIR, shortcut, icon). Without it we fall back to the default
    # paths — fine for the common case, but it won't reflect a customized
    # install (AASX_INSTALL_DIR/AASX_WINEPREFIX different from the defaults).
    if [[ -f "$MANIFEST_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$MANIFEST_FILE"
    else
        warn "Install manifest not found; using default paths (may not remove everything if the install was customized)."
    fi

    warn "This will remove:"
    echo "  - Install directory: $INSTALL_DIR"
    echo "  - Wine prefix:       $WINEPREFIX_DIR"
    echo "  - Menu shortcut:     $DESKTOP_FILE"
    echo "  - Icon:              $ICON_PNG"
    echo
    if ! confirm "Confirm removal of all of the above?" "N"; then
        log "Cancelled."
        exit 0
    fi
    rm -rf "$INSTALL_DIR" "$WINEPREFIX_DIR" "$DESKTOP_FILE" "$ICON_PNG"
    ok "AASX Package Explorer removed from the system."
    exit 0
}

if [[ "${1:-}" == "--uninstall" ]]; then
    do_uninstall
fi

# ---------------------------------------------------------------------------
echo -e "${C_BOLD}AASX Package Explorer installer for Linux (via Wine)${C_RESET}"
echo "Repository: https://github.com/${REPO}"
echo "(use '$0 --uninstall' to remove everything later)"
echo

# ---------------------------------------------------------------------------
log "Checking system dependencies..."

MISSING_PKGS=()
require_cmd curl   || MISSING_PKGS+=(curl)
require_cmd unzip  || MISSING_PKGS+=(unzip)
require_cmd wine   || MISSING_PKGS+=(wine wine64)
dpkg -s wine32:i386 >/dev/null 2>&1 || MISSING_PKGS+=(wine32:i386)

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    warn "Missing packages: ${MISSING_PKGS[*]}"
    if confirm "Install them now via apt (sudo)?"; then
        if ! dpkg --print-foreign-architectures | grep -q i386; then
            log "Enabling i386 architecture (required by Wine)..."
            sudo dpkg --add-architecture i386
        fi
        sudo apt update
        sudo apt install -y "${MISSING_PKGS[@]}"
        ok "Dependencies installed."
    else
        err "Cannot continue without the dependencies. Aborting."
        exit 1
    fi
else
    ok "All system dependencies are already present."
fi

# ---------------------------------------------------------------------------
log "Checking the latest release at github.com/${REPO}..."

RELEASE_JSON="$SCRATCH_DIR/release.json"
curl -sL "$API_URL" -o "$RELEASE_JSON"

TAG_NAME=$(grep -m1 '"tag_name"' "$RELEASE_JSON" | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
if [[ -z "$TAG_NAME" ]]; then
    err "Could not fetch the latest release from GitHub. Check your connection."
    exit 1
fi
ok "Latest release found: ${TAG_NAME}"

mapfile -t ASSET_NAMES < <(grep -o '"name": *"[^"]*\.zip"' "$RELEASE_JSON" | sed -E 's/.*"name": *"([^"]+)".*/\1/')
mapfile -t ASSET_URLS  < <(grep -o '"browser_download_url": *"[^"]*\.zip"' "$RELEASE_JSON" | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/')

if [[ ${#ASSET_NAMES[@]} -eq 0 ]]; then
    err "No .zip asset found in that release."
    exit 1
fi

# Default to the main package "aasx-package-explorer.<date>.zip"
DEFAULT_INDEX=0
for i in "${!ASSET_NAMES[@]}"; do
    if [[ "${ASSET_NAMES[$i]}" =~ ^aasx-package-explorer\.[0-9] ]]; then
        DEFAULT_INDEX=$i
        break
    fi
done

echo
echo "Packages available in this release:"
for i in "${!ASSET_NAMES[@]}"; do
    marker=" "
    [[ "$i" -eq "$DEFAULT_INDEX" ]] && marker="*"
    printf "  %s [%d] %s\n" "$marker" "$((i+1))" "${ASSET_NAMES[$i]}"
done
echo "  (* = recommended — classic WPF desktop build)"
echo

read -r -p "Choose the package number to install [$((DEFAULT_INDEX+1))]: " CHOICE
CHOICE="${CHOICE:-$((DEFAULT_INDEX+1))}"
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#ASSET_NAMES[@]} )); then
    warn "Invalid choice, using the recommended default."
    CHOICE=$((DEFAULT_INDEX+1))
fi
SELECTED_INDEX=$((CHOICE-1))
ASSET_NAME="${ASSET_NAMES[$SELECTED_INDEX]}"
ASSET_URL="${ASSET_URLS[$SELECTED_INDEX]}"

ok "Selected: ${ASSET_NAME}"

# ---------------------------------------------------------------------------
# If we already installed this exact release+package before (recorded in the
# manifest), skip the download/extraction instead of redoing ~250MB.
INSTALLED_TAG=""
INSTALLED_ASSET=""
if [[ -f "$MANIFEST_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$MANIFEST_FILE"
fi

SKIP_DOWNLOAD=false
if [[ -d "$INSTALL_DIR" && "$INSTALLED_TAG" == "$TAG_NAME" && "$INSTALLED_ASSET" == "$ASSET_NAME" ]]; then
    ok "Already installed (${TAG_NAME} / ${ASSET_NAME}) — skipping download."
    if confirm "Force reinstall anyway?" "N"; then
        rm -rf "$INSTALL_DIR"
    else
        SKIP_DOWNLOAD=true
    fi
fi

if [[ "$SKIP_DOWNLOAD" == false ]]; then
    if [[ -d "$INSTALL_DIR" ]]; then
        warn "An installation already exists at: $INSTALL_DIR"
        if confirm "Remove and reinstall?" "N"; then
            rm -rf "$INSTALL_DIR"
        else
            log "Keeping the existing installation; files will be overwritten on conflict."
        fi
    fi
    mkdir -p "$INSTALL_DIR"

    log "Downloading ${ASSET_NAME}..."
    ZIP_PATH="$SCRATCH_DIR/${ASSET_NAME}"
    curl -L --progress-bar -o "$ZIP_PATH" "$ASSET_URL"
    ok "Download complete."

    log "Extracting to ${INSTALL_DIR}..."
    # The zip is packaged on Windows and sometimes ships folders without the
    # execute bit (drw-rw-r--), which stops unzip from entering them. We give
    # u+rwx BEFORE each attempt and afterwards, to avoid getting stuck on
    # "Permission denied".
    find "$INSTALL_DIR" -type d -exec chmod u+rwx {} \; 2>/dev/null || true

    # unzip returns 1 when it only emits warnings (e.g. backslash paths from
    # the Windows-origin zip); only an exit code >= 2 means a real failure.
    set +e
    unzip -oq "$ZIP_PATH" -d "$INSTALL_DIR"
    UNZIP_STATUS=$?
    set -e

    # Make sure every extracted folder stays navigable/writable by the owner.
    find "$INSTALL_DIR" -type d -exec chmod u+rwx {} \;

    if (( UNZIP_STATUS >= 2 )); then
        err "Failed to extract the package (exit code $UNZIP_STATUS)."
        exit 1
    fi
    ok "Files extracted."
fi

# Locate the actual executable folder (the zip usually contains a subfolder)
APP_DIR=$(find "$INSTALL_DIR" -maxdepth 3 -iname "AasxPackageExplorer.exe" -o -iname "BlazorExplorer.exe" 2>/dev/null | head -n1 | xargs -r dirname)
if [[ -z "$APP_DIR" ]]; then
    err "Could not find the main executable inside the extracted package."
    exit 1
fi
EXE_NAME=$(find "$APP_DIR" -maxdepth 1 \( -iname "AasxPackageExplorer.exe" -o -iname "BlazorExplorer.exe" \) -printf "%f\n" | head -n1)
ok "Executable: ${APP_DIR}/${EXE_NAME}"

# ---------------------------------------------------------------------------
log "Setting up the Wine prefix at ${WINEPREFIX_DIR}..."
export WINEARCH=win64
export WINEPREFIX="$WINEPREFIX_DIR"

if [[ ! -d "$WINEPREFIX_DIR" ]]; then
    wineboot --init >/dev/null 2>&1 || true
    ok "Wine prefix created."
else
    ok "Wine prefix already exists, reusing it."
fi

# Check whether the .NET Windows Desktop Runtime is already in the prefix
if find "$WINEPREFIX_DIR/drive_c/Program Files/dotnet/shared/Microsoft.WindowsDesktop.App" -maxdepth 1 -mindepth 1 2>/dev/null | grep -q .; then
    ok ".NET Desktop Runtime already installed in the prefix."
else
    log "Downloading .NET Windows Desktop Runtime 8..."
    RUNTIME_EXE="$SCRATCH_DIR/windowsdesktop-runtime-win-x64.exe"
    curl -L --progress-bar -o "$RUNTIME_EXE" "$DOTNET_DESKTOP_RUNTIME_URL"

    log "Installing .NET Desktop Runtime in the Wine prefix (this can take 1-2 minutes)..."
    wine "$RUNTIME_EXE" /install /quiet /norestart >/dev/null 2>&1 || true

    if find "$WINEPREFIX_DIR/drive_c/Program Files/dotnet/shared/Microsoft.WindowsDesktop.App" -maxdepth 1 -mindepth 1 2>/dev/null | grep -q .; then
        ok ".NET Desktop Runtime installed successfully."
    else
        err "Failed to install the .NET Desktop Runtime. Check it manually with winetricks."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
log "Generating the launch script..."

RUN_SCRIPT="$INSTALL_DIR/run.sh"
cat > "$RUN_SCRIPT" <<EOF
#!/bin/bash
# Runs AASX Package Explorer via Wine
export WINEARCH=win64
export WINEPREFIX="$WINEPREFIX_DIR"
cd "$APP_DIR"
wine "$EXE_NAME" "\$@"
EOF
chmod +x "$RUN_SCRIPT"
ok "Launch script created at: $RUN_SCRIPT"

# ---------------------------------------------------------------------------
if confirm "Create an application menu shortcut (.desktop)?"; then
    mkdir -p "$(dirname "$DESKTOP_FILE")" "$(dirname "$ICON_PNG")"

    # The .desktop entry needs a raster icon (png/svg). The package doesn't
    # ship a standalone .ico: the icon is embedded as a resource inside the
    # .exe itself. We extract it with wrestool (icoutils) and convert it with
    # Pillow, which handles the format fine even when icotool complains about
    # "incorrect total size".
    ICON_MISSING_PKGS=()
    require_cmd wrestool || ICON_MISSING_PKGS+=(icoutils)
    python3 -c "import PIL" >/dev/null 2>&1 || ICON_MISSING_PKGS+=(python3-pil)
    if [[ ${#ICON_MISSING_PKGS[@]} -gt 0 ]]; then
        warn "Missing to extract the real app icon: ${ICON_MISSING_PKGS[*]}"
        if confirm "Install them now via apt (sudo)?"; then
            sudo apt update
            sudo apt install -y "${ICON_MISSING_PKGS[@]}"
        fi
    fi

    ICON_PATH=""
    if require_cmd wrestool && python3 -c "import PIL" >/dev/null 2>&1; then
        GROUP_ID=$(wrestool -l "$APP_DIR/$EXE_NAME" 2>/dev/null | grep -m1 'type=group_icon' | sed -E 's/.*--name=([0-9]+).*/\1/')
        if [[ -n "$GROUP_ID" ]]; then
            ICO_TMP="$SCRATCH_DIR/app-icon.ico"
            wrestool -x --output="$ICO_TMP" --type=group_icon --name="$GROUP_ID" "$APP_DIR/$EXE_NAME" >/dev/null 2>&1 || true
            if [[ -f "$ICO_TMP" ]]; then
                python3 - "$ICO_TMP" "$ICON_PNG" <<'PYEOF' >/dev/null 2>&1 || true
import sys
from PIL import Image
ico = Image.open(sys.argv[1])
sizes = ico.info.get("sizes") or [(256, 256)]
ico.size = max(sizes)
ico.load()
ico.save(sys.argv[2])
PYEOF
            fi
        fi
    fi
    [[ -f "$ICON_PNG" ]] && ICON_PATH="$ICON_PNG"
    if [[ -z "$ICON_PATH" ]]; then
        warn "Could not convert the icon embedded in the .exe; using a generic icon instead. Install 'icoutils' and the Python 'Pillow' module (python3-pil) for the real icon."
    fi

    cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=AASX Package Explorer
Comment=AASX package editor/viewer (Asset Administration Shell)
Exec=$RUN_SCRIPT
Icon=${ICON_PATH:-applications-engineering}
Terminal=false
Categories=Development;Engineering;
EOF
    ok "Shortcut created: $DESKTOP_FILE"
fi

# ---------------------------------------------------------------------------
# Write the manifest so --uninstall can find the real paths later, even if
# the install used a customized AASX_INSTALL_DIR/AASX_WINEPREFIX.
cat > "$MANIFEST_FILE" <<EOF
INSTALL_DIR="$INSTALL_DIR"
WINEPREFIX_DIR="$WINEPREFIX_DIR"
DESKTOP_FILE="$DESKTOP_FILE"
ICON_PNG="$ICON_PNG"
INSTALLED_TAG="$TAG_NAME"
INSTALLED_ASSET="$ASSET_NAME"
EOF

echo
ok "Installation complete!"
echo -e "To run the program: ${C_BOLD}$RUN_SCRIPT${C_RESET}"
echo

if confirm "Run AASX Package Explorer now?"; then
    "$RUN_SCRIPT" &
    disown
fi
