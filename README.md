# CitrixCheck — Automated Citrix Infrastructure Monitoring & Daily Report (PowerShell)

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue?logo=powershell&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Windows-0078d4?logo=windows&logoColor=white)
![Citrix CVAD](https://img.shields.io/badge/Citrix-CVAD%20%7C%20PVS%20%7C%20FAS%20%7C%20ADC-452170)
![License](https://img.shields.io/badge/License-MIT-22c55e)

**Version:** 1.3.0
**Author:** Ufuk Kocak
**Website:** [horizonconsulting.it](https://horizonconsulting.it)
**LinkedIn:** [linkedin.com/in/ufukkocak](https://www.linkedin.com/in/ufukkocak)

A **PowerShell automation tool** that generates a daily HTML health report for **Citrix Virtual Apps and Desktops (CVAD)** environments and delivers it by email via Windows Task Scheduler. One script, one config file, zero agents — covers your entire Citrix stack in a single consolidated report.

> Built for Citrix administrators who want **proactive, automated infrastructure monitoring** without a full SIEM or third-party monitoring platform.

## Key features

- **10 checks in one report** — DDC services, VDA health, sessions, licensing, PVS, FAS, NetScaler ADC, XenServer / Citrix Hypervisor, disk space and Event Log
- **Colour-coded HTML email** with management summary cards, status table and collapsible detail sections
- **Runs fully unattended** via Windows Task Scheduler — no manual steps after initial setup
- **Each check is standalone** — run any script independently for quick diagnostics
- **Single config file** — all servers, thresholds, credentials and email settings in `config.json`
- **Secure credential storage** — AES-256 encrypted passwords, not DPAPI-bound (works under any service account)
- **Suppression list** — suppress known issues by check name and expiry date via `suppressions.json`
- **No external agent required** — uses WinRM, Citrix PowerShell SDKs and the NetScaler NITRO REST API

---

> **DISCLAIMER — USE AT YOUR OWN RISK**
>
> This software is provided as-is, without any warranty. The author accepts no liability whatsoever for damage, data loss, service interruption or any other consequence arising from the use of this software.
> **Always test in a dedicated test environment before deploying to production.**
> See the [LICENSE](LICENSE) file for the full disclaimer.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture and file structure](#2-architecture-and-file-structure)
3. [Requirements](#3-requirements)
4. [One-time installation and configuration](#4-one-time-installation-and-configuration)
   - [Step 1 – Copy files](#step-1--copy-files)
   - [Step 2 – Fill in config.json](#step-2--fill-in-configjson)
   - [Step 3 – Run the setup script](#step-3--run-the-setup-script)
   - [Step 4 – XenServer SDK unblocking (if needed)](#step-4--xenserver-sdk-unblocking-if-needed)
5. [Manual testing](#5-manual-testing)
6. [Creating the Scheduled Task](#6-creating-the-scheduled-task)
7. [Checks — description and behaviour](#7-checks--description-and-behaviour)
8. [Report structure](#8-report-structure)
9. [Thresholds](#9-thresholds)
10. [Troubleshooting](#10-troubleshooting)
11. [Extending with new checks](#11-extending-with-new-checks)
12. [Author](#12-author)
13. [License](#13-license)

---

## 1. Overview

This solution generates a daily HTML report on the Citrix infrastructure and sends it by email. The report covers:

- Service status on all Citrix servers (DDC, StoreFront, PVS, FAS, License Server)
- VDA registration state per Delivery Group
- Session overview (active, disconnected, long-idle)
- License consumption
- Provisioning Services (PVS) — server status, vDisk versions and active devices
- Federated Authentication Service (FAS) — service status and RA certificates
- XenServer / Citrix Hypervisor — hosts, VM distribution, CPU/RAM/storage
- NetScaler (Citrix ADC) — HA status, vServers and SSL certificate expiry
- Disk space on all servers
- Event log errors and warnings (last 24 hours)

The report is sent by email and optionally saved as an HTML file.

---

## 2. Architecture and file structure

```
C:\Scripts\CitrixCheck\
├── Initialize-CitrixCheck.ps1   # One-time setup: configures all credentials and deploys FAS agents
├── Invoke-DailyReport.ps1       # Main orchestrator — runs all checks and sends the report
├── config.json                  # Configuration: servers, thresholds, email and AES credentials
├── suppressions.json            # Suppress known issues (optional)
├── smtp_key.bin                 # AES-256 key for SMTP password encryption
├── ns_key.bin                   # AES-256 key for NetScaler password encryption
├── xen_key.bin                  # AES-256 key for XenServer password encryption
├── checks\
│   ├── Check-Infrastructure.ps1 # Windows service status on all Citrix servers
│   ├── Check-VDAHealth.ps1      # VDA registration state via Citrix Broker SDK
│   ├── Check-Sessions.ps1       # Session overview via Citrix Broker SDK
│   ├── Check-LicenseUsage.ps1   # License consumption via WMI / Citrix Licensing SDK
│   ├── Check-PVS.ps1            # Provisioning Services status, vDisk versions and devices
│   ├── Check-FAS.ps1            # FAS — service status and RA certificates (JSON from FAS agent)
│   ├── Check-NetScaler.ps1      # NetScaler ADC — HA, vServers and SSL certificates
│   ├── Check-XenServer.ps1      # XenServer / Citrix Hypervisor — hosts, VMs, CPU/RAM/storage
│   ├── Check-DiskSpace.ps1      # Disk space on all Citrix servers
│   └── Check-EventLog.ps1       # Event log errors and warnings (24 hours)
├── fas-agents\
│   ├── Run-FasCertCheck.ps1          # Runs LOCALLY on each FAS server (Scheduled Task, 06:00)
│   └── Register-FasScheduledTask.ps1 # Deploys Run-FasCertCheck.ps1 and registers the task
├── logs\
│   └── DailyReport_YYYYMMDD.log      # Daily log file (created automatically)
└── reports\
    └── CitrixReport_YYYYMMDD_HHmm.html  # Saved HTML report (with -SaveReport)
```

> **Key files:** `smtp_key.bin`, `ns_key.bin` and `xen_key.bin` are created automatically by
> `Initialize-CitrixCheck.ps1`. They are tied to the script directory — keep them safe and
> move them along when relocating the script directory.

Each check script can also be run **standalone** for diagnostics:

```powershell
.\checks\Check-VDAHealth.ps1 -Verbose
.\checks\Check-FAS.ps1 -Verbose
```

---

## 3. Requirements

| Requirement | Notes |
|---|---|
| PowerShell 5.1 or higher | On the monitoring server |
| Citrix Virtual Apps and Desktops Remote PowerShell SDK | For VDA and session checks (`Citrix.Broker.Admin.V2`) |
| Citrix FAS PowerShell snap-in | On the FAS servers (`Citrix.Authentication.FederatedAuthenticationService.V1`) |
| Citrix PVS PowerShell SDK | For PVS checks (`Citrix.PVS.SnapIn`) |
| XenServer PowerShell Module | `XenServerPSModule` — installed by default with XenCenter |
| WinRM access | To all servers listed in `config.json` |
| SMTP access | To the mail relay (configured in `config.json`) |
| Service account | With Citrix Read-Only Administrator permissions or higher |

---

## 4. One-time installation and configuration

### Step 1 – Copy files

Copy the full directory to the monitoring server:

```
C:\Scripts\CitrixCheck\
```

Ensure the service account running `Invoke-DailyReport.ps1` has read access to this directory.

---

### Step 2 – Fill in config.json

Open `config.json` and verify the following fields:

- `CVAD.PrimaryController` / `FallbackController` — FQDN of the Delivery Controllers
- `LicenseServer` — FQDN of the license server
- `Servers[]` — All servers to monitor with their roles and services
- `NetScaler[]` — Management IP or hostname per ADC instance
- `XenServer.Pools[].Master` — FQDN or IP of each XenServer pool master
- `Email.To` / `Email.From` / `Email.SmtpServer` — Email delivery settings

Credentials are filled in automatically by the setup script (step 3).

---

### Step 3 – Run the setup script

All further configuration (CVAD profile, SMTP, NetScaler, XenServer) is handled by **one setup script**. Run it once interactively as the service account that will run `Invoke-DailyReport.ps1`:

```powershell
C:\Scripts\CitrixCheck\Initialize-CitrixCheck.ps1
```

The script walks through the following steps interactively — each step can be skipped individually:

| Step | What it does |
|---|---|
| 1 | Set execution policy to Bypass for the current session |
| 2 | Configure CVAD SDK on-premises authentication profile (`Set-XDCredentials -ProfileType OnPrem`) |
| 3 | Create `smtp_key.bin` + AES-256-encrypt the SMTP password + update `config.json` |
| 4 | Create `ns_key.bin` + AES-256-encrypt the NetScaler password + update `config.json` |
| 5 | Create `xen_key.bin` + AES-256-encrypt the XenServer password + update `config.json` |
| 6 | Deploy FAS agent: copies `Run-FasCertCheck.ps1` to `C:\Scripts\` on each FAS server and registers the Scheduled Task (daily at 06:00) |

> **Important:** All credentials are encrypted with AES-256 key files — not with DPAPI.
> This means decryption works **account-independently**. The key files must be present
> in the script directory (`C:\Scripts\CitrixCheck\`).

Skip individual steps using parameters:

```powershell
.\Initialize-CitrixCheck.ps1 -SkipNetScaler -SkipXenServer
.\Initialize-CitrixCheck.ps1 -SkipCVAD -SkipSMTP
.\Initialize-CitrixCheck.ps1 -SkipFasAgents
```

> **Note on CVAD SDK:** If `Set-XDCredentials` is not available (older SDK), the script automatically tries `Set-ConfigSite` as an alternative.

---

### Step 4 – XenServer SDK unblocking (if needed)

When the XenServer PowerShell module is downloaded from the internet, Windows blocks the DLL files (HRESULT 0x80131515). Run once as administrator:

```powershell
# Adjust the path to the correct module location
Get-ChildItem 'C:\Program Files\WindowsPowerShell\Modules\XenServerPSModule\' -Filter *.dll |
    Unblock-File
```

---

## 5. Manual testing

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# Full report with save
C:\Scripts\CitrixCheck\Invoke-DailyReport.ps1 -SaveReport -Verbose

# Skip specific checks
C:\Scripts\CitrixCheck\Invoke-DailyReport.ps1 -SaveReport -SkipChecks 'XenServer,EventLog'
```

After running, verify:

- **Log file:** `C:\Scripts\CitrixCheck\logs\DailyReport_<date>.log`
- **Report:** `C:\Scripts\CitrixCheck\reports\CitrixReport_<date>.html`
- **Email** received at the address configured in `config.json`

---

## 6. Creating the Scheduled Task

Run the following script once as administrator to register the task:

```powershell
$ScriptPath = 'C:\Scripts\CitrixCheck\Invoke-DailyReport.ps1'
$RunAsUser  = 'DOMAIN\svc-citrix'   # Replace with your service account
$TaskFolder = '\CitrixCheck'

$psArgs = "-NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" -SaveReport"

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs

# Trigger 1: Mon–Fri at 07:00
$t1 = New-ScheduledTaskTrigger -Weekly `
    -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday `
    -At '07:00'

# Trigger 2: Mon–Thu at 15:00
$t2 = New-ScheduledTaskTrigger -Weekly `
    -DaysOfWeek Monday,Tuesday,Wednesday,Thursday `
    -At '15:00'

# Trigger 3: Friday at 12:00
$t3 = New-ScheduledTaskTrigger -Weekly `
    -DaysOfWeek Friday `
    -At '12:00'

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
    -RunOnlyIfNetworkAvailable `
    -StartWhenAvailable

# Create task folder if it doesn't exist yet
$schedService = New-Object -ComObject 'Schedule.Service'
$schedService.Connect()
try { $schedService.GetFolder($TaskFolder) | Out-Null }
catch { $schedService.GetFolder('\').CreateFolder('CitrixCheck') | Out-Null }

$password = Read-Host "Password for $RunAsUser" -AsSecureString
$passwordPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
)

Register-ScheduledTask `
    -TaskName 'CitrixCheck - Daily Report' `
    -TaskPath $TaskFolder `
    -Action   $action `
    -Trigger  $t1, $t2, $t3 `
    -Settings $settings `
    -RunLevel Highest `
    -User     $RunAsUser `
    -Password $passwordPlain `
    -Force

Write-Host "Task created: $TaskFolder\CitrixCheck - Daily Report" -ForegroundColor Green
Write-Host "Account : $RunAsUser" -ForegroundColor Cyan
Write-Host "Triggers: Mon-Fri 07:00 | Mon-Thu 15:00 | Fri 12:00" -ForegroundColor Cyan
```

The task will then be visible in Task Scheduler under `\CitrixCheck\CitrixCheck - Daily Report`.

**Task settings (verify manually in Task Scheduler):**

| Setting | Value |
|---|---|
| Program/script | `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` |
| Arguments | `-NonInteractive -ExecutionPolicy Bypass -File C:\Scripts\CitrixCheck\Invoke-DailyReport.ps1 -SaveReport` |
| Start in | `C:\Scripts\CitrixCheck` |
| Run as | your service account |
| Run with highest privileges | Checked |
| Run whether user is logged on or not | Selected |

---

## 7. Checks — description and behaviour

| Check | Script | What is monitored |
|---|---|---|
| **Infrastructure Services** | `Check-Infrastructure.ps1` | Windows service status on DDCs, StoreFront, PVS, FAS and license server via WinRM |
| **VDA Health** | `Check-VDAHealth.ps1` | Registration state of all VDAs per Delivery Group via Citrix Broker SDK; reports unregistered and maintenance-mode machines |
| **Session Monitor** | `Check-Sessions.ps1` | Session counts (active/disconnected) per Delivery Group; flags sessions idle beyond the configured threshold |
| **License Usage** | `Check-LicenseUsage.ps1` | License consumption vs. capacity via WMI; alerts on warning and critical threshold breaches |
| **PVS** | `Check-PVS.ps1` | Server status, vDisk versions, streaming distribution and active devices on all Provisioning Services servers. Connects via SOAP (all servers tried) with WinRM fallback |
| **FAS** | `Check-FAS.ps1` | Service status (via WinRM) and RA certificate data (expiry, status, CA) from JSON written by `Run-FasCertCheck.ps1` on the FAS servers |
| **NetScaler** | `Check-NetScaler.ps1` | HA status, vServer state (LB/CS/Gateway) and SSL certificate expiry on all configured ADC instances via the NITRO REST API |
| **XenServer** | `Check-XenServer.ps1` | Host uptime, CPU and memory usage (via RRD), VM distribution per host, pool master detection and Storage Repository usage |
| **Disk Space** | `Check-DiskSpace.ps1` | Free disk space on all Citrix servers; warning and critical based on configured thresholds |
| **Event Log** | `Check-EventLog.ps1` | Errors and warnings in the System and Application event logs from the past 24 hours on all servers |

### Parameters — Invoke-DailyReport.ps1

| Parameter | Type | Description |
|---|---|---|
| `-ConfigPath` | String | Path to `config.json` (default: same directory as script) |
| `-SaveReport` | Switch | Saves the HTML report to `.\reports\` |
| `-SkipChecks` | String | Comma-separated list of checks to skip, e.g. `'XenServer,EventLog'` |

---

## 8. Report structure

The generated HTML report contains:

1. **Header** — date, environment name and overall status (green/red)
2. **Summary bar** — total checks, passed, failed
3. **Management Summary** — clickable cards per component:
   - DDC, StoreFront, Lic. Server, Lic. Usage, VDA, Sessions, PVS, FAS, NetScaler, XenServer, Disk, Events
4. **Check overview table** — one row per check with result and summary (clickable)
5. **Detail sections** — detailed HTML blocks per check, collapsible in the browser
6. **Footer** — timestamp and script version

---

## 9. Thresholds

All thresholds are configurable in `config.json` under `Thresholds`:

| Setting | Default | Description |
|---|---|---|
| `DiskSpaceWarningPercent` | 20% | Disk space warning threshold |
| `DiskSpaceCriticalPercent` | 10% | Disk space critical threshold |
| `LicenseUsageWarningPercent` | 85% | License usage warning threshold |
| `LicenseUsageCriticalPercent` | 95% | License usage critical threshold |
| `SSLCertExpiryWarningDays` | 30 days | SSL certificate expiry warning |
| `SSLCertExpiryCriticalDays` | 7 days | SSL certificate expiry critical |
| `IdleSessionWarningMinutes` | 480 min (8 h) | Idle session threshold |
| `LogonDurationWarningSeconds` | 60 sec | Logon duration warning |

XenServer thresholds are configured under `XenServer.Thresholds`:

| Setting | Default | Description |
|---|---|---|
| `CpuWarningPercent` | 80% | CPU usage warning threshold |
| `CpuCriticalPercent` | 90% | CPU usage critical threshold |
| `MemoryWarningPercent` | 85% | Memory usage warning threshold |
| `MemoryCriticalPercent` | 95% | Memory usage critical threshold |
| `StorageWarningPercent` | 80% | SR usage warning threshold |
| `StorageCriticalPercent` | 90% | SR usage critical threshold |
| `UptimeWarningDays` | 30 days | Host uptime warning (reboot recommended) |

---

## 10. Troubleshooting

### NetScaler or XenServer hangs / decryption error

**Symptom:** Checks hang or produce an error about credentials or a missing key file.

**Cause:** The key files (`ns_key.bin`, `xen_key.bin`) were created by a different account
than the one running the task, or the files are missing.

**Solution:** Re-run the setup script as the service account:

```powershell
# Run as the monitoring service account (or via runas)
C:\Scripts\CitrixCheck\Initialize-CitrixCheck.ps1 -SkipCVAD -SkipSMTP -SkipFasAgents
```

This creates new `ns_key.bin` and `xen_key.bin` and re-encrypts the credentials.

---

### VDA/Sessions connecting to Citrix Cloud instead of on-premises

**Symptom:** Error message containing `xendesktop.net` in the log file.

**Solution:** Re-run step 2 as the correct service account:

```powershell
Add-PSSnapin Citrix.Broker.Admin.V2
Set-XDCredentials -ProfileType OnPrem -StoreAs Default
```

---

### XenServer module fails to load (HRESULT 0x80131515)

**Symptom:** `Import-Module` fails with a COMException or security error.

**Solution:** Unblock the DLL files (see [Step 4 – XenServer SDK unblocking](#step-4--xenserver-sdk-unblocking-if-needed)).

---

### FAS authorisation certificates show 0

**Possible causes:**
1. FAS snap-in not loaded — verify that `Citrix.Authentication.FederatedAuthenticationService.V1` is available
2. GPO issue — the FAS service is running but has not yet been configured via GPO on the domain controllers
3. Connection error — verify WinRM access to the FAS servers

**Diagnostics:**

```powershell
Add-PSSnapin Citrix.Authentication.FederatedAuthenticationService.V1
Get-FasAuthorizationCertificate -FullCertInfo -Address <FAS-server-FQDN>
```

---

### Email is not sent

1. Verify that `smtp_key.bin` is present in the script directory
2. Verify that `Email.SmtpPassword` in `config.json` is set (no longer a placeholder)
3. Test SMTP connectivity: `Test-NetConnection -ComputerName <SmtpServer> -Port 25`
4. Check the log file for the exact error message
5. If in doubt, re-run step 3: `.\Initialize-CitrixCheck.ps1 -SkipCVAD -SkipNetScaler -SkipXenServer -SkipFasAgents`

---

### suppressions.json ParseExact error

**Symptom:** `[WARN] Could not load suppressions.json: ... String was not recognized as a valid DateTime`

**Cause:** A date in `suppressions.json` is not in `yyyy-MM-dd` format, or the file has an unexpected encoding.

**Solution:** Clear or correct the file:

```powershell
'[]' | Out-File 'C:\Scripts\CitrixCheck\suppressions.json' -Encoding UTF8
```

Valid suppression format:

```json
[
  {
    "CheckName": "XenServer Hosts",
    "Reason": "Known issue week 14 — fix planned",
    "Until": "2026-04-30"
  }
]
```

---

## 11. Extending with new checks

Every check follows the same pattern:

1. Create a new script `checks\Check-NewCheck.ps1` with a function `Invoke-NewCheck`
2. The function accepts `-Config [PSCustomObject]` and returns a `[PSCustomObject]` with properties:
   - `CheckName`, `SectionHtml`, `HasIssues`, `IssueCount`, `Summary`, `Duration`, `Error`
3. Add the check to `$checkDefs` in `Invoke-DailyReport.ps1`:

```powershell
[PSCustomObject]@{ Key = 'NewCheck'; Script = 'Check-NewCheck.ps1'; Function = 'Invoke-NewCheck' }
```

4. Optionally add a management summary card in the `$mgmtSummaryHtml` section

The check is then automatically included in the daily report and can be run standalone.

---

## 12. Author

**Ufuk Kocak**
Horizon IT Consulting
Website: [horizonconsulting.it](https://horizonconsulting.it)
LinkedIn: [linkedin.com/in/ufukkocak](https://www.linkedin.com/in/ufukkocak)

---

## 13. License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.

You are free to use, modify and distribute this project in any environment, including commercial, as long as the original copyright notice is retained.

---

*CitrixCheck is an open-source project. Contributions and issue reports are welcome via GitHub.*

*Built with the help of modern automation and AI-assisted scripting.*
