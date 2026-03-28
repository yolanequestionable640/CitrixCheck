#Requires -Version 5.1
<#
.SYNOPSIS
    Citrix session monitoring and reporting check.

.DESCRIPTION
    Connects to a Citrix Delivery Controller using the Citrix Broker PowerShell
    SDK and retrieves all current sessions. Reports session counts per Delivery
    Group, flags long-idle disconnected sessions, captures top consumers by
    session count and highlights sessions that exceed the idle threshold defined
    in config.json.

    Can be run standalone or dot-sourced by Invoke-DailyReport.ps1.

.PARAMETER Config
    PSCustomObject parsed from config.json. When omitted the script loads config.json
    from its own parent directory (standalone mode).

.EXAMPLE
    PS C:\> .\checks\Check-Sessions.ps1
    Runs the check standalone and prints the result summary to the console.

.EXAMPLE
    # Used by the master orchestrator:
    . .\checks\Check-Sessions.ps1
    $result = Invoke-SessionCheck -Config $config

.INPUTS
    None. All input comes from config.json or the -Config parameter.

.OUTPUTS
    [PSCustomObject] with properties:
        CheckName   [string]  - Display name of this check.
        SectionHtml [string]  - HTML fragment to embed in the daily report.
        HasIssues   [bool]    - $true when long-idle sessions exceed the configured threshold.
        IssueCount  [int]     - Number of sessions exceeding the idle threshold.
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
        - Citrix Virtual Apps and Desktops PowerShell SDK (Citrix.Broker.Admin.V2).
          Installed automatically with Citrix Studio or the Remote PowerShell SDK.
        - Read access to the Delivery Controller (Citrix Read-Only Administrator or higher).

    Idle threshold:
        Configured via Config.Thresholds.IdleSessionWarningMinutes (default: 480 = 8 hours).

    Scheduling:
        Run daily via Windows Task Scheduler or call through Invoke-DailyReport.ps1.
#>

