#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Diagnóstico y reparación de problemas habituales de Windows.
    Agnóstico de marca y modelo — actúa en la capa Windows (PnP, servicios, spooler).
    Cada sección verifica la condición antes de actuar.

.DESCRIPTION
    Secciones disponibles:
      1. Bluetooth        — CM_PROB_FAILED_START (disable/enable PnP)
      2. bthserv          — servicio de alto nivel Bluetooth
      3. Impresoras        — cola atascada + Spooler
      4. SIM / WWAN        — WwanSvc + reset PnP adaptador celular
      5. Caché DNS         — flush + restart Dnscache si procede
      6. Windows Update    — reset completo del cliente WU (SoftwareDistribution + catroot2)
      7. WSL / HNS         — red virtual de WSL y contenedores (HNS + WslService)

.PARAMETER Sections
    Lista de números de sección a ejecutar. Por defecto ejecuta todas.
    Ejemplo: -Sections 1,3,5

.EXAMPLE
    .\fix-habituales.ps1
    .\fix-habituales.ps1 -Sections 3,6
#>
param(
    [int[]]$Sections = @(1,2,3,4,5,6,7)
)

$ErrorActionPreference = "Continue"

$LogsDir = Join-Path $PSScriptRoot "logs"
New-Item -ItemType Directory -Path $LogsDir -Force -ErrorAction SilentlyContinue | Out-Null
$LogFile = "$LogsDir\fix-habituales-$(Get-Date -Format 'yyyy-MM-dd-HHmmss').log"

. "$PSScriptRoot\modules\00-helpers.ps1"

# ── Helpers ──────────────────────────────────────────────────────────────────
function OK($msg)   { Write-Log "[OK]   $msg" "Green" }
function Err($msg)  { Write-Log "[FAIL] $msg" "Red" }
function Skip($msg) { Write-Log "[SKIP] $msg" "DarkGray" }
function Info($msg) { Write-Log "  $msg" "Yellow" }
function Sep($num, $msg) {
    if ($num -notin $script:Sections) { return $false }
    $line = "=" * 60
    Write-Log "`n$line" "Cyan"
    Write-Log "  $num. $msg" "Cyan"
    Write-Log $line "Cyan"
    return $true
}

function Restart-Svc {
    param([string]$Name, [int]$TimeoutSec = 20)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }
    try {
        if ($svc.Status -eq 'Running') {
            Stop-Service -Name $Name -Force -ErrorAction Stop
            $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($TimeoutSec))
        }
        Start-Service -Name $Name -ErrorAction Stop
        $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds($TimeoutSec))
        return $true
    } catch {
        Err "No se pudo reiniciar $Name — $_"
        return $false
    }
}

# Disable+Enable PnP — fuerza al driver manager a reinicializar el dispositivo.
# Devuelve el Status tras el reset ('OK', 'Error', etc.) o $null si falla el ciclo.
function Reset-PnpDevice {
    param([string]$InstanceId, [string]$Label, [int]$DisableSleep = 2, [int]$EnableSleep = 3)
    try {
        Disable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds $DisableSleep
        Enable-PnpDevice  -InstanceId $InstanceId -Confirm:$false -ErrorAction Stop
        # Poll hasta que el driver complete la inicialización — drivers lentos pueden
        # reportar transitoriamente un estado distinto de OK/Error durante el arranque.
        $deadline = (Get-Date).AddSeconds($EnableSleep + 7)
        $status   = $null
        do {
            Start-Sleep -Milliseconds 500
            $status = (Get-PnpDevice -InstanceId $InstanceId -ErrorAction SilentlyContinue).Status
        } while ($status -notin @('OK', 'Error') -and (Get-Date) -lt $deadline)
        return $status
    } catch {
        Err "Reset PnP fallido: $Label — $_"
        return $null
    }
}

# Elimina ficheros en un directorio y devuelve el número de borrados exitosos.
function Clear-DirectoryFiles {
    param([string]$Path, [switch]$Recurse)
    if (-not (Test-Path $Path)) { return 0 }
    $deleted = 0
    $failed  = 0
    Get-ChildItem $Path -File -Recurse:$Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Remove-Item $_.FullName -Force -ErrorAction Stop
            $deleted++
        } catch {
            $failed++
        }
    }
    if ($failed -gt 0) { Info "Advertencia: $failed fichero(s) en uso o sin permisos, no eliminados" }
    return $deleted
}

