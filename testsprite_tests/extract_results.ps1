# Extract all test statuses from test_results.json
$resultsPath = 'C:\Users\HCES\Desktop\Respect App\rp_stream_hub\testsprite_tests\tmp\test_results.json'
$content = Get-Content $resultsPath -Raw

# Use regex to extract title, status pairs
$pattern = '"title":\s*"([^"]+)",[\s\S]*?"testStatus":\s*"([^"]+)"'
$matches = [regex]::Matches($content, $pattern)

Write-Host "=== Test Results Summary ==="
Write-Host "Total tests: $($matches.Count)"
Write-Host ""

$statusGroups = @{}
foreach ($m in $matches) {
    $title = $m.Groups[1].Value
    $status = $m.Groups[2].Value
    Write-Host "[$status] $title"
    if (-not $statusGroups.ContainsKey($status)) {
        $statusGroups[$status] = 0
    }
    $statusGroups[$status]++
}

Write-Host ""
Write-Host "=== Status counts ==="
foreach ($k in $statusGroups.Keys) {
    Write-Host "  $k : $($statusGroups[$k])"
}
