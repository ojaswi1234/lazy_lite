#!/usr/bin/env bash
CONFIG_DIR="$HOME/.config/lite-xl"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing Lite-XL Mossy Configuration..."

mkdir -p "$CONFIG_DIR/plugins"
mkdir -p "$CONFIG_DIR/colors"
mkdir -p "$CONFIG_DIR/fonts"

cp -f "$SRC_DIR"/plugins/*.lua "$CONFIG_DIR/plugins/"
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
