$p = Get-Process -Id 14276 -ErrorAction SilentlyContinue
if ($p) {
    Write-Host "Process 14276 is RUNNING: $($p.ProcessName), started $($p.StartTime)"
} else {
    Write-Host "Process 14276 is NOT running (stale lock)"
}

$log = Get-Content 'C:\Users\HCES\Desktop\Respect App\rp_stream_hub\testsprite_tests\tmp\mcp.log' -Tail 3
Write-Host "--- Last 3 log lines ---"
foreach ($line in $log) {
    Write-Host $line.Substring(0, [Math]::Min(280, $line.Length))
}
