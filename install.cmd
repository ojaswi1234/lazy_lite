@echo off
setlocal enabledelayedexpansion

:: ==============================================================================
:: LazyLite Configuration & Auto-Setup Installer (Windows Command Prompt / Batch)
:: Space-resilient, non-blocking, unattended-capable batch installer.
:: ==============================================================================

set "CONFIG_DIR=%USERPROFILE%\.config\lite-xl"
set "SRC_DIR=%~dp0"
set "UNATTENDED=0"

:: Check for unattended / quiet flags
for %%a in (%*) do (
    if /i "%%a"=="/y" set "UNATTENDED=1"
    if /i "%%a"=="-y" set "UNATTENDED=1"
    if /i "%%a"=="/yes" set "UNATTENDED=1"
    if /i "%%a"=="--yes" set "UNATTENDED=1"
    if /i "%%a"=="/q" set "UNATTENDED=1"
    if /i "%%a"=="-q" set "UNATTENDED=1"
    if /i "%%a"=="/silent" set "UNATTENDED=1"
    if /i "%%a"=="--silent" set "UNATTENDED=1"
    if /i "%%a"=="/unattended" set "UNATTENDED=1"
    if /i "%%a"=="--unattended" set "UNATTENDED=1"
)

if "%CI%"=="true" set "UNATTENDED=1"
if "%GITHUB_ACTIONS%"=="true" set "UNATTENDED=1"

echo ==========================================
echo    LazyLite Configuration Installer
echo ==========================================
echo [*] Welcome to the LazyLite Installer!
echo [+] Transforming your Lite-XL into a modern powerhouse...
if "%UNATTENDED%"=="1" echo [*] Running in unattended auto-setup mode.
echo ------------------------------------------------------------------
echo [!] Note: AI Sidebar and Auto-Healer default to API mode if Antigravity CLI (agy) is not installed.
echo ------------------------------------------------------------------
echo.

:: 1. Check Lite-XL
where lite-xl >nul 2>nul
if %errorlevel% neq 0 (
    if not exist "%ProgramFiles%\Lite XL\lite-xl.exe" (
        if not exist "%ProgramFiles(x86)%\Lite XL\lite-xl.exe" (
            set "install_lite=y"
            if "%UNATTENDED%"=="0" (
                set /p "install_lite=Lite-XL is not found. Download and install it automatically? (y/n) [default: y]: "
                if "!install_lite!"=="" set "install_lite=y"
            )
            if /i "!install_lite!"=="y" (
                echo Downloading Lite-XL setup...
                curl -L --connect-timeout 15 -o "%TEMP%\LiteXL-setup.exe" https://github.com/lite-xl/lite-xl/releases/download/v2.1.8/LiteXL-v2.1.8-addons-x86_64-setup.exe >nul 2>nul
                if not exist "%TEMP%\LiteXL-setup.exe" (
                    echo Curl failed. Trying PowerShell fallback...
                    powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-RestMethod -Uri 'https://github.com/lite-xl/lite-xl/releases/download/v2.1.8/LiteXL-v2.1.8-addons-x86_64-setup.exe' -OutFile '%TEMP%\LiteXL-setup.exe' -ErrorAction Stop" >nul 2>nul
                )
                if exist "%TEMP%\LiteXL-setup.exe" (
                    echo Running Lite-XL installer silently...
                    start /wait "" "%TEMP%\LiteXL-setup.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
                ) else (
                    echo WARNING: Download failed. Placing configuration in %CONFIG_DIR%.
                )
            )
        )
    )
)

:: 1.5. Check GitHub CLI (gh)
where gh >nul 2>nul
if %errorlevel% neq 0 (
    where winget >nul 2>nul
    if !errorlevel! equ 0 (
        echo GitHub CLI not found. Installing via winget...
        winget install --id GitHub.cli --accept-source-agreements --accept-package-agreements --silent >nul 2>nul
    )
)

