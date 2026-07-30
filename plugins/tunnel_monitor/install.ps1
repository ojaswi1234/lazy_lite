$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $ScriptPath

if (Get-Command "go" -ErrorAction SilentlyContinue) {
    Write-Host "Go compiler found. Compiling proxy natively..."
    go build -o proxy.exe proxy.go
} else {
    Write-Host "Go compiler not found. Falling back to pre-built proxy.exe (Windows only)."
}
