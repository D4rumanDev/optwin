# ============================================================
Sep "08.1 ACTUALIZACION DE PROGRAMAS — winget upgrade"
# ============================================================

$wingetLog = "$LogsDir\winget-upgrade.log"

# Instalar App Installer (winget) si no esta disponible
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Log "winget no encontrado — intentando reparar App Installer..." "Yellow"
    try {
        $aiPkg = Get-AppxPackage -AllUsers -Name "Microsoft.DesktopAppInstaller" -ErrorAction SilentlyContinue
        if ($aiPkg) {
            Add-AppxPackage -DisableDevelopmentMode -Register "$($aiPkg.InstallLocation)\AppXManifest.xml" -ErrorAction Stop
            OK "App Installer (winget) reparado/registrado"
        } else {
            # Forzar escan de la Store para que instale App Installer
            Get-CimInstance -Namespace "root\cimv2\mdm\dmmap" `
                -ClassName "MDM_EnterpriseModernAppManagement_AppManagement01" |
                Invoke-CimMethod -MethodName UpdateScanMethod | Out-Null
            Skip "App Installer no encontrado — escan de Store iniciado. Reintentar tras reinicio"
        }
    } catch {
        Skip "App Installer no instalable automaticamente — instalar 'App Installer' desde Microsoft Store"
    }
}

$wingetExe = (Get-Command winget -ErrorAction SilentlyContinue)?.Source
if (-not $wingetExe) {
    # winget puede estar en WindowsApps sin estar en PATH de SYSTEM ni de jobs
    $wingetExe = @(
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe",
        "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe"
    ) | ForEach-Object { Resolve-Path $_ -ErrorAction SilentlyContinue } |
        Select-Object -ExpandProperty Path -First 1
}

if ($wingetExe) {
    Write-Log "winget source update..." "Cyan"
    & $wingetExe source update --disable-interactivity 2>&1 | Out-Null

    Write-Log "Detectando paquetes con actualizacion disponible..." "Cyan"
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] winget upgrade scan" |
        Add-Content -Path $wingetLog -Encoding UTF8

    $scanRaw = & $wingetExe upgrade --include-unknown --accept-source-agreements 2>&1
    $scanRaw | Add-Content -Path $wingetLog -Encoding UTF8

    # Parsear IDs desde la tabla de winget (2+ espacios separan columnas)
    # Los IDs son la única columna sin espacios internos y con al menos un punto.
    # Excluir Microsoft.PowerShell — no puede actualizarse mientras PS7 esta en ejecucion
    $upgradeIds = @(
        $scanRaw | Where-Object {
            $_ -match '\.' -and $_ -notmatch '^\s' -and
            $_ -notmatch '^Nombre|^Name|^-{3}|actualizaci|available'
        } | ForEach-Object {
            # Buscar la primera columna (sin espacios internos) que tenga formato de ID winget
            ($_ -split '\s{2,}') | Where-Object { $_ -match '^[\w][\w.\-+]+$' } | Select-Object -First 1
        } | Where-Object { $_ -and $_ -ne 'Microsoft.PowerShell' }
    )

    if ($upgradeIds.Count -eq 0) {
        Skip "winget: no hay actualizaciones disponibles"
    } else {
        Write-Log "Actualizando $($upgradeIds.Count) paquete(s)..." "Cyan"
        $wOK = 0; $wFail = 0
        foreach ($pkgId in $upgradeIds) {
            Write-Log "  -> $pkgId" "DarkGray"
            "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Actualizando: $pkgId" |
                Add-Content -Path $wingetLog -Encoding UTF8
            $r = & $wingetExe upgrade --id $pkgId --exact --silent `
                --accept-source-agreements --accept-package-agreements `
                --disable-interactivity 2>&1
            $r | Add-Content -Path $wingetLog -Encoding UTF8
            "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $pkgId — exit: $LASTEXITCODE" |
                Add-Content -Path $wingetLog -Encoding UTF8
            # -1978335212 (0x8A150054) = reboot required para completar la instalacion
            if ($LASTEXITCODE -eq 0)           { $wOK++;   OK   "  $pkgId" }
            elseif ($LASTEXITCODE -eq -1978335212) { $wOK++; Skip "  $pkgId (requiere reinicio)" }
            else                               { $wFail++; Err  "  $pkgId (exit $LASTEXITCODE)" }
        }
        if ($wFail -gt 0) {
            Err "winget upgrade — OK: $wOK | Errores: $wFail — Ver: $wingetLog"
        } else {
            OK "winget upgrade — Actualizados: $wOK paquete(s)"
        }
    }
} else {
    Skip "winget no disponible — instalar 'App Installer' desde Microsoft Store"
}

# Actualizar PowerShell 7 via tarea programada de un solo disparo (cmd.exe)
# No puede actualizarse desde PS7 en ejecucion — el installer aborta el proceso activo.
if ($wingetExe) {
    $psUpgradeCheck = & $wingetExe upgrade --id Microsoft.PowerShell --exact --accept-source-agreements 2>&1
    $psNeedsUpgrade = [bool]($psUpgradeCheck | Select-String "Microsoft.PowerShell")

    # Fallback: winget upgrade a veces no detecta la update (lag de catálogo o scope).
    # Comparar version actual con la del catalogo winget directamente.
    if (-not $psNeedsUpgrade) {
        $psShowRaw = & $wingetExe show --id Microsoft.PowerShell --exact --accept-source-agreements --source winget 2>&1
        $psLatestMatch = $psShowRaw | Select-String '7\.(\d+)\.(\d+)' | Select-Object -First 1
        if ($psLatestMatch) {
            try {
                $psLatest  = [version]$psLatestMatch.Matches[0].Value
                $psCurrent = $PSVersionTable.PSVersion
                if ($psCurrent -lt $psLatest) { $psNeedsUpgrade = $true }
            } catch {}
        }
    }

    if ($psNeedsUpgrade) {
        $psUpgradeTaskName = "PS7UpgradeOnce"
        $existingPsTask = Get-ScheduledTask -TaskName $psUpgradeTaskName -ErrorAction SilentlyContinue
        if (-not $existingPsTask) {
            $psAction = New-ScheduledTaskAction `
                -Execute "cmd.exe" `
                -Argument "/c `"$wingetExe`" upgrade --id Microsoft.PowerShell --exact --silent --accept-source-agreements --accept-package-agreements && schtasks /Delete /TN `"$psUpgradeTaskName`" /F"
            $psTrigger = New-ScheduledTaskTrigger -AtStartup
            $psPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
            Register-ScheduledTask `
                -TaskName $psUpgradeTaskName `
                -Action $psAction `
                -Trigger $psTrigger `
                -Principal $psPrincipal `
                -Force | Out-Null
            OK "PowerShell 7: actualizacion programada para el proximo arranque (via cmd.exe)"
        } else {
            Skip "PowerShell 7: tarea de actualizacion ya pendiente ($psUpgradeTaskName)"
        }
    } else {
        Skip "PowerShell 7: ya en ultima version"
    }
}

# Store CLI — CLI nativa de Windows 11 para actualizar apps de Microsoft Store
# Comando: store updates | Disponible con Windows 11 actualizado (desde feb 2026)
$storeLog = "$LogsDir\store-updates.log"
if (Get-Command store -ErrorAction SilentlyContinue) {
    Write-Log "Store CLI (store updates) iniciado en proceso independiente..." "Cyan"
    $sJob = Start-Job -Name "StoreUpdates" -ScriptBlock {
        param($logPath)
        "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] store updates iniciado" |
            Add-Content -Path $logPath -Encoding UTF8
        $result = store updates 2>&1
        $result | Out-File -FilePath $logPath -Encoding UTF8 -Append
        "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] store updates completado" |
            Add-Content -Path $logPath -Encoding UTF8
        return "completado"
    } -ArgumentList $storeLog
    $script:bgJobs += $sJob
    OK "Store CLI en background (Job: $($sJob.Id)) — Log: $storeLog"
} else {
    # Intentar reparar/actualizar Microsoft Store para obtener Store CLI
    Write-Log "Store CLI no encontrado — intentando actualizar Microsoft Store..." "Yellow"
    try {
        $storePkg = Get-AppxPackage -AllUsers -Name "Microsoft.WindowsStore" -ErrorAction SilentlyContinue
        if ($storePkg) {
            Add-AppxPackage -DisableDevelopmentMode `
                -Register "$($storePkg.InstallLocation)\AppXManifest.xml" `
                -ErrorAction SilentlyContinue
        }
        # Disparar escan de actualizaciones de la Store (instala/actualiza Store CLI si disponible)
        Get-CimInstance -Namespace "root\cimv2\mdm\dmmap" `
            -ClassName "MDM_EnterpriseModernAppManagement_AppManagement01" |
            Invoke-CimMethod -MethodName UpdateScanMethod | Out-Null
        Skip "Store CLI no instalado — Store update scan iniciado. Disponible tras actualizar la Store"
    } catch {
        Skip "Store CLI no disponible (requiere Windows 11 actualizado, feb 2026+)"
    }
}

