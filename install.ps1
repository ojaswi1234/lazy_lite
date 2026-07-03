$configDir = "$env:USERPROFILE\.config\lite-xl"
$srcDir = $PSScriptRoot

Write-Host "Lite-XL Mossy Configuration Installer"
Write-Host "---------------------------------------"

# 1. Check Lite-XL
$liteXlInstalled = Get-Command "lite-xl" -ErrorAction SilentlyContinue
if (-not $liteXlInstalled) {
    $installLite = Read-Host "Lite-XL is not installed. Do you want to install it automatically? (Y/N)"
    if ($installLite -match "^[yY]") {
        Write-Host "Installing Lite-XL..."
        $installer = "LiteXL-setup.exe"
        irm https://github.com/lite-xl/lite-xl/releases/download/v2.1.8/LiteXL-v2.1.8-addons-x86_64-setup.exe -OutFile $installer
        Start-Process -FilePath $installer -Wait
        Remove-Item -Path $installer -Force
    } else {
        Write-Host "Lite-XL installation skipped. Cannot proceed without Lite-XL. Exiting."
        exit
    }
}

# 2. Check Antigravity CLI
$agyInstalled = Get-Command "agy" -ErrorAction SilentlyContinue
$installAgySidebar = $true

if (-not $agyInstalled) {
    $installAgy = Read-Host "Antigravity CLI (agy) is not installed. Do you want to install it automatically using the official installer? (Y/N)"
    if ($installAgy -match "^[yY]") {
        Write-Host "Installing Antigravity CLI..."
        irm https://antigravity.google/cli/install.ps1 | iex
        $installAgySidebar = $true
    } else {
        Write-Host ""
        Write-Host "Note: You have chosen not to install the Antigravity CLI. The AI sidebar will not be added to your Lite-XL setup,"
        Write-Host "but other customizations (colors, fonts, tweaks) will still be installed."
        Write-Host "If you change your mind, you can run this script again later to add it."
        Write-Host ""
        $installAgySidebar = $false
    }
}

Write-Host "Installing Lite-XL Mossy Configuration..."

# Create dirs if they don't exist
New-Item -ItemType Directory -Force -Path "$configDir\plugins" | Out-Null
New-Item -ItemType Directory -Force -Path "$configDir\colors" | Out-Null
New-Item -ItemType Directory -Force -Path "$configDir\fonts" | Out-Null

# Copy files
Get-ChildItem -Path "$srcDir\plugins\*.lua" | ForEach-Object {
    if ($_.Name -eq "antigravity_sidebar.lua" -and -not $installAgySidebar) {
        Write-Host "Skipping antigravity_sidebar.lua..."
    } else {
        Copy-Item -Path $_.FullName -Destination "$configDir\plugins\" -Force
    }
}

Copy-Item -Path "$srcDir\colors\*.lua" -Destination "$configDir\colors\" -Force
if (Test-Path "$srcDir\fonts\*.ttf") {
    Copy-Item -Path "$srcDir\fonts\*.ttf" -Destination "$configDir\fonts\" -Force
}
Write-Host "Copied plugins, fonts, and color scheme."

# Update init.lua safely
$initFile = "$configDir\init.lua"
$marker = "-- [[ LazyLite Configuration ]]"
$initContent = ""
if (Test-Path $initFile) {
    $initContent = Get-Content $initFile -Raw
}

if (-not $initContent.Contains($marker)) {
    $append = Get-Content "$srcDir\init_append.lua" -Raw
    Add-Content -Path $initFile -Value "`r`n$append"
    Write-Host "Appended LazyLite configuration to init.lua"
} else {
    Write-Host "Configuration already present in init.lua"
}

Write-Host "Installation complete! Restart Lite-XL."
Read-Host "Press Enter to exit"