# =============================================================================
# Exported function
# =============================================================================
function Invoke-SessionCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $stopwatch         = [System.Diagnostics.Stopwatch]::StartNew()
    $checkName         = 'Session Monitor'
    $idleThresholdMins = if ($Config.Thresholds.IdleSessionWarningMinutes) {
                             $Config.Thresholds.IdleSessionWarningMinutes
                         } else { 480 }

    try {
        # Run Broker SDK commands on the DDC via WinRM (avoids XDSDKProxy/XDAuthentication requirement)
        $ddc     = $Config.CVAD.PrimaryController
        $sessOpt = New-PSSessionOption -OperationTimeout 60000 -OpenTimeout 15000
        Write-Verbose "Connecting to Delivery Controller: $ddc"

        $allSessions = Invoke-Command -ComputerName $ddc -SessionOption $sessOpt -ErrorAction Stop -ScriptBlock {
            if (-not (Get-PSSnapin -Name Citrix.Broker.Admin.V2 -ErrorAction SilentlyContinue)) {
                Add-PSSnapin -Name Citrix.Broker.Admin.V2 -ErrorAction Stop
            }
            Get-BrokerSession -AdminAddress localhost -MaxRecordCount 10000 -ErrorAction Stop
        }

        $active       = @($allSessions | Where-Object { $_.SessionState -eq 'Active' })
        $disconnected = @($allSessions | Where-Object { $_.SessionState -eq 'Disconnected' })

        # Long-idle disconnected sessions
        $longIdle = @($disconnected | Where-Object {
            $lct = $_.PSObject.Properties['LastConnectionTime']
            $lct -and $lct.Value -and
            (New-TimeSpan -Start $lct.Value -End (Get-Date)).TotalMinutes -ge $idleThresholdMins
        })

        $issueCount = $longIdle.Count

        $stopwatch.Stop()

        return [PSCustomObject]@{
            CheckName   = $checkName
            SectionHtml = _BuildSessionHtml -AllSessions $allSessions -Active $active -Disconnected $disconnected -LongIdle $longIdle -IdleThreshold $idleThresholdMins
            HasIssues   = ($issueCount -gt 0)
            IssueCount  = $issueCount
            Summary     = "$($allSessions.Count) session(s) - $($active.Count) active, $($disconnected.Count) disconnected, $issueCount idle >$idleThresholdMins min"
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
function _BuildSessionHtml {
    param(
        [array]$AllSessions,
        [array]$Active,
        [array]$Disconnected,
        [array]$LongIdle,
        [int]$IdleThreshold
    )

    $total       = $AllSessions.Count
    $actCount    = $Active.Count
    $discCount   = $Disconnected.Count
    $idleCount   = $LongIdle.Count
    $hasIssues   = $idleCount -gt 0
    $badgeColour = if ($hasIssues) { '#f39c12' } else { '#27ae60' }
    $badgeText   = if ($hasIssues) { "IDLE SESSIONS ($idleCount)" } else { 'ALL OK' }

    # Summary bar
    $summaryBar = @"
    <div style='display:flex;gap:20px;padding:12px 16px;background:#f8f9fa;border-bottom:1px solid #eee;flex-wrap:wrap'>
      <div style='text-align:center'>
        <div style='font-size:22px;font-weight:700;color:#2c3e50'>$total</div>
        <div style='font-size:11px;color:#777'>Total Sessions</div>
      </div>
      <div style='text-align:center'>
        <div style='font-size:22px;font-weight:700;color:#27ae60'>$actCount</div>
        <div style='font-size:11px;color:#777'>Active</div>
      </div>
      <div style='text-align:center'>
        <div style='font-size:22px;font-weight:700;color:#3498db'>$discCount</div>
        <div style='font-size:11px;color:#777'>Disconnected</div>
      </div>
      <div style='text-align:center'>
        <div style='font-size:22px;font-weight:700;color:$(if($idleCount -gt 0){"#f39c12"}else{"#27ae60"})'>$idleCount</div>
        <div style='font-size:11px;color:#777'>Idle &gt;$IdleThreshold min</div>
      </div>
    </div>
"@

    # Per Delivery Group breakdown
    $groups    = $AllSessions | Group-Object -Property DesktopGroupName
    $groupRows = foreach ($g in ($groups | Sort-Object -Property { $_.Group.Count } -Descending)) {
        $gName    = if ($g.Name) { $g.Name } else { '(No Group)' }
        $gAct     = @($g.Group | Where-Object { $_.SessionState -eq 'Active'       }).Count
        $gDisc    = @($g.Group | Where-Object { $_.SessionState -eq 'Disconnected' }).Count
        $gIdle    = @($g.Group | Where-Object {
            $lct2 = $_.PSObject.Properties['LastConnectionTime']
            $_.SessionState -eq 'Disconnected' -and $lct2 -and $lct2.Value -and
            (New-TimeSpan -Start $lct2.Value -End (Get-Date)).TotalMinutes -ge $IdleThreshold
        }).Count
        @"
        <tr>
          <td style='padding:7px 12px;border-bottom:1px solid #f0f0f0;font-size:13px'>$gName</td>
          <td style='padding:7px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;text-align:center;font-weight:bold;color:#2c3e50'>$($g.Group.Count)</td>
          <td style='padding:7px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;text-align:center;color:#27ae60'>$gAct</td>
          <td style='padding:7px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;text-align:center;color:#3498db'>$gDisc</td>
          <td style='padding:7px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;text-align:center;color:$(if($gIdle -gt 0){"#f39c12"}else{"#555"});font-weight:$(if($gIdle -gt 0){"bold"}else{"normal"})'>$gIdle</td>
        </tr>
"@
    }

    # Long-idle session detail table
    $idleDetail = ''
    if ($idleCount -gt 0) {
        $idleRows = foreach ($s in ($LongIdle | Sort-Object -Property { $p = $_.PSObject.Properties['LastConnectionTime']; if ($p) { $p.Value } })) {
            $user     = $s.UserName -replace '^.*\\', ''
            $machine  = $s.MachineName -replace '^.*\\', ''
            $dgName   = if ($s.DesktopGroupName) { $s.DesktopGroupName } else { '-' }
            $sLct     = $s.PSObject.Properties['LastConnectionTime']
            $lastConn = if ($sLct -and $sLct.Value) { $sLct.Value.ToString('dd-MM-yyyy HH:mm') } else { 'Unknown' }
            $idleMins = if ($sLct -and $sLct.Value) {
                [math]::Round((New-TimeSpan -Start $sLct.Value -End (Get-Date)).TotalMinutes)
            } else { '?' }
            @"
          <tr>
            <td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px'>$user</td>
            <td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px'>$machine</td>
            <td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px'>$dgName</td>
            <td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px'>$lastConn</td>
            <td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#f39c12;font-weight:bold'>$idleMins min</td>
          </tr>
"@
        }

        $idleDetail = @"
      <div style='margin-top:12px'>
        <div style='font-size:13px;font-weight:600;color:#d35400;padding:8px 12px;background:#fff8ee;border-radius:4px;margin-bottom:8px'>
          &#9201; Disconnected sessions idle &gt;$IdleThreshold minutes ($idleCount)
        </div>
        <table style='width:100%;border-collapse:collapse'>
          <thead>
            <tr style='background:#f4f6f8'>
              <th style='padding:6px 10px;text-align:left;color:#555;font-size:12px;font-weight:600'>User</th>
              <th style='padding:6px 10px;text-align:left;color:#555;font-size:12px;font-weight:600'>Machine</th>
              <th style='padding:6px 10px;text-align:left;color:#555;font-size:12px;font-weight:600'>Delivery Group</th>
              <th style='padding:6px 10px;text-align:left;color:#555;font-size:12px;font-weight:600'>Last Connection</th>
              <th style='padding:6px 10px;text-align:left;color:#555;font-size:12px;font-weight:600'>Idle Time</th>
            </tr>
          </thead>
          <tbody>$idleRows</tbody>
        </table>
      </div>
"@
    }

    return @"
<div style='margin-bottom:24px;background:#fff;border-radius:6px;border:1px solid #dde1e7;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.06)'>
  <div style='background:#2c3e50;color:#fff;padding:12px 18px;display:flex;justify-content:space-between;align-items:center'>
    <span style='font-size:16px;font-weight:700'>&#128100; Session Monitor</span>
    <span style='font-size:12px;background:$badgeColour;padding:4px 12px;border-radius:12px;font-weight:700'>$badgeText</span>
  </div>
  $summaryBar
  <div style='padding:16px'>
    <table style='width:100%;border-collapse:collapse'>
      <thead>
        <tr style='background:#f4f6f8'>
          <th style='padding:7px 12px;text-align:left;color:#555;font-size:12px;font-weight:600'>Delivery Group</th>
          <th style='padding:7px 12px;text-align:center;color:#555;font-size:12px;font-weight:600'>Total</th>
          <th style='padding:7px 12px;text-align:center;color:#555;font-size:12px;font-weight:600'>Active</th>
          <th style='padding:7px 12px;text-align:center;color:#555;font-size:12px;font-weight:600'>Disconnected</th>
          <th style='padding:7px 12px;text-align:center;color:#555;font-size:12px;font-weight:600'>Idle &gt;$IdleThreshold min</th>
        </tr>
      </thead>
      <tbody>$groupRows</tbody>
    </table>
    $idleDetail
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
    $result = Invoke-SessionCheck -Config $cfg -Verbose
    Write-Host "`n[$($result.CheckName)] $($result.Summary) | Duration: $($result.Duration)" -ForegroundColor $(if ($result.HasIssues) { 'Yellow' } else { 'Green' })
}

