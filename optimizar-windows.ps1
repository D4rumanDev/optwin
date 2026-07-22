#Requires -RunAsAdministrator
param(
    [string[]]$Only,   # Ejecutar solo estos módulos: -Only 03,05
    [string[]]$Skip    # Saltar estos módulos:        -Skip 04,07
)
<#
.SYNOPSIS
    Optimizacion y desactivacion de telemetria para Windows 11

.DESCRIPTION
    Aplica las siguientes optimizaciones organizadas por modulo:
      00-core.ps1        — Funciones comunes, logging, helpers, rollback
      01-safety.ps1      — Restauracion del sistema, DISM+SFC, PowerShell 7
      02-energy-ssd.ps1  — Plan de energia, SSD, energia y sleep
      03-services.ps1    — Servicios Windows, entradas de inicio
      04-telemetry.ps1   — Telemetria Windows, Office, apps, NVIDIA, Firefox, hosts
      05-performance.ps1 — Rendimiento visual, gaming, red
      06-interface.ps1   — Interfaz, Win11Debloat, Microsoft Edge
      07-privacy.ps1     — Privacidad ampliada, permisos de apps, ubicacion, Defender, WU
      08-apps.ps1        — winget upgrade, eliminar Xbox apps y OneDrive
      09-cleanup.ps1     — Limpieza de archivos temporales
      10-scheduler.ps1   — Tarea semanal, background jobs, resumen final

    Genera log en: $env:USERPROFILE\Scripts\logs\optimizar-windows.log
    Genera backup en: $env:USERPROFILE\Scripts\logs\registry-backup-{timestamp}.reg

.NOTES
    Ejecutar como Administrador:
    pwsh -ExecutionPolicy Bypass -File "$env:USERPROFILE\Scripts\optimizar-windows.ps1"
#>

# ── Bootstrap: relanzar con pwsh (PS7) si se ejecuta desde PS5 ───────────────
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    $pwsh = if ($pwshCmd) { $pwshCmd.Source } else { $null }
    if (-not $pwsh) {
        Write-Host "PowerShell 7 no encontrado. Instalando..." -ForegroundColor Yellow
        winget install --id Microsoft.PowerShell --exact --silent `
            --accept-source-agreements --accept-package-agreements
        $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
        $pwsh = if ($pwshCmd) { $pwshCmd.Source } else { $null }
    }
    if ($pwsh) {
        & $pwsh -ExecutionPolicy Bypass -File $PSCommandPath @args
        exit $LASTEXITCODE
    } else {
        Write-Host "[FAIL] No se pudo instalar PowerShell 7. Instálalo manualmente y vuelve a ejecutar." -ForegroundColor Red
        exit 1
    }
}

# Ruta del script principal — usada por el modulo del scheduler para registrar la tarea
$MainScriptPath = $PSCommandPath
$ModulesDir = "$PSScriptRoot\modules"

# ── Validar que la carpeta de módulos existe ───────────────────────────────
if (-not (Test-Path $ModulesDir -PathType Container)) {
    Write-Host "[FAIL] Carpeta de módulos no encontrada: $ModulesDir" -ForegroundColor Red
    Write-Host "Verifica que optimizar-windows.ps1 está en su ubicación correcta." -ForegroundColor Red
    exit 1
}

# Desbloquear archivos marcados como descargados de internet (Zone.Identifier)
# Necesario cuando el repo se clona desde GitHub — evita bloqueos de ExecutionPolicy
Get-ChildItem $PSScriptRoot -Recurse -ErrorAction SilentlyContinue |
    Unblock-File -ErrorAction SilentlyContinue

. "$ModulesDir\00-core.ps1"

foreach ($_mod in (Get-ChildItem "$ModulesDir\[0-9][0-9]-*.ps1" | Sort-Object Name)) {
    $_num = ($_mod.BaseName -split '-')[0]
    if ($_num -eq '00')                        { continue }
    if ($Only -and $_num -notin $Only)         { continue }
    if ($Skip -and $_num -in $Skip)            { continue }
    Write-Log "── Módulo ${_num}: $($_mod.BaseName)" "DarkGray"
    . $_mod.FullName
}
Remove-Variable _mod, _num -ErrorAction SilentlyContinue

exit 0
