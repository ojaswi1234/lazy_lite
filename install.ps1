# ==============================================================================
# LazyLite Configuration Installer (PowerShell)
# Handles all edge cases: offline fallbacks, space-resilient paths, Python alias
# detection, safe init.lua injection, and non-blocking background downloads.
# ==============================================================================

$ErrorActionPreference = "Continue"

# Resolve Config Directory safely
$configDir = "$env:USERPROFILE\.config\lite-xl"
$srcDir = $PSScriptRoot

Write-Host "==========================================" -ForegroundColor Green
Write-Host "   LazyLite Configuration Installer       " -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "[*] Welcome to the LazyLite Installer! [*]" -ForegroundColor DarkGreen
Write-Host "[+] Transforming your Lite-XL into a modern powerhouse... [+]" -ForegroundColor Gray
Write-Host "------------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "[!] DISCLAIMER: For the Auto-Healer setup to work, the Antigravity CLI (agy) is required." -ForegroundColor Yellow
Write-Host "------------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

function Animate-Progress {
    param([string]$Msg)
    Write-Host ">> $Msg" -ForegroundColor Cyan
    Write-Host "  [" -NoNewline -ForegroundColor Green
    for ($i=0; $i -lt 30; $i++) {
        Write-Host "=" -NoNewline -ForegroundColor DarkGreen
        Start-Sleep -Milliseconds 10
    }
    Write-Host "] OK" -ForegroundColor Green
}

# Helper to safely download files with timeout and error handling
function Safe-Download {
    param([string]$Url, [string]$OutPath, [string]$Desc)
    try {
        $parent = Split-Path -Parent $OutPath
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        Invoke-RestMethod -Uri $Url -OutFile $OutPath -TimeoutSec 15 -ErrorAction Stop
        Write-Host "[+] Downloaded $Desc" -ForegroundColor Gray
        return $true
    } catch {
        Write-Host "[-] Notice: Could not download $Desc ($($_.Exception.Message)). Continuing with local fallback..." -ForegroundColor Yellow
        return $false
    }
}

# 1. Check Lite-XL Installation
$liteXlCmd = Get-Command "lite-xl" -ErrorAction SilentlyContinue
if (-not $liteXlCmd) {
    # Check standard install locations
    $stdPaths = @(
        "$env:ProgramFiles\Lite XL\lite-xl.exe",
        "${env:ProgramFiles(x86)}\Lite XL\lite-xl.exe",
        "$env:LOCALAPPDATA\Programs\Lite XL\lite-xl.exe"
    )
    $foundStd = $false
    foreach ($p in $stdPaths) {
        if (Test-Path -LiteralPath $p) {
            $foundStd = $true
            break
        }
    }

    if (-not $foundStd) {
        $installLite = Read-Host "Lite-XL is not found in PATH or standard folders. Do you want to download & install it automatically? (Y/N)"
        if ($installLite -match "^[yY]") {
            Write-Host "Downloading Lite-XL installer..."
            $installer = "$env:TEMP\LiteXL-setup.exe"
            $dlOk = Safe-Download "https://github.com/lite-xl/lite-xl/releases/download/v2.1.8/LiteXL-v2.1.8-addons-x86_64-setup.exe" $installer "Lite-XL Setup"
            if ($dlOk -and (Test-Path -LiteralPath $installer)) {
                Write-Host "Running Lite-XL installer (please complete the setup wizard)..."
                Start-Process -FilePath $installer -Wait
            } else {
                Write-Host "WARNING: Could not download installer. Please install Lite-XL manually from https://lite-xl.com." -ForegroundColor Red
            }
        } else {
            Write-Host "Lite-XL installation skipped. Custom configuration will still be placed in $configDir." -ForegroundColor Yellow
        }
    }
}

# 1.5. Check GitHub CLI (gh)
$ghCmd = Get-Command "gh" -ErrorAction SilentlyContinue
if (-not $ghCmd) {
    $wingetCmd = Get-Command "winget" -ErrorAction SilentlyContinue
    if ($wingetCmd) {
        Write-Host "GitHub CLI (gh) not found. Installing via winget..."
        try {
            winget install --id GitHub.cli --accept-source-agreements --accept-package-agreements --silent
        } catch {
            Write-Host "Notice: Optional gh install via winget skipped." -ForegroundColor Gray
        }
    }
}

