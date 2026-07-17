#!/usr/bin/env bash
CONFIG_DIR="$HOME/.config/lite-xl"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Lite-XL Mossy Configuration Installer"
echo "---------------------------------------"
echo "DISCLAIMER: For the Auto-Healer setup to work, the Antigravity CLI (agy) is required."
echo ""

# 1. Check Lite-XL
if ! command -v lite-xl &> /dev/null; then
    read -p "Lite-XL is not installed. Do you want to install it automatically? (y/n): " install_lite
    if [[ "$install_lite" =~ ^[Yy]$ ]]; then
        echo "Installing Lite-XL..."
        curl -L -o LiteXL-setup.exe https://github.com/lite-xl/lite-xl/releases/download/v2.1.8/LiteXL-v2.1.8-addons-x86_64-setup.exe
        chmod +x LiteXL-setup.exe
        ./LiteXL-setup.exe
    else
        echo "Lite-XL installation skipped. Cannot proceed without Lite-XL. Exiting."
        exit 1
    fi
fi

# 1.5. Check GitHub CLI (gh)
if ! command -v gh &> /dev/null; then
    echo "Installing GitHub CLI..."
    if command -v apt-get &> /dev/null; then
        type -p curl >/dev/null || (sudo apt-get update && sudo apt-get install curl -y)
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
        && sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
        && sudo apt-get update \
        && sudo apt-get install gh -y
    elif command -v apk &> /dev/null; then
        sudo apk add github-cli
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y gh
    else
        echo "WARNING: Please install GitHub CLI (gh) manually."
    fi
fi

# 1.6. Check Python (required for the AI sidebar PTY bridge on Linux/macOS via the pty module)
if command -v python3 &> /dev/null; then
    echo "Python3 found - AI PTY bridge ready (uses built-in pty module on Linux/macOS)."
else
    echo "python3 not found. Installing Python 3 (required for AI sidebar PTY bridge and MongoDB)..."
    if command -v apt-get &> /dev/null; then sudo apt-get update && sudo apt-get install -y python3 python3-pip python3-venv
    elif command -v apk &> /dev/null; then sudo apk add python3 py3-pip
    elif command -v dnf &> /dev/null; then sudo dnf install -y python3 python3-pip
    elif command -v pacman &> /dev/null; then sudo pacman -Sy --noconfirm python python-pip
    else 
        echo "ERROR: Could not automatically install Python 3. Please install it manually, as it is required."
        exit 1
    fi
fi

# 1.7. Download Nerd Font for icons
echo "Downloading FiraCode Nerd Font..."
mkdir -p "$CONFIG_DIR/fonts"
curl -L -o "$CONFIG_DIR/fonts/FiraCodeNerdFont-Regular.ttf" "https://github.com/ryanoasis/nerd-fonts/raw/master/patched-fonts/FiraCode/Regular/FiraCodeNerdFont-Regular.ttf"

# 1.8. Emoji font fallback (NotoColorEmoji) — ensures emoji render correctly in the AI sidebar
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
    echo "System emoji font found at $p — skipping download."
    break
  fi
done
if [ "$SYSTEM_EMOJI_FOUND" = false ]; then
  if [ -f "$EMOJI_FONT" ]; then
    echo "NotoColorEmoji already in fonts dir — skipping download."
  else
    echo "Downloading NotoColorEmoji for emoji rendering in AI sidebar..."
    curl -L --progress-bar -o "$EMOJI_FONT" \
      "https://github.com/googlefonts/noto-emoji/raw/main/fonts/NotoColorEmoji.ttf" \
      && echo "NotoColorEmoji downloaded successfully." \
      || echo "WARNING: NotoColorEmoji download failed. Emoji may appear as '?' in the AI sidebar."
  fi
fi

# 2. Check Antigravity CLI
INSTALL_AGY_SIDEBAR=true
if ! command -v agy &> /dev/null; then
    read -p "Antigravity CLI (agy) is not installed. Do you want to install it automatically using the official installer? (y/n): " install_agy
    if [[ "$install_agy" =~ ^[Yy]$ ]]; then
        echo "Installing Antigravity CLI..."
        curl -fsSL https://antigravity.google/cli/install.sh | bash
    else
        echo ""
        echo "Note: You have chosen not to install the Antigravity CLI. The AI sidebar will not be added to your Lite-XL setup,"
        echo "but other customizations (colors, fonts, tweaks) will still be installed."
        echo "If you change your mind, you can run this script again later to add it."
        echo ""
        INSTALL_AGY_SIDEBAR=false
    fi
fi

# 3. Optional Features Setup
INSTALL_PODMAN=true
read -p "Do you want to setup Podman support in the editor? (y/n): " prompt_podman
if [[ "$prompt_podman" =~ ^[Yy]$ ]]; then
    if ! command -v podman &> /dev/null; then
        echo "Installing Podman..."
        if command -v apt-get &> /dev/null; then sudo apt-get update && sudo apt-get -y install podman
        elif command -v apk &> /dev/null; then sudo apk add podman
        elif command -v dnf &> /dev/null; then sudo dnf install -y podman
        else echo "WARNING: Please install podman manually."; fi
    fi
