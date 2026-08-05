#!/usr/bin/env bash
# ==============================================================================
# LazyLite Configuration Installer (Linux & macOS)
# Handles all edge cases: sudo/non-root containers, curl/wget fallbacks,
# PEP 668 Python environments, multi-architecture lite-pty, and safe init.lua.
# ==============================================================================

set -e

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
echo "------------------------------------------------------------------"
echo -e "⚠️  \033[1;33mDISCLAIMER:\033[0m For the Auto-Healer setup to work, the \033[1mAntigravity CLI (agy)\033[0m is required."
echo "------------------------------------------------------------------"
echo ""

animate_progress() {
    local msg="$1"
    echo -e "\033[1;36m➤ $msg\033[0m"
    printf "  \033[1;32m["
    for ((i=0; i<30; i++)); do
        printf "\033[38;2;167;192;128m█"
        sleep 0.01
    done
    printf "\033[1;32m]\033[0m \033[1;32m✔\033[0m\n"
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
    echo "[-] Notice: Could not download $desc. Continuing with local fallback..."
    return 1
}

# 1. Check Lite-XL
if ! command -v lite-xl &> /dev/null; then
    read -p "Lite-XL is not installed. Do you want to install it automatically? (y/n): " install_lite || install_lite="n"
    if [[ "$install_lite" =~ ^[Yy]$ ]]; then
        echo "Installing Lite-XL..."
        if command -v apt-get &> /dev/null; then
            $SUDO apt-get update && $SUDO apt-get install -y lite-xl || {
                echo "Adding Lite-XL PPA..."
                $SUDO add-apt-repository -y ppa:lite-xl/lite-xl-stable 2>/dev/null || true
                $SUDO apt-get update && $SUDO apt-get install -y lite-xl || true
            }
        elif command -v apk &> /dev/null; then
            $SUDO apk add lite-xl || true
        elif command -v dnf &> /dev/null; then
            $SUDO dnf install -y lite-xl || true
        elif command -v pacman &> /dev/null; then
            $SUDO pacman -Sy --noconfirm lite-xl || true
        elif command -v brew &> /dev/null; then
            brew install --cask lite-xl || true
        else
            echo "WARNING: Unsupported package manager. Please install Lite-XL manually."
        fi
    else
        echo "Lite-XL installation skipped. Configuration will still be placed in $CONFIG_DIR."
    fi
fi

# 1.5. Check GitHub CLI (gh)
if ! command -v gh &> /dev/null; then
    if command -v apt-get &> /dev/null && [ -n "$SUDO" -o "$EUID" -eq 0 ]; then
        echo "Installing GitHub CLI..."
        $SUDO mkdir -p -m 755 /etc/apt/keyrings 2>/dev/null || true
        download_file "https://cli.github.com/packages/githubcli-archive-keyring.gpg" "/tmp/githubcli.gpg" "GitHub CLI Key" && \
            $SUDO cp -f /tmp/githubcli.gpg /etc/apt/keyrings/githubcli-archive-keyring.gpg 2>/dev/null || true
        echo "deb [arch=$(dpkg --print-architecture 2>/dev/null || echo amd64) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | $SUDO tee /etc/apt/sources.list.d/github-cli.list > /dev/null 2>&1 || true
        $SUDO apt-get update >/dev/null 2>&1 && $SUDO apt-get install -y gh >/dev/null 2>&1 || true
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
INSTALL_AGY_SIDEBAR=true
if ! command -v agy &> /dev/null; then
    read -p "Antigravity CLI (agy) is not installed. Do you want to install it automatically using the official installer? (y/n): " install_agy || install_agy="n"
    if [[ "$install_agy" =~ ^[Yy]$ ]]; then
        echo "Installing Antigravity CLI..."
        if command -v curl &> /dev/null; then
            curl -fsSL https://antigravity.google/cli/install.sh | bash || true
        elif command -v wget &> /dev/null; then
            wget -qO- https://antigravity.google/cli/install.sh | bash || true
        fi
    else
        echo "Note: AI sidebar will be skipped until Antigravity CLI is installed."
        INSTALL_AGY_SIDEBAR=false
    fi
