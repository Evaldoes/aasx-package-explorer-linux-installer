#!/bin/bash
#
# Instalador interativo do AASX Package Explorer para Linux (via Wine).
# Baixa a release do GitHub, instala dependências (Wine + .NET Desktop
# Runtime 8) e configura um prefixo Wine dedicado para rodar o programa.
#
# Repositório: https://github.com/eclipse-aaspe/package-explorer

set -euo pipefail

REPO="eclipse-aaspe/package-explorer"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
DOTNET_DESKTOP_RUNTIME_URL="https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe"

INSTALL_DIR="${AASX_INSTALL_DIR:-$HOME/Aplicativos/AasxPackageExplorer}"
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
    # confirm "pergunta" [default: S]
    local prompt="$1" default="${2:-S}" reply
    if [[ "$default" == "S" ]]; then
        read -r -p "$prompt [S/n] " reply
        reply="${reply:-S}"
    else
        read -r -p "$prompt [s/N] " reply
        reply="${reply:-N}"
    fi
    [[ "$reply" =~ ^[Ss]$ ]]
}

require_cmd() { command -v "$1" >/dev/null 2>&1; }

DESKTOP_FILE="$HOME/.local/share/applications/aasx-package-explorer.desktop"
ICON_PNG="$HOME/.local/share/icons/hicolor/256x256/apps/aasx-package-explorer.png"
MANIFEST_FILE="$INSTALL_DIR/.install-manifest"

