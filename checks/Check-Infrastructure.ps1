#Requires -Version 5.1
<#
.SYNOPSIS
    Citrix infrastructure service status check.

.DESCRIPTION
    Reads server and service definitions from config.json, checks the status of all
    configured Windows services via WinRM/CIM and returns a structured result object
    containing an HTML section fragment and an issue flag. Can be run standalone or
    dot-sourced by Invoke-DailyReport.ps1.

.PARAMETER Config
    PSCustomObject parsed from config.json. When omitted the script loads config.json
    from its own directory (standalone mode).

.EXAMPLE
    PS C:\> .\checks\Check-Infrastructure.ps1
    Runs the check standalone and prints the result summary to the console.

.EXAMPLE
    # Used by the master orchestrator:
    . .\checks\Check-Infrastructure.ps1
    $result = Invoke-InfrastructureCheck -Config $config

.INPUTS
    None. All input comes from config.json or the -Config parameter.

.OUTPUTS
    [PSCustomObject] with properties:
        CheckName   [string]  - Display name of this check.
        SectionHtml [string]  - HTML fragment to embed in the daily report.
        HasIssues   [bool]    - $true when one or more services are not running.
        IssueCount  [int]     - Number of services/servers with a problem.
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
        1.0.0 - 2026-03-15 - Initial release (English rewrite of Check-CitrixInfrastructure.ps1).

    Requirements:
        - PowerShell 5.1 or higher.
        - WinRM access to all servers listed in config.json.
        - Sufficient permissions to query remote services (typically Domain Admin
          or a dedicated monitoring service account with 'Read' on Service Control Manager).

    Scheduling:
        Run daily via Windows Task Scheduler or call through Invoke-DailyReport.ps1.
#>

