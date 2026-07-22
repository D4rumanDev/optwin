# ============================================================
# 04-TELEMETRIA — Deshabilita recopilación de datos Windows/Office/NVIDIA
# ============================================================
# CAMBIOS REALIZADOS:
#   - AllowTelemetry=0: Sin recopilación de datos (Policies)
#   - HKCU Privacy: desactiva experiencias personalizadas, ID publicitario, voz
#   - Office ClientTelemetry: desactiva telemetria Office 16.0
#   - NVIDIA: NvTelemetryContainer en servicios, rutas de registro
#   - Ubicación/GPS: desactivación completa (HKLM + Services)
#   - CapabilityAccessManager: Deny para location y appDiagnostics
#
# CÓMO REVISAR CAMBIOS:
#   1. Telemetria Windows: Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name AllowTelemetry
#   2. Publicidad: Get-ItemProperty "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name Enabled
#   3. Office: Get-ItemProperty "HKCU:\SOFTWARE\Microsoft\Office\Common\ClientTelemetry" -Name DisableTelemetry
#
# ROLLBACK:
#   reg import <ScriptRoot>\logs\registry-backup-*.reg
# ============================================================

# ============================================================

$regTelemetryWindows = Read-DataJson "$PSScriptRoot\..\data\registry\telemetry-windows.json"

$regTelemetryOffice = Read-DataJson "$PSScriptRoot\..\data\registry\telemetry-office.json"

$regTelemetryApps = Read-DataJson "$PSScriptRoot\..\data\registry\telemetry-apps.json"

# ============================================================
Sep "04.1 TELEMETRIA WINDOWS — Registro"
# ============================================================

if (Test-SectionApplied "telemetry-windows-reg" $regTelemetryWindows) {
    Skip "Telemetria Windows: $($regTelemetryWindows.Count) claves — sin cambios"
} else {
    $regTelemetryWindows | ForEach-Object { Set-Reg -Path $_.P -Name $_.N -Value $_.V -Type ($_.T ?? "DWord") }
    Set-SectionApplied "telemetry-windows-reg" $regTelemetryWindows
    OK "Telemetria Windows: $($regTelemetryWindows.Count) claves aplicadas"
}

# ============================================================
Sep "04.2 TELEMETRIA — Tareas programadas"
# ============================================================

$tasks04_2 = Read-DataJson "$PSScriptRoot\..\data\tasks.json" ".telemetry_windows"

if (Test-SectionApplied "tasks-04.2" $tasks04_2 -MaxAgeDays 3) {
    Skip "Tareas telemetria: $($tasks04_2.Count) tareas — verificadas hace <3 dias"
} else {
    $tasks04_2 | ForEach-Object { Disable-Task $_ }
    Set-SectionApplied "tasks-04.2" $tasks04_2
    OK "Tareas telemetria: $($tasks04_2.Count) procesadas"
}

# ============================================================
Sep "04.3 TELEMETRIA — Microsoft Office"
# ============================================================

if (Test-SectionApplied "telemetry-office-reg" $regTelemetryOffice) {
    Skip "Telemetria Office: $($regTelemetryOffice.Count) claves — sin cambios"
} else {
    $regTelemetryOffice | ForEach-Object { Set-Reg -Path $_.P -Name $_.N -Value $_.V -Type ($_.T ?? "DWord") }
    Set-SectionApplied "telemetry-office-reg" $regTelemetryOffice
    OK "Telemetria Office: $($regTelemetryOffice.Count) claves aplicadas"
}

# Tareas programadas del agente de telemetria de Office
$tasks04_3 = Read-DataJson "$PSScriptRoot\..\data\tasks.json" ".telemetry_office"
if (Test-SectionApplied "tasks-04.3" $tasks04_3 -MaxAgeDays 7) {
    Skip "Tareas Office: verificadas hace <7 dias"
} else {
    $tasks04_3 | ForEach-Object { Disable-Task $_ }
    Set-SectionApplied "tasks-04.3" $tasks04_3
    OK "Tareas Office: $($tasks04_3.Count) procesadas"
}

# ============================================================
Sep "04.4-04.5 TELEMETRIA — PowerToys, Adobe, Chrome/Brave, Logitech, NVIDIA, Firefox, IFEO"
# ============================================================

if (Test-SectionApplied "telemetry-apps-reg" $regTelemetryApps) {
    Skip "Telemetria apps: $($regTelemetryApps.Count) claves — sin cambios"
} else {
    $regTelemetryApps | ForEach-Object { Set-Reg -Path $_.P -Name $_.N -Value $_.V -Type ($_.T ?? "DWord") }
    Set-SectionApplied "telemetry-apps-reg" $regTelemetryApps
    OK "Telemetria apps: $($regTelemetryApps.Count) claves aplicadas"
}

# ============================================================
Sep "04.6 TELEMETRIA — VS Code"
# ============================================================

