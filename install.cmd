@echo off
setlocal enabledelayedexpansion

set "CONFIG_DIR=%USERPROFILE%\.config\lite-xl"
set "SRC_DIR=%~dp0"

echo Lite-XL Mossy Configuration Installer
echo ---------------------------------------
echo DISCLAIMER: For the Auto-Healer setup to work, the Antigravity CLI (agy) is required.
echo.

:: 1. Check Lite-XL
where lite-xl >nul 2>nul
if %errorlevel% neq 0 (
    set /p "install_lite=Lite-XL is not installed. Do you want to install it automatically? (y/n): "
    if /i "!install_lite!"=="y" (
        echo Installing Lite-XL...
        curl -L -o LiteXL-setup.exe https://github.com/lite-xl/lite-xl/releases/download/v2.1.8/LiteXL-v2.1.8-addons-x86_64-setup.exe
        LiteXL-setup.exe
    ) else (
        echo Lite-XL installation skipped. Cannot proceed without Lite-XL. Exiting.
        exit /b 1
    )
)

:: 1.5. Check GitHub CLI (gh)
where gh >nul 2>nul
if %errorlevel% neq 0 (
    echo GitHub CLI not found. Installing via winget...
    winget install --id GitHub.cli --accept-source-agreements --accept-package-agreements
)

:: 1.6. Check Python + pywinpty (required for AI sidebar PTY bridge on Windows)
where python >nul 2>nul
if %errorlevel% equ 0 (
    python -c "import winpty" >nul 2>nul
    if !errorlevel! neq 0 (
        echo Installing pywinpty (required for AI sidebar streaming^)...
        python -m pip install pywinpty --quiet
    )
) else (
    echo WARNING: Python not found. The AI sidebar PTY bridge requires Python + pywinpty.
    echo          Install Python from https://python.org and then run: pip install pywinpty
)

:: 1.7. Download Nerd Font for icons
echo Downloading FiraCode Nerd Font...
if not exist "%CONFIG_DIR%\fonts" mkdir "%CONFIG_DIR%\fonts"
curl -L -o "%CONFIG_DIR%\fonts\FiraCodeNerdFont-Regular.ttf" "https://github.com/ryanoasis/nerd-fonts/raw/master/patched-fonts/FiraCode/Regular/FiraCodeNerdFont-Regular.ttf"

:: 2. Check Antigravity CLI
set "INSTALL_AGY_SIDEBAR=true"
where agy >nul 2>nul
if %errorlevel% neq 0 (
    set /p "install_agy=Antigravity CLI (agy) is not installed. Do you want to install it automatically using the official installer? (y/n): "
    if /i "!install_agy!"=="y" (
        echo Installing Antigravity CLI...
        curl -fsSL https://antigravity.google/cli/install.cmd -o install_agy.cmd && install_agy.cmd && del install_agy.cmd
    ) else (
        echo.
        echo Note: You have chosen not to install the Antigravity CLI. The AI sidebar will not be added to your Lite-XL setup,
        echo but other customizations ^(colors, fonts, tweaks^) will still be installed.
        echo If you change your mind, you can run this script again later to add it.
        echo.
        set "INSTALL_AGY_SIDEBAR=false"
    )
)

echo Installing Lite-XL Mossy Configuration...

if not exist "%CONFIG_DIR%\plugins" mkdir "%CONFIG_DIR%\plugins"
if not exist "%CONFIG_DIR%\colors"  mkdir "%CONFIG_DIR%\colors"
if not exist "%CONFIG_DIR%\fonts"   mkdir "%CONFIG_DIR%\fonts"
if not exist "%CONFIG_DIR%\scripts" mkdir "%CONFIG_DIR%\scripts"

:: Copy all .lua plugin files (skip AI sidebar if agy not installed)
for %%f in ("%SRC_DIR%plugins\*.lua") do (
    if "%%~nxf"=="antigravity_sidebar.lua" (
        if "!INSTALL_AGY_SIDEBAR!"=="true" (
            copy /y "%%f" "%CONFIG_DIR%\plugins\" >nul
        ) else (
            echo Skipping antigravity_sidebar.lua...
        )
    ) else (
        copy /y "%%f" "%CONFIG_DIR%\plugins\" >nul
    )
)

:: Copy Python PTY bridge (required for AI sidebar streaming on Windows)
if "!INSTALL_AGY_SIDEBAR!"=="true" (
    if exist "%SRC_DIR%plugins\agy_pty_bridge.py" (
        copy /y "%SRC_DIR%plugins\agy_pty_bridge.py" "%CONFIG_DIR%\plugins\" >nul
    )
)

:: Copy color schemes
copy /y "%SRC_DIR%colors\*.lua" "%CONFIG_DIR%\colors\" >nul 2>nul

:: Copy bundled fonts (if any are in the repo)
copy /y "%SRC_DIR%fonts\*.ttf" "%CONFIG_DIR%\fonts\" >nul 2>nul

:: Copy scripts (remote LSP proxy for Codespaces)
if exist "%SRC_DIR%scripts" (
    xcopy /y "%SRC_DIR%scripts\*" "%CONFIG_DIR%\scripts\" >nul
)

:: Copy sub-directories (third-party and custom plugins)
if exist "%SRC_DIR%plugins\lsp"          xcopy /e /i /y "%SRC_DIR%plugins\lsp"          "%CONFIG_DIR%\plugins\lsp"          >nul
if exist "%SRC_DIR%plugins\widget"       xcopy /e /i /y "%SRC_DIR%plugins\widget"       "%CONFIG_DIR%\plugins\widget"       >nul
if exist "%SRC_DIR%plugins\lintplus"     xcopy /e /i /y "%SRC_DIR%plugins\lintplus"     "%CONFIG_DIR%\plugins\lintplus"     >nul
if exist "%SRC_DIR%plugins\loader_games" xcopy /e /i /y "%SRC_DIR%plugins\loader_games" "%CONFIG_DIR%\plugins\loader_games" >nul
echo Copied plugins, scripts, fonts, and color scheme.

:: Update init.lua safely (append LazyLite block if not already present)
set "INIT_FILE=%CONFIG_DIR%\init.lua"
set "MARKER=-- [[ LazyLite Configuration ]]"

if not exist "%INIT_FILE%" (
    type "%SRC_DIR%init_append.lua" >> "%INIT_FILE%"
    echo Appended LazyLite configuration to init.lua
) else (
    findstr /c:"%MARKER%" "%INIT_FILE%" >nul 2>nul
    if !errorlevel! neq 0 (
        echo. >> "%INIT_FILE%"
        type "%SRC_DIR%init_append.lua" >> "%INIT_FILE%"
        echo Appended LazyLite configuration to init.lua
    ) else (
        echo Configuration already present in init.lua
    )
)

echo.
echo Installation complete! Open Lite-XL to see the new Mossy Configuration.
echo.
echo NEXT STEP: Run "agy install" once in a terminal to configure the AI backend.
pause