else
    INSTALL_PODMAN=false
fi

INSTALL_LEETCODE=true
read -p "Do you want to setup LeetCode plugin? (y/n): " prompt_leetcode
if [[ "$prompt_leetcode" =~ ^[Nn]$ ]]; then
    INSTALL_LEETCODE=false
fi

INSTALL_MONGO=true
read -p "Do you want to setup MongoDB Explorer? (y/n): " prompt_mongo
if [[ "$prompt_mongo" =~ ^[Yy]$ ]]; then
    if ! command -v mongosh &> /dev/null; then
        echo "Installing MongoDB Shell (mongosh)..."
        if command -v apt-get &> /dev/null; then
            wget -qO- https://www.mongodb.org/static/pgp/server-7.0.asc | sudo tee /etc/apt/trusted.gpg.d/server-7.0.asc >/dev/null
            echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list >/dev/null
            sudo apt-get update && sudo apt-get install -y mongodb-mongosh
        elif command -v apk &> /dev/null; then
            sudo apk add mongodb-tools
        else
            echo "WARNING: Could not automatically install mongosh. Please install manually."
        fi
    fi
    if command -v python3 &> /dev/null; then
        python3 -m pip install pymongo --quiet || true
    fi
else
    INSTALL_MONGO=false
fi

echo "Installing Lite-XL Mossy Configuration..."

mkdir -p "$CONFIG_DIR/plugins"
mkdir -p "$CONFIG_DIR/colors"
mkdir -p "$CONFIG_DIR/fonts"
mkdir -p "$CONFIG_DIR/scripts"

# Copy all .lua plugin files (skip AI sidebar if agy not installed)
for plugin in "$SRC_DIR"/plugins/*.lua; do
    plugin_name=$(basename "$plugin")
    if [ "$plugin_name" = "antigravity_sidebar.lua" ] && [ "$INSTALL_AGY_SIDEBAR" = false ]; then
        echo "Skipping antigravity_sidebar.lua..."
        continue
    fi
    if [ "$plugin_name" = "podman_manager.lua" ] && [ "$INSTALL_PODMAN" = false ]; then
        echo "Skipping podman_manager.lua..."
        continue
    fi
    if [ "$plugin_name" = "leetcode.lua" ] && [ "$INSTALL_LEETCODE" = false ]; then
        echo "Skipping leetcode.lua..."
        continue
    fi
    if [ "$plugin_name" = "mongodb_explorer.lua" ] && [ "$INSTALL_MONGO" = false ]; then
        echo "Skipping mongodb_explorer.lua..."
        continue
    fi
    cp -f "$plugin" "$CONFIG_DIR/plugins/"
done

# Copy Python PTY bridge (required for AI sidebar streaming)
if [ "$INSTALL_AGY_SIDEBAR" = true ] && [ -f "$SRC_DIR/plugins/agy_pty_bridge.py" ]; then
    cp -f "$SRC_DIR/plugins/agy_pty_bridge.py" "$CONFIG_DIR/plugins/"
fi

# Copy color schemes
cp -f "$SRC_DIR"/colors/*.lua "$CONFIG_DIR/colors/"

# Copy bundled fonts (if any are in the repo)
cp -f "$SRC_DIR"/fonts/*.ttf "$CONFIG_DIR/fonts/" 2>/dev/null || true

# Copy scripts (remote LSP proxy for Codespaces)
if [ -d "$SRC_DIR/scripts" ]; then
    for script in "$SRC_DIR"/scripts/*; do
        script_name=$(basename "$script")
        if [ "$script_name" = "leetcode_api.py" ] && [ "$INSTALL_LEETCODE" = false ]; then
            echo "Skipping leetcode_api.py..."
            continue
        fi
        if [ "$script_name" = "mongodb_bridge.py" ] && [ "$INSTALL_MONGO" = false ]; then
            echo "Skipping mongodb_bridge.py..."
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
echo "Copied plugins, scripts, fonts, and color scheme."

# Update init.lua safely (append LazyLite block if not already present)
INIT_FILE="$CONFIG_DIR/init.lua"

if [ ! -f "$INIT_FILE" ] || ! grep -qF "-- [[ LazyLite Configuration ]]" "$INIT_FILE"; then
    cat "$SRC_DIR/init_append.lua" >> "$INIT_FILE"
    echo "Appended LazyLite configuration to init.lua"
else
    echo "Configuration already present in init.lua"
fi

echo ""
echo "Installation complete! Restart Lite-XL."
echo ""
echo "NEXT STEP: Run 'agy install' once in a terminal to configure the AI backend."
