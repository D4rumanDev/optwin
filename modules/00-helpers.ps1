function Write-Log {
    param([string]$msg, [string]$color = "White")
    if ($LogFile) {
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        try { Add-Content -Path $LogFile -Value "[$ts] $msg" -Encoding UTF8 -ErrorAction Stop } catch {}
    }
    Write-Host $msg -ForegroundColor $color
}
