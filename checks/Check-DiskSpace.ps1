#Requires -Version 5.1
<#
.SYNOPSIS
    Disk space monitoring check for all Citrix infrastructure servers.

.DESCRIPTION
    Connects to each server defined in config.json via CIM (WinRM) and retrieves
    disk usage for all fixed local drives (DriveType 3). Reports free space as a
    percentage and absolute GB value, and raises a warning or critical flag when
    thresholds defined in config.json are exceeded.

    Can be run standalone or dot-sourced by Invoke-DailyReport.ps1.

.PARAMETER Config
    PSCustomObject parsed from config.json. When omitted the script loads config.json
    from its own parent directory (standalone mode).

.EXAMPLE
    PS C:\> .\checks\Check-DiskSpace.ps1
    Runs the check standalone and prints the result summary to the console.

.EXAMPLE
    # Used by the master orchestrator:
    . .\checks\Check-DiskSpace.ps1
    $result = Invoke-DiskSpaceCheck -Config $config

.INPUTS
    None. All input comes from config.json or the -Config parameter.

.OUTPUTS
    [PSCustomObject] with properties:
        CheckName   [string]  - Display name of this check.
        SectionHtml [string]  - HTML fragment to embed in the daily report.
        HasIssues   [bool]    - $true when any drive breaches the warning threshold.
        IssueCount  [int]     - Number of drives that breached a threshold.
        Summary     [string]  - One-line plain-text summary.
        Duration    [string]  - Elapsed time formatted as "X.Xs".
        Error       [string]  - Error message if the check itself failed, else $null.

.NOTES
    Author:     Ufuk Kocak
    Website:    https://horizonconsulting.it
    LinkedIn:   https://www.linkedin.com/in/ufukkocak
    Created:    2026-03-15
    Version:    1.0.0

    Changelog:
        1.0.0 - 2026-03-15 - Initial release.

    Requirements:
        - PowerShell 5.1 or higher.
        - WinRM / CIM access to all servers listed in config.json.
        - Permissions to query Win32_LogicalDisk via WMI (default admin share access).

    Thresholds:
        Warning  - Config.Thresholds.DiskSpaceWarningPercent  (default: 20% free)
        Critical - Config.Thresholds.DiskSpaceCriticalPercent (default: 10% free)

    Scheduling:
        Run daily via Windows Task Scheduler or call through Invoke-DailyReport.ps1.
#>

