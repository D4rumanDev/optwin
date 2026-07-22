# ============================================================
# Definicion de grupos de registro para FSM
# ============================================================

$regInterfaceUI = Read-DataJson "$PSScriptRoot\..\data\registry\interface-ui.json"

$regWin11Debloat = Read-DataJson "$PSScriptRoot\..\data\registry\interface-win11debloat.json"

$regEdge = Read-DataJson "$PSScriptRoot\..\data\registry\edge.json"

# ============================================================
Sep "06.1 INTERFAZ — Calidad de vida y privacidad UI"
# ============================================================

$script:uiChanged = $false

# Limpiar hack de menu clasico si existe (rompia rename de carpetas en Windows 11)
$classicMenuKey = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}"
if (Test-Path $classicMenuKey) {
    try {
        Remove-Item $classicMenuKey -Recurse -Force -ErrorAction Stop
        OK "Menu clasico eliminado — rename de carpetas restaurado (reiniciar PC para aplicar)"
        $script:uiChanged = $true
    } catch { Err "Eliminar menu clasico — $_" }
}

# Limpiar DisablePCA de HKLM si existe (rompia SHChangeNotify del shell en Windows 11)
$pcaKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat"
if ((Get-ItemProperty $pcaKey -Name "DisablePCA" -ErrorAction SilentlyContinue).DisablePCA -eq 1) {
    try {
        Remove-ItemProperty $pcaKey -Name "DisablePCA" -Force -ErrorAction Stop
        OK "DisablePCA eliminado de HKLM — rename de carpetas restaurado (reiniciar PC para aplicar)"
        $script:uiChanged = $true
    } catch { Err "Eliminar DisablePCA HKLM — $_" }
}

if (Test-SectionApplied "interface-ui-reg" $regInterfaceUI) {
    Skip "Interface UI: $($regInterfaceUI.Count) claves — sin cambios"
} else {
    $regInterfaceUI | ForEach-Object { Set-Reg -Path $_.P -Name $_.N -Value $_.V -Type ($_.T ?? "DWord") }
    Set-SectionApplied "interface-ui-reg" $regInterfaceUI
    OK "Interface UI: $($regInterfaceUI.Count) claves aplicadas"
    $script:uiChanged = $true
}

# Ocultar OneDrive del panel de navegacion del Explorador (fallback si falla desinstalacion)
try {
    if (-not (Get-PSDrive -Name HKCR -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT | Out-Null
    }
    $odClsid  = "HKCR:\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}\ShellFolder"
    $odAttrib = (Get-ItemProperty $odClsid -Name "Attributes" -ErrorAction SilentlyContinue).Attributes
    $odPinned = (Get-ItemProperty $odClsid -Name "System.IsPinnedToNameSpaceTree" -ErrorAction SilentlyContinue)."System.IsPinnedToNameSpaceTree"
    if ($odAttrib -eq 0 -and $odPinned -eq 0) {
        Skip "OneDrive: ya oculto del panel de navegacion del Explorador"
    } else {
        if (-not (Test-Path $odClsid)) { New-Item $odClsid -Force | Out-Null }
        Set-ItemProperty $odClsid "Attributes"                     0 -Type DWord -Force
        Set-ItemProperty $odClsid "System.IsPinnedToNameSpaceTree" 0 -Type DWord -Force
        OK "OneDrive: oculto del panel de navegacion del Explorador (HKCR)"
        $script:uiChanged = $true
    }
} catch { Err "OneDrive HKCR nav pane — $_" }

# Quitar namespaces de Home y Gallery del Explorador
@(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}",   # Gallery (HKLM)
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}",   # Gallery (HKLM alt)
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}"    # Gallery (HKCU)
) | ForEach-Object {
    $nsPath = $_
    try {
        if (Test-Path $nsPath) {
            Remove-Item $nsPath -Recurse -Force -ErrorAction Stop
            OK "Eliminado namespace Explorer: $nsPath"
            $script:uiChanged = $true
        }
    } catch { Err "Namespace $nsPath — $_" }
}

# Ocultar carpetas del panel "Este equipo" en File Explorer
$thisPCData    = Read-DataJson "$PSScriptRoot\..\data\thispc-folders.json"
$thisPCFolders = $thisPCData | Select-Object -ExpandProperty guid
if (Test-SectionApplied "thispc-folders" $thisPCFolders) {
    Skip "Este equipo: carpetas ya ocultas — sin cambios"
} else {
    $thisPCFolders | ForEach-Object {
        Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions\$_\PropertyBag" "ThisPCPolicy" "Hide" "String"
    }
    Set-SectionApplied "thispc-folders" $thisPCFolders
    OK "Este equipo: $($thisPCFolders.Count) carpetas ocultas del panel lateral"
}

# ============================================================
Sep "06.2 WIN11DEBLOAT — Privacidad y bloatware"
# ============================================================

if (Test-SectionApplied "interface-win11debloat-reg" $regWin11Debloat) {
    Skip "Win11Debloat: $($regWin11Debloat.Count) claves — sin cambios"
} else {
    $regWin11Debloat | ForEach-Object { Set-Reg -Path $_.P -Name $_.N -Value $_.V -Type ($_.T ?? "DWord") }
    Set-SectionApplied "interface-win11debloat-reg" $regWin11Debloat
    OK "Win11Debloat: $($regWin11Debloat.Count) claves aplicadas"
    $script:uiChanged = $true
}

# Servicio AI a Manual (no es registro, fuera del bloque FSM)
Set-Svc -Name "WSAIFabricSvc" -Mode "Manual"
Set-Svc -Name "PhoneSvc"      -Mode "Manual"

# ============================================================
Sep "06.3 MICROSOFT EDGE — Politicas"
# ============================================================

if (Test-SectionApplied "interface-edge-reg" $regEdge) {
    Skip "Edge: $($regEdge.Count) claves — sin cambios"
} else {
    $regEdge | ForEach-Object { Set-Reg -Path $_.P -Name $_.N -Value $_.V -Type ($_.T ?? "DWord") }
    Set-SectionApplied "interface-edge-reg" $regEdge
    OK "Edge: $($regEdge.Count) claves aplicadas"
    $script:uiChanged = $true
}

# Reiniciar Explorer solo si hubo cambios en esta seccion
if ($script:uiChanged) {
    try {
        Stop-Process -Name explorer -Force
        OK "Explorer reiniciado para aplicar cambios de UI"
    } catch { Err "Explorer restart — $_" }
} else {
    Skip "Explorer: sin cambios en UI, reinicio omitido"
}

# ============================================================
Sep "06.4 UAC — Seguro con Secure Desktop"
# ============================================================

# UAC: habilitado con prompt en Secure Desktop — protege contra UAC bypass via auto-elevate
# ConsentPromptBehaviorAdmin=2 → siempre pide credenciales (mitiga eventvwr/fodhelper LPE)
$regUAC = @(
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; N="EnableLUA";                  V=1 },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; N="ConsentPromptBehaviorAdmin"; V=2 },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; N="PromptOnSecureDesktop";      V=1 }
)
if (Test-SectionApplied "uac-secure" $regUAC) {
    Skip "UAC: Secure Desktop ya configurado — sin cambios"
} else {
    $regUAC | ForEach-Object { Set-Reg -Path $_.P -Name $_.N -Value $_.V }
    Set-SectionApplied "uac-secure" $regUAC
    OK "UAC: Secure Desktop configurado (ConsentPromptBehaviorAdmin=2)"
}
