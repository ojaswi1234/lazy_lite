# ==============================================================================
# LazyLite Configuration & Auto-Setup Installer (PowerShell)
# High-reliability bootstrap supporting unattended CI, GitHub Actions,
# space-resilient paths, Python alias detection, and safe configuration.
# ==============================================================================

param(
    [switch]$Unattended,
    [switch]$Force,
    [switch]$SkipLiteXl,
    [switch]$SkipAgy,
    [switch]$SkipLeetcode,
    [switch]$SkipMongo
)

$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Auto-detect non-interactive environments (CI, GitHub Actions, background tasks)
if ($env:CI -eq "true" -or $env:GITHUB_ACTIONS -eq "true" -or [Console]::IsInputRedirected) {
    $Unattended = $true
}

# Resolve Config Directory safely
$configDir = "$env:USERPROFILE\.config\lite-xl"
$srcDir = $PSScriptRoot

Write-Host "==========================================" -ForegroundColor Green
Write-Host "   LazyLite Configuration Installer       " -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "[*] Welcome to the LazyLite Installer! [*]" -ForegroundColor DarkGreen
Write-Host "[+] Transforming your Lite-XL into a modern powerhouse... [+]" -ForegroundColor Gray
if ($Unattended) {
    Write-Host "[*] Running in unattended auto-setup mode." -ForegroundColor Cyan
}
Write-Host "------------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "[!] Note: AI Sidebar and Auto-Healer default to API mode if Antigravity CLI (agy) is not installed." -ForegroundColor Yellow
Write-Host "------------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

function Animate-Progress {
    param([string]$Msg)
    Write-Host ">> $Msg" -ForegroundColor Cyan
    if ($Unattended) {
        Write-Host "  [==============================] OK" -ForegroundColor Green
    } else {
        Write-Host "  [" -NoNewline -ForegroundColor Green
        for ($i=0; $i -lt 30; $i++) {
            Write-Host "=" -NoNewline -ForegroundColor DarkGreen
            Start-Sleep -Milliseconds 10
        }
        Write-Host "] OK" -ForegroundColor Green
    }
}

# Helper to safely download files with timeout and error handling
function Safe-Download {
    param([string]$Url, [string]$OutPath, [string]$Desc)
    try {
        $parent = Split-Path -Parent $OutPath
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        Invoke-RestMethod -Uri $Url -OutFile $OutPath -TimeoutSec 120 -ErrorAction Stop
        Write-Host "[+] Downloaded $Desc" -ForegroundColor Gray
        return $true
    } catch {
        Write-Host "[-] Notice: Could not download $Desc ($($_.Exception.Message)). Continuing with fallback..." -ForegroundColor Yellow
        return $false
    }
}

# Handle piped in-memory execution (clone repo if running directly from irm | iex)
if (-not (Test-Path -LiteralPath "$srcDir\plugins")) {
    $tempCloneDir = "$env:TEMP\lazylite-bootstrap-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
    Write-Host "[*] Fetching LazyLite setup bundle from GitHub..." -ForegroundColor Cyan
    $gitCmd = Get-Command "git" -ErrorAction SilentlyContinue
    if ($gitCmd) {
        & git clone --depth 1 https://github.com/ojaswi1234/lazy_lite.git $tempCloneDir 2>$null | Out-Null
    }
    if (Test-Path -LiteralPath "$tempCloneDir\plugins") {
        $srcDir = $tempCloneDir
    }
}

# 1. Check Lite-XL Installation
if (-not $SkipLiteXl) {
    $liteXlCmd = Get-Command "lite-xl" -ErrorAction SilentlyContinue
    if (-not $liteXlCmd) {
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
            $installLite = "Y"
            if (-not $Unattended) {
                $installLite = Read-Host "Lite-XL is not found in PATH. Download & install it automatically? (Y/N) [default: Y]"
                if ([string]::IsNullOrWhiteSpace($installLite)) { $installLite = "Y" }
            }
            if ($installLite -match "^[yY]") {
                Write-Host "Downloading Lite-XL installer..."
                $installer = "$env:TEMP\LiteXL-setup.exe"
                $dlOk = Safe-Download "https://github.com/lite-xl/lite-xl/releases/download/v2.1.8/LiteXL-v2.1.8-addons-x86_64-setup.exe" $installer "Lite-XL Setup"
                if ($dlOk -and (Test-Path -LiteralPath $installer)) {
                    Write-Host "Running Lite-XL installer..."
                    Start-Process -FilePath $installer -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -Wait
                } else {
                    Write-Host "WARNING: Could not download installer. Placing configuration in $configDir." -ForegroundColor Yellow
                }
            } else {
                Write-Host "Lite-XL installation skipped. Configuration will still be placed in $configDir." -ForegroundColor Yellow
            }
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
        } catch {}
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
$agyInstalled = [bool]$agyCmd

if (-not $agyCmd -and -not $SkipAgy) {
    $installAgy = "Y"
    if (-not $Unattended) {
        $installAgy = Read-Host "Antigravity CLI (agy) is not installed. Do you want to install it automatically? (Y/N) [default: Y]"
        if ([string]::IsNullOrWhiteSpace($installAgy)) { $installAgy = "Y" }
    }
    if ($installAgy -match "^[yY]") {
        Write-Host "Installing Antigravity CLI..."
        try {
            Invoke-RestMethod -Uri https://antigravity.google/cli/install.ps1 | Invoke-Expression
            $agyInstalled = $true
        } catch {
            Write-Host "WARNING: Antigravity CLI installer encountered an error. You can run 'irm https://antigravity.google/cli/install.ps1 | iex' manually later." -ForegroundColor Yellow
        }
    }
}

# 3. Optional Features Setup
$setupLeetcode = -not $SkipLeetcode
if (-not $Unattended -and -not $SkipLeetcode) {
    $installLeetcode = Read-Host "Do you want to setup LeetCode plugin & assessment suite? (Y/N) [default: Y]"
    if ([string]::IsNullOrWhiteSpace($installLeetcode)) { $installLeetcode = "Y" }
    $setupLeetcode = ($installLeetcode -match "^[yY]")
}

$setupMongo = -not $SkipMongo
if (-not $Unattended -and -not $SkipMongo) {
    $installMongo = Read-Host "Do you want to setup MongoDB Explorer? (Y/N) [default: Y]"
    if ([string]::IsNullOrWhiteSpace($installMongo)) { $installMongo = "Y" }
    $setupMongo = ($installMongo -match "^[yY]")
}

$wingetAvailable = [bool](Get-Command "winget" -ErrorAction SilentlyContinue)

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
    }
}

