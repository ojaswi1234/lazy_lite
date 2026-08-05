#!/usr/bin/env bash
# ==============================================================================
# LazyLite Configuration Uninstaller (Linux & macOS)
# Cleanly removes all LazyLite plugins, fonts, colors, and scripts,
# and automatically cleans up init.lua (with a safety backup).
# ==============================================================================

CONFIG_DIR="$HOME/.config/lite-xl"
if [[ "$(uname)" == "Darwin" ]] && [ -d "$HOME/Library/Application Support/lite-xl" ]; then
    CONFIG_DIR="$HOME/Library/Application Support/lite-xl"
fi

echo "=========================================="
echo "   LazyLite Configuration Uninstaller     "
echo "=========================================="
echo "Removing LazyLite configuration from $CONFIG_DIR..."

# Individual plugin files
FILES=(
    "plugins/activity_bar.lua"
    "plugins/agy_pty_bridge.py"
    "plugins/ai_plugin_gen.lua"
    "plugins/antigravity_sidebar.lua"
    "plugins/autoclose.lua"
    "plugins/autocomplete.lua"
    "plugins/autosave.lua"
    "plugins/auto_healer.lua"
    "plugins/close_all_tabs.lua"
    "plugins/codespace_treeview.lua"
    "plugins/company_scores.json"
    "plugins/company_tags.json"
    "plugins/complexity.lua"
    "plugins/default_snippets.lua"
    "plugins/dump_log.lua"
    "plugins/emmet.lua"
    "plugins/empty_file_guide.lua"
    "plugins/fix_titleview.lua"
    "plugins/font_picker.lua"
    "plugins/ghost_text.lua"
    "plugins/github_actions.lua"
    "plugins/github_codespaces.lua"
    "plugins/git_timeline.lua"
    "plugins/image_viewer.lua"
    "plugins/img_to_rects.py"
    "plugins/indentguide.lua"
    "plugins/language_dockerfile.lua"
    "plugins/language_ignore.lua"
    "plugins/lazy_lite_preview_server.exe"
    "plugins/lazy_lite_web_preview.lua"
    "plugins/leetcode.lua"
    "plugins/leetcode_assessment.lua"
    "plugins/lsp_setup.lua"
    "plugins/lsp_snippets.lua"
    "plugins/markdown_view.lua"
    "plugins/mongodb_explorer.lua"
    "plugins/mossy_icons.lua"
    "plugins/mossy_statusbar.lua"
    "plugins/mossy_treeview.lua"
    "plugins/open_project_mode.lua"
    "plugins/pdf_engine.py"
    "plugins/pdf_viewer.lua"
    "plugins/podman_manager.lua"
    "plugins/port_forward.lua"
    "plugins/premium_splits.lua"
    "plugins/problem_tags.json"
    "plugins/resource_monitor.lua"
    "plugins/smart_indent.lua"
    "plugins/snippets.lua"
    "plugins/splash_art.lua"
    "plugins/split_editor_buttons.lua"
    "plugins/tempfiles_manager.lua"
    "plugins/toggle_terminal.lua"
    "plugins/virtual_codespace_fs.lua"
    "plugins/workspace.lua"
    "colors/everforest_lite_xl.lua"
    "colors/dark_forest_lite_xl.lua"
    "colors/tokyo_night_remix.lua"
    "fonts/FiraCode-iScript.ttf"
    "fonts/FiraCodeiScript-Bold.ttf"
    "fonts/FiraCodeNerdFont-Regular.ttf"
    "scripts/colab_notebook_parser.py"
    "scripts/gen_splash_art.py"
    "scripts/leetcode_api.py"
    "scripts/localtunnel_bridge.js"
    "scripts/mongodb_bridge.py"
    "scripts/remote_lsp_proxy.py"
)

# Sub-directories
SUBDIRS=(
    "plugins/lsp"
    "plugins/widget"
    "plugins/lintplus"
    "plugins/loader_games"
    "plugins/toggle_terminal"
    "plugins/tunnel_monitor"
    "plugins/python_runtime"
    "codespaces"
)

for dir in "${SUBDIRS[@]}"; do
    if [ -d "$CONFIG_DIR/$dir" ]; then
        rm -rf "$CONFIG_DIR/$dir"
        echo "[-] Removed $dir"
    fi
done

for file in "${FILES[@]}"; do
    if [ -f "$CONFIG_DIR/$file" ]; then
        rm -f "$CONFIG_DIR/$file"
        echo "[-] Removed $file"
    fi
done

# Automatically clean init.lua
INIT_FILE="$CONFIG_DIR/init.lua"
if [ -f "$INIT_FILE" ] && grep -qF -- "-- [[ LazyLite Configuration ]]" "$INIT_FILE"; then
    cp -f "$INIT_FILE" "$CONFIG_DIR/init.lua.bak"
    echo "[+] Created backup at $CONFIG_DIR/init.lua.bak"
    
    # Use python if available or awk/sed for clean multi-line removal
    if command -v python3 &> /dev/null; then
        python3 -c "
import re
p = r'$INIT_FILE'
with open(p, 'r', encoding='utf-8') as f:
    content = f.read()
cleaned = re.sub(r'(?s)--\s*\[\[\s*LazyLite Configuration\s*\]\].*?--\s*\[\[\s*End LazyLite Configuration\s*\]\]\s*', '', content)
if '-- [[ LazyLite Configuration ]]' in cleaned:
    cleaned = re.sub(r'(?s)--\s*\[\[\s*LazyLite Configuration\s*\]\].*', '', content)
with open(p, 'w', encoding='utf-8') as f:
    f.write(cleaned.strip() + '\n')
" 2>/dev/null || true
    else
        sed -i '/-- \[\[ LazyLite Configuration \]\]/,/-- \[\[ End LazyLite Configuration \]\]/d' "$INIT_FILE" 2>/dev/null || true
    fi
    echo "[+] Automatically cleaned up init.lua"
fi

echo ""
echo "=================================================================="
echo "  Uninstallation complete! Restart Lite-XL."
echo "=================================================================="
echo ""
