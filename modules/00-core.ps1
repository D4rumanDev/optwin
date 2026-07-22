Set-StrictMode -Off
$ErrorActionPreference = "Continue"  # Mostrar errores en lugar de silenciarlos — usar -EA SilentlyContinue casos específicos

# ── Contadores ────────────────────────────────────────────────
$script:countOK   = 0
$script:countFail = 0
$script:countSkip = 0
$script:bgJobs    = @()   # Jobs en background (winget, DISM, logs)

# ── Rutas de datos ─────────────────────────────────────────────
$LogsDir = Join-Path (Split-Path $PSScriptRoot -Parent) "logs"
New-Item -ItemType Directory -Path $LogsDir -Force -ErrorAction SilentlyContinue | Out-Null
$LogFile = "$LogsDir\optimizar-windows.log"
$script:BackupJsonFile = "$LogsDir\registry-backup-$(Get-Date -Format 'yyyy-MM-dd-HHmmss').json"
$script:BackupEntries  = [System.Collections.Generic.List[hashtable]]::new()

# ── Log a archivo y consola ───────────────────────────────────
function Write-Log {
    param([string]$msg, [string]$color = "White")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Host $msg -ForegroundColor $color
}
function OK($msg)  { $script:countOK++;   Write-Log "[OK]   $msg" "Green"  }
function Err($msg) { $script:countFail++; Write-Log "[FAIL] $msg" "Red"    }
function Skip($msg){ $script:countSkip++; Write-Log "[SKIP] $msg" "DarkGray" }
function Sep($msg) {
    $line = "=" * 60
    Write-Log "`n$line" "Cyan"
    Write-Log "  $msg"  "Cyan"
    Write-Log "$line"   "Cyan"
}

# ── Backup de registry (rollback) ──────────────────────────────
function Backup-RegistryValue {
    param([string]$Path, [string]$Name)
    try {
        if (-not (Test-Path $Path -ErrorAction SilentlyContinue)) { return }
        $cur = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        $script:BackupEntries.Add(@{
            path  = $Path
            name  = $Name
            value = if ($null -ne $cur) { $cur.$Name } else { $null }
            type  = if ($null -ne $cur) { try { (Get-Item $Path -ErrorAction SilentlyContinue).GetValueKind($Name) } catch { $null } } else { $null }
            ts    = (Get-Date -Format 'o')
        })
    } catch {
        Write-Log "  Advertencia: no se pudo leer backup de ${Path}\${Name}" "Yellow"
    }
}

function Save-RegistryBackupJson {
    if ($script:BackupEntries.Count -eq 0) { return }
    try {
        $script:BackupEntries | ConvertTo-Json -Depth 4 |
            Set-Content $script:BackupJsonFile -Encoding UTF8 -NoNewline -ErrorAction Stop
        Write-Log "  Backup registry: $([System.IO.Path]::GetFileName($script:BackupJsonFile)) ($($script:BackupEntries.Count) valores)" "DarkGray"
    } catch {
        Write-Log "  Advertencia: no se pudo guardar backup JSON: $_" "Yellow"
    }
}

# ── Helpers ───────────────────────────────────────────────────

# Aplica una clave de registro de forma segura (con backup y skip si ya correcto)
function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = "DWord")
    try {
        $keyExists = Test-Path $Path -ErrorAction SilentlyContinue
        if (-not $keyExists) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        } else {
            $cur = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
            if ($null -ne $cur) {
                $match = if ($Type -in 'DWord','QWord') { [int64]$cur -eq [int64]$Value } else { "$cur" -eq "$Value" }
                if ($match) { return }
            }
        }
        Backup-RegistryValue $Path $Name
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force -ErrorAction Stop
    } catch [System.UnauthorizedAccessException] {
        $script:countSkip++
        Write-Log "[SKIP] $Name ($Path) — protegida por Windows" "DarkGray"
    } catch [System.Security.SecurityException] {
        $script:countSkip++
        Write-Log "[SKIP] $Name ($Path) — acceso denegado por sistema" "DarkGray"
    } catch {
        Err "$Name  ($Path) — $_"
    }
}