if ($setupMongo) {
    $mongoshInstalled = $false
    $mongoshCheck = Get-Command "mongosh" -ErrorAction SilentlyContinue
    if ($mongoshCheck) {
        $mongoshInstalled = $true
    }

    # 1. Prefer official standalone winget package
    if (-not $mongoshInstalled -and $wingetAvailable) {
        Write-Host "Installing official MongoDB Shell (mongosh) via winget..." -ForegroundColor Cyan
        try {
            winget install -e --id MongoDB.mongosh --accept-source-agreements --accept-package-agreements --silent
            $mongoshCheck = Get-Command "mongosh" -ErrorAction SilentlyContinue
            if ($mongoshCheck) { $mongoshInstalled = $true }
        } catch {}
    }

    # 2. Standalone binary check in LOCALAPPDATA
    if (-not $mongoshInstalled -and (Test-Path "$env:LOCALAPPDATA\Programs\mongosh\mongosh.exe")) {
        $mongoshInstalled = $true
    }

    # 3. NPM fallback only if native installer is unavailable
    if (-not $mongoshInstalled) {
        $npmCheck = Get-Command "npm" -ErrorAction SilentlyContinue
        if ($npmCheck) {
            Write-Host "Installing MongoDB Shell (mongosh) via npm fallback..." -ForegroundColor Cyan
            try {
                & npm install -g mongosh --silent 2>$null
                $mongoshCheck = Get-Command "mongosh" -ErrorAction SilentlyContinue
                if ($mongoshCheck) {
                    $mongoshInstalled = $true
                }
            } catch {}
        }
    }

    if ($realPython) {
        try { & python -m pip install pymongo --quiet 2>$null } catch {}
    }
}

if ($realPython) {
    Write-Host "Installing Core AI Dependencies (LangGraph, MCP, Graphify, etc.)..." -ForegroundColor Cyan
    try { & python -m pip install langchain-core langchain-google-genai langchain-groq langchain-openai langchain-anthropic langgraph mcp langchain-mcp-adapters graphifyy duckduckgo-search psutil --quiet 2>$null } catch {}
}

Animate-Progress "Installing Lite-XL Mossy Configuration & Plugins..."

# Create target directories safely using -LiteralPath
$dirsToCreate = @(
    "$configDir\plugins",
    "$configDir\colors",
    "$configDir\fonts",
    "$configDir\scripts",
    "$configDir\attachments"
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
        } elseif (($_.Name -eq "leetcode.lua" -or $_.Name -eq "leetcode_assessment.lua" -or $_.Name -eq "company_tags.json" -or $_.Name -eq "problem_tags.json" -or $_.Name -eq "company_scores.json") -and -not $setupLeetcode) {
            # skip
        } elseif ($_.Name -eq "mongodb_explorer.lua" -and -not $setupMongo) {
            # skip
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
            # skip
        } elseif ($_.Name -eq "mongodb_bridge.py" -and -not $setupMongo) {
            # skip
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
$apiFallbackMarker = "-- [[ LazyLite API Fallback ]]"
$initContentNew = Get-Content -LiteralPath $initFile -Raw
if (-not $initContentNew.Contains($apiFallbackMarker)) {
    $apiFallbackCode = @"

$apiFallbackMarker
config.ai_sidebar = config.ai_sidebar or {}
config.ai_sidebar.active_tool = "cloud_api"
"@
    Add-Content -LiteralPath $initFile -Value $apiFallbackCode -Encoding utf8
    Write-Host "[+] Configured AI Sidebar to default to API Mode (cloud_api)." -ForegroundColor Green
}
Write-Host ""
Write-Host "==================================================================" -ForegroundColor Green
Write-Host "  Installation complete! Restart Lite-XL to enjoy LazyLite." -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "NEXT STEP: Run 'agy install' once in a terminal to configure the AI backend." -ForegroundColor Cyan
Write-Host ""
if (-not $Unattended) {
    Read-Host "Press Enter to exit"
}