# ============================================================
Sep "08.2 ELIMINAR BLOATWARE — AppxPackage"
# ============================================================

$bloatwareJson = Join-Path $PSScriptRoot "..\data\bloatware.json"
$bloatwareData = Get-Content $bloatwareJson -Raw | ConvertFrom-Json
$allBloatware  = $bloatwareData.bloatware.PSObject.Properties.Value | ForEach-Object { $_ }
$allWildcards  = $bloatwareData.wildcards

# Nombres exactos
$allBloatware | ForEach-Object {
    $appName = $_
    try {
        $pkg = Get-AppxPackage $appName -AllUsers -ErrorAction SilentlyContinue
        if ($pkg) {
            try {
                $pkg | Remove-AppxPackage -AllUsers -ErrorAction Stop
            } catch {
                $pkg | Remove-AppxPackage -ErrorAction Stop
            }
            Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object DisplayName -EQ $appName |
                Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
            OK "Eliminado: $appName"
        } else {
            Skip "No instalado: $appName"
        }
    } catch [System.Runtime.InteropServices.COMException] {
        Skip "$appName — proveedor Appx no disponible (Clase no registrada)"
    } catch {
        Err "$appName — $_"
    }
}

# Wildcards — patrones para apps con publisher ID variable entre versiones de Windows
# NOTA: actualizaciones mayores de Windows pueden reinstalar apps eliminadas; este bloque
# las limpia de nuevo en cada ejecucion de optwin.
$allWildcards | ForEach-Object {
    $pattern = $_
    try {
        $pkgs = Get-AppxPackage -Name $pattern -AllUsers -ErrorAction SilentlyContinue
        if ($pkgs) {
            foreach ($pkg in $pkgs) {
                try {
                    $pkg | Remove-AppxPackage -AllUsers -ErrorAction Stop
                } catch {
                    $pkg | Remove-AppxPackage -ErrorAction Stop
                }
                Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                    Where-Object DisplayName -like $pattern |
                    Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
                OK "Eliminado (wildcard): $($pkg.Name)"
            }
        } else {
            Skip "No instalado: $pattern"
        }
    } catch {
        Err "Wildcard $pattern — $_"
    }
}

