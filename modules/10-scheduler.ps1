# ============================================================
Sep "10.1 TAREA PROGRAMADA — Ejecucion automatica semanal"
# ============================================================

try {
    $taskName  = "WindowsOptimizer"
    $action    = New-ScheduledTaskAction `
        -Execute "pwsh.exe" `
        -Argument "-ExecutionPolicy Bypass -NonInteractive -File `"$MainScriptPath`""
    $trigger   = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 3am
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -RunOnlyIfIdle `
        -IdleDuration    (New-TimeSpan -Minutes 10) `
        -IdleWaitTimeout (New-TimeSpan -Hours 2) `
        -ExecutionTimeLimit (New-TimeSpan -Hours 3) `
        -MultipleInstances IgnoreNew

    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        # Detectar si la ruta registrada difiere de la ubicacion actual del script
        $registeredPath = $existingTask.Actions[0].Arguments -replace '^.*-File\s+"([^"]+)".*$','$1'
        $pathChanged    = $registeredPath -ne $MainScriptPath
        $needsUpdate    = $pathChanged -or (-not $existingTask.Settings.StartWhenAvailable)

        if ($needsUpdate) {
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                -Settings $settings -Principal $principal -Force | Out-Null
            if ($pathChanged) {
                OK "Tarea '$taskName': ruta actualizada ($registeredPath → $MainScriptPath)"
            } else {
                OK "Tarea '$taskName': settings actualizados (StartWhenAvailable + idle)"
            }
        } else {
            Skip "Tarea '$taskName' ya configurada y apuntando a la ruta correcta"
        }
    } else {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Force | Out-Null
        OK "Tarea '$taskName' registrada: domingos 03:00 + ejecutar si se perdio + solo en reposo"
    }
} catch { Err "Tarea programada — $_" }

# ============================================================
Sep "10.2 COMANDOS LINUX — Perfil de PowerShell 7"
# ============================================================

try {
    $ps7Profile   = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "PowerShell\profile.ps1"
    $profileMarker = "# linux-commands-v1"

    $functionBlock = @"

$profileMarker
function optwin  { Start-Process pwsh -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File ``"$MainScriptPath``"" }

# Navegacion
function ..    { Set-Location .. }
function ...   { Set-Location ..\.. }
function ....  { Set-Location ..\..\.. }
function open  { if (`$args.Count -eq 0) { Invoke-Item . } else { Invoke-Item `$args[0] } }
function reload { . `$PROFILE.CurrentUserAllHosts; Write-Host "Perfil recargado." -ForegroundColor Green }

