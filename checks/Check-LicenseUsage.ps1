#Requires -Version 5.1
<#
.SYNOPSIS
    Citrix License Server usage and capacity check.

.DESCRIPTION
    Queries the Citrix License Server via WMI (ROOT\CitrixLicensing) to retrieve
    current license consumption for each product/edition combination. Reports
    usage percentages and raises a warning or critical flag when configured
    thresholds are exceeded.

    Can be run standalone or dot-sourced by Invoke-DailyReport.ps1.

.PARAMETER Config
    PSCustomObject parsed from config.json. When omitted the script loads config.json
    from its own parent directory (standalone mode).

.EXAMPLE
    PS C:\> .\checks\Check-LicenseUsage.ps1
    Runs the check standalone and prints the result summary to the console.

.EXAMPLE
    # Used by the master orchestrator:
    . .\checks\Check-LicenseUsage.ps1
    $result = Invoke-LicenseUsageCheck -Config $config

.INPUTS
    None. All input comes from config.json or the -Config parameter.

.OUTPUTS
    [PSCustomObject] with properties:
        CheckName   [string]  - Display name of this check.
        SectionHtml [string]  - HTML fragment to embed in the daily report.
        HasIssues   [bool]    - $true when usage exceeds the warning threshold.
        IssueCount  [int]     - Number of license types exceeding the threshold.
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
        - WMI access to the Citrix License Server (ROOT\CitrixLicensing namespace).
        - The Citrix Licensing service must be running on the target server.
        - Sufficient permissions (typically Domain Admin or a dedicated monitoring
          service account with WMI read access on the license server).

    Thresholds:
        Warning  - Config.Thresholds.LicenseUsageWarningPercent  (default: 85)
        Critical - Config.Thresholds.LicenseUsageCriticalPercent (default: 95)

    Scheduling:
        Run daily via Windows Task Scheduler or call through Invoke-DailyReport.ps1.
#>

