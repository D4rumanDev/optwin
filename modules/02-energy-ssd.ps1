# ============================================================
# Definicion de grupos de registro para FSM
# ============================================================

$regSsdMemory = @(
    # LargeSystemCache: kernel usa mas RAM para cache del sistema de archivos
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"; N="LargeSystemCache";              V=1 },
    # Mantener kernel y drivers en RAM, evitar paging a disco
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"; N="DisablePagingExecutive";        V=1 },
    # Win11: alta resolucion de timer global para apps que lo soliciten
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel";            N="GlobalTimerResolutionRequests"; V=1 },
    # Explorer: eliminar delay de inicio al arrancar Windows
    @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize";      N="StartupDelayInMSec";            V=0 },
    @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize";      N="WaitForIdleState";              V=0 },
    # Habilitar rutas largas (>260 caracteres)
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem";                        N="LongPathsEnabled";              V=1 }
)

$regEnergyStatic = @(
    # Desactivar red durante Modern Standby (AC y DC — bateria)
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\f15576e8-98b7-4186-b944-eafa664402d9"; N="ACSettingIndex"; V=0 },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\f15576e8-98b7-4186-b944-eafa664402d9"; N="DCSettingIndex"; V=0 },
    # WaitToKillServiceTimeout: reduce espera al apagar servicios de 5s a 2s
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control"; N="WaitToKillServiceTimeout"; V="2000"; T="String" },
    # Desactivar power throttling (EcoQoS) globalmente — solo escritorio (ver bloque condicional abajo)
    # En portatil EcoQoS ayuda a contener procesos en background y reducir calor
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Power"; N="EventProcessorEnabled"; V=0 },
    # Telemetria de energia: desactivar logging de consumo por aplicacion
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Power\EnergyEstimation\TaggedEnergy"; N="DisableTaggedEnergyLogging";    V=1 },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Power\EnergyEstimation\TaggedEnergy"; N="TelemetryMaxApplication";       V=0 },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Power\EnergyEstimation\TaggedEnergy"; N="TelemetryMaxTagPerApplication"; V=0 },
    # Detener escritura de timestamp al registro cada 5s (reduce escrituras SSD)
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Reliability"; N="TimeStampInterval"; V=0 },
    # Shutdown mas rapido: terminar apps colgadas automaticamente sin dialogo
    @{ P="HKCU:\Control Panel\Desktop"; N="HungAppTimeout";       V="2000"; T="String" },
    @{ P="HKCU:\Control Panel\Desktop"; N="WaitToKillAppTimeout"; V="2000"; T="String" },
    @{ P="HKCU:\Control Panel\Desktop"; N="AutoEndTasks";         V="1";    T="String" },
    # Crash Dump: minidump en lugar de completo (ahorra GB en disco)
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"; N="CrashDumpEnabled"; V=3 },
    # Desactivar Fast Startup: evita shutdown hibrido (hiberfil parcial), problemas con dual-boot
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"; N="HiberbootEnabled"; V=0 }
)

# ============================================================
Sep "02.1 ENERGIA — Plan de Maximo Rendimiento"
# ============================================================

$ultimateGUID = "e9a42b02-d5df-448d-aa00-03f14749eb61"
$highGUID     = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
$guidRx       = "(?i)([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})"

try {
    # Listar todos los planes existentes
    $allPlans = powercfg /list
    $planCount = ($allPlans | Where-Object { $_ -match $guidRx }).Count
    Write-Log "  Planes de energia detectados: $planCount" "DarkGray"
    $allPlans | Where-Object { $_ -match $guidRx } | ForEach-Object { Write-Log "    $_" "DarkGray" }

    # Buscar todos los planes Maximo/Ultimate (puede haber duplicados de ejecuciones anteriores)
    $maxPlans = $allPlans | Where-Object { $_ -imatch "ltimo rendimiento|ximo rendimiento|Ultimate Performance|Maximum Performance" }
    $maxGuids = @($maxPlans | ForEach-Object { if ($_ -match $guidRx) { $Matches[1] } })

    if ($maxGuids.Count -gt 1) {
        # Activar el primero y eliminar los restantes
        powercfg /setactive $maxGuids[0]
        OK "Plan Maximo Rendimiento activado ($($maxGuids[0]))"
        foreach ($dup in $maxGuids[1..($maxGuids.Count - 1)]) {
            powercfg /delete $dup 2>&1 | Out-Null
            OK "Plan duplicado eliminado: $dup"
        }
    } elseif ($maxGuids.Count -eq 1) {
        powercfg /setactive $maxGuids[0]
        OK "Plan Maximo Rendimiento ya existe — activado ($($maxGuids[0]))"
    } else {
        # No existe: duplicar el esquema Ultimate
        $dupeOut = powercfg -duplicatescheme $ultimateGUID 2>&1 | Out-String
        if ($dupeOut -match $guidRx) {
            powercfg /setactive $Matches[1]
            OK "Plan Maximo Rendimiento creado y activado ($($Matches[1]))"
        } else {
            powercfg /setactive $highGUID
            OK "Plan Alto Rendimiento activado (fallback)"
        }
    }
} catch { Err "Plan de energia — $_" }