:: 1.7. Download Nerd Font for icons
echo Downloading FiraCode Nerd Font...
if not exist "%CONFIG_DIR%\fonts" mkdir "%CONFIG_DIR%\fonts" >nul 2>nul
if not exist "%CONFIG_DIR%\fonts\FiraCodeNerdFont-Regular.ttf" (
    curl -L --connect-timeout 15 -o "%CONFIG_DIR%\fonts\FiraCodeNerdFont-Regular.ttf" "https://github.com/ryanoasis/nerd-fonts/raw/master/patched-fonts/FiraCode/Regular/FiraCodeNerdFont-Regular.ttf" >nul 2>nul
)

:: 1.8. Emoji font check and fallback download
if exist "%WINDIR%\Fonts\seguiemj.ttf" (
    echo [+] Segoe UI Emoji detected on system.
) else (
    if not exist "%CONFIG_DIR%\fonts\NotoColorEmoji.ttf" (
        echo Downloading NotoColorEmoji as fallback...
        curl -L --connect-timeout 15 -o "%CONFIG_DIR%\fonts\NotoColorEmoji.ttf" "https://github.com/googlefonts/noto-emoji/raw/main/fonts/NotoColorEmoji.ttf" >nul 2>nul
    )
)

:: 2. Check Antigravity CLI
set "AGY_INSTALLED=true"
where agy >nul 2>nul
if %errorlevel% neq 0 (
    set "install_agy=y"
    if "%UNATTENDED%"=="0" (
        set /p "install_agy=Antigravity CLI (agy) is not installed. Do you want to install it automatically? (y/n) [default: y]: "
        if "!install_agy!"=="" set "install_agy=y"
    )
    if /i "!install_agy!"=="y" (
        echo Installing Antigravity CLI...
        curl -fsSL --connect-timeout 15 https://antigravity.google/cli/install.cmd -o "%TEMP%\install_agy.cmd" 2>nul
        if not exist "%TEMP%\install_agy.cmd" (
            powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-RestMethod -Uri 'https://antigravity.google/cli/install.cmd' -OutFile '%TEMP%\install_agy.cmd' -ErrorAction SilentlyContinue" >nul 2>nul
        )
        if exist "%TEMP%\install_agy.cmd" (
            call "%TEMP%\install_agy.cmd"
            del "%TEMP%\install_agy.cmd" >nul 2>nul
        )
    ) else (
        set "AGY_INSTALLED=false"
    )
)

:: 3. Optional Features Setup
set "SETUP_LEETCODE=y"
if "%UNATTENDED%"=="0" (
    set /p "setup_lc=Do you want to setup LeetCode plugin & assessment suite? (y/n) [default: y]: "
    if /i "!setup_lc!"=="n" set "SETUP_LEETCODE=n"
)

set "SETUP_MONGO=y"
if "%UNATTENDED%"=="0" (
    set /p "setup_mg=Do you want to setup MongoDB Explorer plugin? (y/n) [default: y]: "
    if /i "!setup_mg!"=="n" set "SETUP_MONGO=n"
)

:: Check real Python 3 runtime
python -c "import sys; sys.exit(0 if sys.version_info[0]==3 else 1)" >nul 2>nul
if %errorlevel% equ 0 (
    if /i "!SETUP_LEETCODE!"=="y" (
        echo Installing Python dependencies for LeetCode API...
        python -m pip install requests --quiet >nul 2>nul
    )
    if /i "!SETUP_MONGO!"=="y" (
        python -m pip install pymongo --quiet >nul 2>nul
    )
    echo Installing Core AI Dependencies (LangGraph, MCP, Graphify, etc.)...
    python -m pip install pypdfium2 pypdf Pillow --quiet >nul 2>nul
    python -m pip install langchain-core langchain-google-genai langchain-groq langchain-openai langchain-anthropic langgraph mcp langchain-mcp-adapters graphifyy duckduckgo-search psutil --quiet >nul 2>nul
)

