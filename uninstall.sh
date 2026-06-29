#!/usr/bin/env bash
CONFIG_DIR="$HOME/.config/lite-xl"

echo "Uninstalling Lite-XL Mossy Configuration..."

rm -f "$CONFIG_DIR/plugins/antigravity_sidebar.lua"
rm -f "$CONFIG_DIR/plugins/mossy_icons.lua"
rm -f "$CONFIG_DIR/plugins/mossy_treeview.lua"
rm -f "$CONFIG_DIR/plugins/toggle_terminal.lua"
rm -f "$CONFIG_DIR/plugins/mossy_statusbar.lua"
rm -f "$CONFIG_DIR/colors/everforest_lite_xl.lua"

echo "Removed plugin and color files."
echo ""
echo "IMPORTANT: Please manually open $CONFIG_DIR/init.lua"
echo "and delete the lines under '-- [[ LazyLite Configuration ]]'"
echo ""
echo "Uninstallation complete! Restart Lite-XL."