# ============================================================
Sep "02.2 SSD — Optimizaciones"
# ============================================================

try {
    $trimVal = (fsutil behavior query disabledeletenotify 2>&1) -join ""
    if ($trimVal -match "=\s*0") { Skip "TRIM: ya habilitado (DisableDeleteNotify = 0)" }
    else {
        fsutil behavior set DisableDeleteNotify 0 | Out-Null
        OK "TRIM habilitado (DisableDeleteNotify = 0)"
    }
} catch { Err "TRIM — $_" }

try {
    if ((Get-MMAgent -ErrorAction Stop).MemoryCompression) { Skip "Compresion de memoria: ya habilitada" }
    else {
        Enable-MMAgent -MemoryCompression -ErrorAction Stop
        OK "Compresion de memoria habilitada"
    }
} catch { Err "MemoryCompression — $_" }

# NTFS Last Access Timestamp: elimina escrituras innecesarias en SSD
try {
    $laVal = (fsutil behavior query disablelastaccess 2>&1) -join ""
    if ($laVal -match "=\s*1") { Skip "NTFS Last Access: ya desactivado" }
    else {
        fsutil behavior set disablelastaccess 1 | Out-Null
        OK "NTFS Last Access Timestamp desactivado (menos escrituras en SSD)"
    }
} catch { Err "NTFS LastAccess — $_" }

# Memoria, rutas y Explorer startup — registro estatico
if (Test-SectionApplied "ssd-memory-reg" $regSsdMemory) {
    Skip "SSD/Memoria registro: $($regSsdMemory.Count) claves — sin cambios"
} else {
    $regSsdMemory | ForEach-Object { Set-Reg -Path $_.P -Name $_.N -Value $_.V -Type ($_.T ?? "DWord") }
    Set-SectionApplied "ssd-memory-reg" $regSsdMemory
    OK "SSD/Memoria registro: $($regSsdMemory.Count) claves aplicadas"
}

# Ajustar umbral de separacion de svchost segun RAM instalada (reduce procesos svchost)
try {
    $totalRAMkb = [long]((Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop |
                          Measure-Object -Property Capacity -Sum).Sum / 1KB)
    Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control" "SvcHostSplitThresholdInKB" $totalRAMkb "DWord"
} catch { Err "SvcHostSplitThresholdInKB — $_" }

# ============================================================
Sep "02.3 ENERGIA Y SLEEP — Optimizaciones de portatil"
# ============================================================

# Desactivar hibernacion (ahorra ~16 GB en SSD, mejora seguridad)
# En portatil se conserva — necesaria para recuperacion con bateria critica
if ($IsLaptop) {
    Skip "Hibernacion: conservada en portatil (necesaria para bateria critica)"
} else {
    try {
        powercfg.exe /hibernate off
        Set-Reg "HKLM:\System\CurrentControlSet\Control\Session Manager\Power" "HibernateEnabled" 0
        Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings" "ShowHibernateOption" 0
        $hiberGB = [math]::Round(((Get-Item 'C:\hiberfil.sys' -ErrorAction SilentlyContinue)?.Length ?? 0) / 1GB, 1)
        OK "Hibernacion desactivada$(if ($hiberGB -gt 0) { " (libera ~$hiberGB GB en SSD)" })"
    } catch { Err "Hibernacion — $_" }
}