# Parsea un fichero .reg (UTF-16 LE) y devuelve array de @{Path,Name,Value,Type}
function Get-RegOperationsFromFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    $lines   = Get-Content $Path -Encoding Unicode -ErrorAction Stop
    $ops     = [System.Collections.Generic.List[hashtable]]::new()
    $curKey  = $null
    $pending = $null

    foreach ($raw in $lines) {
        $line = if ($null -ne $pending) { $pending + $raw.TrimStart() } else { $raw }
        $pending = $null
        if ($line -match '\\$') { $pending = $line -replace '\\$',''; continue }
        if ($line -match '^\s*[;#]' -or $line -match '^\s*$') { continue }

        if ($line -match '^\[([^\]]+)\]') {
            $curKey = $Matches[1] `
                -replace '^HKEY_LOCAL_MACHINE',  'HKLM:' `
                -replace '^HKEY_CURRENT_USER',   'HKCU:' `
                -replace '^HKEY_CLASSES_ROOT',   'HKCR:' `
                -replace '^HKEY_USERS',          'HKU:'  `
                -replace '^HKEY_CURRENT_CONFIG', 'HKCC:'
            continue
        }
        if (-not $curKey) { continue }

        if ($line -match '^"([^"]+)"\s*=\s*dword:([0-9a-fA-F]+)') {
            $ops.Add(@{ Path=$curKey; Name=$Matches[1]; Value=[Convert]::ToInt32($Matches[2],16); Type='DWord' }); continue
        }
        if ($line -match '^"([^"]+)"\s*=\s*hex\(b\):([0-9a-fA-F,]+)') {
            $bytes = $Matches[2] -split ',' | ForEach-Object { [Convert]::ToByte($_,16) }
            $ops.Add(@{ Path=$curKey; Name=$Matches[1]; Value=[System.BitConverter]::ToInt64([byte[]]$bytes,0); Type='QWord' }); continue
        }
        if ($line -match '^"([^"]+)"\s*=\s*"(.*)"') {
            $ops.Add(@{ Path=$curKey; Name=$Matches[1]; Value=($Matches[2] -replace '\\\\','\\' -replace '\\"','"'); Type='String' }); continue
        }
        if ($line -match '^"([^"]+)"\s*=\s*hex\(2\):([0-9a-fA-F,\s]+)') {
            $hex=$Matches[2] -replace '\s',''; $bytes=$hex -split ',' | Where-Object {$_} | ForEach-Object {[Convert]::ToByte($_,16)}
            $ops.Add(@{ Path=$curKey; Name=$Matches[1]; Value=[System.Text.Encoding]::Unicode.GetString([byte[]]$bytes).TrimEnd("`0"); Type='ExpandString' }); continue
        }
        if ($line -match '^"([^"]+)"\s*=\s*hex\(7\):([0-9a-fA-F,\s]+)') {
            $hex=$Matches[2] -replace '\s',''; $bytes=$hex -split ',' | Where-Object {$_} | ForEach-Object {[Convert]::ToByte($_,16)}
            $ops.Add(@{ Path=$curKey; Name=$Matches[1]; Value=([System.Text.Encoding]::Unicode.GetString([byte[]]$bytes).TrimEnd("`0") -split "`0"); Type='MultiString' }); continue
        }
        if ($line -match '^"([^"]+)"\s*=\s*hex:([0-9a-fA-F,\s]+)') {
            $hex=$Matches[2] -replace '\s',''; $bytes=$hex -split ',' | Where-Object {$_} | ForEach-Object {[Convert]::ToByte($_,16)}
            $ops.Add(@{ Path=$curKey; Name=$Matches[1]; Value=[byte[]]$bytes; Type='Binary' }); continue
        }
    }
    return $ops.ToArray()
}

# Configura un servicio (Disabled / Manual)
function Set-Svc {
    param([string]$Name, [string]$Mode)
    $svc = $script:AllServices[$Name.ToLower()]
    if (-not $svc) { Skip "Servicio no encontrado: $Name"; return }
    try {
        if ("$($svc.StartType)" -eq $Mode -and $svc.Status -ne "Running") { return }
        if ($svc.Status -eq "Running") { Stop-Service -Name $Name -Force -ErrorAction Stop }
        Set-Service -Name $Name -StartupType $Mode -ErrorAction Stop
        OK "$Mode : $Name"
    } catch {
        Err "$Name — $_"
    }
}

