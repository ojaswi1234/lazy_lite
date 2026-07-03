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
        rm LiteXL-setup.exe
    else
        echo "Lite-XL installation skipped. Cannot proceed without Lite-XL. Exiting."
        exit 1
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

echo "Installing Lite-XL Mossy Configuration..."

mkdir -p "$CONFIG_DIR/plugins"
mkdir -p "$CONFIG_DIR/colors"
mkdir -p "$CONFIG_DIR/fonts"

for plugin in "$SRC_DIR"/plugins/*.lua; do
    plugin_name=$(basename "$plugin")
    if [ "$plugin_name" = "antigravity_sidebar.lua" ] && [ "$INSTALL_AGY_SIDEBAR" = false ]; then
        echo "Skipping antigravity_sidebar.lua..."
        continue
    fi
    cp -f "$plugin" "$CONFIG_DIR/plugins/"
done

cp -f "$SRC_DIR"/colors/*.lua "$CONFIG_DIR/colors/"
cp -f "$SRC_DIR"/fonts/*.ttf "$CONFIG_DIR/fonts/" 2>/dev/null || true
echo "Copied plugins, fonts, and color scheme."

INIT_FILE="$CONFIG_DIR/init.lua"
MARKER="-- \[\[ LazyLite Configuration \]\]"

if [ ! -f "$INIT_FILE" ] || ! grep -qF "-- [[ LazyLite Configuration ]]" "$INIT_FILE"; then
    cat "$SRC_DIR/init_append.lua" >> "$INIT_FILE"
    echo "Appended LazyLite configuration to init.lua"
else
    echo "Configuration already present in init.lua"
fi

echo "Installation complete! Restart Lite-XL."