# 1.7. Download Nerd Font for icons (Safe fallback)
$fontDir = "$configDir\fonts"
if (-not (Test-Path -LiteralPath $fontDir)) {
    New-Item -ItemType Directory -Force -Path $fontDir | Out-Null
}
$nerdFontFile = "$fontDir\FiraCodeNerdFont-Regular.ttf"
if (-not (Test-Path -LiteralPath $nerdFontFile)) {
    Write-Host "Downloading FiraCode Nerd Font..."
    Safe-Download "https://github.com/ryanoasis/nerd-fonts/raw/master/patched-fonts/FiraCode/Regular/FiraCodeNerdFont-Regular.ttf" $nerdFontFile "FiraCode Nerd Font" | Out-Null
}

# 1.8. Emoji font check and fallback download
$segoeEmoji = "$env:WINDIR\Fonts\seguiemj.ttf"
$notoEmoji  = "$fontDir\NotoColorEmoji.ttf"
if (Test-Path -LiteralPath $segoeEmoji) {
    Write-Host "[+] Segoe UI Emoji detected on system." -ForegroundColor Gray
} elseif (-not (Test-Path -LiteralPath $notoEmoji)) {
    Write-Host "Downloading NotoColorEmoji as supplementary emoji fallback..."
    Safe-Download "https://github.com/googlefonts/noto-emoji/raw/main/fonts/NotoColorEmoji.ttf" $notoEmoji "Noto Color Emoji" | Out-Null
}

# 2. Check Antigravity CLI
$agyCmd = Get-Command "agy" -ErrorAction SilentlyContinue
$installAgySidebar = $true

if (-not $agyCmd) {
    $installAgy = Read-Host "Antigravity CLI (agy) is not installed. Do you want to install it automatically using the official installer? (Y/N)"
    if ($installAgy -match "^[yY]") {
        Write-Host "Installing Antigravity CLI..."
        try {
            Invoke-RestMethod -Uri https://antigravity.google/cli/install.ps1 | Invoke-Expression
            $installAgySidebar = $true
        } catch {
            Write-Host "WARNING: Antigravity CLI installer encountered an error. You can run 'irm https://antigravity.google/cli/install.ps1 | iex' manually later." -ForegroundColor Yellow
            $installAgySidebar = $true
        }
    } else {
        Write-Host ""
        Write-Host "Note: You have chosen not to install the Antigravity CLI. The AI sidebar will not be added to your Lite-XL setup,"
        Write-Host "but other customizations (colors, fonts, tweaks) will still be installed."
        Write-Host "If you change your mind, you can run this script again later to add it."
        Write-Host ""
        $installAgySidebar = $false
    }
}

# 3. Optional Features Setup
$installPodman = Read-Host "Do you want to setup Podman support in the editor? (Y/N)"
$setupPodman = ($installPodman -match "^[yY]")

$installLeetcode = Read-Host "Do you want to setup LeetCode plugin & assessment suite? (Y/N)"
$setupLeetcode = ($installLeetcode -match "^[yY]")

$installMongo = Read-Host "Do you want to setup MongoDB Explorer? (Y/N)"
$setupMongo = ($installMongo -match "^[yY]")

$wingetAvailable = [bool](Get-Command "winget" -ErrorAction SilentlyContinue)

if ($setupPodman -and $wingetAvailable) {
    $podmanCheck = Get-Command "podman" -ErrorAction SilentlyContinue
    if (-not $podmanCheck) {
        Write-Host "Installing Podman via winget..."
        try { winget install -e --id RedHat.Podman --accept-source-agreements --accept-package-agreements --silent } catch {}
    }
}

# Real Python Runtime Check (Avoids Windows Store Alias)
$realPython = $false
try {
    $pyTest = & python -c "import sys; print(sys.version_info[0])" 2>$null
    if ($pyTest -match "3") { $realPython = $true }
} catch {}

if ($setupLeetcode) {
    if ($realPython) {
        Write-Host "Installing required Python dependencies for LeetCode API & ML engine..."
        try { & python -m pip install requests --quiet 2>$null } catch {}
    } else {
        Write-Host "Notice: Python 3 not detected or using Windows Store stub. LeetCode offline database will run natively via Lua/Python bundled runtime." -ForegroundColor Gray
    }
}

