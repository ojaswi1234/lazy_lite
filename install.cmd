@echo off
setlocal enabledelayedexpansion

set "CONFIG_DIR=%USERPROFILE%\.config\lite-xl"
set "SRC_DIR=%~dp0"

echo Lite-XL Mossy Configuration Installer
echo ---------------------------------------

:: 1. Check Lite-XL
where lite-xl >nul 2>nul
if %errorlevel% neq 0 (
    set /p "install_lite=Lite-XL is not installed. Do you want to install it automatically using winget? (y/n): "
    if /i "!install_lite!"=="y" (
        echo Installing Lite-XL...
        winget install -e --id lite-xl.lite-xl
    ) else (
        echo Lite-XL installation skipped. Cannot proceed without Lite-XL. Exiting.
        exit /b 1
    )
)

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
if not exist "%CONFIG_DIR%\colors" mkdir "%CONFIG_DIR%\colors"
if not exist "%CONFIG_DIR%\fonts" mkdir "%CONFIG_DIR%\fonts"

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

copy /y "%SRC_DIR%colors\*.lua" "%CONFIG_DIR%\colors\" >nul 2>nul
copy /y "%SRC_DIR%fonts\*.ttf" "%CONFIG_DIR%\fonts\" >nul 2>nul
echo Copied plugins, fonts, and color scheme.

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

echo Installation complete! Open Lite-XL to see the new Mossy Configuration.
pause