# Configuracion estatica de energia y shutdown
if (Test-SectionApplied "energy-static-reg" $regEnergyStatic) {
    Skip "Energia registro: $($regEnergyStatic.Count) claves — sin cambios"
} else {
    $regEnergyStatic | ForEach-Object { Set-Reg -Path $_.P -Name $_.N -Value $_.V -Type ($_.T ?? "DWord") }
    Set-SectionApplied "energy-static-reg" $regEnergyStatic
    OK "Energia registro: $($regEnergyStatic.Count) claves aplicadas"
}

# EcoQoS / Power Throttling: en escritorio se desactiva para maximo rendimiento en background
# En portatil se conserva activo: el OS puede contener automaticamente procesos pesados
# (complementa el limite explicito de Defender al 20% CPU)
if (-not $IsLaptop) {
    try {
        $cur = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name "PowerThrottlingOff" -ErrorAction SilentlyContinue).PowerThrottlingOff
        if ($cur -eq 1) { Skip "EcoQoS (PowerThrottlingOff): ya desactivado en escritorio" }
        else {
            Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\Power" "PowerThrottlingOff" 1
            OK "EcoQoS desactivado (escritorio — procesos background sin throttling automatico)"
        }
    } catch { Err "EcoQoS — $_" }
} else {
    Skip "EcoQoS: conservado en portatil (ayuda a contener procesos pesados en background)"
}

# Modern Standby: forzar S3 clasico en portatiles con S0 agresivo (reduce sobrecalentamiento)
if ($IsLaptop) {
    try {
        $acIdle = (powercfg /GETACVALUEINDEX SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>&1) -join ""
        $dcIdle = (powercfg /GETDCVALUEINDEX SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>&1) -join ""
        if ($acIdle -match ":\s*0\b" -and $dcIdle -match ":\s*0\b") {
            Skip "Modern Standby: idle ya a 0 en AC y DC"
        } else {
            powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0 | Out-Null
            powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0 | Out-Null
            powercfg /setactive SCHEME_CURRENT | Out-Null
            OK "Modern Standby: idle forzado a 0 en AC y DC"
        }
    } catch { Err "Modern Standby — $_" }
} else {
    Skip "Modern Standby: solo aplica a portatiles"
}

# Timer de alta resolucion (solo en escritorio — en portatil aumenta consumo)
if (-not $IsLaptop) {
    try {
        bcdedit /set useplatformtick yes    | Out-Null
        bcdedit /set disabledynamictick yes | Out-Null
        bcdedit /set tscsyncpolicy enhanced | Out-Null
        bcdedit /deletevalue useplatformclock 2>$null | Out-Null
        OK "Timer BCD: useplatformtick=yes, disabledynamictick=yes, tscsyncpolicy=enhanced"
    } catch { Err "Timer BCD — $_" }
} else {
    Skip "Timer BCD: omitido en portatil (aumentaria consumo energetico)"
}

# Limite termico de CPU: 90% AC / 80% DC en portatil
# Evita que el firmware limite todos los cores (Event ID 37) bajo carga sostenida.
# En escritorio no aplica: la refrigeracion es suficiente para mantener 100% sin throttling.
if ($IsLaptop) {
    try {
        $procSub = "54533251-82be-4824-96c1-47b60b740d00"
        $procMax = "bc5038f7-23e0-4960-96da-33abaf5935ec"
        $acVal = (powercfg /GETACVALUEINDEX SCHEME_CURRENT $procSub $procMax 2>&1) -join ""
        $dcVal = (powercfg /GETDCVALUEINDEX SCHEME_CURRENT $procSub $procMax 2>&1) -join ""
        if ($acVal -match ":\s*90\b" -and $dcVal -match ":\s*80\b") {
            Skip "CPU max estado: ya 90% AC / 80% DC"
        } else {
            powercfg /SETACVALUEINDEX SCHEME_CURRENT $procSub $procMax 90 | Out-Null
            powercfg /SETDCVALUEINDEX SCHEME_CURRENT $procSub $procMax 80 | Out-Null
            powercfg /SETACTIVE SCHEME_CURRENT | Out-Null
            OK "CPU max estado: 90% AC / 80% DC (previene throttling firmware en portatil)"
        }
    } catch { Err "CPU max estado — $_" }
} else {
    Skip "CPU max estado: escritorio — sin limite (100%)"
}
