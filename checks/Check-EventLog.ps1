#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Event Log error and warning check for all Citrix infrastructure servers.

.DESCRIPTION
    Connects to each server defined in config.json via WinRM and queries the
    Application and System event logs for Error and Warning entries generated
    in the last 24 hours. Filters results to Citrix-related event sources and
    a set of other relevant Windows sources (Service Control Manager, DNS, etc.)
    and returns a consolidated HTML report section.

    Can be run standalone or dot-sourced by Invoke-DailyReport.ps1.

.PARAMETER Config
    PSCustomObject parsed from config.json. When omitted the script loads config.json
    from its own parent directory (standalone mode).

.PARAMETER HoursBack
    How many hours back to scan the event logs. Default: 24.

.EXAMPLE
    PS C:\> .\checks\Check-EventLog.ps1
    Runs the check for the last 24 hours on all configured servers.

.EXAMPLE
    PS C:\> .\checks\Check-EventLog.ps1 -HoursBack 48
    Scans the last 48 hours instead.

.EXAMPLE
    # Used by the master orchestrator:
    . .\checks\Check-EventLog.ps1
    $result = Invoke-EventLogCheck -Config $config

.INPUTS
    None. All input comes from config.json or the -Config parameter.

.OUTPUTS
    [PSCustomObject] with properties:
        CheckName   [string]  - Display name of this check.
        SectionHtml [string]  - HTML fragment to embed in the daily report.
        HasIssues   [bool]    - $true when Error-level events are found.
        IssueCount  [int]     - Total number of Error-level events across all servers.
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
        - WinRM access to all servers listed in config.json.
        - Permissions to read remote event logs (Event Log Readers group or admin).

    Event sources monitored:
        Citrix*                                           - all Citrix-prefixed sources
            (except 'Citrix Director Service' — excluded, generates unrelated noise)
        Service Control Manager                           - only events whose message
                                                            contains 'Citrix' (filters
                                                            non-Citrix service failures)
        Microsoft-Windows-TerminalServices-RemoteConnectionManager
        Microsoft-Windows-TerminalServices-LocalSessionManager
        Microsoft-Windows-GroupPolicy
        Microsoft-Windows-Security-SPP                    - Windows licensing
        Disk, volmgr, NTFS                                - storage errors

    Scheduling:
        Run daily via Windows Task Scheduler or call through Invoke-DailyReport.ps1.
#>