fi

# 3. Optional Features Setup
INSTALL_LEETCODE=true
read -p "Do you want to setup LeetCode plugin & assessment suite? (y/n) [default: y]: " prompt_leetcode || prompt_leetcode="y"
if [[ "$prompt_leetcode" =~ ^[Nn]$ ]]; then
    INSTALL_LEETCODE=false
else
    if command -v python3 &> /dev/null; then
        echo "Installing Python dependencies for LeetCode API..."
        python3 -m pip install requests --break-system-packages --quiet 2>/dev/null || \
        python3 -m pip install requests --user --quiet 2>/dev/null || \
        python3 -m pip install requests --quiet 2>/dev/null || true
    fi
fi

animate_progress "Installing Lite-XL Mossy Configuration..."

# Create target directories
mkdir -p "$CONFIG_DIR/plugins" "$CONFIG_DIR/colors" "$CONFIG_DIR/scripts" "$CONFIG_DIR/fonts"

# Copy main plugins (.lua, .json, .py, .exe)
for plugin in "$SRC_DIR"/plugins/*; do
    [ -f "$plugin" ] || continue
    plugin_name=$(basename "$plugin")
    if [ "$plugin_name" = "antigravity_sidebar.lua" ] && [ "$INSTALL_AGY_SIDEBAR" = false ]; then
        continue
    fi
    if [ "$plugin_name" = "agy_pty_bridge.py" ] && [ "$INSTALL_AGY_SIDEBAR" = false ]; then
        continue
    fi
    if { [ "$plugin_name" = "leetcode.lua" ] || [ "$plugin_name" = "leetcode_assessment.lua" ] || [ "$plugin_name" = "company_tags.json" ] || [ "$plugin_name" = "problem_tags.json" ] || [ "$plugin_name" = "company_scores.json" ]; } && [ "$INSTALL_LEETCODE" = false ]; then
        continue
    fi
    cp -f "$plugin" "$CONFIG_DIR/plugins/"
done

# Copy color schemes
cp -f "$SRC_DIR"/colors/*.lua "$CONFIG_DIR/colors/" 2>/dev/null || true

# Copy bundled fonts
cp -f "$SRC_DIR"/fonts/*.ttf "$CONFIG_DIR/fonts/" 2>/dev/null || true

# Copy scripts
if [ -d "$SRC_DIR/scripts" ]; then
    for script in "$SRC_DIR"/scripts/*; do
        [ -f "$script" ] || continue
        script_name=$(basename "$script")
        if [ "$script_name" = "leetcode_api.py" ] && [ "$INSTALL_LEETCODE" = false ]; then
            continue
        fi
        cp -f "$script" "$CONFIG_DIR/scripts/"
    done
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
    fi
fi

if [ -d "$SRC_DIR/plugins/tunnel_monitor" ]; then
    cp -rf "$SRC_DIR/plugins/tunnel_monitor" "$CONFIG_DIR/plugins/"
    if command -v go &> /dev/null; then
        (cd "$CONFIG_DIR/plugins/tunnel_monitor" && go build -o proxy .) 2>/dev/null || true
    fi
fi

if [ -d "$SRC_DIR/plugins/python_runtime" ]; then 
    cp -rf "$SRC_DIR/plugins/python_runtime" "$CONFIG_DIR/plugins/"
fi

echo "[+] Copied plugins, scripts, fonts, and color schemes."

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

echo ""
echo "=================================================================="
echo "  Installation complete! Restart Lite-XL to enjoy LazyLite."
echo "=================================================================="
echo ""
echo "NEXT STEP: Run 'agy install' once in a terminal to configure the AI backend."
echo ""
