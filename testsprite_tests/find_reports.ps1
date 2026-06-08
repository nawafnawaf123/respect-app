# Find any report or result files
$root = 'C:\Users\HCES\Desktop\Respect App\rp_stream_hub\testsprite_tests'
$recent = Get-Date
Write-Host "=== All files in testsprite_tests ==="
Get-ChildItem $root -File -ErrorAction SilentlyContinue | Select-Object FullName,Length,LastWriteTime | Format-Table -AutoSize

Write-Host ""
Write-Host "=== Files modified in the last 90 minutes ==="
Get-ChildItem $root -File -Recurse -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-90) } |
  Select-Object FullName,Length,LastWriteTime | Format-Table -AutoSize

Write-Host ""
Write-Host "=== Files containing 'raw_report' or 'testsprite-mcp' ==="
Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -like '*report*' -or $_.Name -like '*testsprite-mcp*' -or $_.Name -like '*.md' } |
  Select-Object FullName,Length,LastWriteTime | Format-Table -AutoSize

Write-Host ""
Write-Host "=== Search mcp.log for test results section ==="
$log = Get-Content 'C:\Users\HCES\Desktop\Respect App\rp_stream_hub\testsprite_tests\tmp\mcp.log' -Raw
foreach ($pat in @('"testStatus":', 'Report', 'saved', 'result.json', 'TC001', 'complete')) {
    $count = ([regex]::Matches($log, [regex]::Escape($pat))).Count
    if ($count -gt 0) {
        Write-Host "  '$pat' appears: $count times"
    }
}
