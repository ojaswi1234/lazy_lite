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
    } else {
        Write-Host "Lite-XL installation skipped. Cannot proceed without Lite-XL. Exiting."
        exit
    }
}

# 1.5. Check GitHub CLI (gh)
$ghInstalled = Get-Command "gh" -ErrorAction SilentlyContinue
if (-not $ghInstalled) {
    Write-Host "GitHub CLI (gh) not found. Installing via winget..."
    winget install --id GitHub.cli --accept-source-agreements --accept-package-agreements
}

# 1.6. Check Python + pywinpty (required for the AI sidebar's PTY bridge on Windows)
$pythonInstalled = Get-Command "python" -ErrorAction SilentlyContinue
if ($pythonInstalled) {
    $pywinptyCheck = python -c "import winpty" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Installing pywinpty (required for AI sidebar streaming)..."
        python -m pip install pywinpty --quiet
    }
} else {
    Write-Host "WARNING: Python not found. The AI sidebar PTY bridge (agy_pty_bridge.py) requires Python + pywinpty."
    Write-Host "         Install Python from https://python.org and then run: pip install pywinpty"
}

# 1.7. Download Nerd Font for icons
Write-Host "Downloading FiraCode Nerd Font..."
$fontDir = "$configDir\fonts"
New-Item -ItemType Directory -Force -Path $fontDir | Out-Null
irm "https://github.com/ryanoasis/nerd-fonts/raw/master/patched-fonts/FiraCode/Regular/FiraCodeNerdFont-Regular.ttf" -OutFile "$fontDir\FiraCodeNerdFont-Regular.ttf"

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
New-Item -ItemType Directory -Force -Path "$configDir\colors"  | Out-Null
New-Item -ItemType Directory -Force -Path "$configDir\fonts"   | Out-Null
New-Item -ItemType Directory -Force -Path "$configDir\scripts" | Out-Null

# Copy all .lua plugin files (skip AI sidebar if agy not installed)
Get-ChildItem -Path "$srcDir\plugins\*.lua" | ForEach-Object {
    if ($_.Name -eq "antigravity_sidebar.lua" -and -not $installAgySidebar) {
        Write-Host "Skipping antigravity_sidebar.lua..."
    } else {
        Copy-Item -Path $_.FullName -Destination "$configDir\plugins\" -Force
    }
}

# Copy Python bridge (required for AI sidebar on Windows)
if ($installAgySidebar -and (Test-Path "$srcDir\plugins\agy_pty_bridge.py")) {
    Copy-Item -Path "$srcDir\plugins\agy_pty_bridge.py" -Destination "$configDir\plugins\" -Force
}

# Copy color schemes
Copy-Item -Path "$srcDir\colors\*.lua" -Destination "$configDir\colors\" -Force

# Copy bundled fonts (if any are in the repo)
if (Test-Path "$srcDir\fonts\*.ttf") {
    Copy-Item -Path "$srcDir\fonts\*.ttf" -Destination "$configDir\fonts\" -Force
}

# Copy scripts (remote LSP proxy for Codespaces)
if (Test-Path "$srcDir\scripts") {
    Copy-Item -Path "$srcDir\scripts\*" -Destination "$configDir\scripts\" -Force
}

# Copy sub-directories (third-party and custom plugins)
if (Test-Path "$srcDir\plugins\lsp") {
    Copy-Item -Path "$srcDir\plugins\lsp" -Destination "$configDir\plugins\lsp" -Recurse -Force
}
if (Test-Path "$srcDir\plugins\widget") {
    Copy-Item -Path "$srcDir\plugins\widget" -Destination "$configDir\plugins\widget" -Recurse -Force
}
if (Test-Path "$srcDir\plugins\lintplus") {
    Copy-Item -Path "$srcDir\plugins\lintplus" -Destination "$configDir\plugins\lintplus" -Recurse -Force
}
if (Test-Path "$srcDir\plugins\loader_games") {
    Copy-Item -Path "$srcDir\plugins\loader_games" -Destination "$configDir\plugins\loader_games" -Recurse -Force
}
Write-Host "Copied plugins, scripts, fonts, and color scheme."

# Update init.lua safely (append LazyLite block if not already present)
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

Write-Host ""
Write-Host "Installation complete! Restart Lite-XL."
Write-Host ""
Write-Host "NEXT STEP: Run 'agy install' once in a terminal to configure the AI backend."
Read-Host "Press Enter to exit"