# Desactiva una tarea programada de forma robusta
function Disable-Task {
    param([string]$FullPath)
    $leaf = [System.IO.Path]::GetFileName($FullPath)
    $dir  = [System.IO.Path]::GetDirectoryName($FullPath) + "\"
    $key  = ($dir.TrimEnd('\') + '\' + $leaf).ToLower()
    $t    = $script:AllTasks[$key]
    if (-not $t) { return }   # tarea no existe en este sistema — ignorar silenciosamente
    if ($t.State -eq 'Disabled') { return }   # ya desactivada — sin ruido
    try {
        Disable-ScheduledTask -TaskPath $dir -TaskName $leaf -ErrorAction Stop | Out-Null
        OK "Tarea desactivada: $FullPath"
    } catch {
        # Fallback: schtasks.exe funciona con tareas protegidas donde PS falla
        $tnArg = ($dir.TrimEnd('\') + '\' + $leaf) -replace '\\\\','\'
        $result = schtasks.exe /Change /TN "$tnArg" /Disable 2>&1
        if ($LASTEXITCODE -eq 0) {
            OK "Tarea desactivada (schtasks): $FullPath"
        } else {
            Skip "Tarea protegida, no se pudo desactivar: $FullPath"
        }
    }
}

# ── State Machine (FSM) ───────────────────────────────────
$script:StateFile = "$LogsDir\state.json"
$script:AppState  = if (Test-Path $script:StateFile -ErrorAction SilentlyContinue) {
    try   { Get-Content $script:StateFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -AsHashtable }
    catch { @{} }
} else { @{} }

function Get-StateHash($Data) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Data | ConvertTo-Json -Depth 10 -Compress))
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    return [System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-',''
}

function Save-AppState {
    $script:AppState | ConvertTo-Json -Depth 3 |
        Set-Content $script:StateFile -Encoding UTF8 -NoNewline -ErrorAction SilentlyContinue
}

function Test-SectionApplied([string]$Key, $Data, [int]$MaxAgeDays = 0) {
    $s = $script:AppState[$Key]
    if (-not $s -or $s.state -ne 'Applied') { return $false }
    if ($s.hash -ne (Get-StateHash $Data))  { return $false }
    if ($MaxAgeDays -gt 0 -and ((Get-Date) - [datetime]$s.ts).TotalDays -gt $MaxAgeDays) { return $false }
    return $true
}

function Set-SectionApplied([string]$Key, $Data) {
    $script:AppState[$Key] = @{
        state = 'Applied'
        hash  = Get-StateHash $Data
        ts    = (Get-Date -Format 'o')
    }
    Save-AppState
}

function Read-DataJson {
    param([string]$Path, [string]$Property = "")
    $data = Get-Content $Path -Raw | ConvertFrom-Json
    $result = if ($Property) { $data | Select-Object -ExpandProperty ($Property.TrimStart('.')) } else { $data }
    $result | ForEach-Object {
        if ($_ -is [PSCustomObject]) {
            # A2: rechazar rutas de registro fuera de los hives estándar de Windows.
            # Un JSON manipulado no puede apuntar a rutas arbitrarias del sistema de archivos.
            if ($_.P -and $_.P -notmatch '^HK(LM|CU|CR|U|CC):\\') {
                throw "Ruta de registro no permitida en '$(Split-Path $Path -Leaf)': $($_.P)"
            }
            if ($_.T -eq "Binary" -and $_.V -is [array]) {
                $_ | Add-Member -NotePropertyName V -NotePropertyValue ([byte[]]$_.V) -Force
            }
        }
        $_
    }
}

# Appx module carga via Windows PowerShell 5.1 (evita error de proxy en PS7)
Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

# ── Deteccion de tipo de equipo ───────────────────────────────
# Win32_Battery devuelve resultado solo si hay bateria (portatil/tablet)
$IsLaptop = $null -ne (Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
Write-Log "Tipo de equipo detectado: $(if ($IsLaptop) { 'PORTATIL' } else { 'ESCRITORIO' })" "Cyan"

# ── Pre-carga bulk: tareas y servicios ────────────────────────
# Una sola query al inicio → hashtable O(1) — elimina N queries WMI individuales
$script:AllTasks = @{}
Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
    $key = ($_.TaskPath.TrimEnd('\') + '\' + $_.TaskName).ToLower()
    $script:AllTasks[$key] = $_
}
$script:AllServices = @{}
Get-Service -ErrorAction SilentlyContinue | ForEach-Object {
    $script:AllServices[$_.Name.ToLower()] = $_
}
Write-Log "  Cache: $($script:AllTasks.Count) tareas, $($script:AllServices.Count) servicios" "DarkGray"

# ─────────────────────────────────────────────────────────────
Write-Log "╔══════════════════════════════════════════════════╗" "Cyan"
Write-Log "║   OPTIMIZACION WINDOWS — $(Get-Date -Format 'yyyy-MM-dd')          ║" "Cyan"
Write-Log "║   Backup JSON: $([System.IO.Path]::GetFileName($script:BackupJsonFile))       ║" "Cyan"
Write-Log "╚══════════════════════════════════════════════════╝" "Cyan"
