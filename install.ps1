$configDir = "$env:USERPROFILE\.config\lite-xl"
$srcDir = $PSScriptRoot

Write-Host @"
    __                      __    _ __     
   / /   ____ _____  __  __/ /   (_) /____ 
  / /   / __ `/_  / / / / / /   / / __/ _ \
 / /___/ /_/ / / /_/ /_/ / /___/ / /_/  __/
/_____/\__,_/ /___/\__, /_____/_/\__/\___/ 
                  /____/                   

"@ -ForegroundColor Green

Write-Host "[*] Welcome to the LazyLite Installer! [*]" -ForegroundColor DarkGreen
Write-Host "[+] Transforming your Lite-XL into a modern powerhouse... [+]" -ForegroundColor Gray
Write-Host "------------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "[!] DISCLAIMER: For the Auto-Healer setup to work, the Antigravity CLI (agy) is required." -ForegroundColor Yellow
Write-Host "------------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

function Animate-Progress {
    param([string]$Msg)
    Write-Host "➤ $Msg" -ForegroundColor Cyan
    Write-Host "  [" -NoNewline -ForegroundColor Green
    for ($i=0; $i -lt 30; $i++) {
        Write-Host "█" -NoNewline -ForegroundColor DarkGreen
        Start-Sleep -Milliseconds 30
    }
    Write-Host "] ✔" -ForegroundColor Green
}

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

# 1.8. Emoji font — Windows has Segoe UI Emoji built-in (C:\Windows\Fonts\seguiemj.ttf).
#      The AI sidebar auto-detects it. We download NotoColorEmoji as a supplementary fallback
#      in case the font picker needs a wider emoji range.
$segoeEmoji = "$env:WINDIR\Fonts\seguiemj.ttf"
$notoEmoji   = "$fontDir\NotoColorEmoji.ttf"
if (Test-Path $segoeEmoji) {
    Write-Host "Segoe UI Emoji found at $segoeEmoji — primary emoji font ready."
} else {
    Write-Host "WARNING: seguiemj.ttf not found — downloading NotoColorEmoji as fallback..."
    irm "https://github.com/googlefonts/noto-emoji/raw/main/fonts/NotoColorEmoji.ttf" -OutFile $notoEmoji
    Write-Host "NotoColorEmoji downloaded to $notoEmoji"
}
if (-not (Test-Path $notoEmoji)) {
    Write-Host "Downloading NotoColorEmoji as supplementary emoji fallback..."
    Try {
        irm "https://github.com/googlefonts/noto-emoji/raw/main/fonts/NotoColorEmoji.ttf" -OutFile $notoEmoji
        Write-Host "NotoColorEmoji downloaded successfully."
    } Catch {
        Write-Host "WARNING: NotoColorEmoji download failed. Emoji will still work via Segoe UI Emoji."
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

# 3. Optional Features Setup
$installPodman = Read-Host "Do you want to setup Podman support in the editor? (Y/N)"
$setupPodman = ($installPodman -match "^[yY]")

$installLeetcode = Read-Host "Do you want to setup LeetCode plugin? (Y/N)"
$setupLeetcode = ($installLeetcode -match "^[yY]")

$installMongo = Read-Host "Do you want to setup MongoDB Explorer? (Y/N)"
$setupMongo = ($installMongo -match "^[yY]")

if ($setupPodman) {
    $podmanCheck = Get-Command "podman" -ErrorAction SilentlyContinue
    if (-not $podmanCheck) {
        Write-Host "Installing Podman..."
        winget install -e --id RedHat.Podman --accept-source-agreements --accept-package-agreements
    }
}

if ($setupMongo) {
    $mongoshCheck = Get-Command "mongosh" -ErrorAction SilentlyContinue
    if (-not $mongoshCheck) {
        Write-Host "Installing MongoDB Shell (mongosh)..."
        winget install -e --id MongoDB.mongosh --accept-source-agreements --accept-package-agreements
    }
    $pythonCheck = Get-Command "python" -ErrorAction SilentlyContinue
    if ($pythonCheck) {
        python -m pip install pymongo --quiet
    } else {
        Write-Host "WARNING: Python is required for MongoDB Explorer."
    }
}

Animate-Progress "Installing Lite-XL Mossy Configuration..."

# Create dirs if they don't exist
New-Item -ItemType Directory -Force -Path "$configDir\plugins" | Out-Null
New-Item -ItemType Directory -Force -Path "$configDir\colors"  | Out-Null
New-Item -ItemType Directory -Force -Path "$configDir\fonts"   | Out-Null
New-Item -ItemType Directory -Force -Path "$configDir\scripts" | Out-Null

# Copy all .lua plugin files (skip AI sidebar if agy not installed)
Get-ChildItem -Path "$srcDir\plugins\*.lua" | ForEach-Object {
    if ($_.Name -eq "antigravity_sidebar.lua" -and -not $installAgySidebar) {
        Write-Host "Skipping antigravity_sidebar.lua..."
    } elseif ($_.Name -eq "podman_manager.lua" -and -not $setupPodman) {
        Write-Host "Skipping podman_manager.lua..."
    } elseif ($_.Name -eq "leetcode.lua" -and -not $setupLeetcode) {
        Write-Host "Skipping leetcode.lua..."
    } elseif ($_.Name -eq "mongodb_explorer.lua" -and -not $setupMongo) {
        Write-Host "Skipping mongodb_explorer.lua..."
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
    Get-ChildItem -Path "$srcDir\scripts\*" | ForEach-Object {
        if ($_.Name -eq "leetcode_api.py" -and -not $setupLeetcode) {
            Write-Host "Skipping leetcode_api.py..."
        } elseif ($_.Name -eq "mongodb_bridge.py" -and -not $setupMongo) {
            Write-Host "Skipping mongodb_bridge.py..."
        } else {
            Copy-Item -Path $_.FullName -Destination "$configDir\scripts\" -Force
        }
    }
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
if (Test-Path "$srcDir\plugins\tunnel_monitor") {
    Copy-Item -Path "$srcDir\plugins\tunnel_monitor" -Destination "$configDir\plugins\tunnel_monitor" -Recurse -Force
}
if (Test-Path "$srcDir\plugins\python_runtime") {
    Copy-Item -Path "$srcDir\plugins\python_runtime" -Destination "$configDir\plugins\python_runtime" -Recurse -Force
}
Write-Host "Copied plugins, scripts, fonts, and color scheme."

# Copy custom agent skills
$geminiConfigDir = "$env:USERPROFILE\.gemini\config"
if (Test-Path "$srcDir\skills") {
    New-Item -ItemType Directory -Force -Path "$geminiConfigDir\skills" | Out-Null
    Copy-Item -Path "$srcDir\skills\*" -Destination "$geminiConfigDir\skills\" -Recurse -Force
    Write-Host "Copied custom Antigravity skills."
}

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
Write-Host "💡 Tip: LazyLite is fully yours to shape! Feel free to explore your new .config\lite-xl folder and tweak the configs, plugins, and colors to make it uniquely yours." -ForegroundColor Cyan
Write-Host ""
Write-Host "NEXT STEP: Run 'agy install' once in a terminal to configure the AI backend."
Read-Host "Press Enter to exit"