# =============================================================================
# Exported function
# =============================================================================
function Invoke-DiskSpaceCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $stopwatch    = [System.Diagnostics.Stopwatch]::StartNew()
    $checkName    = 'Disk Space'
    $warnPct      = if ($Config.Thresholds.DiskSpaceWarningPercent)  { $Config.Thresholds.DiskSpaceWarningPercent  } else { 20 }
    $critPct      = if ($Config.Thresholds.DiskSpaceCriticalPercent) { $Config.Thresholds.DiskSpaceCriticalPercent } else { 10 }
    $driveFilter  = if ($Config.PSObject.Properties['DiskDriveFilter'] -and $Config.DiskDriveFilter) { [string[]]$Config.DiskDriveFilter } else { @('C:', 'D:') }

    try {
        $serverResults = [System.Collections.Generic.List[PSCustomObject]]::new()
        $totalIssues   = 0

        foreach ($server in $Config.Servers) {
            Write-Verbose "Querying disk space: $($server.Name)"

            # Per-server override takes priority over the global filter
            $effectiveDriveFilter = if ($server.PSObject.Properties['DiskDriveFilter'] -and $server.DiskDriveFilter) { [string[]]$server.DiskDriveFilter } else { $driveFilter }

            $reachable = Test-Connection -ComputerName $server.Name -Count 1 -Quiet -ErrorAction SilentlyContinue
            $drives    = [System.Collections.Generic.List[PSCustomObject]]::new()

            if ($reachable) {
                try {
                    $diskObjs = Get-CimInstance -ClassName Win32_LogicalDisk `
                                    -ComputerName $server.Name `
                                    -Filter "DriveType = 3" `
                                    -ErrorAction Stop |
                                Where-Object { $_.DeviceID -in $effectiveDriveFilter }

                    foreach ($disk in $diskObjs) {
                        $totalGB  = [math]::Round($disk.Size        / 1GB, 1)
                        $freeGB   = [math]::Round($disk.FreeSpace   / 1GB, 1)
                        $usedGB   = [math]::Round(($disk.Size - $disk.FreeSpace) / 1GB, 1)
                        $freePct  = if ($disk.Size -gt 0) { [math]::Round(($disk.FreeSpace / $disk.Size) * 100) } else { 0 }
                        $severity = if ($freePct -le $critPct) { 'CRITICAL' } elseif ($freePct -le $warnPct) { 'WARNING' } else { 'OK' }

                        if ($severity -ne 'OK') { $totalIssues++ }

                        $drives.Add([PSCustomObject]@{
                            Drive    = $disk.DeviceID
                            TotalGB  = $totalGB
                            UsedGB   = $usedGB
                            FreeGB   = $freeGB
                            FreePct  = $freePct
                            Severity = $severity
                        })
                    }
                }
                catch {
                    $totalIssues++
                    $drives.Add([PSCustomObject]@{
                        Drive    = 'ERROR'
                        TotalGB  = 0
                        UsedGB   = 0
                        FreeGB   = 0
                        FreePct  = 0
                        Severity = 'ERROR'
                        Error    = $_.Exception.Message
                    })
                }
            }
            else {
                $totalIssues++
            }

            $serverResults.Add([PSCustomObject]@{
                Name      = $server.Name
                Role      = $server.Role
                Reachable = $reachable
                Drives    = $drives
            })
        }

        $stopwatch.Stop()

        return [PSCustomObject]@{
            CheckName   = $checkName
            SectionHtml = _BuildDiskHtml -ServerResults $serverResults -WarnPct $warnPct -CritPct $critPct
            HasIssues   = ($totalIssues -gt 0)
            IssueCount  = $totalIssues
            Summary     = "$($Config.Servers.Count) server(s) checked - $totalIssues drive(s) below threshold"
            Duration    = "$([math]::Round($stopwatch.Elapsed.TotalSeconds,1))s"
            Error       = $null
        }
    }
    catch {
        $stopwatch.Stop()
        return [PSCustomObject]@{
            CheckName   = $checkName
            SectionHtml = _BuildErrorHtml -CheckName $checkName -Message $_.Exception.Message
            HasIssues   = $true
            IssueCount  = 1
            Summary     = "Check failed: $($_.Exception.Message)"
            Duration    = "$([math]::Round($stopwatch.Elapsed.TotalSeconds,1))s"
            Error       = $_.Exception.Message
        }
    }
}

# =============================================================================
# Private helpers
# =============================================================================
function _BuildDiskHtml {
    param(
        [array]$ServerResults,
        [int]$WarnPct,
        [int]$CritPct
    )

    $hasIssues   = $ServerResults | Where-Object { -not $_.Reachable -or ($_.Drives | Where-Object { $_.Severity -ne 'OK' }) }
    $badgeColour = if ($hasIssues) { '#e74c3c' } else { '#27ae60' }
    $badgeText   = if ($hasIssues) { 'ISSUES FOUND' } else { 'ALL OK' }

    $serverBlocks = foreach ($srv in $ServerResults) {
        $reachIcon  = if ($srv.Reachable) { '&#10003;' } else { '&#10007;' }
        $reachColor = if ($srv.Reachable) { '#27ae60'  } else { '#e74c3c'  }
        $reachText  = if ($srv.Reachable) { 'Reachable' } else { 'UNREACHABLE' }

        $driveRows = ''
        if ($srv.Reachable -and $srv.Drives.Count -gt 0) {
            $driveRows = foreach ($d in ($srv.Drives | Sort-Object Drive)) {
                if ($d.Drive -eq 'ERROR') {
                    "<tr><td colspan='5' style='padding:7px 12px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#e74c3c'>Query failed: $($d.Error)</td></tr>"
                    continue
                }
                $usedPct   = 100 - $d.FreePct
                $barColour = switch ($d.Severity) {
                    'CRITICAL' { '#e74c3c' }
                    'WARNING'  { '#f39c12' }
                    default    { '#27ae60' }
                }
                $rowBg = switch ($d.Severity) {
                    'CRITICAL' { '#fff5f5' }
                    'WARNING'  { '#fffdf0' }
                    default    { '' }
                }
                @"
                <tr style='background:$rowBg'>
                  <td style='padding:7px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;font-weight:600'>$($d.Drive)</td>
                  <td style='padding:7px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;text-align:right'>$($d.TotalGB) GB</td>
                  <td style='padding:7px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;text-align:right'>$($d.UsedGB) GB</td>
                  <td style='padding:7px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;text-align:right;color:$barColour;font-weight:bold'>$($d.FreeGB) GB ($($d.FreePct)%)</td>
                  <td style='padding:7px 12px;border-bottom:1px solid #f0f0f0;width:200px'>
                    <div style='background:#ecf0f1;border-radius:4px;height:10px'>
                      <div style='width:$usedPct%;background:$barColour;height:10px;border-radius:4px'></div>
                    </div>
                  </td>
                </tr>
"@
            }
        }

        @"
      <div style='margin-bottom:16px;border:1px solid #dde1e7;border-radius:6px;overflow:hidden'>
        <div style='background:#2c3e50;color:#fff;padding:9px 14px;display:flex;justify-content:space-between;align-items:center'>
          <span style='font-size:14px;font-weight:600'>$($srv.Name)</span>
          <span style='font-size:11px;background:#34495e;padding:2px 9px;border-radius:10px'>$($srv.Role)</span>
        </div>
        <div style='padding:4px 12px;font-size:12px;background:#f8f9fa;border-bottom:1px solid #eee'>
          Reachability: <span style='color:$reachColor;font-weight:bold'>$reachIcon $reachText</span>
        </div>
        $(if ($srv.Reachable -and $srv.Drives.Count -gt 0) {
            "<table style='width:100%;border-collapse:collapse'>
              <thead><tr style='background:#f4f6f8'>
                <th style='padding:7px 12px;text-align:left;color:#555;font-size:12px;font-weight:600'>Drive</th>
                <th style='padding:7px 12px;text-align:right;color:#555;font-size:12px;font-weight:600'>Total</th>
                <th style='padding:7px 12px;text-align:right;color:#555;font-size:12px;font-weight:600'>Used</th>
                <th style='padding:7px 12px;text-align:right;color:#555;font-size:12px;font-weight:600'>Free</th>
                <th style='padding:7px 12px;text-align:left;color:#555;font-size:12px;font-weight:600'>Usage</th>
              </tr></thead>
              <tbody>$driveRows</tbody>
            </table>"
        })
      </div>
"@
    }

    return @"
<div style='margin-bottom:24px;background:#fff;border-radius:6px;border:1px solid #dde1e7;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.06)'>
  <div style='background:#2c3e50;color:#fff;padding:12px 18px;display:flex;justify-content:space-between;align-items:center'>
    <span style='font-size:16px;font-weight:700'>&#128190; Disk Space</span>
    <span style='font-size:12px;background:$badgeColour;padding:4px 12px;border-radius:12px;font-weight:700'>$badgeText</span>
  </div>
  <div style='padding:4px 16px;font-size:11px;color:#777;background:#f8f9fa;border-bottom:1px solid #eee'>
    <span style='color:#f39c12'>&#9650; Warning below $WarnPct% free</span> &nbsp;
    <span style='color:#e74c3c'>&#9650; Critical below $CritPct% free</span>
  </div>
  <div style='padding:16px'>
    $serverBlocks
  </div>
</div>
"@
}

function _BuildErrorHtml {
    param([string]$CheckName, [string]$Message)
    return @"
<div style='margin-bottom:24px;background:#fff;border-radius:6px;border:1px solid #e74c3c;overflow:hidden'>
  <div style='background:#e74c3c;color:#fff;padding:12px 18px;font-size:16px;font-weight:700'>&#9888; $CheckName - Check Failed</div>
  <div style='padding:16px;color:#c0392b;font-size:13px'>$Message</div>
</div>
"@
}

# =============================================================================
# Standalone entry point
# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {
    $scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
    $configPath = Join-Path (Split-Path $scriptDir) 'config.json'
    if (-not (Test-Path $configPath)) {
        Write-Error "config.json not found at: $configPath"
        exit 1
    }
    $cfg    = Get-Content $configPath -Raw | ConvertFrom-Json
    $result = Invoke-DiskSpaceCheck -Config $cfg -Verbose
    Write-Host "`n[$($result.CheckName)] $($result.Summary) | Duration: $($result.Duration)" -ForegroundColor $(if ($result.HasIssues) { 'Red' } else { 'Green' })
}