# =============================================================================
# Exported function
# =============================================================================
function Invoke-InfrastructureCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $checkName = 'Infrastructure Services'

    try {
        $serverReports = [System.Collections.Generic.List[PSCustomObject]]::new()
        $totalIssues   = 0

        foreach ($server in $Config.Servers) {
            Write-Verbose "Checking: $($server.Name) [$($server.Role)]"

            $ping      = New-Object System.Net.NetworkInformation.Ping
            $reachable = try { ($ping.Send($server.Name, 2000)).Status -eq 'Success' } catch { $false }
            $serviceResults = [System.Collections.Generic.List[PSCustomObject]]::new()

            if (-not $reachable) {
                $totalIssues++
                foreach ($svc in $server.Services) {
                    $serviceResults.Add([PSCustomObject]@{
                        Service = $svc
                        Status  = 'UNKNOWN'
                        Reason  = 'Server unreachable'
                    })
                }
            }
            else {
                # Fetch all services once per server via WinRM (explicit timeout prevents hanging in Task Scheduler)
                $sessOpt = New-PSSessionOption -OperationTimeout 30000 -OpenTimeout 15000
                $allSvcs = @(Invoke-Command -ComputerName $server.Name -SessionOption $sessOpt -ScriptBlock { Get-Service } -ErrorAction SilentlyContinue)

                foreach ($svc in $server.Services) {
                    $obj = $allSvcs | Where-Object { $_.DisplayName -eq $svc }
                    if ($obj) {
                        $status = switch ($obj.Status) {
                            'Running' { 'RUNNING' }
                            'Stopped' { 'STOPPED' }
                            'Paused'  { 'PAUSED'  }
                            default   { $obj.Status.ToString().ToUpper() }
                        }
                        if ($status -ne 'RUNNING') { $totalIssues++ }
                        $serviceResults.Add([PSCustomObject]@{
                            Service = $svc
                            Status  = $status
                            Reason  = ''
                        })
                    }
                    else {
                        $totalIssues++
                        $serviceResults.Add([PSCustomObject]@{
                            Service = $svc
                            Status  = 'ERROR'
                            Reason  = "Service not found"
                        })
                    }
                }
            }

            $serverReports.Add([PSCustomObject]@{
                Name       = $server.Name
                Role       = $server.Role
                Reachable  = $reachable
                Services   = $serviceResults
            })
        }

        $stopwatch.Stop()
        $hasIssues   = $totalIssues -gt 0
        $sectionHtml = _BuildInfrastructureHtml -ServerReports $serverReports

        # Per-role summary for management cards
        $roleData = @{}
        foreach ($sr in $serverReports) {
            $role = $sr.Role
            if (-not $roleData.ContainsKey($role)) {
                $roleData[$role] = [PSCustomObject]@{ Servers = 0; Issues = 0 }
            }
            $roleData[$role].Servers++
            $roleIssues = @($sr.Services | Where-Object { $_.Status -ne 'RUNNING' }).Count
            if (-not $sr.Reachable) { $roleIssues = $sr.Services.Count }
            $roleData[$role].Issues += $roleIssues
        }

        return [PSCustomObject]@{
            CheckName   = $checkName
            SectionHtml = $sectionHtml
            HasIssues   = $hasIssues
            IssueCount  = $totalIssues
            RoleData    = $roleData
            Summary     = "$($Config.Servers.Count) server(s) checked - $totalIssues issue(s) found"
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
function _BuildInfrastructureHtml {
    param([array]$ServerReports)

    $overallOk   = -not ($ServerReports | Where-Object { -not $_.Reachable -or ($_.Services | Where-Object { $_.Status -ne 'RUNNING' }) })
    $badgeColour = if ($overallOk) { '#27ae60' } else { '#e74c3c' }
    $badgeText   = if ($overallOk) { 'ALL OK'  } else { 'ISSUES FOUND' }

    # Collect unique roles in original config order
    $roleOrder = [System.Collections.Generic.List[string]]::new()
    foreach ($sr in $ServerReports) {
        if (-not $roleOrder.Contains($sr.Role)) { $roleOrder.Add($sr.Role) }
    }

    $roleBlocks = foreach ($roleName in $roleOrder) {
        $roleReports  = @($ServerReports | Where-Object { $_.Role -eq $roleName })
        $roleIssues   = @($roleReports | Where-Object { -not $_.Reachable -or ($_.Services | Where-Object { $_.Status -ne 'RUNNING' }) }).Count
        $roleBadgeTxt = if ($roleIssues -eq 0) { 'OK' } else { "$roleIssues server(s) with issues" }
        $roleBadgeCol = if ($roleIssues -eq 0) { '#27ae60' } else { '#e74c3c' }

        $serverBlocksInRole = foreach ($report in $roleReports) {
            $reachIcon  = if ($report.Reachable) { '&#10003;' } else { '&#10007;' }
            $reachColor = if ($report.Reachable) { '#27ae60'  } else { '#e74c3c'  }
            $reachText  = if ($report.Reachable) { 'Reachable' } else { 'UNREACHABLE' }

            $rows = foreach ($svc in $report.Services) {
                $colour = switch ($svc.Status) {
                    'RUNNING' { '#27ae60' }
                    'STOPPED' { '#e74c3c' }
                    'PAUSED'  { '#f39c12' }
                    default   { '#95a5a6' }
                }
                $icon   = switch ($svc.Status) {
                    'RUNNING' { '&#10003;' }
                    'STOPPED' { '&#10007;' }
                    default   { '?' }
                }
                $reason = if ($svc.Reason) { "<br><small style='color:#777'>$($svc.Reason)</small>" } else { '' }
                @"
              <tr>
                <td style='padding:7px 12px;border-bottom:1px solid #ecf0f1;font-size:13px'>$($svc.Service)</td>
                <td style='padding:7px 12px;border-bottom:1px solid #ecf0f1;color:$colour;font-weight:bold;font-size:13px'>
                  $icon $($svc.Status)$reason
                </td>
              </tr>
"@
            }

            @"
        <div style='margin-bottom:12px;border:1px solid #dde1e7;border-radius:6px;overflow:hidden'>
          <div style='background:#2c3e50;color:#fff;padding:9px 14px'>
            <span style='font-size:14px;font-weight:600'>$($report.Name)</span>
          </div>
          <div style='padding:5px 12px 4px;font-size:12px;background:#f8f9fa;border-bottom:1px solid #eee'>
            Reachability: <span style='color:$reachColor;font-weight:bold'>$reachIcon $reachText</span>
          </div>
          <table style='width:100%;border-collapse:collapse'>
            <thead>
              <tr style='background:#f4f6f8'>
                <th style='padding:7px 12px;text-align:left;color:#555;font-size:12px;font-weight:600;width:65%'>Service</th>
                <th style='padding:7px 12px;text-align:left;color:#555;font-size:12px;font-weight:600'>Status</th>
              </tr>
            </thead>
            <tbody>$rows</tbody>
          </table>
        </div>
"@
        }

        @"
    <div class='cx-sub' data-collapsed='0' style='margin-bottom:14px;border:1px solid #dde1e7;border-radius:6px;overflow:hidden'>
      <div style='background:#455a64;color:#fff;padding:8px 14px;display:flex;justify-content:space-between;align-items:center'>
        <span style='font-size:13px;font-weight:700'>$roleName ($($roleReports.Count))</span>
        <span style='font-size:11px;background:$roleBadgeCol;padding:2px 8px;border-radius:10px;font-weight:700;color:#fff'>$roleBadgeTxt</span>
      </div>
      <div style='padding:10px 14px'>
        $serverBlocksInRole
      </div>
    </div>
"@
    }

    return @"
<div style='margin-bottom:24px;background:#fff;border-radius:6px;border:1px solid #dde1e7;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.06)'>
  <div style='background:#2c3e50;color:#fff;padding:12px 18px;display:flex;justify-content:space-between;align-items:center'>
    <span style='font-size:16px;font-weight:700'>&#9881; Infrastructure Services</span>
    <span style='font-size:12px;background:$badgeColour;padding:4px 12px;border-radius:12px;font-weight:700'>$badgeText</span>
  </div>
  <div style='padding:16px'>
    $roleBlocks
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
    $result = Invoke-InfrastructureCheck -Config $cfg -Verbose
    Write-Host "`n[$($result.CheckName)] $($result.Summary) | Duration: $($result.Duration)" -ForegroundColor $(if ($result.HasIssues) { 'Red' } else { 'Green' })
}

