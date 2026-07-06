$configDir = "$env:USERPROFILE\.config\lite-xl"

Write-Host "Uninstalling Lite-XL Mossy Configuration..."

# Delete files
$files = @(
    "$configDir\plugins\antigravity_sidebar.lua",
    "$configDir\plugins\mossy_icons.lua",
    "$configDir\plugins\mossy_treeview.lua",
    "$configDir\plugins\toggle_terminal.lua",
    "$configDir\plugins\mossy_statusbar.lua",
    "$configDir\plugins\autoclose.lua",
    "$configDir\plugins\auto_healer.lua",
    "$configDir\plugins\git_timeline.lua",
    "$configDir\plugins\github_codespaces.lua",
    "$configDir\plugins\language_ignore.lua",
    "$configDir\plugins\resource_monitor.lua",
    "$configDir\plugins\tempfiles_manager.lua",
    "$configDir\plugins\workspace.lua",
    "$configDir\plugins\virtual_codespace_fs.lua",
    "$configDir\plugins\codespace_treeview.lua",
    "$configDir\plugins\agy_pty_bridge.py",
    "$configDir\colors\everforest_lite_xl.lua",
    "$configDir\colors\dark_forest_lite_xl.lua",
    "$configDir\colors\tokyo_night_remix.lua",
    "$configDir\fonts\FiraCode-iScript.ttf",
    "$configDir\fonts\FiraCodeiScript-Bold.ttf",
    "$configDir\fonts\FiraCodeNerdFont-Regular.ttf",
    "$configDir\scripts\remote_lsp_proxy.py"
)

# Remove plugin sub-directories and codespaces cache
if (Test-Path "$configDir\plugins\lsp") {
    Remove-Item -Path "$configDir\plugins\lsp" -Recurse -Force
    Write-Host "Removed lsp directory"
}
if (Test-Path "$configDir\plugins\widget") {
    Remove-Item -Path "$configDir\plugins\widget" -Recurse -Force
    Write-Host "Removed widget directory"
}
if (Test-Path "$configDir\plugins\lintplus") {
    Remove-Item -Path "$configDir\plugins\lintplus" -Recurse -Force
    Write-Host "Removed lintplus directory"
}
if (Test-Path "$configDir\plugins\loader_games") {
    Remove-Item -Path "$configDir\plugins\loader_games" -Recurse -Force
    Write-Host "Removed loader_games directory"
}
if (Test-Path "$configDir\codespaces") {
    Remove-Item -Path "$configDir\codespaces" -Recurse -Force
    Write-Host "Removed codespaces cache directory"
}

foreach ($file in $files) {
    if (Test-Path $file) {
        Remove-Item -Path $file -Force
        Write-Host "Removed $(Split-Path $file -Leaf)"
    }
}

# Warn about init.lua
Write-Host ""
Write-Host "IMPORTANT: Please manually open $configDir\init.lua"
Write-Host "and delete the lines under '-- [[ LazyLite Configuration ]]'"
Write-Host ""
Write-Host "Uninstallation complete! Restart Lite-XL."
Read-Host "Press Enter to exit"