do_uninstall() {
    echo -e "${C_BOLD}Desinstalador do AASX Package Explorer${C_RESET}"
    echo

    # O manifesto grava os caminhos reais usados na instalação (INSTALL_DIR,
    # WINEPREFIX_DIR, atalho e ícone). Sem ele, caímos nos caminhos padrão —
    # o que funciona no caso comum, mas não reflete uma instalação em local
    # customizado (AASX_INSTALL_DIR/AASX_WINEPREFIX diferentes do padrão).
    if [[ -f "$MANIFEST_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$MANIFEST_FILE"
    else
        warn "Manifesto de instalação não encontrado; usando caminhos padrão (pode não remover tudo se a instalação foi customizada)."
    fi

    warn "Isto vai remover:"
    echo "  - Pasta de instalação: $INSTALL_DIR"
    echo "  - Prefixo Wine:        $WINEPREFIX_DIR"
    echo "  - Atalho de menu:      $DESKTOP_FILE"
    echo "  - Ícone:               $ICON_PNG"
    echo
    if ! confirm "Confirma a remoção de tudo isso?" "N"; then
        log "Cancelado."
        exit 0
    fi
    rm -rf "$INSTALL_DIR" "$WINEPREFIX_DIR" "$DESKTOP_FILE" "$ICON_PNG"
    ok "AASX Package Explorer removido do sistema."
    exit 0
}

if [[ "${1:-}" == "--uninstall" ]]; then
    do_uninstall
fi

# ---------------------------------------------------------------------------
echo -e "${C_BOLD}Instalador do AASX Package Explorer para Linux (via Wine)${C_RESET}"
echo "Repositório: https://github.com/${REPO}"
echo "(use '$0 --uninstall' para remover tudo depois)"
echo

# ---------------------------------------------------------------------------
log "Verificando dependências do sistema..."

MISSING_PKGS=()
require_cmd curl   || MISSING_PKGS+=(curl)
require_cmd unzip  || MISSING_PKGS+=(unzip)
require_cmd wine   || MISSING_PKGS+=(wine wine64)
dpkg -s wine32:i386 >/dev/null 2>&1 || MISSING_PKGS+=(wine32:i386)

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    warn "Pacotes ausentes: ${MISSING_PKGS[*]}"
    if confirm "Instalar agora via apt (sudo)?"; then
        if ! dpkg --print-foreign-architectures | grep -q i386; then
            log "Habilitando arquitetura i386 (necessária para o Wine)..."
            sudo dpkg --add-architecture i386
        fi
        sudo apt update
        sudo apt install -y "${MISSING_PKGS[@]}"
        ok "Dependências instaladas."
    else
        err "Não é possível continuar sem as dependências. Abortando."
        exit 1
    fi
else
    ok "Todas as dependências do sistema já estão presentes."
fi

# ---------------------------------------------------------------------------
log "Consultando a última release em github.com/${REPO}..."

RELEASE_JSON="$SCRATCH_DIR/release.json"
curl -sL "$API_URL" -o "$RELEASE_JSON"

TAG_NAME=$(grep -m1 '"tag_name"' "$RELEASE_JSON" | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
if [[ -z "$TAG_NAME" ]]; then
    err "Não foi possível obter a última release do GitHub. Verifique sua conexão."
    exit 1
fi
ok "Última release encontrada: ${TAG_NAME}"

mapfile -t ASSET_NAMES < <(grep -o '"name": *"[^"]*\.zip"' "$RELEASE_JSON" | sed -E 's/.*"name": *"([^"]+)".*/\1/')
mapfile -t ASSET_URLS  < <(grep -o '"browser_download_url": *"[^"]*\.zip"' "$RELEASE_JSON" | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/')

if [[ ${#ASSET_NAMES[@]} -eq 0 ]]; then
    err "Nenhum asset .zip encontrado nessa release."
    exit 1
fi

# Escolhe como padrão o pacote principal "aasx-package-explorer.<data>.zip"
DEFAULT_INDEX=0
for i in "${!ASSET_NAMES[@]}"; do
    if [[ "${ASSET_NAMES[$i]}" =~ ^aasx-package-explorer\.[0-9] ]]; then
        DEFAULT_INDEX=$i
        break
    fi
done

echo
echo "Pacotes disponíveis nessa release:"
for i in "${!ASSET_NAMES[@]}"; do
    marker=" "
    [[ "$i" -eq "$DEFAULT_INDEX" ]] && marker="*"
    printf "  %s [%d] %s\n" "$marker" "$((i+1))" "${ASSET_NAMES[$i]}"
done
echo "  (* = recomendado — versão desktop clássica WPF)"
echo

read -r -p "Escolha o número do pacote a instalar [$((DEFAULT_INDEX+1))]: " CHOICE
CHOICE="${CHOICE:-$((DEFAULT_INDEX+1))}"
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#ASSET_NAMES[@]} )); then
    warn "Opção inválida, usando o padrão recomendado."
    CHOICE=$((DEFAULT_INDEX+1))
fi
SELECTED_INDEX=$((CHOICE-1))
ASSET_NAME="${ASSET_NAMES[$SELECTED_INDEX]}"
ASSET_URL="${ASSET_URLS[$SELECTED_INDEX]}"

ok "Selecionado: ${ASSET_NAME}"

# ---------------------------------------------------------------------------
# Se já instalamos exatamente essa release+pacote antes (registrado no
# manifesto), pula o download/extração de novo em vez de repetir ~250MB.
INSTALLED_TAG=""
INSTALLED_ASSET=""
if [[ -f "$MANIFEST_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$MANIFEST_FILE"
fi

SKIP_DOWNLOAD=false
if [[ -d "$INSTALL_DIR" && "$INSTALLED_TAG" == "$TAG_NAME" && "$INSTALLED_ASSET" == "$ASSET_NAME" ]]; then
    ok "Já instalado (${TAG_NAME} / ${ASSET_NAME}) — pulando download."
    if confirm "Forçar reinstalação mesmo assim?" "N"; then
        rm -rf "$INSTALL_DIR"
    else
        SKIP_DOWNLOAD=true
    fi
fi

if [[ "$SKIP_DOWNLOAD" == false ]]; then
    if [[ -d "$INSTALL_DIR" ]]; then
        warn "Já existe uma instalação em: $INSTALL_DIR"
        if confirm "Remover e reinstalar?" "N"; then
            rm -rf "$INSTALL_DIR"
        else
            log "Mantendo instalação existente; os arquivos serão sobrescritos onde houver conflito."
        fi
    fi
    mkdir -p "$INSTALL_DIR"

    log "Baixando ${ASSET_NAME}..."
    ZIP_PATH="$SCRATCH_DIR/${ASSET_NAME}"
    curl -L --progress-bar -o "$ZIP_PATH" "$ASSET_URL"
    ok "Download concluído."

    log "Extraindo para ${INSTALL_DIR}..."
    # O zip é empacotado no Windows e às vezes traz pastas sem o bit de execução
    # (drw-rw-r--), o que impede o unzip de entrar nelas. Damos u+rwx ANTES de
    # cada tentativa e depois, para não travar em "Permission denied".
    find "$INSTALL_DIR" -type d -exec chmod u+rwx {} \; 2>/dev/null || true

    # unzip retorna 1 quando emite apenas avisos (ex.: paths com barra invertida
    # no zip de origem no Windows); só um código >= 2 indica falha real.
    set +e
    unzip -oq "$ZIP_PATH" -d "$INSTALL_DIR"
    UNZIP_STATUS=$?
    set -e

    # Garante que todas as pastas extraídas fiquem navegáveis/graváveis pelo dono.
    find "$INSTALL_DIR" -type d -exec chmod u+rwx {} \;

    if (( UNZIP_STATUS >= 2 )); then
        err "Falha ao extrair o pacote (código $UNZIP_STATUS)."
        exit 1
    fi
    ok "Arquivos extraídos."
fi

# Descobre a pasta real do executável (o zip normalmente contém uma subpasta)
APP_DIR=$(find "$INSTALL_DIR" -maxdepth 3 -iname "AasxPackageExplorer.exe" -o -iname "BlazorExplorer.exe" 2>/dev/null | head -n1 | xargs -r dirname)
if [[ -z "$APP_DIR" ]]; then
    err "Não encontrei o executável principal dentro do pacote extraído."
    exit 1
fi
EXE_NAME=$(find "$APP_DIR" -maxdepth 1 \( -iname "AasxPackageExplorer.exe" -o -iname "BlazorExplorer.exe" \) -printf "%f\n" | head -n1)
ok "Executável: ${APP_DIR}/${EXE_NAME}"

# ---------------------------------------------------------------------------
log "Configurando o prefixo Wine em ${WINEPREFIX_DIR}..."
export WINEARCH=win64
export WINEPREFIX="$WINEPREFIX_DIR"

if [[ ! -d "$WINEPREFIX_DIR" ]]; then
    wineboot --init >/dev/null 2>&1 || true
    ok "Prefixo Wine criado."
else
    ok "Prefixo Wine já existe, reutilizando."
fi

# Verifica se o .NET Windows Desktop Runtime já está instalado no prefixo
if find "$WINEPREFIX_DIR/drive_c/Program Files/dotnet/shared/Microsoft.WindowsDesktop.App" -maxdepth 1 -mindepth 1 2>/dev/null | grep -q .; then
    ok ".NET Desktop Runtime já instalado no prefixo."
else
    log "Baixando .NET Windows Desktop Runtime 8..."
    RUNTIME_EXE="$SCRATCH_DIR/windowsdesktop-runtime-win-x64.exe"
    curl -L --progress-bar -o "$RUNTIME_EXE" "$DOTNET_DESKTOP_RUNTIME_URL"

    log "Instalando .NET Desktop Runtime no prefixo Wine (isso pode levar 1-2 minutos)..."
    wine "$RUNTIME_EXE" /install /quiet /norestart >/dev/null 2>&1 || true

    if find "$WINEPREFIX_DIR/drive_c/Program Files/dotnet/shared/Microsoft.WindowsDesktop.App" -maxdepth 1 -mindepth 1 2>/dev/null | grep -q .; then
        ok ".NET Desktop Runtime instalado com sucesso."
    else
        err "Falha ao instalar o .NET Desktop Runtime. Verifique manualmente com winetricks."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
log "Gerando script de execução..."

RUN_SCRIPT="$INSTALL_DIR/run.sh"
cat > "$RUN_SCRIPT" <<EOF
#!/bin/bash
# Executa o AASX Package Explorer via Wine
export WINEARCH=win64
export WINEPREFIX="$WINEPREFIX_DIR"
cd "$APP_DIR"
wine "$EXE_NAME" "\$@"
EOF
chmod +x "$RUN_SCRIPT"
ok "Script de execução criado em: $RUN_SCRIPT"

# ---------------------------------------------------------------------------
if confirm "Criar atalho no menu de aplicativos (.desktop)?"; then
    mkdir -p "$(dirname "$DESKTOP_FILE")" "$(dirname "$ICON_PNG")"

    # O .desktop precisa de um ícone raster (png/svg). O pacote não traz um
    # .ico solto: o ícone fica embutido como recurso dentro do próprio .exe.
    # Extraímos com wrestool (icoutils) e convertemos com Pillow, que lida
    # bem com o formato mesmo quando icotool acusa "incorrect total size".
    ICON_MISSING_PKGS=()
    require_cmd wrestool || ICON_MISSING_PKGS+=(icoutils)
    python3 -c "import PIL" >/dev/null 2>&1 || ICON_MISSING_PKGS+=(python3-pil)
    if [[ ${#ICON_MISSING_PKGS[@]} -gt 0 ]]; then
        warn "Para extrair o ícone real do programa faltam: ${ICON_MISSING_PKGS[*]}"
        if confirm "Instalar agora via apt (sudo)?"; then
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
        warn "Não converti o ícone embutido no .exe; usando ícone genérico. Instale 'icoutils' e o módulo Python 'Pillow' (python3-pil) se quiser o ícone real."
    fi

    cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=AASX Package Explorer
Comment=Editor/visualizador de pacotes AASX (Asset Administration Shell)
Exec=$RUN_SCRIPT
Icon=${ICON_PATH:-applications-engineering}
Terminal=false
Categories=Development;Engineering;
EOF
    ok "Atalho criado: $DESKTOP_FILE"
fi

# ---------------------------------------------------------------------------
# Grava o manifesto para o --uninstall encontrar os caminhos reais depois,
# mesmo que a instalação tenha usado AASX_INSTALL_DIR/AASX_WINEPREFIX customizados.
cat > "$MANIFEST_FILE" <<EOF
INSTALL_DIR="$INSTALL_DIR"
WINEPREFIX_DIR="$WINEPREFIX_DIR"
DESKTOP_FILE="$DESKTOP_FILE"
ICON_PNG="$ICON_PNG"
INSTALLED_TAG="$TAG_NAME"
INSTALLED_ASSET="$ASSET_NAME"
EOF

echo
ok "Instalação concluída!"
echo -e "Para executar o programa: ${C_BOLD}$RUN_SCRIPT${C_RESET}"
echo

if confirm "Executar o AASX Package Explorer agora?"; then
    "$RUN_SCRIPT" &
    disown
fi