# =============================================================================
# Exported function
# =============================================================================
function Invoke-LicenseUsageCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $stopwatch     = [System.Diagnostics.Stopwatch]::StartNew()
    $checkName     = 'License Usage'
    $warnPct       = if ($Config.Thresholds.LicenseUsageWarningPercent)  { $Config.Thresholds.LicenseUsageWarningPercent  } else { 85 }
    $critPct       = if ($Config.Thresholds.LicenseUsageCriticalPercent) { $Config.Thresholds.LicenseUsageCriticalPercent } else { 95 }
    $licServer     = $Config.LicenseServer

    try {
        Write-Verbose "Querying license WMI on: $licServer"

        # Try known WMI class names in order of preference
        $wmiClasses = @('Citrix_GT_License_Inventory', 'Citrix_GF_License_Inventory', 'Citrix_GT_License_Pool', 'Citrix_GT_LicensesInLicensePool')
        $inventory  = $null
        $usedClass  = $null

        foreach ($cls in $wmiClasses) {
            try {
                $inventory = Get-WmiObject `
                    -Namespace    'ROOT\CitrixLicensing' `
                    -Class        $cls `
                    -ComputerName $licServer `
                    -ErrorAction  Stop
                $usedClass = $cls
                Write-Verbose "License WMI class in use: $cls"
                break
            }
            catch { Write-Verbose "WMI class $cls not available: $($_.Exception.Message)" }
        }

        # Auto-discovery: enumerate namespace and try any class with 'Inventory' in the name
        if (-not $usedClass) {
            Write-Verbose "Known classes not found - enumerating ROOT\CitrixLicensing namespace"
            $availableClasses = @(Get-WmiObject -Namespace 'ROOT\CitrixLicensing' -List `
                -ComputerName $licServer -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Name)
            Write-Verbose "Available classes: $($availableClasses -join ', ')"

            $discoveredClass = $availableClasses | Where-Object { $_ -like '*Inventory*' } | Select-Object -First 1
            if ($discoveredClass) {
                try {
                    $inventory = Get-WmiObject -Namespace 'ROOT\CitrixLicensing' -Class $discoveredClass `
                        -ComputerName $licServer -ErrorAction Stop
                    $usedClass = $discoveredClass
                    Write-Verbose "Auto-discovered license WMI class: $discoveredClass"
                }
                catch { Write-Verbose "Auto-discovered class $discoveredClass also failed: $($_.Exception.Message)" }
            }

            if (-not $usedClass) {
                $classHint = if ($availableClasses) { " Beschikbare classes: $($availableClasses -join ', ')" } else { '' }
                throw "No supported license WMI class found in ROOT\CitrixLicensing on $licServer. Tried: $($wmiClasses -join ', ').$classHint"
            }
        }

        $licenseData = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($lic in $inventory) {
            $total     = [int]$lic.Count
            $inUse     = [int]$lic.InUseCount
            $overdraft = if ($lic.PSObject.Properties['Overdraft']  -and $lic.Overdraft)  { [int]$lic.Overdraft  } `
                    elseif ($lic.PSObject.Properties['OverDraft']   -and $lic.OverDraft)   { [int]$lic.OverDraft  } else { 0 }
            $available = if ($lic.PSObject.Properties['PooledAvailable'] -and $null -ne $lic.PooledAvailable) { [int]$lic.PooledAvailable } else { $total - $inUse }
            $product   = if ($lic.PSObject.Properties['PLDFullName'] -and $lic.PLDFullName) { $lic.PLDFullName } `
                    elseif ($lic.PSObject.Properties['PLD']          -and $lic.PLD)          { $lic.PLD          } else { '(unknown)' }
            $pct       = if ($total -gt 0) { [math]::Round(($inUse / $total) * 100) } else { 0 }
            $severity  = if ($pct -ge $critPct) { 'CRITICAL' } elseif ($pct -ge $warnPct) { 'WARNING' } else { 'OK' }

            $licenseData.Add([PSCustomObject]@{
                Product   = $product
                Total     = $total
                InUse     = $inUse
                Available = $available
                Overdraft = $overdraft
                Percent   = $pct
                Severity  = $severity
            })
        }

        $issueCount  = @($licenseData | Where-Object { $_.Severity -ne 'OK' }).Count
        $stopwatch.Stop()

        return [PSCustomObject]@{
            CheckName   = $checkName
            SectionHtml = _BuildLicenseHtml -LicenseData $licenseData -WarnPct $warnPct -CritPct $critPct -Server $licServer
            HasIssues   = ($issueCount -gt 0)
            IssueCount  = $issueCount
            Summary     = "$($licenseData.Count) license type(s) - $issueCount above warning threshold"
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
function _BuildLicenseHtml {
    param(
        [System.Collections.Generic.List[PSCustomObject]]$LicenseData,
        [int]$WarnPct,
        [int]$CritPct,
        [string]$Server
    )

    $anyIssue    = $LicenseData | Where-Object { $_.Severity -ne 'OK' }
    $badgeColour = if ($anyIssue) { '#e74c3c' } else { '#27ae60' }
    $badgeText   = if ($anyIssue) { 'THRESHOLD EXCEEDED' } else { 'ALL OK' }

    $rows = foreach ($lic in ($LicenseData | Sort-Object Percent -Descending)) {
        $barColour = switch ($lic.Severity) {
            'CRITICAL' { '#e74c3c' }
            'WARNING'  { '#f39c12' }
            default    { '#27ae60' }
        }
        $rowBg = switch ($lic.Severity) {
            'CRITICAL' { '#fff5f5' }
            'WARNING'  { '#fffdf0' }
            default    { '#fff'   }
        }
        $overdraftCell = if ($lic.Overdraft -gt 0) {
            "<span style='color:#e74c3c;font-weight:bold'>+$($lic.Overdraft)</span>"
        } else { '-' }

        @"
      <tr style='background:$rowBg'>
        <td style='padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;font-weight:500'>$($lic.Product)</td>
        <td style='padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;text-align:center'>$($lic.Total)</td>
        <td style='padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;text-align:center;font-weight:bold'>$($lic.InUse)</td>
        <td style='padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;text-align:center;color:#27ae60'>$($lic.Available)</td>
        <td style='padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;text-align:center'>$overdraftCell</td>
        <td style='padding:8px 12px;border-bottom:1px solid #f0f0f0'>
          <div style='display:flex;align-items:center;gap:8px'>
            <div style='flex:1;background:#ecf0f1;border-radius:4px;height:10px;position:relative'>
              <div style='width:$($lic.Percent)%;background:$barColour;height:10px;border-radius:4px'></div>
              $(if ($WarnPct -le 100) { "<div style='position:absolute;left:$WarnPct%;top:-2px;width:1px;height:14px;background:#f39c12;opacity:.7'></div>" })
              $(if ($CritPct -le 100) { "<div style='position:absolute;left:$CritPct%;top:-2px;width:1px;height:14px;background:#e74c3c;opacity:.7'></div>" })
            </div>
            <span style='font-size:12px;font-weight:bold;color:$barColour;min-width:36px'>$($lic.Percent)%</span>
          </div>
        </td>
      </tr>
"@
    }

    return @"
<div style='margin-bottom:24px;background:#fff;border-radius:6px;border:1px solid #dde1e7;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.06)'>
  <div style='background:#2c3e50;color:#fff;padding:12px 18px;display:flex;justify-content:space-between;align-items:center'>
    <span style='font-size:16px;font-weight:700'>&#128273; License Usage</span>
    <span style='font-size:12px;background:$badgeColour;padding:4px 12px;border-radius:12px;font-weight:700'>$badgeText</span>
  </div>
  <div style='padding:4px 16px 4px;font-size:11px;color:#777;background:#f8f9fa;border-bottom:1px solid #eee'>
    License Server: <strong>$Server</strong> &nbsp;|&nbsp;
    <span style='color:#f39c12'>&#9650; Warning at $WarnPct%</span> &nbsp;
    <span style='color:#e74c3c'>&#9650; Critical at $CritPct%</span>
  </div>
  <div style='padding:16px'>
    <table style='width:100%;border-collapse:collapse'>
      <thead>
        <tr style='background:#f4f6f8'>
          <th style='padding:8px 12px;text-align:left;color:#555;font-size:12px;font-weight:600'>Product / Edition</th>
          <th style='padding:8px 12px;text-align:center;color:#555;font-size:12px;font-weight:600'>Total</th>
          <th style='padding:8px 12px;text-align:center;color:#555;font-size:12px;font-weight:600'>In Use</th>
          <th style='padding:8px 12px;text-align:center;color:#555;font-size:12px;font-weight:600'>Available</th>
          <th style='padding:8px 12px;text-align:center;color:#555;font-size:12px;font-weight:600'>Overdraft</th>
          <th style='padding:8px 12px;text-align:left;color:#555;font-size:12px;font-weight:600'>Usage</th>
        </tr>
      </thead>
      <tbody>$rows</tbody>
    </table>
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
    $result = Invoke-LicenseUsageCheck -Config $cfg -Verbose
    Write-Host "`n[$($result.CheckName)] $($result.Summary) | Duration: $($result.Duration)" -ForegroundColor $(if ($result.HasIssues) { 'Yellow' } else { 'Green' })
}

