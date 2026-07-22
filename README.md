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

## Sources / inspiration

- [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil) — tweaks.json
- [memstechtips/Winhance](https://github.com/memstechtips/Winhance) — privacy and interface tweaks
- [simeononsecurity/Windows-Optimize-Harden-Debloat](https://github.com/simeononsecurity/Windows-Optimize-Harden-Debloat) — SCHANNEL TLS, network hardening, PS transcription
- [undergroundwires/privacy.sexy](https://github.com/undergroundwires/privacy.sexy) — O&O ShutUp10 AI/Recall keys

## License

MIT