# ── 1. BLUETOOTH — CM_PROB_FAILED_START ──────────────────────────────────────
if (Sep 1 "BLUETOOTH — fallo al arrancar") {
    $btDevices = Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue |
                 Where-Object { $_.Status -eq 'Error' }

    if (-not $btDevices) {
        Skip "Bluetooth: sin adaptadores en estado Error"
    } else {
        foreach ($dev in $btDevices) {
            Info "Detectado en error: $($dev.FriendlyName)"
            $status = Reset-PnpDevice $dev.InstanceId $dev.FriendlyName
            if     ($status -eq 'OK')   { OK  "Bluetooth restaurado: $($dev.FriendlyName)" }
            elseif ($null -ne $status)  { Err "Sigue en error tras reset PnP: $($dev.FriendlyName) (Status: $status)" }
        }
    }
}

# ── 2. SERVICIO BLUETOOTH (bthserv) ──────────────────────────────────────────
if (Sep 2 "BLUETOOTH — servicio de alto nivel (bthserv)") {
    $bthServ = Get-Service -Name 'bthserv' -ErrorAction SilentlyContinue
    if (-not $bthServ) {
        Skip "bthserv: no instalado en este equipo"
    } elseif ($bthServ.Status -eq 'Running') {
        Skip "bthserv: en ejecución"
    } else {
        Info "bthserv en estado: $($bthServ.Status) — reiniciando"
        if (Restart-Svc 'bthserv') { OK "bthserv reiniciado" }
    }
}

# ── 3. IMPRESORAS — cola atascada y Spooler ───────────────────────────────────
if (Sep 3 "IMPRESORAS — cola atascada / Spooler") {
    $spoolDir   = "$env:SystemRoot\System32\spool\PRINTERS"
    $spooler    = Get-Service -Name 'Spooler' -ErrorAction SilentlyContinue
    $stuckFiles = if (Test-Path $spoolDir) {
        Get-ChildItem $spoolDir -File -ErrorAction SilentlyContinue
    } else { @() }

    $needsFix = ($spooler -and $spooler.Status -ne 'Running') -or ($stuckFiles.Count -gt 0)

    if (-not $needsFix) {
        Skip "Spooler: activo y cola vacía"
    } else {
        if ($stuckFiles.Count -gt 0) { Info "Cola con $($stuckFiles.Count) fichero(s) atascado(s)" }
        if ($spooler.Status -ne 'Running') { Info "Spooler en estado: $($spooler.Status)" }

        try {
            Stop-Service -Name 'Spooler' -Force -ErrorAction Stop
            Start-Sleep -Seconds 2

            $deleted = 0
            $stuckFiles | ForEach-Object {
                try { Remove-Item $_.FullName -Force -ErrorAction Stop; $deleted++ } catch {}
            }
            if ($deleted -gt 0) { OK "Cola limpiada: $deleted fichero(s) eliminado(s)" }

            Start-Service -Name 'Spooler' -ErrorAction Stop
            Start-Sleep -Seconds 2
            $after = (Get-Service 'Spooler').Status
            if ($after -eq 'Running') { OK "Spooler reiniciado correctamente" }
            else { Err "Spooler sigue en estado: $after" }
        } catch {
            Err "Error gestionando Spooler — $_"
        }
    }
}

