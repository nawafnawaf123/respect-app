# Read the last lines of mcp.log
$logPath = 'C:\Users\HCES\Desktop\Respect App\rp_stream_hub\testsprite_tests\tmp\mcp.log'
if (Test-Path $logPath) {
    Write-Host "=== Last 25 lines of mcp.log ==="
    Get-Content $logPath -Tail 25 | ForEach-Object {
        $line = $_
        if ($line.Length -gt 280) { $line = $line.Substring(0, 280) }
        Write-Host $line
    }
    Write-Host ""
    Write-Host "=== Searching for final status keywords ==="
    $content = Get-Content $logPath -Raw
    foreach ($kw in @('Test execution completed', 'All tests completed', 'Report saved', 'testStatus', 'PASSED', 'FAILED', 'BLOCKED', 'summary')) {
        $count = ([regex]::Matches($content, [regex]::Escape($kw))).Count
        if ($count -gt 0) {
            Write-Host "  '$kw' appears: $count times"
        }
    }
}

# Check for new results
$resultsPath = 'C:\Users\HCES\Desktop\Respect App\rp_stream_hub\testsprite_tests\tmp\test_results.json'
if (Test-Path $resultsPath) {
    $info = Get-Item $resultsPath
    Write-Host ""
    Write-Host "=== test_results.json ==="
    Write-Host "Last modified: $($info.LastWriteTime)"
    Write-Host "Size: $($info.Length) bytes"
    # Count test statuses
    $content = Get-Content $resultsPath -Raw
    $passCount = ([regex]::Matches($content, '"testStatus": "PASSED"')).Count
    $failCount = ([regex]::Matches($content, '"testStatus": "FAILED"')).Count
    $blockCount = ([regex]::Matches($content, '"testStatus": "BLOCKED"')).Count
    Write-Host "Test statuses: PASSED=$passCount, FAILED=$failCount, BLOCKED=$blockCount"
}