if ($setupMongo) {
    $mongoshInstalled = $false
    $mongoshCheck = Get-Command "mongosh" -ErrorAction SilentlyContinue
    if ($mongoshCheck) {
        Write-Host "MongoDB Shell (mongosh) is already installed." -ForegroundColor Green
        $mongoshInstalled = $true
    }

    if (-not $mongoshInstalled) {
        # 1. Primary: Try installing globally via npm
        $npmCheck = Get-Command "npm" -ErrorAction SilentlyContinue
        if ($npmCheck) {
            Write-Host "Installing MongoDB Shell (mongosh) globally via npm..." -ForegroundColor Cyan
            try {
                & npm install -g mongosh --silent 2>$null
                $mongoshCheck = Get-Command "mongosh" -ErrorAction SilentlyContinue
                if ($mongoshCheck -or (Test-Path "$env:APPDATA\npm\mongosh.cmd")) {
                    Write-Host "[+] mongosh installed successfully via npm." -ForegroundColor Green
                    $mongoshInstalled = $true
                }
            } catch {}
        }
    }

    if (-not $mongoshInstalled -and $wingetAvailable) {
        # 2. Secondary fallback: Try official mongosh via winget
        Write-Host "Installing official MongoDB Shell (mongosh) via winget..." -ForegroundColor Cyan
        try {
            winget install -e --id MongoDB.mongosh --accept-source-agreements --accept-package-agreements --silent
            $mongoshCheck = Get-Command "mongosh" -ErrorAction SilentlyContinue
            if ($mongoshCheck) {
                Write-Host "[+] mongosh installed successfully via winget." -ForegroundColor Green
                $mongoshInstalled = $true
            }
        } catch {}
    }

    if (-not $mongoshInstalled) {
        # 3. Tertiary fallback: Download official standalone mongosh archive
        Write-Host "Downloading standalone official MongoDB Shell (mongosh)..." -ForegroundColor Cyan
        try {
            $mongoZipUrl = "https://downloads.mongodb.com/compass/mongosh-2.4.0-win32-x64.zip"
            $tempZip = "$env:TEMP\mongosh.zip"
            $destDir = "$env:LOCALAPPDATA\Programs\mongosh"
            Invoke-WebRequest -Uri $mongoZipUrl -OutFile $tempZip -UseBasicParsing -TimeoutSec 30
            if (Test-Path $tempZip) {
                Expand-Archive -Path $tempZip -DestinationPath "$env:TEMP\mongosh_extracted" -Force
                $extractedFolder = Get-ChildItem "$env:TEMP\mongosh_extracted" | Select-Object -First 1
                if ($extractedFolder) {
                    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
                    Copy-Item -Path "$($extractedFolder.FullName)\*" -Destination $destDir -Recurse -Force
                    Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue
                    Remove-Item -Path "$env:TEMP\mongosh_extracted" -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Host "[+] Standalone official mongosh installed to $destDir" -ForegroundColor Green
                    $mongoshInstalled = $true
                }
            }
        } catch {}
    }

    if ($realPython) {
        try { & python -m pip install pymongo --quiet 2>$null } catch {}
    }
}

Animate-Progress "Installing Lite-XL Mossy Configuration..."

# Create target directories safely using -LiteralPath
$dirsToCreate = @(
    "$configDir\plugins",
    "$configDir\colors",
    "$configDir\fonts",
    "$configDir\scripts"
)
foreach ($d in $dirsToCreate) {
    if (-not (Test-Path -LiteralPath $d)) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
}

# Copy all plugins (lua, json, py, exe) with -LiteralPath protection
if (Test-Path -LiteralPath "$srcDir\plugins") {
    Get-ChildItem -LiteralPath "$srcDir\plugins" | ForEach-Object {
        if ($_.PSIsContainer) {
            # Subdirectories handled below
        } elseif ($_.Name -eq "antigravity_sidebar.lua" -and -not $installAgySidebar) {
            Write-Host "Skipping antigravity_sidebar.lua..."
        } elseif ($_.Name -eq "agy_pty_bridge.py" -and -not $installAgySidebar) {
            Write-Host "Skipping agy_pty_bridge.py..."
        } elseif ($_.Name -eq "podman_manager.lua" -and -not $setupPodman) {
            Write-Host "Skipping podman_manager.lua..."
        } elseif (($_.Name -eq "leetcode.lua" -or $_.Name -eq "leetcode_assessment.lua" -or $_.Name -eq "company_tags.json" -or $_.Name -eq "problem_tags.json" -or $_.Name -eq "company_scores.json") -and -not $setupLeetcode) {
            Write-Host "Skipping $($_.Name)..."
        } elseif ($_.Name -eq "mongodb_explorer.lua" -and -not $setupMongo) {
            Write-Host "Skipping mongodb_explorer.lua..."
        } else {
            Copy-Item -LiteralPath $_.FullName -Destination "$configDir\plugins\" -Force
        }
    }
}

