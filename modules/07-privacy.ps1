# Definicion unica de todas las claves de privacidad (07.1-07.6) para FSM
$regPrivacy = Read-DataJson "$PSScriptRoot\..\data\registry\privacy.json"

# ============================================================
Sep "07.13 SCHANNEL — TLS/SSL hardening + .NET Strong Crypto"
# ============================================================

# Backup previo de las ramas afectadas (.reg importable directamente con reg import)
$bkTs = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($bkEntry in @(
    @{ Key="HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL"; Tag="schannel" },
    @{ Key="HKLM\SOFTWARE\Microsoft\.NETFramework";                            Tag="netfx"    }
)) {
    $psPath = $bkEntry.Key -replace '^HKLM\\','HKLM:\'
    if (Test-Path $psPath) {
        $bkFile = "$LogsDir\backup-$($bkEntry.Tag)-$bkTs.reg"
        reg export $bkEntry.Key $bkFile /y 2>&1 | Out-Null
        if (Test-Path $bkFile) { Write-Log "  Backup $($bkEntry.Tag): $([System.IO.Path]::GetFileName($bkFile))" "DarkGray" }
    }
}

$tlsBase = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols"
$regTLS  = @()
foreach ($proto in @("SSL 2.0","SSL 3.0","TLS 1.0","TLS 1.1")) {
    foreach ($side in @("Server","Client")) {
        $regTLS += @{ P="$tlsBase\$proto\$side"; N="Enabled";           V=0 }
        $regTLS += @{ P="$tlsBase\$proto\$side"; N="DisabledByDefault"; V=1 }
    }
}
foreach ($proto in @("TLS 1.2","TLS 1.3")) {
    foreach ($side in @("Server","Client")) {
        $regTLS += @{ P="$tlsBase\$proto\$side"; N="Enabled";           V=1 }
        $regTLS += @{ P="$tlsBase\$proto\$side"; N="DisabledByDefault"; V=0 }
    }
}

# .NET 2.x y 4.x — ambas arquitecturas (32 y 64 bit) para que el runtime use TLS moderno
$regNETFX = @()
foreach ($ver in @("v2.0.50727","v4.0.30319")) {
    foreach ($root in @("HKLM:\SOFTWARE\Microsoft\.NETFramework","HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework")) {
        $regNETFX += @{ P="$root\$ver"; N="SchUseStrongCrypto";       V=1 }
        $regNETFX += @{ P="$root\$ver"; N="SystemDefaultTlsVersions"; V=1 }
    }
}

if (Test-SectionApplied "tls-schannel" ($regTLS + $regNETFX)) {
    Skip "SCHANNEL TLS + .NET Strong Crypto: $($regTLS.Count + $regNETFX.Count) claves — sin cambios"
} else {
    $regTLS   | ForEach-Object { Set-Reg -Path $_.P -Name $_.N -Value $_.V }
    $regNETFX | ForEach-Object { Set-Reg -Path $_.P -Name $_.N -Value $_.V }
    Set-SectionApplied "tls-schannel" ($regTLS + $regNETFX)
    OK "SCHANNEL: SSL2/3 + TLS1.0/1.1 desactivados · TLS1.2/1.3 forzados · .NET Strong Crypto ($($regTLS.Count + $regNETFX.Count) claves)"
}

# ============================================================
Sep "07.14 RED — WPAD, Zona descarga, Activacion voz, LanmanServer, NoLMHash"
# ============================================================

$bkTs2 = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($bkEntry in @(
    @{ Key="HKLM\SYSTEM\CurrentControlSet\Control\Lsa";                          Tag="lsa"       },
    @{ Key="HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters";     Tag="lanmansrv" }
)) {
    $psPath = $bkEntry.Key -replace '^HKLM\\','HKLM:\'
    if (Test-Path $psPath) {
        $bkFile = "$LogsDir\backup-$($bkEntry.Tag)-$bkTs2.reg"
        reg export $bkEntry.Key $bkFile /y 2>&1 | Out-Null
        if (Test-Path $bkFile) { Write-Log "  Backup $($bkEntry.Tag): $([System.IO.Path]::GetFileName($bkFile))" "DarkGray" }
    }
}

