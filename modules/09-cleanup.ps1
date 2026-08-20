# ============================================================
Sep "09.1 LIMPIEZA DE ARCHIVOS TEMPORALES"
# ============================================================

$cleanupData = Read-DataJson "$PSScriptRoot\..\data\cleanup.json"

$script:freedBytes = 0

function Remove-TempFolder {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path $Path)) { Skip "No existe: $Label"; return }
    try {
        $items = Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue
        $size  = ($items | Measure-Object -Property Length -Sum).Sum
        $items | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
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
    "$env:ProgramFiles\BleachBit\bleachbit_console.exe",
    "${env:ProgramFiles(x86)}\BleachBit\bleachbit_console.exe"
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
Remove-TempFolder "$env:SystemRoot\SoftwareDistribution\Download" "Windows Update cache"

# Logs de Windows antiguos (> 30 dias) — proceso independiente (Get-ChildItem -Recurse puede ser lento)
$logsJob = Start-Job -Name "LogsCleanup" -ScriptBlock {
    param($logPath)
    $cutoff  = (Get-Date).AddDays(-30)
    $oldLogs = Get-ChildItem "$env:SystemRoot\Logs" -Recurse -Force -ErrorAction SilentlyContinue |
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
if (Test-Path "$env:SystemDrive\Windows.old") {
    $oldSize = (Get-ChildItem "$env:SystemDrive\Windows.old" -Recurse -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
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

# ============================================================
Sep "09.3 DISPOSITIVOS USB Y BLUETOOTH FANTASMA"
# ============================================================
# Elimina entradas de dispositivos USB y Bluetooth LE que Windows tiene
# registrados pero que ya no están conectados (status Unknown).
# Se reinstalan solos al volver a enchufarse/emparejarse.
# USB: evita errores de "Se sobrepasó la capacidad del puerto USB".
# BT LE: evita que emparejamientos duplicados bloqueen la reconexión.

function Remove-GhostDevices {
    param([string]$Label, $Devices)
    if (-not $Devices) { Skip "$Label fantasma: ninguno encontrado"; return }
    $removed = 0
    $failed  = 0
    foreach ($dev in $Devices) {
        $result = & pnputil /remove-device $dev.InstanceId 2>&1
        if ($LASTEXITCODE -eq 0) {
            $removed++
            Write-Log "  Eliminado: $($dev.FriendlyName) [$($dev.InstanceId)]" "DarkGray"
        } else {
            $failed++
            Write-Log "  No eliminado: $($dev.FriendlyName) — $result" "Yellow"
        }
    }
    if ($removed -gt 0) { OK "$Label fantasma eliminados: $removed" }
    if ($failed  -gt 0) { Err "$Label fantasma no eliminados: $failed" }
}

$usbGhosts = Get-PnpDevice -Class USB -ErrorAction SilentlyContinue |
             Where-Object { $_.Status -eq 'Unknown' }
Remove-GhostDevices "Dispositivos USB" $usbGhosts

# BT LE: clases BTHLEDevice y BTHLE — solo los nodos raíz (BTHLE\DEV_*)
# para no eliminar servicios hijos de dispositivos activos
$bthleGhosts = Get-PnpDevice -ErrorAction SilentlyContinue |
               Where-Object { $_.Status -eq 'Unknown' -and $_.InstanceId -match '^BTHLE\\DEV_' }
Remove-GhostDevices "Dispositivos Bluetooth LE" $bthleGhosts

# ============================================================
Sep "09.4 USB POWER MANAGEMENT — anti-overcurrent"
# ============================================================
# Dispositivos USB 2.0 con consumo declarado cercano al límite de 500 mA
# pueden disparar "Se sobrepasó la capacidad del puerto USB" si Windows
# Update reactiva USB selective suspend o el power management de los hubs.
# Esta sección restaura los ajustes necesarios de forma idempotente.

# 1. USB Selective Suspend — deshabilitar en plan activo (AC + DC)
$guidUsb = "2a737441-1930-4402-8d77-b2bebba308a3"
$guidSs  = "48e6b7a6-50f5-4782-a5d4-53bb8f07e226"
& powercfg /setacvalueindex SCHEME_CURRENT $guidUsb $guidSs 0 2>&1 | Out-Null; $acOk = $LASTEXITCODE -eq 0
& powercfg /setdcvalueindex SCHEME_CURRENT $guidUsb $guidSs 0 2>&1 | Out-Null; $dcOk = $LASTEXITCODE -eq 0
& powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null;                          $apOk = $LASTEXITCODE -eq 0
if ($acOk -and $dcOk -and $apOk) { OK "USB Selective Suspend: deshabilitado (AC + DC)" }
else                              { Err "USB Selective Suspend: powercfg falló (AC=$acOk DC=$dcOk apply=$apOk)" }

# 2. Root Hub EnhancedPowerManagement — deshabilitar en todos los concentradores raíz
$hubs = Get-PnpDevice | Where-Object {
    $_.Status -eq 'OK' -and $_.InstanceId -match '^USB\\ROOT_HUB'
}
$hubCount = 0
foreach ($hub in $hubs) {
    $rp = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($hub.InstanceId)\Device Parameters"
    if (Test-Path $rp) {
        Set-ItemProperty -Path $rp -Name "EnhancedPowerManagementEnabled" -Value 0 -Type DWord -Force
        $hubCount++
    }
}
if ($hubCount -gt 0) { OK "Root Hub EnhancedPowerManagementEnabled=0: $hubCount hubs" }
else                 { Skip "Root Hub: ningún concentrador raíz encontrado" }

# 3. xHCI AMD (VEN_1022 DEV_15C0) — deshabilitar D3/idle
# Aplica solo si el controlador está presente; no actúa en hardware distinto.
$xhciEntry = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Enum\PCI" -ErrorAction SilentlyContinue |
             Where-Object { $_.PSChildName -match 'VEN_1022&DEV_15C0' } |
             ForEach-Object { Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue } |
             Select-Object -First 1

if ($xhciEntry) {
    $dp  = Join-Path $xhciEntry.PSPath "Device Parameters"
    $wdf = Join-Path $dp "WDF"
    New-Item -Path $wdf -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $wdf -Name "IdleInD3"                 -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $dp  -Name "D3ColdSupported"           -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $dp  -Name "EnableIdlePowerManagement" -Value 0 -Type DWord -Force
    OK "xHCI VEN_1022 DEV_15C0: IdleInD3=0, D3ColdSupported=0, EnableIdlePowerManagement=0"
} else {
    Skip "xHCI VEN_1022 DEV_15C0: no presente en este equipo"
}

# ============================================================
Sep "09.5 REGISTRO — Historial de actividad"
# ============================================================
# Borra claves de registro que acumulan historial de actividad del usuario.
# Los módulos anteriores ya aplican valores de configuración permanente;
# esta sección elimina el historial acumulado hasta el momento de ejecución.
# Donde Windows requiere que la clave exista, se recrea vacía (-Recreate).

function Remove-HistoryKey {
    param([string]$Path, [string]$Label, [switch]$Recreate)
    if (-not (Test-Path $Path)) { Skip "No existe: $Label"; return }
    try {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        if ($Recreate) { New-Item -Path $Path -Force -ErrorAction SilentlyContinue | Out-Null }
        OK "Historial borrado: $Label"
    } catch {
        Err "Error borrando $Label — $_"
    }
}

$historyKeys = @(
    @{ P = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RecentDocs";                  L = "Documentos recientes (Explorer)";          R = $true  },
    @{ P = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths";                  L = "Rutas escritas en barra de Explorer";      R = $true  },
    @{ P = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU";                      L = "Historial de Ejecutar (Win+R)";             R = $true  },
    @{ P = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\WordWheelQuery";              L = "Historial de búsqueda en Explorer";         R = $true  },
    @{ P = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\SearchHistory";               L = "Historial de búsqueda (SearchHistory)";    R = $false },
    @{ P = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Map Network Drive MRU";       L = "Historial de unidades de red conectadas";  R = $false },
    @{ P = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\OpenSaveMRU";        L = "Historial de diálogos Abrir/Guardar";      R = $false },
    @{ P = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\OpenSavePidlMRU";    L = "Historial PIDL de diálogos";               R = $false },
    @{ P = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\LastVisitedMRU";     L = "Última carpeta visitada (diálogos)";       R = $false },
    @{ P = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\LastVisitedPidlMRU"; L = "Última carpeta PIDL visitada (diálogos)";  R = $false },
    @{ P = "HKCU:\Software\Microsoft\Windows\Shell\Copilot\BingChat";                              L = "Historial de Copilot / Bing Chat";          R = $false }
)

foreach ($k in $historyKeys) {
    Remove-HistoryKey -Path $k.P -Label $k.L -Recreate:($k.R -eq $true)
}

# UserAssist: subclaves GUID con seguimiento de frecuencia de lanzamiento de apps.
# Se borran los registros internos (Count) pero se conserva la estructura de claves
# para que Windows no pierda la capacidad de escribir en UserAssist.
$uaPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist"
if (Test-Path $uaPath) {
    $cleared = 0
    Get-ChildItem $uaPath -ErrorAction SilentlyContinue | ForEach-Object {
        $countKey = Join-Path $_.PSPath "Count"
        if (Test-Path $countKey) {
            Remove-Item -Path $countKey -Recurse -Force -ErrorAction SilentlyContinue
            New-Item   -Path $countKey -Force         -ErrorAction SilentlyContinue | Out-Null
            $cleared++
        }
    }
    if ($cleared -gt 0) { OK "UserAssist: $cleared registros de seguimiento de apps eliminados" }
    else                 { Skip "UserAssist: sin datos de seguimiento acumulado" }
} else {
    Skip "UserAssist: clave no existe"
}
