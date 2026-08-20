# optwin — Windows 10/11 optimization, hardening & debloat

PowerShell script for Windows 10/11 that applies performance tuning, privacy hardening, telemetry removal, service debloat and cleanup in a single idempotent run.

## Requirements

- Windows 10 21H2+ or Windows 11
- PowerShell 7 (auto-installed if missing via `winget`)
- Run as Administrator

## Quick start

```powershell
# Run as Administrator
pwsh -ExecutionPolicy Bypass -File "$env:USERPROFILE\Scripts\optimizar-windows.ps1"

# Run specific modules only
pwsh -ExecutionPolicy Bypass -File "...\optimizar-windows.ps1" -Only 04,07

# Skip specific modules
pwsh -ExecutionPolicy Bypass -File "...\optimizar-windows.ps1" -Skip 08,09
```

## Module overview

| Module | Description |
|--------|-------------|
| `00-core.ps1` | Helpers, logging, FSM idempotency, rollback support |
| `01-safety.ps1` | System Restore point, DISM+SFC health check, PS7 bootstrap |
| `02-energy-ssd.ps1` | Power plan, SSD TRIM, sleep/hibernate tuning |
| `03-services.ps1` | Disable telemetry/Xbox/NVIDIA services; set low-value services to Manual |
| `04-telemetry.ps1` | Windows/Office/NVIDIA/browser telemetry opt-out, hosts file |
| `05-performance.ps1` | Visual effects, gaming (Game Mode, GPU priority), network stack |
| `06-interface.ps1` | Explorer tweaks, Win11 debloat, Edge hardening, accessibility |
| `07-privacy.ps1` | Privacy registry, Defender hardening, Windows Update, TLS/SCHANNEL, PS logging |
| `08-apps.ps1` | winget upgrades, AppX debloat, OneDrive removal, PS v2 disable |
| `09-cleanup.ps1` | Temp files, BleachBit integration, CleanMgr, DISM WinSxS |
| `10-scheduler.ps1` | Weekly scheduled task, background jobs, final summary, backup save |

## Key features

**Idempotency** — Every section uses SHA256-based FSM state (`logs/state.json`). Re-running the script skips already-applied sections; weekly sections re-apply automatically after 6 days to counteract Windows Update resets.

**Rollback** — Before any registry change, `Set-Reg` captures the original value into `logs/registry-backup-{timestamp}.json`. Sections 07.13/07.14 additionally export `.reg` files importable with `reg import`.

**Laptop/Desktop detection** — `$IsLaptop` flag adjusts sensor services (Manual vs Disabled) and power plan defaults.

**BleachBit integration** — If BleachBit is installed at `%LOCALAPPDATA%\BleachBit\`, module 09 delegates browser cache and temp cleanup to it, avoiding overlap with CleanMgr.

**winget app list** — `modules/apps.json` lists apps to install/upgrade. Edit this file to match your setup before first run.

## Companion: fix-habituales.ps1

Standalone troubleshooting script for common Windows issues. Runs independently from the main optimization script — no shared state, no side effects on optwin's FSM.

```powershell
# Run as Administrator — all sections
pwsh -ExecutionPolicy Bypass -File "$env:USERPROFILE\Scripts\fix-habituales.ps1"

# Run specific sections only
pwsh -ExecutionPolicy Bypass -File "...\fix-habituales.ps1" -Sections 1,3,5
```

| # | Section | Diagnostic signal | Fix |
|---|---------|-------------------|-----|
| 1 | **Bluetooth** | Adapter `Status=Error` (PnP code 10/43) | `Disable-PnpDevice` + `Enable-PnpDevice` |
| 2 | **bthserv** | Service not running | Restart service |
| 3 | **Printers / Spooler** | Files in `spool\PRINTERS` or Spooler stopped | Stop Spooler → clear queue → restart |
| 4 | **SIM / WWAN** | `WwanSvc` stopped or WWAN adapter `Status=Error` | Restart `WwanSvc`; if still failing, PnP reset |
| 5 | **DNS cache** | Always safe to flush | `Clear-DnsClientCache`; restarts `Dnscache` only if service is in error |
| 6 | **Windows Update** | Downloads older than 7 days in `SoftwareDistribution\Download` | Stop WU services → clear `SoftwareDistribution\Download` + `catroot2` → restart |
| 7 | **WSL / HNS** | `vEthernet (WSL)` adapter missing or down | Restart HNS (recreates virtual adapters for WSL and Docker) |

All fixes operate at the Windows service/PnP layer — no manufacturer-specific tools required. Hardware failures (dead adapter, unseated SIM) are reported but cannot be resolved by software.

## What it does NOT do

- No Spectre/Meltdown registry patches (Windows 11 manages this via firmware)
- No AppLocker (requires Enterprise edition)
- No SMB client signing enforcement (NAS/homelab compatibility)
- No Windows Script Host disable (breaks some vendor installers)
- VBS/HVCI left **enabled** — do not disable on modern hardware

## Customization

**Service lists** (`03-services.ps1`): `$svcDisabledList` and `$svcManualList` — add or remove services for your hardware. The script skips services that don't exist.

**App list** (`apps.json`): Remove entries you don't want installed. The script uses `winget upgrade --id` and will not install apps not already present.

**Privacy sections** (`07-privacy.ps1`): Each sub-section is independently gated by FSM. You can comment out sections (e.g., 07.13 TLS hardening) without affecting others.

## Log output

```
logs/
  optimizar-windows.log          — timestamped run log
  state.json                     — FSM idempotency state
  registry-backup-{ts}.json      — per-key rollback data
  backup-schannel-{ts}.reg       — SCHANNEL subtree export
  backup-netfx-{ts}.reg          — .NET Framework subtree export
  backup-lsa-{ts}.reg            — LSA subtree export
  backup-lanmansrv-{ts}.reg      — LanmanServer subtree export