# ── 4. SIM / WWAN ────────────────────────────────────────────────────────────
if (Sep 4 "SIM / WWAN — detección y reset") {
    # WwanSvc abstrae todo el hardware celular — agnóstico de marca/modelo.
    $wwanSvc = Get-Service -Name 'WwanSvc' -ErrorAction SilentlyContinue

    if (-not $wwanSvc) {
        Skip "SIM/WWAN: WwanSvc no encontrado — este equipo no tiene hardware celular"
    } else {
        $wwanDevices = Get-PnpDevice -Class 'Net'   -ErrorAction SilentlyContinue |
                       Where-Object { $_.FriendlyName -match 'WWAN|Mobile Broadband|Cellular|LTE|5G|4G|3G' }
        $wwanModems  = Get-PnpDevice -Class 'Modem' -ErrorAction SilentlyContinue |
                       Where-Object { $_.FriendlyName -match 'WWAN|Broadband|Cellular|LTE|5G|4G|3G|eSIM' }
        $allWwan     = @($wwanDevices) + @($wwanModems) | Where-Object { $_ }

        if (-not $allWwan) {
            Skip "SIM/WWAN: no se detectan adaptadores celulares"
        } else {
            foreach ($dev in $allWwan) {
                Write-Log "  Adaptador: $($dev.FriendlyName) — Status: $($dev.Status)" "White"
            }

            $wwanErrors = $allWwan | Where-Object { $_.Status -eq 'Error' }
            $svcStopped = $wwanSvc.Status -ne 'Running'

            if (-not $wwanErrors -and -not $svcStopped) {
                Skip "SIM/WWAN: sin errores detectados"
            } else {
                if ($svcStopped) { Info "WwanSvc en estado: $($wwanSvc.Status) — reiniciando" }
                else             { Info "$($wwanErrors.Count) adaptador(es) en error — reiniciando WwanSvc" }

                if (Restart-Svc 'WwanSvc') { OK "WwanSvc reiniciado" }
                Start-Sleep -Seconds 5

                # Re-query para ver si el reinicio del servicio ya los recuperó
                $stillBad = $wwanErrors | Where-Object {
                    (Get-PnpDevice -InstanceId $_.InstanceId -ErrorAction SilentlyContinue).Status -eq 'Error'
                }

                if (-not $stillBad) {
                    if ($wwanErrors) { OK "Adaptadores WWAN recuperados tras reinicio de servicio" }
                } else {
                    Info "$($stillBad.Count) adaptador(es) siguen en error — reset PnP"
                    foreach ($dev in $stillBad) {
                        $status = Reset-PnpDevice $dev.InstanceId $dev.FriendlyName -DisableSleep 3 -EnableSleep 5
                        if     ($status -eq 'OK')  { OK  "WWAN restaurado: $($dev.FriendlyName)" }
                        elseif ($null -ne $status) {
                            Err "Sigue en error tras reset PnP: $($dev.FriendlyName)"
                            Info "→ Posible causa hardware: SIM no insertada, ranura defectuosa o driver corrupto"
                        }
                    }
                }
            }
        }
    }
}

# ── 5. CACHÉ DNS ─────────────────────────────────────────────────────────────
if (Sep 5 "CACHÉ DNS — flush y reset Dnscache") {
    # No existe señal fiable de "caché corrupta" — el flush siempre es inocuo.
    $dnsSvc = Get-Service -Name 'Dnscache' -ErrorAction SilentlyContinue

    try {
        Clear-DnsClientCache -ErrorAction Stop
        OK "Caché DNS vaciada"
    } catch {
        Err "No se pudo vaciar la caché DNS — $_"
    }

    if ($dnsSvc -and $dnsSvc.Status -ne 'Running') {
        Info "Dnscache en estado: $($dnsSvc.Status) — reiniciando"
        if (Restart-Svc 'Dnscache') { OK "Dnscache reiniciado" }
    } else {
        Skip "Dnscache: en ejecución, no se reinicia"
    }
}

