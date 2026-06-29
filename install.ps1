$configDir = "$env:USERPROFILE\.config\lite-xl"
$srcDir = $PSScriptRoot

Write-Host "Installing Lite-XL Mossy Configuration..."

# Create dirs if they don't exist
New-Item -ItemType Directory -Force -Path "$configDir\plugins" | Out-Null
New-Item -ItemType Directory -Force -Path "$configDir\colors" | Out-Null
New-Item -ItemType Directory -Force -Path "$configDir\fonts" | Out-Null

# Copy files
Copy-Item -Path "$srcDir\plugins\*.lua" -Destination "$configDir\plugins\" -Force
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
