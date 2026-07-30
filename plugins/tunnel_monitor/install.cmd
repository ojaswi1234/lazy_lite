@echo off
cd /d "%~dp0"
where go >nul 2>nul
if %errorlevel% equ 0 (
    echo Go compiler found. Compiling proxy natively...
    go build -o proxy.exe proxy.go
) else (
    echo Go compiler not found. Falling back to pre-built proxy.exe (Windows only).
)