# ── 6. WINDOWS UPDATE — reset del cliente ────────────────────────────────────
if (Sep 6 "WINDOWS UPDATE — reset del cliente WU") {
    # Diagnóstico: descargas con más de 7 días en SoftwareDistribution\Download
    # o wuauserv en estado distinto de Running/Stopped.
    # No toca la configuración de WU, solo el estado del cliente.

    $wuSvc   = Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
    $sdPath  = "$env:SystemRoot\SoftwareDistribution\Download"
    $cr2Path = "$env:SystemRoot\System32\catroot2"
    $cutoff  = (Get-Date).AddDays(-7)

    $stuckDl = if (Test-Path $sdPath) {
        Get-ChildItem $sdPath -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff }
    } else { @() }

    $wuError  = $wuSvc -and $wuSvc.Status -notin @('Running', 'Stopped')
    $needsFix = $wuError -or ($stuckDl.Count -gt 0)

    if (-not $needsFix) {
        Skip "Windows Update: sin descargas atascadas (>7 días) y wuauserv OK"
    } else {
        if ($stuckDl.Count -gt 0) { Info "$($stuckDl.Count) fichero(s) de descarga con más de 7 días" }
        if ($wuError)              { Info "wuauserv en estado: $($wuSvc.Status)" }

        try {
            Stop-Service -Name @('wuauserv', 'bits', 'cryptsvc', 'msiserver') `
                         -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3

            $delSd = Clear-DirectoryFiles $sdPath  -Recurse
            $delCr = Clear-DirectoryFiles $cr2Path -Recurse
            if ($delSd -gt 0) { OK "SoftwareDistribution\Download: $delSd fichero(s) eliminado(s)" }
            if ($delCr -gt 0) { OK "catroot2: $delCr fichero(s) eliminado(s)" }

            Start-Service -Name @('bits', 'cryptsvc', 'wuauserv') -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            $after = (Get-Service 'wuauserv').Status
            if ($after -eq 'Running') { OK "Windows Update reiniciado correctamente" }
            else { Err "wuauserv en estado: $after tras el reset" }
        } catch {
            Err "Error durante reset de Windows Update — $_"
        }
    }
}

# ── 7. WSL / HNS — red virtual ───────────────────────────────────────────────
if (Sep 7 "WSL / HNS — red virtual de WSL y contenedores") {
    # Fix: reiniciar HNS recrea los adaptadores virtuales de WSL y Docker
    # sin modificar la configuración de red del host.
    # No ejecuta netsh winsock reset (requeriría reinicio del equipo).

    $wslExe = Get-Command 'wsl.exe' -ErrorAction SilentlyContinue
    if (-not $wslExe) {
        Skip "WSL: wsl.exe no encontrado — WSL no está instalado"
    } else {
        $hnsSvc    = Get-Service -Name 'hns'        -ErrorAction SilentlyContinue
        $wslSvc    = Get-Service -Name 'WslService' -ErrorAction SilentlyContinue
        $wslAdapter = Get-NetAdapter -Name 'vEthernet (WSL*' -ErrorAction SilentlyContinue |
                      Select-Object -First 1

        $hnsError      = $hnsSvc -and $hnsSvc.Status -ne 'Running'
        $adapterMissing = -not $wslAdapter
        $adapterDown    = $wslAdapter -and $wslAdapter.Status -ne 'Up'

        if (-not $hnsError -and -not $adapterMissing -and -not $adapterDown) {
            Skip "WSL/HNS: sin problemas detectados (HNS activo, adaptador vEthernet OK)"
        } else {
            if ($hnsError)       { Info "HNS en estado: $($hnsSvc.Status)" }
            if ($adapterMissing) { Info "Adaptador vEthernet (WSL) no encontrado" }
            if ($adapterDown)    { Info "Adaptador vEthernet (WSL) en estado: $($wslAdapter.Status)" }

            if ($hnsSvc) {
                Info "Reiniciando HNS (Host Network Service)..."
                if (Restart-Svc 'hns' -TimeoutSec 30) { OK "HNS reiniciado" }
                Start-Sleep -Seconds 5
            }

            if ($wslSvc -and $wslSvc.Status -ne 'Running') {
                Info "Reiniciando WslService..."
                if (Restart-Svc 'WslService') { OK "WslService reiniciado" }
            }

            Start-Sleep -Seconds 5
            $adapterAfter = Get-NetAdapter -Name 'vEthernet (WSL*' -ErrorAction SilentlyContinue |
                            Select-Object -First 1
            if ($adapterAfter -and $adapterAfter.Status -eq 'Up') {
                OK "Adaptador vEthernet (WSL) restaurado"
            } elseif ($adapterAfter) {
                Err "Adaptador vEthernet (WSL) sigue en estado: $($adapterAfter.Status)"
                Info "→ Prueba: wsl --shutdown && wsl para forzar reinicio de la instancia"
            } else {
                Err "Adaptador vEthernet (WSL) no se recreó"
                Info "→ Prueba: wsl --shutdown, o reiniciar el equipo si persiste"
            }
        }
    }
}

# ── Resumen ──────────────────────────────────────────────────────────────────
$line = "=" * 60
Write-Log "`n$line" "Cyan"
Write-Log "  Completado. Revisa los [FAIL] si los hay." "Cyan"
Write-Log "$line`n" "Cyan"