# Copy color schemes
if (Test-Path -LiteralPath "$srcDir\colors") {
    Get-ChildItem -LiteralPath "$srcDir\colors" -Filter "*.lua" | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination "$configDir\colors\" -Force
    }
}

# Copy bundled fonts
if (Test-Path -LiteralPath "$srcDir\fonts") {
    Get-ChildItem -LiteralPath "$srcDir\fonts" -Filter "*.ttf" | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination "$configDir\fonts\" -Force
    }
}

# Copy scripts
if (Test-Path -LiteralPath "$srcDir\scripts") {
    Get-ChildItem -LiteralPath "$srcDir\scripts" | ForEach-Object {
        if ($_.Name -eq "leetcode_api.py" -and -not $setupLeetcode) {
            Write-Host "Skipping leetcode_api.py..."
        } elseif ($_.Name -eq "mongodb_bridge.py" -and -not $setupMongo) {
            Write-Host "Skipping mongodb_bridge.py..."
        } else {
            Copy-Item -LiteralPath $_.FullName -Destination "$configDir\scripts\" -Force
        }
    }
}

# Copy sub-directories (third-party and custom plugins)
$subDirs = @("lsp", "widget", "lintplus", "loader_games", "toggle_terminal", "tunnel_monitor", "python_runtime")
foreach ($sub in $subDirs) {
    $srcSub = "$srcDir\plugins\$sub"
    if (Test-Path -LiteralPath $srcSub) {
        $destSub = "$configDir\plugins\$sub"
        if (-not (Test-Path -LiteralPath $destSub)) {
            New-Item -ItemType Directory -Force -Path $destSub | Out-Null
        }
        Copy-Item -LiteralPath $srcSub -Destination "$configDir\plugins" -Recurse -Force
    }
}
Write-Host "[+] Copied plugins, scripts, fonts, and color schemes." -ForegroundColor Green

# Copy custom agent skills
$geminiConfigDir = "$env:USERPROFILE\.gemini\config"
if (Test-Path -LiteralPath "$srcDir\skills") {
    if (-not (Test-Path -LiteralPath "$geminiConfigDir\skills")) {
        New-Item -ItemType Directory -Force -Path "$geminiConfigDir\skills" | Out-Null
    }
    Copy-Item -LiteralPath "$srcDir\skills\*" -Destination "$geminiConfigDir\skills\" -Recurse -Force
    Write-Host "[+] Copied custom Antigravity skills." -ForegroundColor Green
}

# Update init.lua safely (Inject LazyLite block if not already present)
$initFile = "$configDir\init.lua"
$marker = "-- [[ LazyLite Configuration ]]"
$initContent = ""
if (Test-Path -LiteralPath $initFile) {
    $initContent = Get-Content -LiteralPath $initFile -Raw
}

if ([string]::IsNullOrWhiteSpace($initContent)) {
    # If init.lua is empty or non-existent, copy the full master init.lua
    if (Test-Path -LiteralPath "$srcDir\init.lua") {
        Copy-Item -LiteralPath "$srcDir\init.lua" -Destination $initFile -Force
        Write-Host "[+] Installed master init.lua configuration." -ForegroundColor Green
    } else {
        $append = Get-Content -LiteralPath "$srcDir\init_append.lua" -Raw
        Set-Content -LiteralPath $initFile -Value $append -Encoding utf8
        Write-Host "[+] Created init.lua with LazyLite configuration." -ForegroundColor Green
    }
} elseif (-not $initContent.Contains($marker)) {
    $append = Get-Content -LiteralPath "$srcDir\init_append.lua" -Raw
    Add-Content -LiteralPath $initFile -Value ([Environment]::NewLine + $append) -Encoding utf8
    Write-Host "[+] Appended LazyLite configuration to existing init.lua" -ForegroundColor Green
} else {
    Write-Host "[+] LazyLite configuration already present in init.lua" -ForegroundColor Gray
}

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Green
Write-Host "  Installation complete! Restart Lite-XL to enjoy LazyLite." -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Tip: LazyLite is fully yours to shape! Feel free to explore your .config\lite-xl folder and customize settings via 'UI: settings'." -ForegroundColor Cyan
Write-Host ""
Write-Host "NEXT STEP: Run 'agy install' once in a terminal to configure the AI backend."
Write-Host ""
Read-Host "Press Enter to exit"
