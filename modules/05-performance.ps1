# ============================================================
# Definicion de grupos de registro para FSM
# ============================================================

$regVisual = Read-DataJson "$PSScriptRoot\..\data\registry\performance-visual.json"

$regGaming = Read-DataJson "$PSScriptRoot\..\data\registry\performance-gaming.json"

$regNetworkStatic = Read-DataJson "$PSScriptRoot\..\data\registry\performance-network.json"

# ============================================================
Sep "05.1 RENDIMIENTO VISUAL — Animaciones y efectos"
# ============================================================

if (Test-SectionApplied "performance-visual" $regVisual) {
    Skip "Visual: $($regVisual.Count) claves — sin cambios"
} else {
    $regVisual | ForEach-Object { Set-Reg -Path $_.P -Name $_.N -Value $_.V -Type ($_.T ?? "DWord") }
    Set-SectionApplied "performance-visual" $regVisual
    OK "Visual: $($regVisual.Count) claves aplicadas"
}

# ============================================================
Sep "05.2 GAMING — Optimizaciones para juegos"
# ============================================================

if (Test-SectionApplied "performance-gaming" $regGaming) {
    Skip "Gaming: $($regGaming.Count) claves — sin cambios"
} else {
    $regGaming | ForEach-Object { Set-Reg -Path $_.P -Name $_.N -Value $_.V -Type ($_.T ?? "DWord") }
    Set-SectionApplied "performance-gaming" $regGaming
    OK "Gaming: $($regGaming.Count) claves aplicadas"
}

# GPU DisableDynamicPstate: bloquea la GPU en P0 (frecuencia maxima) — elimina latencia de cambios de P-state
# Solo en escritorio: en portatil mantiene la GPU a maxima frecuencia incluso en reposo → mas calor y bateria
if (-not $IsLaptop) {
    try {
        $gpus = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
                Where-Object { $_.PNPDeviceID -match "^PCI\\VEN_" }
        foreach ($gpu in $gpus) {
            $driverKey = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$($gpu.PNPDeviceID)" `
                            -Name "Driver" -ErrorAction SilentlyContinue).Driver
            if ($driverKey -match '\{.*\}') {
                $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$driverKey"
                $cur = (Get-ItemProperty $regPath -Name "DisableDynamicPstate" -ErrorAction SilentlyContinue).DisableDynamicPstate
                if ($cur -eq 1) { Skip "DisableDynamicPstate ya=1: $($gpu.Name)"; continue }
                Set-ItemProperty -Path $regPath -Name "DisableDynamicPstate" -Value 1 -Type DWord -Force
                OK "DisableDynamicPstate=1: $($gpu.Name)"
            }
        }
    } catch { Err "DisableDynamicPstate — $_" }
} else {
    Skip "DisableDynamicPstate: portatil — GPU conserva gestion dinamica de P-state (ahorro calor y bateria)"
}

# Boot menu clasico: restaura F8 para acceder a Modo Seguro
try {
    $bcdOut = bcdedit /enum "{current}" 2>&1 | Out-String
    if ($bcdOut -imatch "bootmenupolicy\s+legacy") {
        Skip "BCD: bootmenupolicy ya es legacy"
    } else {
        bcdedit /set bootmenupolicy legacy | Out-Null
        OK "BCD: bootmenupolicy = legacy (F8 habilitado para modo seguro)"
    }
} catch { Err "BCD bootmenupolicy — $_" }

# ============================================================
Sep "05.3 RED — Optimizaciones de red"
# ============================================================

# Registro estatico de red (IPv6, TCP, throttling)
if (Test-SectionApplied "performance-network-reg" $regNetworkStatic) {
    Skip "Red registro: $($regNetworkStatic.Count) claves — sin cambios"
} else {
    $regNetworkStatic | ForEach-Object { Set-Reg -Path $_.P -Name $_.N -Value $_.V -Type ($_.T ?? "DWord") }
    Set-SectionApplied "performance-network-reg" $regNetworkStatic
    OK "Red registro: $($regNetworkStatic.Count) claves aplicadas"
}