$regNetwork14 = @(
    # WPAD: previene MITM via Web Proxy Auto-Discovery en WiFi publico
    @{ P="HKLM:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Wpad"; N="WpadOverride"; V=1 },
    @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Wpad"; N="WpadOverride"; V=1 },
    # Zona descarga: conserva ADS :Zone.Identifier en archivos de internet para evaluacion SmartScreen
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments"; N="SaveZoneInformation"; V=2 },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments"; N="SaveZoneInformation"; V=2 },
    # Activacion por voz: Force Deny para activacion de apps en background por voz
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy"; N="LetAppsActivateWithVoice"; V=2 },
    # LanmanServer: impide enumeracion anonima de shares sin autenticacion
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"; N="RestrictNullSessAccess"; V=1 },
    # LSA: no almacenar hash LM (susceptible a rainbow tables — formato obsoleto desde Vista)
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"; N="NoLMHash"; V=1 }
)

if (Test-SectionApplied "network-hardening-14" $regNetwork14) {
    Skip "Red hardening 07.14: $($regNetwork14.Count) claves — sin cambios"
} else {
    $regNetwork14 | ForEach-Object { Set-Reg -Path $_.P -Name $_.N -Value $_.V }
    Set-SectionApplied "network-hardening-14" $regNetwork14
    OK "Red hardening 07.14: $($regNetwork14.Count) claves aplicadas"
}

# ============================================================
Sep "07.15 POWERSHELL — Transcription"
# ============================================================

$psTransDir = "C:\ProgramData\PSTranscripts"
New-Item -ItemType Directory -Path $psTransDir -Force -ErrorAction SilentlyContinue | Out-Null

$regPSTrans = @(
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription"; N="EnableTranscripting";    V=1            },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription"; N="EnableInvocationHeader"; V=1            },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription"; N="OutputDirectory";        V=$psTransDir; T="String" }
)

if (Test-SectionApplied "ps-transcription" $regPSTrans) {
    Skip "PowerShell Transcription: sin cambios"
} else {
    $regPSTrans | ForEach-Object { Set-Reg -Path $_.P -Name $_.N -Value $_.V -Type ($_.T ?? "DWord") }
    Set-SectionApplied "ps-transcription" $regPSTrans
    OK "PowerShell Transcription: activo → logs en $psTransDir"
}

# DisablePCA en HKCU rompe IShellFolder::SetNameOf (rename de carpetas en Explorer en Windows 11)
$pcaHkcu = "HKCU:\SOFTWARE\Policies\Microsoft\Windows\AppCompat"
if ((Get-ItemProperty $pcaHkcu -Name "DisablePCA" -ErrorAction SilentlyContinue).DisablePCA -eq 1) {
    try {
        Remove-ItemProperty $pcaHkcu -Name "DisablePCA" -Force -ErrorAction Stop
        OK "DisablePCA eliminado de HKCU — rename de carpetas restaurado"
    } catch { Err "Eliminar DisablePCA HKCU — $_" }
}

# Limpieza de claves legacy que bloqueaban Windows Update en versiones anteriores del script
$legacyWUKeys = @(
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; N="SetDisableUXWUAccess" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; N="DisableOSUpgrade" }
)
foreach ($key in $legacyWUKeys) {
    if (Get-ItemProperty -Path $key.P -Name $key.N -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $key.P -Name $key.N -Force
        OK "Legacy WU: eliminada clave $($key.N)"
    }
}

# ============================================================
Sep "07 PRIVACIDAD — Registro consolidado (07.1-07.6)"
# ============================================================

if (Test-SectionApplied "privacy-reg" $regPrivacy) {
    Skip "Privacidad registro: $($regPrivacy.Count) claves — sin cambios"
} else {
    $regPrivacy | ForEach-Object { Set-Reg -Path $_.P -Name $_.N -Value $_.V -Type ($_.T ?? "DWord") }
    Set-SectionApplied "privacy-reg" $regPrivacy
    OK "Privacidad registro: $($regPrivacy.Count) claves aplicadas"
}

# ============================================================
Sep "07.7 SEGURIDAD DE RED — NetBIOS, SMB y Secure Boot"
# ============================================================

# NetBIOS OFF en todas las interfaces (puede ser reseteado por WU — MaxAgeDays 6)
$netbiosRoot = "HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces"
$netbiosIfaces = Get-ChildItem $netbiosRoot -ErrorAction SilentlyContinue
if ($netbiosIfaces) {
    $netbiosHash = ($netbiosIfaces.PSChildName | Sort-Object) -join ","
    if (Test-SectionApplied "netbios-off" $netbiosHash -MaxAgeDays 6) {
        Skip "NetBIOS: desactivado — sin cambios desde hace <6 dias"
    } else {
        $changed = 0
        $netbiosIfaces | ForEach-Object {
            $cur = (Get-ItemProperty $_.PSPath -Name "NetbiosOptions" -ErrorAction SilentlyContinue).NetbiosOptions
            if ($cur -ne 2) {
                Set-ItemProperty $_.PSPath -Name "NetbiosOptions" -Value 2 -Type DWord -Force
                $changed++
            }
        }
        if ($changed -gt 0) { OK "NetBIOS desactivado en $changed interfaz(es)" }
        else                 { OK "NetBIOS: ya desactivado en todas las interfaces" }
        Set-SectionApplied "netbios-off" $netbiosHash
    }
} else { Skip "NetBIOS: no se encontraron interfaces NetBT" }

