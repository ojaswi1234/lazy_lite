#!/usr/bin/env bash
CONFIG_DIR="$HOME/.config/lite-xl"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Lite-XL Mossy Configuration Installer"
echo "---------------------------------------"

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
    type -p curl >/dev/null || (sudo apt update && sudo apt install curl -y)
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && sudo apt update \
    && sudo apt install gh -y
fi

# 1.6. Check Python (required for the AI sidebar PTY bridge on Linux/macOS via the pty module)
if command -v python3 &> /dev/null; then
    echo "Python3 found — AI PTY bridge ready (uses built-in pty module on Linux/macOS)."
else
    echo "WARNING: python3 not found. The AI sidebar PTY bridge (agy_pty_bridge.py) requires Python 3."
    echo "         Install via your package manager, e.g.: sudo apt install python3"
fi

# 1.7. Download Nerd Font for icons
echo "Downloading FiraCode Nerd Font..."
mkdir -p "$CONFIG_DIR/fonts"
curl -L -o "$CONFIG_DIR/fonts/FiraCodeNerdFont-Regular.ttf" "https://github.com/ryanoasis/nerd-fonts/raw/master/patched-fonts/FiraCode/Regular/FiraCodeNerdFont-Regular.ttf"

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
    cp -f "$SRC_DIR/scripts/"* "$CONFIG_DIR/scripts/"
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