```

## Changelog

### 2026-08-20 — systematic source-repo audit

**Registry data files — ~120 new entries across 6 files**

`privacy.json`:
- Windows AI agent controls: `DisableSettingsAgent`, `DisableAgentConnectors`, `DisableAgentWorkspaces`, `AllowCopilotRuntime=0` (`HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI`)
- AppPrivacy GPO block for newer capabilities: `LetAppsAccessMotion=2`, `LetAppsActivateWithVoice=2`, `LetAppsAccessGenerativeAI=2`, `LetAppsAccessSystemAIModels=2`
- Copilot Shell controls: `IsCopilotAvailable=0`, `IsUserEligible=0` (BingChat), `ShowCopilotNudges=0`
- Additional ConsentStore deny: `activity`, `email`, `userDataTasks`, `radios` (HKCU + HKLM)
- Autorun/Autoplay block: `NoDriveTypeAutoRun=255`, `NoAutorun=1`, `NoAutoplayfornonVolume=1`
- Recent docs: `NoRecentDocsHistory=1` (HKLM), `ClearRecentDocsOnExit=1` (HKCU)
- SettingSync disable: `DisableSettingSync=2`, `DisableSettingSyncUserOverride=1`
- InputPersonalization policies: `RestrictImplicitInkCollection` / `RestrictImplicitTextCollection` (HKCU + HKLM under `Policies`)
- Maps: `AutoDownloadAndUpdateMapData=0`, `AllowUntriggeredNetworkTrafficOnSettingsPage=0`
- HTTP language fingerprint opt-out: `HttpAcceptLanguageOptOut=1` (`HKCU:\Control Panel\International\User Profile`)

`telemetry-windows.json`:
- Extended Cortana block: PolicyManager `AllowCortana value=0`, `CortanaEnabled` / `CanCortanaBeEnabled` / `CortanaConsent` (HKCU paths), `AllowCortanaAboveLock`
- Windows Insider / Preview Builds: `EnableExperimentation=0`, `EnableConfigFlighting=0`, `AllowBuildPreview=0`, `HideInsiderPage=1`
- WER consent overrides: `DefaultConsent=0`, `DefaultOverrideBehavior=1`, `DontSendAdditionalData=1`, `LoggingDisabled=1`
- Defender reporting: `DisableGenericReports=1`, `LocalSettingOverrideSpynetReporting=0`
- CPSS Store: `AdvertisingInfo`, `InkingAndTypingPersonalization`, `ImproveInkingAndTyping` set to 0
- SearchSettings: `IsMSACloudSearchEnabled=0`, `IsAADCloudSearchEnabled=0`
- Additional: `MaxTelemetryAllowed=0` (HKCU), `LimitEnhancedDiagnosticDataWindowsAnalytics=0`, DiagTrack `ShowedToastAtLevel=1`, `InsightsEnabled=0`

`telemetry-office.json`:
- `controllerconnectedservicesenabled=2` (`HKCU:\Software\Policies\Microsoft\office\16.0\common\privacy`)
- OneNote Copilot controls: `EnableCopilotNotebooks=0`, `EnableCopilotSkittle=0`

`edge.json`:
- Edge AI policy block: `Microsoft365CopilotChatIconEnabled=0`, `BuiltInAIAPIsEnabled=0`, `AIGenThemesEnabled=0`, `DevToolsGenAiSettings=2`, `ShareBrowsingHistoryWithCopilotSearchAllowed=0`

`interface-win11debloat.json`:
- Hibernate: `HibernateEnabled=0` (Power), `ShowHibernateOption=0` (FlyoutMenuSettings)
- Lock screen notifications: `DisableLockScreenAppNotifications=1`
- Tile push notifications: `NoTileApplicationNotification=1`
- ContentDelivery master switches: `ContentDeliveryAllowed=0`, `SubscribedContentEnabled=0`, `FeatureManagementEnabled=0`, `PreInstalledAppsEverEnabled=0`, `RotatingLockScreenEnabled=0`

`performance-network.json`:
- SMB client cache tuning: `FileInfoCacheEntriesMax=1024`, `DirectoryCacheEntriesMax=1024`, `FileNotFoundCacheEntriesMax=2048` (LanmanWorkstation)
- SMB server stack: `IRPStackSize=20` (LanmanServer)

**Module 09 — new section `09.5 REGISTRO — Historial de actividad`**

Clears accumulated activity history from 11 Explorer registry keys:
`RecentDocs`, `TypedPaths`, `RunMRU`, `WordWheelQuery`, `SearchHistory`, Map Network Drive MRU, `ComDlg32` Open/Save/LastVisited (MRU + PIDL variants), Copilot/BingChat history.

Clears `UserAssist\{GUID}\Count` subkeys (tracks app launch frequency) while preserving the GUID parent structure so Windows can continue writing there.

Keys Windows requires to exist are recreated empty after deletion (`-Recreate`). Implementation follows the privacy-sexy `Remove-Item` pattern — complements the permanent value-setting approach of modules 04/06/07 by clearing history accumulated before first run.

## Sources / inspiration

- [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil) — tweaks.json
- [memstechtips/Winhance](https://github.com/memstechtips/Winhance) — privacy and interface tweaks
- [simeononsecurity/Windows-Optimize-Harden-Debloat](https://github.com/simeononsecurity/Windows-Optimize-Harden-Debloat) — SCHANNEL TLS, network hardening, PS transcription
- [undergroundwires/privacy.sexy](https://github.com/undergroundwires/privacy.sexy) — O&O ShutUp10 AI/Recall keys

## License

MIT