# Optimizar stack TCP (autotuninglevel, RSS, chimney, ECN)
try {
    $tcpState = netsh int tcp show global 2>&1 | Out-String
    $tcpOk = ($tcpState -imatch "Auto-Tuning.*normal") -and
             ($tcpState -imatch "Receive-Side Scaling.*enabled") -and
             ($tcpState -imatch "ECN.*enabled")
    if ($tcpOk) {
        Skip "TCP stack ya optimizado (autotune/RSS/ECN)"
    } else {
        netsh int tcp set global autotuninglevel=normal | Out-Null
        netsh int tcp set global rss=enabled           | Out-Null
        netsh int tcp set global chimney=enabled        | Out-Null
        netsh int tcp set global ecncapability=enabled  | Out-Null
        OK "TCP stack optimizado (autotune/RSS/chimney/ECN)"
    }
} catch { Err "TCP stack — $_" }

# Desactivar Teredo (tunneling IPv6, aumenta latencia en juegos)
try {
    $teredoState = netsh interface teredo show state 2>&1 | Out-String
    if ($teredoState -imatch "Type\s*:\s*disabled") {
        Skip "Teredo ya desactivado"
    } else {
        netsh interface teredo set state disabled | Out-Null
        OK "Teredo tunneling desactivado"
    }
} catch { Err "Teredo — $_" }

# TcpAckFrequency=1 por adaptador (Windows lo lee por NIC, no del global)
try {
    $nicBase    = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
    $nicKeys    = Get-ChildItem $nicBase -ErrorAction Stop
    $nicChanged = 0
    foreach ($nic in $nicKeys) {
        $cur = (Get-ItemProperty -Path $nic.PSPath -Name "TcpAckFrequency" -ErrorAction SilentlyContinue).TcpAckFrequency
        if ($cur -ne 1) {
            Set-ItemProperty -Path $nic.PSPath -Name "TcpAckFrequency" -Value 1 -Type DWord -Force
            $nicChanged++
        }
    }
    if ($nicChanged -eq 0) { Skip "TcpAckFrequency=1 ya configurado en todos los adaptadores" }
    else                   { OK "TcpAckFrequency=1 aplicado en $nicChanged adaptador(es)" }
} catch { Err "TcpAckFrequency per-NIC — $_" }

# Deshabilitar SMB 1.0 (protocolo obsoleto y vulnerable — WannaCry/EternalBlue)
# Set-SmbServerConfiguration es instantaneo; Get-WindowsOptionalFeature/DISM puede bloquearse minutos
try {
    $smb1cfg = Get-SmbServerConfiguration -ErrorAction Stop
    if (-not $smb1cfg.EnableSMB1Protocol) {
        Skip "SMB 1.0 ya estaba deshabilitado"
    } else {
        Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction Stop
        OK "SMB 1.0 deshabilitado"
    }
} catch { Err "SMB 1.0 — $_" }

# USB Selective Suspend: desactivar en el plan de energia activo (reduce latencia USB)
try {
    $usbSub  = "2a737441-1930-4402-8d77-b2bebba308a3"
    $usbSet  = "48e6b7a6-50f5-4782-a5d4-53bb8f07e226"
    $acVal   = (powercfg /GETACVALUEINDEX SCHEME_CURRENT $usbSub $usbSet 2>&1) -join ""
    $dcVal   = (powercfg /GETDCVALUEINDEX SCHEME_CURRENT $usbSub $usbSet 2>&1) -join ""
    if ($acVal -match ":\s*0\b" -and $dcVal -match ":\s*0\b") {
        Skip "USB Selective Suspend: ya desactivado en plan de energia"
    } else {
        powercfg /SETACVALUEINDEX SCHEME_CURRENT $usbSub $usbSet 0 | Out-Null
        powercfg /SETDCVALUEINDEX SCHEME_CURRENT $usbSub $usbSet 0 | Out-Null
        powercfg /SETACTIVE SCHEME_CURRENT | Out-Null
        OK "USB Selective Suspend desactivado en plan de energia"
    }
} catch { Err "USB Selective Suspend powercfg — $_" }