# SMB EncryptData (MaxAgeDays 30 — WU raramente lo resetea)
if (Test-SectionApplied "smb-encrypt" "EncryptData=1" -MaxAgeDays 30) {
    Skip "SMB: cifrado activado — sin cambios desde hace <30 dias"
} else {
    try {
        Set-SmbServerConfiguration -EncryptData $true -Force -ErrorAction Stop
        OK "SMB: EncryptData activado (AES-GCM)"
        Set-SectionApplied "smb-encrypt" "EncryptData=1"
    } catch { Err "SMB EncryptData — $_" }
}

# Secure Boot — solo verificar, no se puede automatizar
try {
    $sb = Confirm-SecureBootUEFI -ErrorAction Stop
    if ($sb) { OK "Secure Boot: activo" }
    else      { Skip "Secure Boot: DESACTIVADO — activar manualmente en UEFI (F2/Del al arrancar → Security/Boot)" }
} catch { Skip "Secure Boot: no verificable (VM o firmware legacy)" }

# ============================================================
Sep "07.8 ASR — Attack Surface Reduction (Windows Defender)"
# ============================================================

# Reglas elegidas por balance protección/false-positives en entorno developer:
#   9e6c...4b0  — bloquea robo de credenciales desde LSASS (Mimikatz, etc.)
#   5beb...801d — bloquea scripts ofuscados (PowerShell/JS malicioso)
#   be9b...0550 — bloquea ejecutables adjuntos en email
#   d3e0...596d — bloquea JS/VBS lanzando ejecutables descargados
#   b2b3...9ba4 — bloquea procesos sin firma desde USB
$asrRules = @(
    "9e6c4e1f-7d60-472f-ba1a-a39ef669e4b0",
    "5beb7efe-fd9a-4556-801d-275e5ffc04cc",
    "be9ba2d9-53ea-4cdc-84e5-9b1eeee46550",
    "d3e037e1-3eb8-44c8-a917-57927947596d",
    "b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4"
)
$asrActions = $asrRules | ForEach-Object { "Enabled" }

if (Test-SectionApplied "asr-rules" $asrRules -MaxAgeDays 30) {
    Skip "ASR: $($asrRules.Count) reglas — sin cambios desde hace <30 dias"
} else {
    try {
        Add-MpPreference -AttackSurfaceReductionRules_Ids $asrRules `
                         -AttackSurfaceReductionRules_Actions $asrActions `
                         -ErrorAction Stop
        OK "ASR: $($asrRules.Count) reglas activadas"
        Set-SectionApplied "asr-rules" $asrRules
    } catch { Err "ASR rules — $_" }
}

# ============================================================
Sep "07.9 HARDENING — Remote Desktop, Developer Mode, Notificaciones"
# ============================================================

# Protege contra herramientas de configuración automática (ej. WindowsDeveloperConfig)
# que habilitan RDP, Developer Mode o desactivan notificaciones de seguridad.
$regHardening09 = @(
    # RDP: rechazar conexiones entrantes (el servicio TermService queda en Manual — es normal)
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"; N="fDenyTSConnections"; V=1 },
    # Developer Mode: desactivado (permite sideload de apps sin verificación de Store)
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"; N="AllowDevelopmentWithoutDevLicense"; V=0 },
    # Do Not Disturb global: asegurar que las notificaciones de seguridad (Defender, etc.) llegan
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings"; N="NOC_GLOBAL_SETTING_TOASTS_ENABLED"; V=1 }
)

if (Test-SectionApplied "hardening-dev-config" $regHardening09) {
    Skip "Hardening dev: $($regHardening09.Count) claves — sin cambios"
} else {
    $regHardening09 | ForEach-Object { Set-Reg -Path $_.P -Name $_.N -Value $_.V -Type ($_.T ?? "DWord") }
    Set-SectionApplied "hardening-dev-config" $regHardening09
    OK "Hardening dev: $($regHardening09.Count) claves aplicadas"
}
