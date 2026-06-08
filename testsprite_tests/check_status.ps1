# Check the status of test execution
$lock = 'C:\Users\HCES\Desktop\Respect App\rp_stream_hub\testsprite_tests\tmp\execution.lock'
$rawReport = 'C:\Users\HCES\Desktop\Respect App\rp_stream_hub\testsprite_tests\tmp\raw_report.md'
$results = 'C:\Users\HCES\Desktop\Respect App\rp_stream_hub\testsprite_tests\tmp\test_results.json'
$log = 'C:\Users\HCES\Desktop\Respect App\rp_stream_hub\testsprite_run2.log'
$port = 5173
$portListening = $false
try {
    $conn = New-Object System.Net.Sockets.TcpClient
    $conn.Connect('127.0.0.1', $port)
    $portListening = $true
    $conn.Close()
} catch {}

Write-Host "=== Test Status ==="
Write-Host "Port $port listening: $portListening"
Write-Host "Lock file exists: $(Test-Path $lock)"
Write-Host "raw_report.md exists: $(Test-Path $rawReport)"
Write-Host "test_results.json exists: $(Test-Path $results)"
if (Test-Path $log) {
    $info = Get-Item $log
    Write-Host "Run log size: $($info.Length) bytes, last write: $($info.LastWriteTime)"
}
if (Test-Path $rawReport) {
    $info = Get-Item $rawReport
    Write-Host "raw_report.md size: $($info.Length) bytes, last write: $($info.LastWriteTime)"
}
if (Test-Path $results) {
    $info = Get-Item $results
    Write-Host "test_results.json size: $($info.Length) bytes, last write: $($info.LastWriteTime)"
}
