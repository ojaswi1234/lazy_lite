# ==============================================================================
# LazyLite Configuration Uninstaller (PowerShell)
# Cleanly removes all LazyLite plugins, fonts, colors, and scripts,
# and automatically cleans up init.lua (with a safety backup).
# ==============================================================================

$configDir = "$env:USERPROFILE\.config\lite-xl"

Write-Host "==========================================" -ForegroundColor Red
Write-Host "   LazyLite Configuration Uninstaller     " -ForegroundColor Red
Write-Host "==========================================" -ForegroundColor Red
Write-Host ""
Write-Host "[*] Removing LazyLite configuration from $configDir..." -ForegroundColor Yellow

# Comprehensive list of individual files installed by LazyLite
$files = @(
    "$configDir\plugins\activity_bar.lua",
    "$configDir\plugins\agy_pty_bridge.py",
    "$configDir\plugins\ai_plugin_gen.lua",
    "$configDir\plugins\antigravity_sidebar.lua",
    "$configDir\plugins\autoclose.lua",
    "$configDir\plugins\autocomplete.lua",
    "$configDir\plugins\autosave.lua",
    "$configDir\plugins\auto_healer.lua",
    "$configDir\plugins\close_all_tabs.lua",
    "$configDir\plugins\codespace_treeview.lua",
    "$configDir\plugins\company_scores.json",
    "$configDir\plugins\company_tags.json",
    "$configDir\plugins\complexity.lua",
    "$configDir\plugins\default_snippets.lua",
    "$configDir\plugins\dump_log.lua",
    "$configDir\plugins\emmet.lua",
    "$configDir\plugins\empty_file_guide.lua",
    "$configDir\plugins\fix_titleview.lua",
    "$configDir\plugins\font_picker.lua",
    "$configDir\plugins\ghost_text.lua",
    "$configDir\plugins\github_actions.lua",
    "$configDir\plugins\github_codespaces.lua",
    "$configDir\plugins\git_timeline.lua",
    "$configDir\plugins\image_viewer.lua",
    "$configDir\plugins\img_to_rects.py",
    "$configDir\plugins\indentguide.lua",
    "$configDir\plugins\language_dockerfile.lua",
    "$configDir\plugins\language_ignore.lua",
    "$configDir\plugins\lazy_lite_preview_server.exe",
    "$configDir\plugins\lazy_lite_web_preview.lua",
    "$configDir\plugins\leetcode.lua",
    "$configDir\plugins\leetcode_assessment.lua",
    "$configDir\plugins\lsp_setup.lua",
    "$configDir\plugins\lsp_snippets.lua",
    "$configDir\plugins\markdown_view.lua",
    "$configDir\plugins\mongodb_explorer.lua",
    "$configDir\plugins\mossy_icons.lua",
    "$configDir\plugins\mossy_statusbar.lua",
    "$configDir\plugins\mossy_treeview.lua",
    "$configDir\plugins\open_project_mode.lua",
    "$configDir\plugins\pdf_engine.py",
    "$configDir\plugins\pdf_viewer.lua",
    "$configDir\plugins\podman_manager.lua",
    "$configDir\plugins\port_forward.lua",
    "$configDir\plugins\premium_splits.lua",
    "$configDir\plugins\problem_tags.json",
    "$configDir\plugins\resource_monitor.lua",
    "$configDir\plugins\smart_indent.lua",
    "$configDir\plugins\snippets.lua",
    "$configDir\plugins\splash_art.lua",
    "$configDir\plugins\split_editor_buttons.lua",
    "$configDir\plugins\tempfiles_manager.lua",
    "$configDir\plugins\toggle_terminal.lua",
    "$configDir\plugins\virtual_codespace_fs.lua",
    "$configDir\plugins\workspace.lua",
    "$configDir\colors\everforest_lite_xl.lua",
    "$configDir\colors\dark_forest_lite_xl.lua",
    "$configDir\colors\tokyo_night_remix.lua",
    "$configDir\fonts\FiraCode-iScript.ttf",
    "$configDir\fonts\FiraCodeiScript-Bold.ttf",
    "$configDir\fonts\FiraCodeNerdFont-Regular.ttf",
    "$configDir\scripts\colab_notebook_parser.py",
    "$configDir\scripts\gen_splash_art.py",
    "$configDir\scripts\leetcode_api.py",
    "$configDir\scripts\localtunnel_bridge.js",
    "$configDir\scripts\mongodb_bridge.py",
    "$configDir\scripts\remote_lsp_proxy.py"
)

# Sub-directories installed by LazyLite
$subDirs = @(
    "$configDir\plugins\lsp",
    "$configDir\plugins\widget",
    "$configDir\plugins\lintplus",
    "$configDir\plugins\loader_games",
    "$configDir\plugins\toggle_terminal",
    "$configDir\plugins\tunnel_monitor",
    "$configDir\plugins\python_runtime",
    "$configDir\codespaces"
)

foreach ($dir in $subDirs) {
    if (Test-Path -LiteralPath $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[-] Removed $(Split-Path $dir -Leaf) directory" -ForegroundColor Gray
    }
}

foreach ($file in $files) {
    if (Test-Path -LiteralPath $file) {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        Write-Host "[-] Removed $(Split-Path $file -Leaf)" -ForegroundColor Gray
    }
}

# Automatically clean init.lua
$initFile = "$configDir\init.lua"
if (Test-Path -LiteralPath $initFile) {
    $initContent = Get-Content -LiteralPath $initFile -Raw
    $marker = "-- [[ LazyLite Configuration ]]"
    if ($initContent.Contains($marker)) {
        # Create safety backup
        Copy-Item -LiteralPath $initFile -Destination "$configDir\init.lua.bak" -Force
        Write-Host "[+] Created safety backup at $configDir\init.lua.bak" -ForegroundColor Green

        # Regex removal of the LazyLite block
        $cleaned = $initContent -replace '(?s)--\s*\[\[\s*LazyLite Configuration\s*\]\].*?--\s*\[\[\s*End LazyLite Configuration\s*\]\]\s*', ''
        # Fallback if End marker not found
        if ($cleaned.Contains($marker)) {
            $cleaned = $initContent -replace '(?s)--\s*\[\[\s*LazyLite Configuration\s*\]\].*', ''
        }
        Set-Content -LiteralPath $initFile -Value $cleaned.Trim() -Encoding utf8
        Write-Host "[+] Automatically removed LazyLite block from init.lua" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Green
Write-Host "  Uninstallation complete! Restart Lite-XL." -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
Write-Host ""
Read-Host "Press Enter to exit"
