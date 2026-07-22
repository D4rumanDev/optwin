# ============================================================
Sep "09.1 LIMPIEZA DE ARCHIVOS TEMPORALES"
# ============================================================

$cleanupData = Read-DataJson "$PSScriptRoot\..\data\cleanup.json"

$script:freedBytes = 0

function Remove-TempFolder {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path $Path)) { Skip "No existe: $Label"; return }
    try {
        $size = (Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue |
                 Measure-Object -Property Length -Sum).Sum
        Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue |
            Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        $script:freedBytes += $size
        $mb = [math]::Round($size / 1MB, 1)
        OK "Limpiado: $Label ($mb MB liberados)"
    } catch {
        Err "Error limpiando $Label — $_"
    }
}

# Detección temprana de BleachBit para condicionar la limpieza manual
$bleachbitExeEarly = @(
    "$env:LOCALAPPDATA\BleachBit\bleachbit_console.exe",
    "C:\Program Files\BleachBit\bleachbit_console.exe",
    "C:\Program Files (x86)\BleachBit\bleachbit_console.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

# A1: verificar firma Authenticode antes de ejecutar como elevado.
# Previene que un ejecutable sustituto en LOCALAPPDATA corra con privilegios de admin/SYSTEM.
if ($bleachbitExeEarly) {
    $bbSig = Get-AuthenticodeSignature $bleachbitExeEarly -ErrorAction SilentlyContinue
    if ($bbSig.Status -ne 'Valid') {
        Write-Log "  [WARN] BleachBit: firma no válida en $bleachbitExeEarly — se usará limpieza manual" "Yellow"
        $bleachbitExeEarly = $null
    }
}

if (-not $bleachbitExeEarly) {
    # Fallback manual cuando BleachBit no está instalado
    $cleanupData.temp_paths | ForEach-Object {
        $expanded = [Environment]::ExpandEnvironmentVariables($_.path)
        Remove-TempFolder $expanded "$($_.label) ($env:USERNAME)"
    }

    # Miniaturas (thumbcache_*.db)
    $thumbDir = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
    if (Test-Path $thumbDir) {
        $thumbFiles = Get-ChildItem $thumbDir -Filter "thumbcache_*.db" -Force -ErrorAction SilentlyContinue
        $thumbSize  = ($thumbFiles | Measure-Object -Property Length -Sum).Sum
        $thumbFiles | Remove-Item -Force -ErrorAction SilentlyContinue
        $script:freedBytes += $thumbSize
        OK "Limpiado: Thumbnail cache ($([math]::Round($thumbSize/1MB,1)) MB)"
    }
} else {
    Skip "Temp usuario/sistema + INetCache + Thumbnail: delegados a BleachBit (09.2)"
}

# Prefetch conservado: en SSD sigue acelerando el arranque de apps (~10-15%)
# Limpiar semanalmente reinicia el aprendizaje y degrada el rendimiento de arranque

# SoftwareDistribution siempre manual — BleachBit no puede detener/reiniciar el servicio WU
Remove-TempFolder "C:\Windows\SoftwareDistribution\Download" "Windows Update cache"

# Logs de Windows antiguos (> 30 dias) — proceso independiente (Get-ChildItem -Recurse puede ser lento)
$logsJob = Start-Job -Name "LogsCleanup" -ScriptBlock {
    param($logPath)
    $cutoff  = (Get-Date).AddDays(-30)
    $oldLogs = Get-ChildItem "C:\Windows\Logs" -Recurse -Force -ErrorAction SilentlyContinue |
               Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $cutoff }
    $size  = ($oldLogs | Measure-Object -Property Length -Sum).Sum
    $count = ($oldLogs | Measure-Object).Count
    $oldLogs | Remove-Item -Force -ErrorAction SilentlyContinue
    $mb = [math]::Round($size / 1MB, 1)
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [OK]   Logs Windows >30 dias: $count archivos, $mb MB liberados" |
        Add-Content -Path $logPath -Encoding UTF8
    return "$count archivos, $mb MB"
} -ArgumentList $LogFile
$script:bgJobs += $logsJob
OK "Limpieza de logs Windows >30 dias iniciada en background (Job: $($logsJob.Id))"

# Ejecutar Liberador de espacio en disco en background (puede tardar varios minutos)
try {
    $regClean = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"
    $categories = $cleanupData.cleanmgr_categories
    foreach ($cat in $categories) {
        $catPath = "$regClean\$cat"
        if (Test-Path $catPath) {
            Set-ItemProperty -Path $catPath -Name "StateFlags0064" -Value 2 -Type DWord -Force
        }
    }
    Start-Process cleanmgr.exe -ArgumentList "/sagerun:64" -WindowStyle Hidden
    OK "Liberador de espacio en disco lanzado en background (sin ventana)"
} catch {
    Err "cleanmgr fallido — $_"
}

# WinSxS: limpiar componentes obsoletos — proceso independiente (puede tardar 10-30 min)
# Solo se ejecuta si no se ha realizado en los ultimos 30 dias (stamp file)
$dismWinSxsStamp = "$LogsDir\dism-winsxs.stamp"
$dismWinSxsAge   = if (Test-Path $dismWinSxsStamp) { ((Get-Date) - (Get-Item $dismWinSxsStamp).LastWriteTime).TotalDays } else { 999 }
if ($dismWinSxsAge -lt 30) {
    Skip "DISM WinSxS: ejecutado hace $([math]::Round($dismWinSxsAge)) dias — omitiendo (umbral: 30 dias)"
} else {
    $dismJob = Start-Job -Name "DismWinSxS" -ScriptBlock {
        param($stampFile, $logFile)
        dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1 | Out-Null
        [System.IO.File]::WriteAllText($stampFile, (Get-Date).ToString('o'))
        "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [OK]   WinSxS limpiado (DISM StartComponentCleanup /ResetBase)" |
            Add-Content -Path $logFile -Encoding UTF8
        return "WinSxS limpiado correctamente"
    } -ArgumentList $dismWinSxsStamp, $LogFile
    $script:bgJobs += $dismJob
    OK "DISM WinSxS cleanup iniciado en background (Job: $($dismJob.Id)) — puede tardar 10-30 min"
}

# Windows.old — gestionado por cleanmgr "Previous Installations" (job en background)
if (Test-Path "C:\Windows.old") {
    $oldSize = (Get-ChildItem "C:\Windows.old" -Recurse -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
    $script:freedBytes += $oldSize
    OK "Windows.old detectado ($([math]::Round($oldSize/1GB,1)) GB) — eliminacion delegada a cleanmgr (job en background)"
} else {
    Skip "Windows.old no existe"
}

$totalFreedMB = [math]::Round($script:freedBytes / 1MB, 1)
$totalFreedGB = [math]::Round($script:freedBytes / 1GB, 2)
Write-Log "   Espacio total liberado: $totalFreedMB MB ($totalFreedGB GB)" "Yellow"

# ============================================================
Sep "09.2 BLEACHBIT — Limpieza complementaria"
# ============================================================

$bleachbitExe = $bleachbitExeEarly  # ya resuelto y validado con Authenticode en 09.1

if (-not $bleachbitExe) {
    Skip "BleachBit: no instalado — omitiendo"
} else {
    $bbCleaners = $cleanupData.bleachbit
    try {
        $bbOut = & $bleachbitExe --clean @bbCleaners 2>&1 | Out-String
        $bbLines = ($bbOut -split "`n" | Where-Object { $_ -match '\S' }).Count
        OK "BleachBit: limpieza completada — $($bbCleaners.Count) cleaners, $bbLines líneas de salida"
    } catch {
        Err "BleachBit: $_"
    }
}
