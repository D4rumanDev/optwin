# ============================================================
# 03-SERVICIOS — Desactiva servicios de telemetria y optimización
# ============================================================
# CAMBIOS REALIZADOS:
#   - DiagTrack, dmwappushservice, MapsBroker: telemetria Windows
#   - XblAuthManager, XblGameSave, XboxNetApiSvc: Xbox/Gaming
#   - NvTelemetryContainer: NVIDIA telemetria
#   - SensrSvc/SensorService: sensores (Manual en portatiles, Disabled en escritorio)
#   - Spooler, edgeupdate, SSDPSRV: servicios bajo demanda
#   - WinRing0: MSR driver (configurado a Manual para no cargar siempre)
#
# CÓMO REVISAR CAMBIOS:
#   1. Get-Service | Where {$_.StartType -eq "Disabled"} | Select Name
#   2. Get-Service | Where {$_.StartType -eq "Manual"} | Select Name
#
# ROLLBACK:
#   reg import <ScriptRoot>\logs\registry-backup-*.reg
# ============================================================

# ============================================================

# FSM con MaxAgeDays=6: se re-aplica en la ejecucion semanal pero se salta en re-ejecuciones
# manuales dentro de la misma semana. Windows Update puede resetear servicios, por eso no
# usamos un umbral mayor.
$svcData = Read-DataJson "$PSScriptRoot\..\data\services.json"
$svcDisabledList = $svcData.disabled | Select-Object -ExpandProperty name
$svcSensorMode = if ($IsLaptop) { "Manual" } else { "Disabled" }

if (Test-SectionApplied "services-disabled" ($svcDisabledList + $svcSensorMode) -MaxAgeDays 6) {
    Skip "Servicios desactivados: sin cambios desde hace <6 dias"
} else {
    $svcDisabledList | ForEach-Object { Set-Svc -Name $_ -Mode "Disabled" }

    # Sensores de hardware: en escritorio son inutiles; en portatil gestionan acelerometro
    # (rotacion de pantalla en convertibles) y sensor de luz ambiental (brillo adaptativo)
    @("SensrSvc", "SensorService") | ForEach-Object { Set-Svc -Name $_ -Mode $svcSensorMode }

    Set-SectionApplied "services-disabled" ($svcDisabledList + $svcSensorMode)
}

# ============================================================
Sep "03.2 SERVICIOS — Poner en Manual"
# ============================================================

$svcManualList   = $svcData.manual   | Select-Object -ExpandProperty name

if (Test-SectionApplied "services-manual" $svcManualList -MaxAgeDays 6) {
    Skip "Servicios en manual: sin cambios desde hace <6 dias"
} else {
    # Google Updater: buscar por patron en cache (nombre cambia con cada version)
    $script:AllServices.Values | Where-Object { $_.Name -match "^GoogleUpdater" } |
        ForEach-Object { Set-Svc -Name $_.Name -Mode "Manual" }

    $svcManualList | ForEach-Object { Set-Svc -Name $_ -Mode "Manual" }
    Set-SectionApplied "services-manual" $svcManualList
}

# ============================================================
Sep "03.3 INICIO — Eliminar entradas innecesarias"
# ============================================================

$runPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$svcData.startup_remove | ForEach-Object {
    $entryName = $_
    try {
        if (Get-ItemProperty -Path $runPath -Name $entryName -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $runPath -Name $entryName -Force -ErrorAction Stop
            OK "Eliminado del inicio: $entryName"
        } else {
            Skip "No en inicio: $entryName"
        }
    } catch { Err "Inicio $entryName — $_" }
}
