try {
    $r = Invoke-WebRequest -Uri 'http://localhost:5173/' -UseBasicParsing -TimeoutSec 8
    Write-Host "STATUS:" $r.StatusCode
    Write-Host "BODY_LENGTH:" $r.Content.Length
    Write-Host "BODY_PREVIEW:"
    Write-Host $r.Content.Substring(0, [Math]::Min(500, $r.Content.Length))
} catch {
    Write-Host "ERROR:" $_.Exception.Message
}