if /i "!SETUP_MONGO!"=="y" (
    where mongosh >nul 2>nul
    if !errorlevel! neq 0 (
        where winget >nul 2>nul
        if !errorlevel! equ 0 (
            echo Installing official MongoDB Shell via winget...
            winget install -e --id MongoDB.mongosh --accept-source-agreements --accept-package-agreements --silent >nul 2>nul
        )
        where mongosh >nul 2>nul
        if !errorlevel! neq 0 (
            if exist "%LOCALAPPDATA%\Programs\mongosh\mongosh.exe" (
                echo Found standalone mongosh in %LOCALAPPDATA%\Programs\mongosh.
            ) else (
                where npm >nul 2>nul
                if !errorlevel! equ 0 (
                    echo Installing MongoDB Shell (mongosh) via npm...
                    call npm install -g mongosh --silent >nul 2>nul
                )
            )
        )
    )
)

echo Installing Lite-XL Mossy Configuration...

if not exist "%CONFIG_DIR%\plugins" mkdir "%CONFIG_DIR%\plugins" >nul 2>nul
if not exist "%CONFIG_DIR%\colors"  mkdir "%CONFIG_DIR%\colors"  >nul 2>nul
if not exist "%CONFIG_DIR%\fonts"   mkdir "%CONFIG_DIR%\fonts"   >nul 2>nul
if not exist "%CONFIG_DIR%\scripts" mkdir "%CONFIG_DIR%\scripts" >nul 2>nul
if not exist "%CONFIG_DIR%\attachments" mkdir "%CONFIG_DIR%\attachments" >nul 2>nul
if not exist "%CONFIG_DIR%\libraries" mkdir "%CONFIG_DIR%\libraries" >nul 2>nul

:: Copy libraries
if exist "%SRC_DIR%libraries\" xcopy /y /e /q "%SRC_DIR%libraries\*" "%CONFIG_DIR%\libraries\" >nul 2>nul

:: Copy all plugin files (.lua, .json, .py, .exe)
for %%f in ("%SRC_DIR%plugins\*.lua" "%SRC_DIR%plugins\*.json" "%SRC_DIR%plugins\*.py" "%SRC_DIR%plugins\*.exe") do (
    if exist "%%f" (
        if "%%~nxf"=="leetcode.lua" (
            if /i "!SETUP_LEETCODE!"=="y" copy /y "%%f" "%CONFIG_DIR%\plugins\" >nul
        ) else if "%%~nxf"=="leetcode_assessment.lua" (
            if /i "!SETUP_LEETCODE!"=="y" copy /y "%%f" "%CONFIG_DIR%\plugins\" >nul
        ) else if "%%~nxf"=="mongodb_explorer.lua" (
            if /i "!SETUP_MONGO!"=="y" copy /y "%%f" "%CONFIG_DIR%\plugins\" >nul
        ) else (
            copy /y "%%f" "%CONFIG_DIR%\plugins\" >nul
        )
    )
)

:: Copy color schemes
copy /y "%SRC_DIR%colors\*.lua" "%CONFIG_DIR%\colors\" >nul 2>nul

:: Copy bundled fonts
copy /y "%SRC_DIR%fonts\*.ttf" "%CONFIG_DIR%\fonts\" >nul 2>nul

:: Copy scripts
if exist "%SRC_DIR%scripts" (
    xcopy /e /i /y /q "%SRC_DIR%scripts\*" "%CONFIG_DIR%\scripts\" >nul 2>nul
)

