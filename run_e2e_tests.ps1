param(
    [string]$LiteXlPath = ""
)

$ErrorActionPreference = "Stop"

# 1. Locate lite-xl.exe if not provided
if (-not $LiteXlPath) {
    # Check common locations
    $paths = @(
        "C:\Program Files\Lite XL\lite-xl.exe",
        "C:\Program Files (x86)\Lite XL\lite-xl.exe",
        "$env:LOCALAPPDATA\Programs\Lite XL\lite-xl.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) {
            $LiteXlPath = $p
            break
        }
    }
    
    if (-not $LiteXlPath) {
        # Check system PATH
        $whereResult = where.exe lite-xl 2>$null
        if ($whereResult) {
            $LiteXlPath = $whereResult[0]
        }
    }
}

if (-not $LiteXlPath -or -not (Test-Path $LiteXlPath)) {
    Write-Error "Could not locate lite-xl.exe. Please provide the path via -LiteXlPath."
    exit 1
}

Write-Host "Using Lite-XL executable: $LiteXlPath"

# 2. Clear previous test results
$resultPath = "C:\Users\ojasw\Documents\LiteXL-Mossy-Setup\e2e_test_results.json"
$errorsLog = "C:\Users\ojasw\Documents\LiteXL-Mossy-Setup\init_errors.log"
$debugLog = "C:\Users\ojasw\Documents\LiteXL-Mossy-Setup\e2e_debug_run.log"
if (Test-Path $resultPath) {
    Write-Host "Removing old test results..."
    Remove-Item $resultPath -Force
}
if (Test-Path $errorsLog) {
    Remove-Item $errorsLog -Force
}
if (Test-Path $debugLog) {
    Remove-Item $debugLog -Force
}

# 3. Launch Lite-XL with e2e userdir and redirect outputs
$userdir = "C:\Users\ojasw\Documents\LiteXL-Mossy-Setup\e2e_test_env"
$stdoutLog = "C:\Users\ojasw\Documents\LiteXL-Mossy-Setup\lite_xl_stdout.log"
$stderrLog = "C:\Users\ojasw\Documents\LiteXL-Mossy-Setup\lite_xl_stderr.log"
if (Test-Path $stdoutLog) { Remove-Item $stdoutLog -Force }
if (Test-Path $stderrLog) { Remove-Item $stderrLog -Force }

Write-Host "Running tests in Lite-XL..."
$process = Start-Process -FilePath $LiteXlPath -ArgumentList "--userdir `"$userdir`"" -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -NoNewWindow -PassThru

# 4. Wait for exit with a timeout
$timeoutSec = 75
$elapsedSec = 0
while (-not $process.HasExited) {
    Start-Sleep -Seconds 1
    $elapsedSec++
    if ($elapsedSec -ge $timeoutSec) {
        Write-Warning "Lite-XL did not exit within $timeoutSec seconds. Force-terminating process..."
        Stop-Process -Id $process.Id -Force
        break
    }
}

# 5. Read and parse results
if (-not (Test-Path $resultPath)) {
    Write-Host "`n--- Lite-XL Standard Output ---"
    if (Test-Path $stdoutLog) { Get-Content $stdoutLog }
    Write-Host "`n--- Lite-XL Standard Error ---"
    if (Test-Path $stderrLog) { Get-Content $stderrLog }
    Write-Host "`n--- Lite-XL Init Errors ---"
    if (Test-Path $errorsLog) { Get-Content $errorsLog }
    Write-Host "`n--- Lite-XL E2E Debug Run Log ---"
    if (Test-Path $debugLog) { Get-Content $debugLog }
    Write-Error "Test result file not found at $resultPath. The test suite did not complete or write output."
    exit 1
}

$resultsContent = Get-Content -Raw -Path $resultPath
try {
    $results = ConvertFrom-Json $resultsContent
} catch {
    Write-Error "Failed to parse JSON result file: $_"
    exit 1
}

Write-Host "`n========================================"
Write-Host "             E2E Test Summary"
Write-Host "========================================"
Write-Host "Total:  $($results.summary.total)"
Write-Host "Passed: $($results.summary.passed)"
Write-Host "Failed: $($results.summary.failed)"
Write-Host "========================================"

if ($results.summary.failed -gt 0) {
    Write-Host "`nFailed Tests Detail:" -ForegroundColor Red
    foreach ($test in $results.tests) {
        if ($test.status -ne "passed") {
            Write-Host "  - $($test.name): $($test.error)" -ForegroundColor Red
        }
    }
    exit 1
} else {
    Write-Host "`nAll tests passed successfully!" -ForegroundColor Green
    exit 0
}