$vsSettings = "$env:APPDATA\Code\User\settings.json"
try {
    if (Test-Path $vsSettings) {
        $raw = Get-Content $vsSettings -Raw -Encoding UTF8
        if ($raw -match '"telemetry\.telemetryLevel"\s*:\s*"off"') {
            Skip "VS Code: telemetry.telemetryLevel ya es off"
        } else {
            if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Trim() -eq '{}') {
                $raw = '{"telemetry.telemetryLevel": "off"}'
            } elseif ($raw -match '"telemetry\.telemetryLevel"') {
                $raw = $raw -replace '"telemetry\.telemetryLevel"\s*:\s*"[^"]*"', '"telemetry.telemetryLevel": "off"'
            } else {
                $raw = $raw -replace '(\s*\}\s*)$', ",`n    `"telemetry.telemetryLevel`": `"off`"`$1"
            }
            Set-Content $vsSettings $raw -Encoding UTF8 -NoNewline
            OK "VS Code: telemetry.telemetryLevel = off"
        }
    } else {
        '{"telemetry.telemetryLevel": "off"}' | Set-Content $vsSettings -Encoding UTF8
        OK "VS Code: telemetry.telemetryLevel = off"
    }
} catch {
    Err "VS Code settings.json — $_"
}

# ============================================================
Sep "04.9 TELEMETRIA — PowerShell 7"
# ============================================================

# Variable de entorno persistente para el usuario actual
$ps7TelCur = [System.Environment]::GetEnvironmentVariable("POWERSHELL_TELEMETRY_OPTOUT", "User")
if ($ps7TelCur -eq "1") { Skip "PowerShell 7: POWERSHELL_TELEMETRY_OPTOUT ya = 1" }
else {
    [System.Environment]::SetEnvironmentVariable("POWERSHELL_TELEMETRY_OPTOUT", "1", "User")
    OK "PowerShell 7: POWERSHELL_TELEMETRY_OPTOUT = 1"
}

# ============================================================
Sep "04.9b TELEMETRIA — dotnet CLI"
# ============================================================

$dotnetTel = [System.Environment]::GetEnvironmentVariable("DOTNET_CLI_TELEMETRY_OPTOUT", "User")
if ($dotnetTel -eq "1") { Skip "dotnet CLI: DOTNET_CLI_TELEMETRY_OPTOUT ya = 1" }
else {
    [System.Environment]::SetEnvironmentVariable("DOTNET_CLI_TELEMETRY_OPTOUT", "1", "User")
    OK "dotnet CLI: DOTNET_CLI_TELEMETRY_OPTOUT = 1"
}

# ============================================================
Sep "04.9c TELEMETRIA — GitHub CLI"
# ============================================================

if (Get-Command gh -ErrorAction SilentlyContinue) {
    $ghAnalytics = gh config get analytics 2>&1
    if ($ghAnalytics -eq "false") { Skip "GitHub CLI: analytics ya desactivados" }
    else {
        gh config set analytics false
        OK "GitHub CLI: analytics = false"
    }
} else {
    Skip "GitHub CLI: no instalado"
}

# ============================================================
Sep "04.10 TELEMETRIA — NVIDIA (tareas)"
# ============================================================

# Servicio NvTelemetryContainer ya desactivado en seccion 3
# Tareas programadas de telemetria NVIDIA
$tasks04_10 = Read-DataJson "$PSScriptRoot\..\data\tasks.json" ".telemetry_nvidia"
if (Test-SectionApplied "tasks-04.10" $tasks04_10 -MaxAgeDays 7) {
    Skip "Tareas NVIDIA: verificadas hace <7 dias"
} else {
    $tasks04_10 | ForEach-Object { Disable-Task $_ }
    Set-SectionApplied "tasks-04.10" $tasks04_10
    OK "Tareas NVIDIA: $($tasks04_10.Count) procesadas"
}

# ============================================================
Sep "04.12 PRIVACIDAD — AutoLogger ETL"
# ============================================================

# Denegar escritura de SYSTEM en el directorio de logs de diagrama de arranque
# Impide que DiagTrack/telemetria escriba logs incluso si el servicio se reactiva
try {
    $etlPath = "C:\ProgramData\Microsoft\Diagnosis\ETLLogs\AutoLogger"
    if (Test-Path $etlPath) {
        $aclOut = icacls $etlPath 2>&1 | Out-String
        if ($aclOut -imatch "SYSTEM.*Deny") {
            Skip "AutoLogger ETL: permiso SYSTEM ya denegado"
        } else {
            icacls $etlPath /deny "SYSTEM:(OI)(CI)(F)" /T /C 2>&1 | Out-Null
            OK "AutoLogger ETL: escritura de SYSTEM denegada permanentemente"
        }
    } else {
        Skip "AutoLogger ETL: directorio no encontrado ($etlPath)"
    }
} catch { Err "AutoLogger ETL icacls — $_" }

# ============================================================
Sep "04.14 PRIVACIDAD — Hosts (telemetria)"
# ============================================================

try {
    $hostsPath    = "$env:windir\System32\drivers\etc\hosts"
    $hostsContent = (Get-Content $hostsPath -Raw -ErrorAction SilentlyContinue) ?? ""

    # Parsear dominios bloqueados existentes en un HashSet para lookup O(1)
    $existingBlocked = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    ($hostsContent -split "`n") | Where-Object { $_ -match '^\s*0\.0\.0\.0\s+(\S+)' } |
        ForEach-Object { [void]$existingBlocked.Add($Matches[1]) }

    $allDomainGroups = Read-DataJson "$PSScriptRoot\..\data\telemetry-domains.json"
    $domains = $allDomainGroups.PSObject.Properties.Value | ForEach-Object { $_ }
    # M1: validar formato de dominio antes de escribir en hosts.
    # Previene inyección de entradas malformadas si el JSON es manipulado.
    $validDomainRx = '^(?!-)([A-Za-z0-9\-]{1,63}\.)+[A-Za-z]{2,}$'
    $toAdd = $domains | Select-Object -Unique |
        Where-Object { $_ -match $validDomainRx -and -not $existingBlocked.Contains($_) }
    if ($toAdd) {
        $lines = $toAdd | ForEach-Object { "0.0.0.0 $_" }
        Add-Content $hostsPath ($lines -join "`n") -Encoding UTF8
        OK "Hosts file: $($toAdd.Count) dominio(s) de telemetria bloqueados"
    } else {
        Skip "Hosts file: todos los dominios ya bloqueados ($($existingBlocked.Count))"
    }
} catch { Err "Hosts file — $_" }