:: Copy sub-directories (third-party and custom plugins)
if exist "%SRC_DIR%plugins\lsp"          xcopy /e /i /y /q "%SRC_DIR%plugins\lsp"          "%CONFIG_DIR%\plugins\lsp\"          >nul 2>nul
if exist "%SRC_DIR%plugins\widget"       xcopy /e /i /y /q "%SRC_DIR%plugins\widget"       "%CONFIG_DIR%\plugins\widget\"       >nul 2>nul
if exist "%SRC_DIR%plugins\lintplus"     xcopy /e /i /y /q "%SRC_DIR%plugins\lintplus"     "%CONFIG_DIR%\plugins\lintplus\"     >nul 2>nul
if exist "%SRC_DIR%plugins\loader_games" xcopy /e /i /y /q "%SRC_DIR%plugins\loader_games" "%CONFIG_DIR%\plugins\loader_games\" >nul 2>nul
if exist "%SRC_DIR%plugins\toggle_terminal" xcopy /e /i /y /q "%SRC_DIR%plugins\toggle_terminal" "%CONFIG_DIR%\plugins\toggle_terminal\" >nul 2>nul
if exist "%SRC_DIR%plugins\tunnel_monitor" xcopy /e /i /y /q "%SRC_DIR%plugins\tunnel_monitor" "%CONFIG_DIR%\plugins\tunnel_monitor\" >nul 2>nul
if exist "%SRC_DIR%plugins\python_runtime" xcopy /e /i /y /q "%SRC_DIR%plugins\python_runtime" "%CONFIG_DIR%\plugins\python_runtime\" >nul 2>nul
echo [+] Copied plugins, scripts, fonts, and color schemes.

:: Install WSL Wrapper if WSL is present
wsl.exe -l >nul 2>nul
if %ERRORLEVEL% equ 0 (
    if exist "%SRC_DIR%lite-xl-wsl\lite-xl-wsl-wrapper" (
        echo Installing WSL interop wrapper...
        type "%SRC_DIR%lite-xl-wsl\lite-xl-wsl-wrapper" | wsl -u root bash -c "cat > /usr/local/bin/lite-xl && chmod +x /usr/local/bin/lite-xl"
        if !ERRORLEVEL! equ 0 (
            echo [+] WSL wrapper for lite-xl installed successfully.
        ) else (
            echo [-] Could not automatically install WSL wrapper.
        )
    )
)

:: Copy Antigravity custom skills
set "GEMINI_CONFIG_DIR=%USERPROFILE%\.gemini\config"
if exist "%SRC_DIR%skills" (
    if not exist "%GEMINI_CONFIG_DIR%\skills" mkdir "%GEMINI_CONFIG_DIR%\skills" >nul 2>nul
    xcopy /e /i /y /q "%SRC_DIR%skills" "%GEMINI_CONFIG_DIR%\skills\" >nul 2>nul
    echo [+] Copied custom Antigravity skills.
)

:: Update init.lua safely
set "INIT_FILE=%CONFIG_DIR%\init.lua"
set "MARKER=-- [[ LazyLite Configuration ]]"

if not exist "%INIT_FILE%" (
    if exist "%SRC_DIR%init.lua" (
        copy /y "%SRC_DIR%init.lua" "%INIT_FILE%" >nul
    ) else (
        type "%SRC_DIR%init_append.lua" > "%INIT_FILE%"
    )
    echo [+] Initialized init.lua with LazyLite configuration.
) else (
    findstr /c:"%MARKER%" "%INIT_FILE%" >nul 2>nul
    if !errorlevel! neq 0 (
        echo. >> "%INIT_FILE%"
        type "%SRC_DIR%init_append.lua" >> "%INIT_FILE%"
        echo [+] Appended LazyLite configuration to init.lua.
    ) else (
        echo [+] LazyLite configuration already present in init.lua.
    )
)

set "API_FALLBACK_MARKER=-- [[ LazyLite API Fallback ]]"
findstr /c:"!API_FALLBACK_MARKER!" "%INIT_FILE%" >nul 2>nul
if !errorlevel! neq 0 (
    echo. >> "%INIT_FILE%"
    echo !API_FALLBACK_MARKER! >> "%INIT_FILE%"
    echo config.ai_sidebar = config.ai_sidebar or {} >> "%INIT_FILE%"
    echo config.ai_sidebar.active_tool = "cloud_api" >> "%INIT_FILE%"
    echo [+] Configured AI Sidebar to default to API Mode (cloud_api).
)

echo.
echo ==================================================================
echo   Installation complete! Restart Lite-XL to enjoy LazyLite.
echo ==================================================================
echo.
echo Tip: Run 'agy install' once in a terminal to configure the AI backend.
echo.
if "%UNATTENDED%"=="0" pause
