#!/usr/bin/env bash
# ==============================================================================
# LazyLite Configuration & Auto-Setup Installer (Linux, macOS, GitHub Codespaces)
# High-reliability bootstrap supporting unattended CI, Docker, Codespaces,
# multi-architecture binaries, resilient fallbacks, and safe configuration.
# ==============================================================================

set -e

# Parse Command-Line Flags
UNATTENDED=false
INSTALL_LITE=true
INSTALL_AGY=true
INSTALL_LEETCODE=true
INSTALL_MONGO=true

for arg in "$@"; do
    case "$arg" in
        -y|--yes|-u|--unattended|-s|--silent)
            UNATTENDED=true
            ;;
        --skip-lite)
            INSTALL_LITE=false
            ;;
        --skip-agy)
            INSTALL_AGY=false
            ;;
        --skip-leetcode)
            INSTALL_LEETCODE=false
            ;;
        --skip-mongo)
            INSTALL_MONGO=false
            ;;
        -h|--help)
            echo "Usage: ./install.sh [OPTIONS]"
            echo "Options:"
            echo "  -y, --yes, -u, --unattended   Run non-interactively with default selections"
            echo "  --skip-lite                   Do not install Lite-XL binary"
            echo "  --skip-agy                    Do not install Antigravity CLI"
            echo "  --skip-leetcode               Skip LeetCode dependencies"
            echo "  --skip-mongo                  Skip MongoDB explorer & mongosh"
            exit 0
            ;;
    esac
done

# Auto-detect non-interactive environments (Codespaces, CI, Docker, piped curl)
if [ ! -t 0 ] || [ "$CI" = "true" ] || [ -n "$CODESPACES" ] || [ -n "$REMOTE_CONTAINERS" ] || [ "$DEBIAN_FRONTEND" = "noninteractive" ]; then
    UNATTENDED=true
fi

# Detect Config Directory (supports Linux ~/.config/lite-xl and macOS Application Support)
CONFIG_DIR="$HOME/.config/lite-xl"
if [[ "$(uname)" == "Darwin" ]] && [ -d "$HOME/Library/Application Support/lite-xl" ]; then
    CONFIG_DIR="$HOME/Library/Application Support/lite-xl"
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sudo wrapper (handles running as root in Docker/Codespaces without sudo)
SUDO=""
if [ "$EUID" -ne 0 ] && command -v sudo &> /dev/null; then
    SUDO="sudo"
fi