# USB Selective Suspend por dispositivo (SelectiveSuspendEnabled + AllowIdleIrpInD3)
try {
    $usbDevs    = Get-PnpDevice -ErrorAction Stop | Where-Object { $_.Status -eq "OK" -and $_.Class -in @("USB","USBDevice") }
    $usbChanged = 0
    foreach ($dev in $usbDevs) {
        $base = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($dev.InstanceId)\Device Parameters"
        if (-not (Test-Path $base)) { continue }
        $cur = Get-ItemProperty $base -ErrorAction SilentlyContinue
        if ($cur.SelectiveSuspendEnabled -ne 0 -or $cur.AllowIdleIrpInD3 -ne 0) {
            Set-ItemProperty $base "SelectiveSuspendEnabled" 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty $base "AllowIdleIrpInD3"        0 -Type DWord -Force -ErrorAction SilentlyContinue
            $usbChanged++
        }
    }
    if ($usbChanged -eq 0) { Skip "USB Selective Suspend per-device: ya configurado en todos los dispositivos" }
    else                   { OK "USB Selective Suspend desactivado en $usbChanged dispositivo(s)" }
} catch { Err "USB Selective Suspend per-device — $_" }

# Adaptadores de red: desactivar ahorro de energia ("apagar este dispositivo para ahorrar energia")
try {
    $nics = Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction Stop |
            Where-Object { $_.PNPDeviceID -and $_.PNPDeviceID -match "^PCI|^USB" }
    $nicPowerChanged = 0
    foreach ($nic in $nics) {
        $powerMgmt = Get-CimInstance -Namespace "root\wmi" -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue |
                     Where-Object { $_.InstanceName -match [regex]::Escape($nic.PNPDeviceID) }
        if ($powerMgmt -and $powerMgmt.Enable) {
            Set-CimInstance -InputObject $powerMgmt -Property @{ Enable = $false } -ErrorAction SilentlyContinue
            $nicPowerChanged++
        }
    }
    if ($nicPowerChanged -eq 0) { Skip "NIC power save: ya desactivado en todos los adaptadores" }
    else { OK "Power save desactivado en $nicPowerChanged NIC(s)" }
} catch { Err "NIC power save — $_" }

# Winsock e IP stack reset + flush DNS — solo si no se ha realizado en los ultimos 30 dias
$winsockStamp = "$LogsDir\winsock-reset.stamp"
$winsockAge   = if (Test-Path $winsockStamp) { ((Get-Date) - (Get-Item $winsockStamp).LastWriteTime).TotalDays } else { 999 }
try {
    if ($winsockAge -lt 30) {
        Skip "Winsock reset: realizado hace $([math]::Round($winsockAge)) dias — omitiendo (umbral: 30 dias)"
    } else {
        netsh winsock reset  | Out-Null
        netsh int ip reset   | Out-Null
        ipconfig /flushdns   | Out-Null
        (Get-Date).ToString('o') | Set-Content $winsockStamp -Encoding UTF8
        OK "Winsock, IP stack reseteados y DNS cache limpiada (requiere reinicio)"
    }
} catch { Err "Winsock reset — $_" }

# Bindings del adaptador de red: desactivar protocolos innecesarios (conserva IPv4)
try {
    $bindingsOff     = @("ms_lldp","ms_lltdio","ms_implat","ms_rspndr","ms_server","ms_msclient","ms_pacer")
    $bindingChanged  = 0
    foreach ($b in $bindingsOff) {
        $active = Get-NetAdapterBinding -ComponentID $b -ErrorAction SilentlyContinue | Where-Object Enabled
        if ($active) {
            $active | Disable-NetAdapterBinding -ErrorAction SilentlyContinue
            $bindingChanged++
        }
    }
    if ($bindingChanged -eq 0) { Skip "Bindings de red: ya desactivados" }
    else                       { OK "Adaptador de red: $bindingChanged binding(s) desactivados (LLDP/QoS/Sharing)" }
} catch { Err "NetAdapterBinding — $_" }

# TCP timestamps: desactiva fingerprinting del uptime del sistema via RFC 1323
try {
    $tcpTs = netsh int tcp show global 2>&1 | Out-String
    if ($tcpTs -imatch "RFC 1323 Timestamps\s*:\s*disabled") {
        Skip "TCP timestamps: ya desactivados"
    } else {
        netsh int tcp set global timestamps=disabled | Out-Null
        OK "TCP timestamps desactivados (previene fingerprinting de uptime)"
    }
} catch { Err "TCP timestamps — $_" }