# Sistema
function free {
    `$os = Get-CimInstance Win32_OperatingSystem
    `$total = [math]::Round(`$os.TotalVisibleMemorySize / 1MB, 2)
    `$free  = [math]::Round(`$os.FreePhysicalMemory     / 1MB, 2)
    `$used  = [math]::Round(`$total - `$free, 2)
    `$pct = [math]::Round(`$used / `$total * 100, 1)
    [PSCustomObject]@{ 'Total(GB)'=`$total; 'Usado(GB)'=`$used; 'Libre(GB)'=`$free; 'Uso%'="`$pct%" } | Format-Table -AutoSize
}
function du {
    param([string]`$Path = '.')
    `$bytes = (Get-ChildItem `$Path -Recurse -EA SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    Write-Host "`$([System.IO.Path]::GetFullPath(`$Path))  ->  `$([math]::Round(`$bytes/1MB,2)) MB  (`$([math]::Round(`$bytes/1GB,3)) GB)"
}
function ports {
    Get-NetTCPConnection -State Listen |
        Select-Object LocalAddress, LocalPort, @{N='Proceso';E={(Get-Process -Id `$_.OwningProcess -EA SilentlyContinue).Name}} |
        Sort-Object LocalPort | Format-Table -AutoSize
}
function localip {
    Get-NetIPAddress -AddressFamily IPv4 | Where-Object { `$_.IPAddress -ne '127.0.0.1' } |
        Select-Object InterfaceAlias, IPAddress | Format-Table -AutoSize
}
function path { `$env:PATH -split ';' | Where-Object { `$_ } | ForEach-Object { Write-Host `$_ } }

# Ficheros
function ls {
    `$flags = ''; `$path = '.'
    foreach (`$arg in `$args) { if (`$arg -match '^-') { `$flags = `$arg } else { `$path = `$arg } }
    `$items = Get-ChildItem -Path `$path -Force:(`$flags -match 'a') -EA SilentlyContinue
    if (`$flags -match 'l') { `$items | Format-Table Mode, LastWriteTime, @{N='Tamanio';E={if(`$_.PSIsContainer){'<DIR>'}else{`$_.Length}}}, Name -AutoSize }
    else { `$items | Format-Wide Name -AutoSize }
}
function edit {
    if (`$args.Count -eq 0) { Write-Host "Uso: edit <fichero>" -ForegroundColor Yellow } else { & `$EDITOR `$args }
}
function backup {
    param([Parameter(Mandatory,Position=0)][string]`$Path)
    `$item = Get-Item `$Path -EA Stop
    `$dest = "`$(`$item.FullName).`$(Get-Date -Format 'yyyyMMdd_HHmmss').bak"
    Copy-Item `$item.FullName `$dest
    Write-Host "Backup -> `$dest" -ForegroundColor Green
}
function mv {
    param([Parameter(Mandatory,Position=0)][string]`$Source,[Parameter(Mandatory,Position=1)][string]`$Destination)
    Move-Item -Path `$Source -Destination `$Destination
}
function rm {
    `$r=`$false;`$f=`$false;`$p=@()
    foreach(`$a in `$args){if(`$a -match '^-'){`$r=`$a -match 'r';`$f=`$a -match 'f'}else{`$p+=`$a}}
    foreach(`$x in `$p){Remove-Item `$x -Recurse:`$r -Force:`$f -EA `$(if(`$f){'SilentlyContinue'}else{'Continue'})}
}
function mkdir { foreach(`$p in `$args){New-Item -ItemType Directory -Path `$p -Force|Out-Null;Write-Host "mkdir: directorio '`$p' creado"} }
function rmdir {
    `$r=`$false;`$f=`$false;`$p=@()
    foreach(`$a in `$args){if(`$a -match '^-'){`$r=`$a -match 'r';`$f=`$a -match 'f'}else{`$p+=`$a}}
    foreach(`$x in `$p){Remove-Item `$x -Recurse:`$r -Force:`$f -EA `$(if(`$f){'SilentlyContinue'}else{'Continue'})}
}

# Utilidades
function zip {
    param([Parameter(Mandatory,Position=0)][string]`$Destino,[Parameter(Mandatory,Position=1,ValueFromRemainingArguments)][string[]]`$Origen)
    if(-not `$Destino.EndsWith('.zip')){`$Destino+='.zip'}
    Compress-Archive -Path `$Origen -DestinationPath `$Destino -Force
    Write-Host "Creado: `$Destino" -ForegroundColor Green
}
function sha256 { param([Parameter(Mandatory,Position=0)][string]`$Path) (Get-FileHash `$Path -Algorithm SHA256).Hash }
function md5    { param([Parameter(Mandatory,Position=0)][string]`$Path) (Get-FileHash `$Path -Algorithm MD5).Hash }
function wc {
    `$flags='';`$paths=@()
    foreach(`$a in `$args){if(`$a -match '^-'){`$flags=`$a}else{`$paths+=`$a}}
    foreach(`$p in `$paths){
        `$c=Get-Content `$p -EA Stop
        `$l=`$c.Count;`$w=((`$c -join ' ') -split '\s+' | Where-Object{`$_}).Count;`$ch=(`$c -join "`n").Length
        if(`$flags -match 'l'){Write-Host "`$l `$p"}elseif(`$flags -match 'w'){Write-Host "`$w `$p"}elseif(`$flags -match 'c'){Write-Host "`$ch `$p"}else{Write-Host "`$l `$w `$ch `$p"}
    }
}
"@

    if (Test-Path $ps7Profile) {
        $profileContent = Get-Content $ps7Profile -Raw -ErrorAction SilentlyContinue
        if ($profileContent -match [regex]::Escape($profileMarker)) {
            # Perfil ya tiene el bloque — comprobar si la ruta de optwin es la actual
            if ($profileContent -notmatch [regex]::Escape($MainScriptPath)) {
                $newOptwinLine = 'function optwin  { Start-Process pwsh -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"' + $MainScriptPath + '`"" }'
                $updated = $profileContent -replace 'function optwin\s+\{[^}]+\}', $newOptwinLine
                Set-Content -Path $ps7Profile -Value $updated -Encoding UTF8 -NoNewline
                OK "Perfil: función optwin actualizada con nueva ruta ($MainScriptPath)"
            } else {
                Skip "Comandos Linux ya instalados y ruta optwin correcta en $ps7Profile"
            }
        } else {
            Add-Content -Path $ps7Profile -Value $functionBlock -Encoding UTF8
            OK "Comandos Linux añadidos a $ps7Profile"
        }
    } else {
        $null = New-Item -Path $ps7Profile -ItemType File -Force
        Set-Content -Path $ps7Profile -Value $functionBlock.TrimStart() -Encoding UTF8
        OK "Creado $ps7Profile con comandos Linux"
    }
} catch { Err "Comandos Linux — $_" }

# ============================================================
Sep "10.3 BACKGROUND JOBS — Resultados de tareas async"
# ============================================================

if ($script:bgJobs.Count -gt 0) {
    Write-Log "Esperando $($script:bgJobs.Count) job(s) en background..." "Cyan"
    foreach ($job in $script:bgJobs) {
        Write-Log "  Procesando: $($job.Name) (Job $($job.Id))..." "DarkGray"
        $jobTimeout = switch ($job.Name) {
            "DISM+SFC Repair" { 1800 }  # 30 min — puede tardar en sistemas lentos
            "DismWinSxS"      { 1800 }  # 30 min — StartComponentCleanup /ResetBase
            default           { 300  }  # 5 min para el resto
        }
        try {
            $result = $job | Wait-Job -Timeout $jobTimeout | Receive-Job -ErrorAction SilentlyContinue
            if ($job.State -eq "Completed") {
                OK "$($job.Name): $result"
            } elseif ($job.State -eq "Failed") {
                $reason = $job.ChildJobs[0].JobStateInfo.Reason?.Message ?? "error desconocido"
                Err "$($job.Name) fallo: $reason"
            } else {
                Skip "$($job.Name) supero el limite (${jobTimeout}s) — revisar log especifico"
                Stop-Job $job -ErrorAction SilentlyContinue
            }
        } catch {
            Err "Job $($job.Name) — $_"
        } finally {
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
    }
} else {
    Skip "No habia jobs en background"
}

Save-RegistryBackupJson

# ============================================================
# RESUMEN FINAL
# ============================================================

$total = $script:countOK + $script:countFail + $script:countSkip
$summary = @"

╔══════════════════════════════════════════════════╗
║              RESUMEN DE EJECUCION                ║
╠══════════════════════════════════════════════════╣
║  Total cambios intentados : $($total.ToString().PadRight(19))║
║  Aplicados correctamente  : $($script:countOK.ToString().PadRight(19))║
║  Omitidos (no encontrado) : $($script:countSkip.ToString().PadRight(19))║
║  Fallidos                 : $($script:countFail.ToString().PadRight(19))║
╠══════════════════════════════════════════════════╣
║  Espacio liberado : $("$totalFreedMB MB ($totalFreedGB GB)".PadRight(29))║
╠══════════════════════════════════════════════════╣
║  Log principal  : logs\optimizar-windows.log     ║
║  Log winget     : logs\winget-upgrade.log        ║
║  Log store-cli  : logs\store-updates.log         ║
╚══════════════════════════════════════════════════╝
"@

Write-Log $summary "Cyan"
if ($script:countFail -gt 0) {
    Write-Log "Revisa el log para ver los errores." "Yellow"
}

# Verificacion final de PowerShell 7
if (Test-PwshInstalled) {
    $pwshVerFinal = (& pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null)
    OK "PowerShell 7 verificado al finalizar: v$pwshVerFinal"
} else {
    Err "PowerShell 7 NO detectado al finalizar — instalar manualmente:"
    Write-Log "  winget install Microsoft.PowerShell --accept-source-agreements --accept-package-agreements" "Red"
}
