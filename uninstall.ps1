$configDir = "$env:USERPROFILE\.config\lite-xl"

Write-Host "Uninstalling Lite-XL Mossy Configuration..."

# Delete files
$files = @(
    "$configDir\plugins\antigravity_sidebar.lua",
    "$configDir\plugins\mossy_icons.lua",
    "$configDir\plugins\mossy_treeview.lua",
    "$configDir\plugins\toggle_terminal.lua",
    "$configDir\plugins\mossy_statusbar.lua",
    "$configDir\colors\everforest_lite_xl.lua"
)

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