# ============================================================
Sep "08.3 TAREAS PROGRAMADAS XBOX — Deshabilitar"
# ============================================================

@(
    @{ Path = "\Microsoft\XblGameSave\"; Name = "XblGameSaveTask" },
    @{ Path = "\Microsoft\XblGameSave\"; Name = "XblGameSaveTaskLogon" }
) | ForEach-Object {
    $t = $_
    try {
        $task = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
        if (-not $task) {
            Skip "Tarea no encontrada: $($t.Path)$($t.Name)"
        } elseif ($task.State -eq "Disabled") {
            Skip "Tarea ya deshabilitada: $($t.Path)$($t.Name)"
        } else {
            Disable-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction Stop | Out-Null
            OK "Tarea deshabilitada: $($t.Path)$($t.Name)"
        }
    } catch {
        Err "Tarea $($t.Path)$($t.Name) — $_"
    }
}

# Carpeta \Microsoft\Xbox\ — captura todas las tareas que pueda haber
try {
    $xboxTasks = Get-ScheduledTask -TaskPath "\Microsoft\Xbox\" -ErrorAction SilentlyContinue
    if ($xboxTasks) {
        foreach ($task in $xboxTasks) {
            if ($task.State -ne "Disabled") {
                Disable-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -ErrorAction SilentlyContinue | Out-Null
                OK "Tarea deshabilitada: $($task.TaskPath)$($task.TaskName)"
            } else {
                Skip "Tarea ya deshabilitada: $($task.TaskPath)$($task.TaskName)"
            }
        }
    } else {
        Skip "No hay tareas en \Microsoft\Xbox\"
    }
} catch {
    Skip "Carpeta \Microsoft\Xbox\ no existe en este sistema"
}

# ============================================================
Sep "08.4 ELIMINAR ONEDRIVE"
# ============================================================

$odExe     = "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe"
$odSetup64 = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
$odSetup32 = "$env:SystemRoot\System32\OneDriveSetup.exe"
$odPkg     = Get-AppxPackage "*OneDrive*" -ErrorAction SilentlyContinue

# SysWOW64\OneDriveSetup.exe siempre existe en W11 aunque OneDrive este desinstalado —
# solo comprobar si el ejecutable de usuario esta presente o hay paquete Appx activo
if (-not ((Test-Path $odExe) -or $odPkg)) {
    Skip "OneDrive no detectado — ya desinstalado o nunca presente"
} else {
    try {
        if (Get-Process OneDrive -ErrorAction SilentlyContinue) {
            taskkill /f /im OneDrive.exe 2>&1 | Out-Null
        }
        $odPath = if (Test-Path $odSetup64) { $odSetup64 } elseif (Test-Path $odSetup32) { $odSetup32 } else { $null }
        if ($odPath) {
            Start-Process $odPath "/uninstall" -NoNewWindow -Wait
            OK "OneDrive desinstalado"
        } elseif ($odPkg) {
            $odPkg | Remove-AppxPackage -ErrorAction SilentlyContinue
            OK "OneDrive (Appx) eliminado"
        } else {
            Skip "OneDrive: proceso detenido pero setup no encontrado"
        }
    } catch { Err "OneDrive removal — $_" }
}

# ============================================================
Sep "08.5 APPS REQUERIDAS — Verificar e instalar si faltan"
# ============================================================

$appsJsonPath = "$PSScriptRoot\apps.json"
$requiredApps = Get-Content $appsJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Skip "winget no disponible — se omite verificacion de apps requeridas"
} else {
    foreach ($app in $requiredApps) {
        $check = & $wingetExe list --id $app.id --exact --accept-source-agreements 2>&1
        # Buscar el ID en la salida (no depende del idioma del sistema)
        if (-not ($check | Select-String ([regex]::Escape($app.id)))) {
            Write-Log "Instalando: $($app.name)..." "Yellow"
            $result = winget install --id $app.id --exact --silent `
                --accept-source-agreements --accept-package-agreements 2>&1
            if ($LASTEXITCODE -eq 0) {
                OK "Instalado: $($app.name)"
            } else {
                $errLine = ($result | Select-String "error|failed" | Select-Object -First 1).Line
                Err "No se pudo instalar: $($app.name)$(if ($errLine) { " — $errLine" })"
            }
        } else {
            Skip "Ya instalado: $($app.name)"
        }
    }
}

# ============================================================
Sep "08.6 ANDROID PLATFORM TOOLS — adb / fastboot en C:\platform-tools"
# ============================================================

$ptDest = "C:\platform-tools"
$ptExe  = "$ptDest\adb.exe"

if (Test-Path $ptExe) {
    Skip "Android Platform Tools ya en $ptDest"
} else {
    Write-Log "Descargando Android Platform Tools en $ptDest..." "Yellow"
    $ptZip = "$env:TEMP\platform-tools-latest.zip"
    try {
        Invoke-WebRequest -Uri "https://dl.google.com/android/repository/platform-tools-latest-windows.zip" `
            -OutFile $ptZip -UseBasicParsing

        Expand-Archive -Path $ptZip -DestinationPath "$env:TEMP\pt-extract" -Force
        Remove-Item $ptZip -Force -ErrorAction SilentlyContinue

        # Verificar firma Authenticode de adb.exe antes de instalar.
        # Un zip interceptado (MITM) no puede presentar un binario firmado por Google LLC.
        $adbExtracted = "$env:TEMP\pt-extract\platform-tools\adb.exe"
        $sig = Get-AuthenticodeSignature $adbExtracted -ErrorAction SilentlyContinue
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Google') {
            Remove-Item "$env:TEMP\pt-extract" -Recurse -Force -ErrorAction SilentlyContinue
            throw "Firma no válida (status=$($sig.Status), sujeto=$($sig.SignerCertificate.Subject)) — instalación abortada"
        }

        New-Item -ItemType Directory -Path $ptDest -Force | Out-Null
        Copy-Item "$env:TEMP\pt-extract\platform-tools\*" -Destination $ptDest -Force
        Remove-Item "$env:TEMP\pt-extract" -Recurse -Force -ErrorAction SilentlyContinue

        $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
        if ($userPath -notlike "*$ptDest*") {
            [Environment]::SetEnvironmentVariable("PATH", "$ptDest;$userPath", "User")
            Write-Log "  PATH de usuario actualizado con $ptDest" "DarkGray"
        }
        OK "Android Platform Tools instalado en $ptDest — firmado por $($sig.SignerCertificate.Subject.Split(',')[0])"
    } catch {
        Err "Android Platform Tools: $_"
    }
}

# ============================================================
Sep "08.7 POWERSHELL v2 — Desactivar"
# ============================================================

# PS v2 no soporta AMSI ni ScriptBlockLogging — bypasea todas las protecciones de PS moderno
@("MicrosoftWindowsPowerShellV2Root","MicrosoftWindowsPowerShellV2") | ForEach-Object {
    $feat = $_
    try {
        $state = Get-WindowsOptionalFeature -Online -FeatureName $feat -ErrorAction Stop
        if ($state.State -eq "Disabled") {
            Skip "PS v2 ($feat): ya desactivado"
        } elseif ($state.State -eq "Enabled") {
            Disable-WindowsOptionalFeature -Online -FeatureName $feat -NoRestart -ErrorAction Stop | Out-Null
            OK "PS v2 desactivado: $feat"
        } else {
            Skip "PS v2 ($feat): estado '$($state.State)' — no aplicable"
        }
    } catch [System.ComponentModel.Win32Exception] {
        Skip "PS v2 ($feat): caracteristica no disponible en esta edicion de Windows"
    } catch {
        Err "PS v2 $feat — $_"
    }
}
