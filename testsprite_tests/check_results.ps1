$lock = 'C:\Users\HCES\Desktop\Respect App\rp_stream_hub\testsprite_tests\tmp\execution.lock'
if (Test-Path $lock) {
    Remove-Item $lock -Force
    Write-Host "Removed stale execution.lock"
} else {
    Write-Host "No lock file to remove"
}

$results = 'C:\Users\HCES\Desktop\Respect App\rp_stream_hub\testsprite_tests\tmp\test_results.json'
if (Test-Path $results) {
    Write-Host "--- test_results.json preview ---"
    $content = Get-Content $results -Raw
    Write-Host $content.Substring(0, [Math]::Min(2500, $content.Length))
}