echo -e "\033[38;2;167;192;128m"
cat << 'EOF'
    __                      __    _ __     
   / /   ____ _____  __  __/ /   (_) /____ 
  / /   / __ `/_  / / / / / /   / / __/ _ \
 / /___/ /_/ / / /_/ /_/ / /___/ / /_/  __/
/_____/\__,_/ /___/\__, /_____/_/\__/\___/ 
                  /____/                   

EOF
echo -e "\033[0m"
echo -e "🌿 \033[1;32mWelcome to the LazyLite Installer!\033[0m 🌿"
echo -e "✨ \033[3;37mTransforming your Lite-XL into a modern powerhouse...\033[0m ✨"
if [ "$UNATTENDED" = true ]; then
    echo -e "⚡ \033[1;34mRunning in unattended auto-setup mode.\033[0m"
fi
echo "------------------------------------------------------------------"
echo -e "⚠️  \033[1;33mNote:\033[0m AI Sidebar and Auto-Healer default to API mode if \033[1mAntigravity CLI (agy)\033[0m is not installed."
echo "------------------------------------------------------------------"
echo ""

animate_progress() {
    local msg="$1"
    echo -e "\033[1;36m➤ $msg\033[0m"
    if [ "$UNATTENDED" = true ]; then
        echo -e "  \033[1;32m[==============================] ✔\033[0m"
    else
        printf "  \033[1;32m["
        for ((i=0; i<30; i++)); do
            printf "\033[38;2;167;192;128m█"
            sleep 0.01
        done
        printf "\033[1;32m]\033[0m \033[1;32m✔\033[0m\n"
    fi
}

# Download helper with curl and wget fallbacks
download_file() {
    local url="$1"
    local dest="$2"
    local desc="$3"
    mkdir -p "$(dirname "$dest")"
    if command -v curl &> /dev/null; then
        if curl -fsSL --connect-timeout 15 -o "$dest" "$url" 2>/dev/null; then
            echo "[+] Downloaded $desc"
            return 0
        fi
    elif command -v wget &> /dev/null; then
        if wget -q --timeout=15 -O "$dest" "$url" 2>/dev/null; then
            echo "[+] Downloaded $desc"
            return 0
        fi
    fi
    echo "[-] Notice: Could not download $desc. Continuing with fallback..."
    return 1
}

# Handle piped in-memory execution (clone repo if running directly from curl)
if [ ! -d "$SRC_DIR/plugins" ]; then
    TEMP_CLONE_DIR="/tmp/lazylite-bootstrap-$$"
    echo "[*] Fetching LazyLite setup bundle from GitHub..."
    if command -v git &> /dev/null; then
        git clone --depth 1 https://github.com/ojaswi1234/lazy_lite.git "$TEMP_CLONE_DIR" 2>/dev/null || true
    fi
    if [ -d "$TEMP_CLONE_DIR/plugins" ]; then
        SRC_DIR="$TEMP_CLONE_DIR"
    fi
fi

# 1. Check Lite-XL Installation
IS_WSL=false
if grep -qi microsoft /proc/version 2>/dev/null; then IS_WSL=true; fi

if [ "$IS_WSL" = true ]; then
    echo "[+] WSL environment detected. Installing Windows interop wrapper for lite-xl..."
    if [ -f "$SRC_DIR/lite-xl-wsl/lite-xl-wsl-wrapper" ]; then
        $SUDO cp -f "$SRC_DIR/lite-xl-wsl/lite-xl-wsl-wrapper" /usr/local/bin/lite-xl 2>/dev/null || cp -f "$SRC_DIR/lite-xl-wsl/lite-xl-wsl-wrapper" ~/.local/bin/lite-xl 2>/dev/null
        $SUDO chmod +x /usr/local/bin/lite-xl 2>/dev/null || chmod +x ~/.local/bin/lite-xl 2>/dev/null
        echo "[+] Installed WSL lite-xl wrapper successfully."
    fi
elif ! command -v lite-xl &> /dev/null && [ "$INSTALL_LITE" = true ]; then
    do_install="y"
    if [ "$UNATTENDED" = false ]; then
        read -p "Lite-XL is not installed. Do you want to install it automatically? (y/n) [default: y]: " prompt_lite || prompt_lite="y"
        if [[ "$prompt_lite" =~ ^[Nn]$ ]]; then do_install="n"; fi
    fi
    
    if [[ "$do_install" =~ ^[Yy]$ ]]; then
        echo "Installing Lite-XL..."
        if command -v apt-get &> /dev/null; then
            $SUDO apt-get update -yq >/dev/null 2>&1 || true
            $SUDO apt-get install -yq lite-xl >/dev/null 2>&1 || {
                $SUDO add-apt-repository -y ppa:lite-xl/lite-xl-stable 2>/dev/null || true
                $SUDO apt-get update -yq >/dev/null 2>&1 || true
                $SUDO apt-get install -yq lite-xl >/dev/null 2>&1 || true
            }
        elif command -v apk &> /dev/null; then
            $SUDO apk add --no-cache lite-xl >/dev/null 2>&1 || true
        elif command -v dnf &> /dev/null; then
            $SUDO dnf install -y lite-xl >/dev/null 2>&1 || true
        elif command -v pacman &> /dev/null; then
            $SUDO pacman -Sy --noconfirm lite-xl >/dev/null 2>&1 || true
        elif command -v brew &> /dev/null; then
            brew install --cask lite-xl >/dev/null 2>&1 || true
        fi
        
        # Verify if installed, if not, use AppImage fallback
        if ! command -v lite-xl &> /dev/null; then
            echo "Package manager installation failed or unavailable. Falling back to AppImage..."
            mkdir -p ~/.local/bin
            APPIMAGE_URL="https://github.com/lite-xl/lite-xl/releases/download/v2.1.8/LiteXL-v2.1.8-addons-x86_64.AppImage"
            if command -v curl &> /dev/null; then
                curl -L --connect-timeout 15 -o ~/.local/bin/lite-xl "$APPIMAGE_URL"
            elif command -v wget &> /dev/null; then
                wget -T 15 -qO ~/.local/bin/lite-xl "$APPIMAGE_URL"
            fi
            chmod +x ~/.local/bin/lite-xl
            # Export to path just for this session, users should have ~/.local/bin in PATH
            export PATH="$HOME/.local/bin:$PATH"
            if ! command -v lite-xl &> /dev/null; then
                echo "WARNING: Could not install Lite-XL binary automatically. Configuration will be placed in $CONFIG_DIR."
            else
                echo "[+] Installed Lite-XL AppImage to ~/.local/bin/lite-xl"
            fi
        fi
    fi
fi

# 1.5. Check GitHub CLI (gh)
if ! command -v gh &> /dev/null; then
    echo "Installing GitHub CLI (gh)..."
    if command -v apt-get &> /dev/null && [ -n "$SUDO" -o "$EUID" -eq 0 ]; then
        $SUDO mkdir -p -m 755 /etc/apt/keyrings 2>/dev/null || true
        download_file "https://cli.github.com/packages/githubcli-archive-keyring.gpg" "/tmp/githubcli.gpg" "GitHub CLI Key" && \
            $SUDO cp -f /tmp/githubcli.gpg /etc/apt/keyrings/githubcli-archive-keyring.gpg 2>/dev/null || true
        echo "deb [arch=$(dpkg --print-architecture 2>/dev/null || echo amd64) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | $SUDO tee /etc/apt/sources.list.d/github-cli.list > /dev/null 2>&1 || true
        $SUDO apt-get update -yq >/dev/null 2>&1 && $SUDO apt-get install -yq gh >/dev/null 2>&1 || true
    elif command -v apk &> /dev/null; then
        $SUDO apk add --no-cache github-cli >/dev/null 2>&1 || true
    elif command -v dnf &> /dev/null; then
        $SUDO dnf install -y gh >/dev/null 2>&1 || true
    elif command -v pacman &> /dev/null; then
        $SUDO pacman -Sy --noconfirm github-cli >/dev/null 2>&1 || true
    elif command -v brew &> /dev/null; then
        brew install gh >/dev/null 2>&1 || true
    fi
fi

# 1.7. Download Nerd Font for icons (Safe fallback)
mkdir -p "$CONFIG_DIR/fonts"
NERD_FONT_DEST="$CONFIG_DIR/fonts/FiraCodeNerdFont-Regular.ttf"
if [ ! -f "$NERD_FONT_DEST" ]; then
    echo "Downloading FiraCode Nerd Font..."
    download_file "https://github.com/ryanoasis/nerd-fonts/raw/master/patched-fonts/FiraCode/Regular/FiraCodeNerdFont-Regular.ttf" "$NERD_FONT_DEST" "FiraCode Nerd Font" || true
fi

# 1.8. Emoji font fallback (NotoColorEmoji)
EMOJI_FONT="$CONFIG_DIR/fonts/NotoColorEmoji.ttf"
SYSTEM_EMOJI_PATHS=(
  "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf"
  "/usr/share/fonts/noto/NotoColorEmoji.ttf"
  "/usr/share/fonts/google-noto-emoji/NotoColorEmoji.ttf"
  "/Library/Fonts/Apple Color Emoji.ttc"
)
SYSTEM_EMOJI_FOUND=false
for p in "${SYSTEM_EMOJI_PATHS[@]}"; do
  if [ -f "$p" ]; then
    SYSTEM_EMOJI_FOUND=true
    break
  fi
done
if [ "$SYSTEM_EMOJI_FOUND" = false ] && [ ! -f "$EMOJI_FONT" ]; then
    download_file "https://github.com/googlefonts/noto-emoji/raw/main/fonts/NotoColorEmoji.ttf" "$EMOJI_FONT" "Noto Color Emoji" || true
fi

# 2. Check Antigravity CLI
if ! command -v agy &> /dev/null && [ "$INSTALL_AGY" = true ]; then
    do_install_agy="y"
    if [ "$UNATTENDED" = false ]; then
        read -p "Antigravity CLI (agy) is not installed. Do you want to install it automatically? (y/n) [default: y]: " prompt_agy || prompt_agy="y"
        if [[ "$prompt_agy" =~ ^[Nn]$ ]]; then do_install_agy="n"; fi
    fi
    if [[ "$do_install_agy" =~ ^[Yy]$ ]]; then
        echo "Installing Antigravity CLI..."
        if command -v curl &> /dev/null; then
            curl -fsSL https://antigravity.google/cli/install.sh | bash 2>/dev/null || true
        elif command -v wget &> /dev/null; then
            wget -qO- https://antigravity.google/cli/install.sh | bash 2>/dev/null || true
        fi
    else
        INSTALL_AGY=false
    fi
fi

# 3. LeetCode & Assessment Suite Dependencies
if [ "$INSTALL_LEETCODE" = true ]; then
    if [ "$UNATTENDED" = false ]; then
        read -p "Do you want to setup LeetCode plugin & assessment suite? (y/n) [default: y]: " prompt_lc || prompt_lc="y"
        if [[ "$prompt_lc" =~ ^[Nn]$ ]]; then INSTALL_LEETCODE=false; fi
    fi
    if [ "$INSTALL_LEETCODE" = true ] && command -v python3 &> /dev/null; then
        echo "Installing Python dependencies for LeetCode API & ranking engine..."
        python3 -m pip install requests --break-system-packages --quiet 2>/dev/null || \
        python3 -m pip install requests --user --quiet 2>/dev/null || \
        python3 -m pip install requests --quiet 2>/dev/null || true
    fi
fi

# 4. MongoDB Explorer & Shell
if [ "$INSTALL_MONGO" = true ]; then
    if [ "$UNATTENDED" = false ]; then
        read -p "Do you want to setup MongoDB Explorer plugin? (y/n) [default: y]: " prompt_mg || prompt_mg="y"
        if [[ "$prompt_mg" =~ ^[Nn]$ ]]; then INSTALL_MONGO=false; fi
    fi
    if [ "$INSTALL_MONGO" = true ]; then
        if ! command -v mongosh &> /dev/null; then
            MONGOSH_INSTALLED=false
            if command -v npm &> /dev/null; then
                echo "Installing MongoDB Shell (mongosh) globally via npm..."
                $SUDO npm install -g mongosh --silent 2>/dev/null || npm install -g mongosh --silent 2>/dev/null || true
                if command -v mongosh &> /dev/null; then MONGOSH_INSTALLED=true; fi
            fi
            if [ "$MONGOSH_INSTALLED" = false ]; then
                if command -v brew &> /dev/null; then
                    brew install mongosh >/dev/null 2>&1 || true
                elif command -v apt-get &> /dev/null && [ -n "$SUDO" -o "$EUID" -eq 0 ]; then
                    $SUDO apt-get update >/dev/null 2>&1 && $SUDO apt-get install -y mongodb-mongosh >/dev/null 2>&1 || true
                elif command -v pacman &> /dev/null && [ -n "$SUDO" -o "$EUID" -eq 0 ]; then
                    $SUDO pacman -S --noconfirm mongosh >/dev/null 2>&1 || true
                elif command -v dnf &> /dev/null && [ -n "$SUDO" -o "$EUID" -eq 0 ]; then
                    $SUDO dnf install -y mongodb-mongosh >/dev/null 2>&1 || true
                fi
            fi
        fi
        if command -v python3 &> /dev/null; then
            python3 -m pip install pymongo --break-system-packages --quiet 2>/dev/null || \
            python3 -m pip install pymongo --user --quiet 2>/dev/null || \
            python3 -m pip install pymongo --quiet 2>/dev/null || true
        fi
    fi
fi

animate_progress "Installing Lite-XL Mossy Configuration & Plugins..."

# Create target directories
mkdir -p "$CONFIG_DIR/plugins" "$CONFIG_DIR/colors" "$CONFIG_DIR/scripts" "$CONFIG_DIR/fonts" "$CONFIG_DIR/attachments"

# Copy main plugins (.lua, .json, .py, .exe)
if [ -d "$SRC_DIR/plugins" ]; then
    for plugin in "$SRC_DIR"/plugins/*; do
        [ -f "$plugin" ] || continue
        plugin_name=$(basename "$plugin")
        if { [ "$plugin_name" = "leetcode.lua" ] || [ "$plugin_name" = "leetcode_assessment.lua" ] || [ "$plugin_name" = "company_tags.json" ] || [ "$plugin_name" = "problem_tags.json" ] || [ "$plugin_name" = "company_scores.json" ]; } && [ "$INSTALL_LEETCODE" = false ]; then continue; fi
        if [ "$plugin_name" = "mongodb_explorer.lua" ] && [ "$INSTALL_MONGO" = false ]; then continue; fi
        cp -f "$plugin" "$CONFIG_DIR/plugins/"
    done
fi

# Copy color schemes
if [ -d "$SRC_DIR/colors" ]; then
    cp -f "$SRC_DIR"/colors/*.lua "$CONFIG_DIR/colors/" 2>/dev/null || true
fi

# Copy bundled fonts
if [ -d "$SRC_DIR/fonts" ]; then
    cp -f "$SRC_DIR"/fonts/*.ttf "$CONFIG_DIR/fonts/" 2>/dev/null || true
fi

# Copy scripts
if [ -d "$SRC_DIR/scripts" ]; then
    for script in "$SRC_DIR"/scripts/*; do
        [ -f "$script" ] || continue
        script_name=$(basename "$script")
        if [ "$script_name" = "leetcode_api.py" ] && [ "$INSTALL_LEETCODE" = false ]; then continue; fi
        if [ "$script_name" = "mongodb_bridge.py" ] && [ "$INSTALL_MONGO" = false ]; then continue; fi
        cp -f "$script" "$CONFIG_DIR/scripts/"
    done
    chmod +x "$CONFIG_DIR"/scripts/*.py "$CONFIG_DIR"/scripts/*.js 2>/dev/null || true
fi

# Copy sub-directories (third-party and custom plugins)
if [ -d "$SRC_DIR/plugins/lsp" ];          then cp -rf "$SRC_DIR/plugins/lsp"          "$CONFIG_DIR/plugins/"; fi
if [ -d "$SRC_DIR/plugins/widget" ];       then cp -rf "$SRC_DIR/plugins/widget"       "$CONFIG_DIR/plugins/"; fi
if [ -d "$SRC_DIR/plugins/lintplus" ];     then cp -rf "$SRC_DIR/plugins/lintplus"     "$CONFIG_DIR/plugins/"; fi
if [ -d "$SRC_DIR/plugins/loader_games" ]; then cp -rf "$SRC_DIR/plugins/loader_games" "$CONFIG_DIR/plugins/"; fi

# Multi-Architecture lite-pty Setup
if [ -d "$SRC_DIR/plugins/toggle_terminal" ]; then
    cp -rf "$SRC_DIR/plugins/toggle_terminal" "$CONFIG_DIR/plugins/"
    
    OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
    ARCH="$(uname -m)"
    if [ "$ARCH" = "x86_64" ]; then ARCH="amd64"; fi
    if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then ARCH="arm64"; fi
    
    BIN_NAME="lite-pty-${OS}-${ARCH}"
    PTY_DIR="$CONFIG_DIR/plugins/toggle_terminal/lite-pty"
    if [ -f "$PTY_DIR/$BIN_NAME" ]; then
        cp -f "$PTY_DIR/$BIN_NAME" "$PTY_DIR/lite-pty"
        chmod +x "$PTY_DIR/lite-pty"
    elif command -v go &> /dev/null; then
        echo "Compiling lite-pty natively..."
        (cd "$PTY_DIR" && go build -o lite-pty .) 2>/dev/null || true
        chmod +x "$PTY_DIR/lite-pty" 2>/dev/null || true
    fi
fi

if [ -d "$SRC_DIR/plugins/tunnel_monitor" ]; then
    cp -rf "$SRC_DIR/plugins/tunnel_monitor" "$CONFIG_DIR/plugins/"
    if command -v go &> /dev/null; then
        (cd "$CONFIG_DIR/plugins/tunnel_monitor" && go build -o proxy .) 2>/dev/null || true
        chmod +x "$CONFIG_DIR/plugins/tunnel_monitor/proxy" 2>/dev/null || true
    fi
fi

if [ -d "$SRC_DIR/plugins/python_runtime" ]; then 
    cp -rf "$SRC_DIR/plugins/python_runtime" "$CONFIG_DIR/plugins/"
fi

# Copy Antigravity custom skills
GEMINI_CONFIG_DIR="$HOME/.gemini/config"
if [ -d "$SRC_DIR/skills" ]; then
    mkdir -p "$GEMINI_CONFIG_DIR/skills"
    cp -rf "$SRC_DIR/skills/"* "$GEMINI_CONFIG_DIR/skills/"
    echo "[+] Copied custom Antigravity skills."
fi

# Update init.lua safely
INIT_FILE="$CONFIG_DIR/init.lua"
MARKER="-- [[ LazyLite Configuration ]]"

if [ ! -f "$INIT_FILE" ] || [ ! -s "$INIT_FILE" ]; then
    if [ -f "$SRC_DIR/init.lua" ]; then
        cp -f "$SRC_DIR/init.lua" "$INIT_FILE"
    else
        cat "$SRC_DIR/init_append.lua" > "$INIT_FILE"
    fi
    echo "[+] Initialized init.lua with LazyLite configuration."
elif ! grep -qF -- "$MARKER" "$INIT_FILE"; then
    echo "" >> "$INIT_FILE"
    cat "$SRC_DIR/init_append.lua" >> "$INIT_FILE"
    echo "[+] Appended LazyLite configuration to init.lua."
else
    echo "[+] LazyLite configuration already present in init.lua."
fi

API_FALLBACK_MARKER="-- [[ LazyLite API Fallback ]]"
if ! grep -qF -- "$API_FALLBACK_MARKER" "$INIT_FILE"; then
    cat <<EOF >> "$INIT_FILE"

$API_FALLBACK_MARKER
config.ai_sidebar = config.ai_sidebar or {}
config.ai_sidebar.active_tool = "cloud_api"
EOF
    echo "[+] Configured AI Sidebar to default to API Mode (cloud_api)."
fi

echo ""
echo "=================================================================="
echo -e "\033[1;32m  Installation complete! Restart Lite-XL to enjoy LazyLite.\033[0m"
echo "=================================================================="
echo ""
echo "Tip: Run 'agy install' once in a terminal to configure the AI backend."
echo ""