# =============================================================================
# Exported function
# =============================================================================
function Invoke-EventLogCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter()]
        [int]$HoursBack = 24
    )

    $stopwatch  = [System.Diagnostics.Stopwatch]::StartNew()
    $checkName  = 'Event Log'
    $since      = (Get-Date).AddHours(-$HoursBack)

    # Sources we care about (supports wildcards)
    $relevantSources = @(
        'Citrix*',
        'Service Control Manager',
        'Microsoft-Windows-TerminalServices-RemoteConnectionManager',
        'Microsoft-Windows-TerminalServices-LocalSessionManager',
        'Microsoft-Windows-GroupPolicy',
        'Microsoft-Windows-Security-SPP',
        'Disk',
        'volmgr',
        'NTFS'
    )

    try {
        $serverResults = [System.Collections.Generic.List[PSCustomObject]]::new()
        $totalErrors   = 0

        foreach ($server in $Config.Servers) {
            Write-Verbose "Querying event logs: $($server.Name)"

            $reachable = Test-Connection -ComputerName $server.Name -Count 1 -Quiet -ErrorAction SilentlyContinue
            $events    = [System.Collections.Generic.List[PSCustomObject]]::new()

            if ($reachable) {
                foreach ($log in @('Application', 'System')) {
                    try {
                        $rawEvents = Get-WinEvent -ComputerName $server.Name -FilterHashtable @{
                            LogName   = $log
                            Level     = @(1, 2)       # Critical=1, Error=2
                            StartTime = $since
                        } -ErrorAction SilentlyContinue

                        if ($rawEvents) {
                            foreach ($ev in $rawEvents) {
                                # Filter to relevant sources only
                                $match = $false
                                foreach ($src in $relevantSources) {
                                    if ($ev.ProviderName -like $src) { $match = $true; break }
                                }
                                if (-not $match) { continue }

                                # Citrix Director Service genereert veel ruis die niet aan
                                # Citrix-infrastructuur gerelateerd is — volledig uitsluiten.
                                if ($ev.ProviderName -eq 'Citrix Director Service') { continue }

                                # Service Control Manager alleen tonen als het bericht
                                # een Citrix-service betreft.
                                if ($ev.ProviderName -eq 'Service Control Manager' -and
                                    $ev.Message -notlike '*Citrix*') { continue }

                                $levelText = switch ($ev.Level) {
                                    1 { 'CRITICAL' }
                                    2 { 'ERROR'    }
                                    3 { 'WARNING'  }
                                    default { 'INFO' }
                                }
                                if ($levelText -in @('CRITICAL','ERROR')) { $totalErrors++ }

                                # Truncate long messages
                                $msg = $ev.Message -replace '\r\n|\n', ' '
                                if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '...' }

                                $events.Add([PSCustomObject]@{
                                    TimeCreated = $ev.TimeCreated
                                    Log         = $log
                                    Level       = $levelText
                                    Source      = $ev.ProviderName
                                    EventId     = $ev.Id
                                    Message     = $msg
                                })
                            }
                        }
                    }
                    catch {
                        Write-Verbose "  Could not query $log on $($server.Name): $($_.Exception.Message)"
                    }
                }
            }
            else {
                $totalErrors++
            }

            # Sort newest first, cap at 50 events per server to keep email size manageable
            $sortedEvents = $events | Sort-Object TimeCreated -Descending | Select-Object -First 50

            $serverResults.Add([PSCustomObject]@{
                Name      = $server.Name
                Role      = $server.Role
                Reachable = $reachable
                Events    = @($sortedEvents)
                ErrorCount   = @($sortedEvents | Where-Object { $_.Level -in @('CRITICAL','ERROR')   }).Count
                WarningCount = @($sortedEvents | Where-Object { $_.Level -eq 'WARNING' }).Count
            })
        }

        $stopwatch.Stop()

        return [PSCustomObject]@{
            CheckName   = $checkName
            SectionHtml = _BuildEventLogHtml -ServerResults $serverResults -HoursBack $HoursBack
            HasIssues   = ($totalErrors -gt 0)
            IssueCount  = $totalErrors
            Summary     = "$($Config.Servers.Count) server(s) scanned (last $HoursBack h) - $totalErrors error/critical event(s)"
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
function _BuildEventLogHtml {
    param(
        [array]$ServerResults,
        [int]$HoursBack
    )

    $totalErrors   = ($ServerResults | Measure-Object -Property ErrorCount   -Sum).Sum
    $totalWarnings = ($ServerResults | Measure-Object -Property WarningCount -Sum).Sum
    $badgeColour   = if ($totalErrors -gt 0) { '#e74c3c' } elseif ($totalWarnings -gt 0) { '#f39c12' } else { '#27ae60' }
    $badgeText     = if ($totalErrors -gt 0) { "ERRORS ($totalErrors)" } elseif ($totalWarnings -gt 0) { "WARNINGS ($totalWarnings)" } else { 'ALL CLEAN' }

    $serverBlocks = foreach ($srv in $ServerResults) {
        $reachIcon  = if ($srv.Reachable) { '&#10003;' } else { '&#10007;' }
        $srvBadge   = if ($srv.ErrorCount -gt 0) { "<span style='background:#e74c3c;color:#fff;font-size:11px;padding:2px 8px;border-radius:10px;margin-left:8px'>$($srv.ErrorCount) error(s)</span>" } `
                      elseif ($srv.WarningCount -gt 0) { "<span style='background:#f39c12;color:#fff;font-size:11px;padding:2px 8px;border-radius:10px;margin-left:8px'>$($srv.WarningCount) warning(s)</span>" } `
                      else { "<span style='background:#27ae60;color:#fff;font-size:11px;padding:2px 8px;border-radius:10px;margin-left:8px'>Clean</span>" }

        $eventRows = ''
        if ($srv.Reachable -and @($srv.Events).Count -gt 0) {
            $eventRows = foreach ($ev in $srv.Events) {
                $lvlColor = switch ($ev.Level) {
                    'CRITICAL' { '#e74c3c' }
                    'ERROR'    { '#e74c3c' }
                    'WARNING'  { '#f39c12' }
                    default    { '#555'   }
                }
                $rowBg = switch ($ev.Level) {
                    'CRITICAL' { '#fff5f5' }
                    'ERROR'    { '#fff5f5' }
                    'WARNING'  { '#fffdf0' }
                    default    { ''        }
                }
                $timeStr = $ev.TimeCreated.ToString('dd-MM HH:mm:ss')
                @"
                <tr style='background:$rowBg'>
                  <td style='padding:5px 10px;border-bottom:1px solid #f5f5f5;font-size:11px;white-space:nowrap;color:#555'>$timeStr</td>
                  <td style='padding:5px 10px;border-bottom:1px solid #f5f5f5;font-size:11px;white-space:nowrap'>$($ev.Log)</td>
                  <td style='padding:5px 10px;border-bottom:1px solid #f5f5f5;font-size:11px;color:$lvlColor;font-weight:bold;white-space:nowrap'>$($ev.Level)</td>
                  <td style='padding:5px 10px;border-bottom:1px solid #f5f5f5;font-size:11px;white-space:nowrap'>$($ev.Source) ($($ev.EventId))</td>
                  <td style='padding:5px 10px;border-bottom:1px solid #f5f5f5;font-size:11px;color:#555'>$($ev.Message)</td>
                </tr>
"@
            }
        }
        elseif ($srv.Reachable) {
            $eventRows = "<tr><td colspan='5' style='padding:8px 12px;font-size:12px;color:#27ae60'>&#10003; No relevant events in the last $HoursBack hours</td></tr>"
        }

        @"
      <div style='margin-bottom:16px;border:1px solid #dde1e7;border-radius:6px;overflow:hidden'>
        <div style='background:#2c3e50;color:#fff;padding:9px 14px;display:flex;justify-content:space-between;align-items:center'>
          <span style='font-size:14px;font-weight:600'>$($srv.Name) $srvBadge</span>
          <span style='font-size:11px;background:#34495e;padding:2px 9px;border-radius:10px'>$($srv.Role)</span>
        </div>
        $(if (-not $srv.Reachable) {
            "<div style='padding:8px 12px;font-size:12px;color:#e74c3c;background:#fff5f5'>$reachIcon UNREACHABLE - could not query event logs</div>"
        } else {
            "<table style='width:100%;border-collapse:collapse'>
              <thead><tr style='background:#f4f6f8'>
                <th style='padding:5px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Time</th>
                <th style='padding:5px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Log</th>
                <th style='padding:5px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Level</th>
                <th style='padding:5px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Source (ID)</th>
                <th style='padding:5px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Message</th>
              </tr></thead>
              <tbody>$eventRows</tbody>
            </table>"
        })
      </div>
"@
    }

    return @"
<div style='margin-bottom:24px;background:#fff;border-radius:6px;border:1px solid #dde1e7;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.06)'>
  <div style='background:#2c3e50;color:#fff;padding:12px 18px;display:flex;justify-content:space-between;align-items:center'>
    <span style='font-size:16px;font-weight:700'>&#128221; Event Log (last $HoursBack hours)</span>
    <span style='font-size:12px;background:$badgeColour;padding:4px 12px;border-radius:12px;font-weight:700'>$badgeText</span>
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
    $result = Invoke-EventLogCheck -Config $cfg -Verbose
    Write-Host "`n[$($result.CheckName)] $($result.Summary) | Duration: $($result.Duration)" -ForegroundColor $(if ($result.HasIssues) { 'Red' } else { 'Green' })
}

