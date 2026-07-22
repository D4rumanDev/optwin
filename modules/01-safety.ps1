# ============================================================
Sep "01.1 SAFETY — Punto de restauracion del sistema"
# ============================================================

$restoreStamp = "$LogsDir\restore-point.stamp"
$restoreAge   = if (Test-Path $restoreStamp) { ((Get-Date) - (Get-Item $restoreStamp).LastWriteTime).TotalDays } else { 999 }

if ($restoreAge -lt 30) {
    Skip "Punto de restauracion: creado hace $([math]::Round($restoreAge)) dias — omitiendo (umbral: 30 dias)"
} else {
    try {
        Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore" `
            "SystemRestorePointCreationFrequency" 0 -Type DWord -Force
        Checkpoint-Computer -Description "Pre-Optimizacion $(Get-Date -Format 'yyyy-MM-dd')" `
            -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        (Get-Date).ToString('o') | Set-Content $restoreStamp -Encoding UTF8
        OK "Punto de restauracion creado"
    } catch {
        Err "Punto de restauracion — $_"
    }
}

# ============================================================
Sep "01.2 INTEGRIDAD — DISM + SFC"
# ============================================================

# Ejecutar en background — puede tardar 10-30 min en sistemas con imagen dañada
# Solo se ejecuta si no se ha realizado en los ultimos 30 dias (stamp file)
$dismSfcStamp = "$LogsDir\dism-sfc.stamp"
$dismSfcAge   = if (Test-Path $dismSfcStamp) { ((Get-Date) - (Get-Item $dismSfcStamp).LastWriteTime).TotalDays } else { 999 }
if ($dismSfcAge -lt 30) {
    Skip "DISM+SFC: ejecutado hace $([math]::Round($dismSfcAge)) dias — omitiendo (umbral: 30 dias)"
} else {
    $dismRepairJob = Start-Job -Name "DISM+SFC Repair" -ScriptBlock {
        param($logPath, $stamp)
        function BgLog($msg) { "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg" | Add-Content $logPath -Encoding UTF8 }
        BgLog "[    ] DISM ScanHealth iniciado..."
        Dism.exe /Online /Cleanup-Image /ScanHealth 2>&1 | Out-Null
        BgLog "[    ] DISM CheckHealth..."
        Dism.exe /Online /Cleanup-Image /CheckHealth 2>&1 | Out-Null
        BgLog "[    ] DISM RestoreHealth (puede tardar varios minutos)..."
        Dism.exe /Online /Cleanup-Image /RestoreHealth 2>&1 | Out-Null
        BgLog "[    ] SFC /scannow..."
        sfc /scannow 2>&1 | Out-Null
        BgLog "[OK]   DISM + SFC completados"
        (Get-Date).ToString('o') | Set-Content $stamp -Encoding UTF8
        return "DISM ScanHealth + RestoreHealth + SFC completados"
    } -ArgumentList $LogFile, $dismSfcStamp
    $script:bgJobs += $dismRepairJob
    OK "DISM + SFC iniciados en background (Job: $($dismRepairJob.Id))"
}

# ============================================================
Sep "01.3 PREREQUISITOS — PowerShell 7"
# ============================================================

function Test-PwshInstalled {
    if (Get-Command pwsh -ErrorAction SilentlyContinue) { return $true }
    $commonPaths = @(
        "$env:ProgramFiles\PowerShell\7\pwsh.exe",
        "$env:ProgramFiles\PowerShell\pwsh.exe"
    )
    return ($commonPaths | Where-Object { Test-Path $_ }).Count -gt 0
}

if (Test-PwshInstalled) {
    $pwshVer = (& pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null)
    OK "PowerShell 7 presente: v$pwshVer"
} else {
    Write-Log "PowerShell 7 no detectado — instalando via winget..." "Yellow"
    try {
        winget install Microsoft.PowerShell --silent --accept-source-agreements --accept-package-agreements | Out-Null
        if (Test-PwshInstalled) {
            OK "PowerShell 7 instalado correctamente"
        } else {
            Err "PowerShell 7: instalacion completada pero pwsh.exe no encontrado — puede requerir reinicio"
        }
    } catch {
        Err "PowerShell 7 instalacion — $_"
    }
}
