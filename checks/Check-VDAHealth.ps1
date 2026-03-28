#Requires -Version 5.1
<#
.SYNOPSIS
    Citrix VDA (Virtual Delivery Agent) health and registration check.

.DESCRIPTION
    Connects to a Citrix Delivery Controller using the Citrix Broker PowerShell
    SDK and retrieves the registration state of all VDAs across all Machine
    Catalogs and Delivery Groups. Reports unregistered, maintenance-mode and
    power-off machines in the HTML section fragment.

    Can be run standalone or dot-sourced by Invoke-DailyReport.ps1.

.PARAMETER Config
    PSCustomObject parsed from config.json. When omitted the script loads config.json
    from its own parent directory (standalone mode).

.EXAMPLE
    PS C:\> .\checks\Check-VDAHealth.ps1
    Runs the check standalone and prints the result summary to the console.

.EXAMPLE
    # Used by the master orchestrator:
    . .\checks\Check-VDAHealth.ps1
    $result = Invoke-VDAHealthCheck -Config $config

.INPUTS
    None. All input comes from config.json or the -Config parameter.

.OUTPUTS
    [PSCustomObject] with properties:
        CheckName   [string]  - Display name of this check.
        SectionHtml [string]  - HTML fragment to embed in the daily report.
        HasIssues   [bool]    - $true when unregistered or faulted VDAs are found.
        IssueCount  [int]     - Number of VDAs with a non-registered state.
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

    Scheduling:
        Run daily via Windows Task Scheduler or call through Invoke-DailyReport.ps1.
#>

# =============================================================================
# Exported function
# =============================================================================
function Invoke-VDAHealthCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $checkName = 'VDA Health'

    try {
        # Build ordered list of controllers to try
        $controllers = [System.Collections.Generic.List[string]]::new()
        $controllers.Add($Config.CVAD.PrimaryController)
        if ($Config.CVAD.FallbackController -and $Config.CVAD.FallbackController -ne $Config.CVAD.PrimaryController) {
            $controllers.Add($Config.CVAD.FallbackController)
        }

        # Run Broker SDK commands on the DDC via WinRM (avoids XDSDKProxy/XDAuthentication requirement)
        $sessOpt     = New-PSSessionOption -OperationTimeout 120000 -OpenTimeout 15000
        $allMachines = $null
        $lastError   = $null
        foreach ($ddc in $controllers) {
            try {
                Write-Verbose "Connecting to Delivery Controller: $ddc"
                $allMachines = Invoke-Command -ComputerName $ddc -SessionOption $sessOpt -ErrorAction Stop -ScriptBlock {
                    if (-not (Get-PSSnapin -Name Citrix.Broker.Admin.V2 -ErrorAction SilentlyContinue)) {
                        Add-PSSnapin -Name Citrix.Broker.Admin.V2 -ErrorAction Stop
                    }
                    Get-BrokerMachine -AdminAddress localhost -MaxRecordCount 10000 -ErrorAction Stop
                }
                $lastError = $null
                break
            }
            catch {
                $lastError = $_
                Write-Warning "DDC unavailable ($ddc), trying next controller..."
            }
        }

        if ($lastError) { throw $lastError }

        if (-not $allMachines) {
            $stopwatch.Stop()
            return [PSCustomObject]@{
                CheckName   = $checkName
                SectionHtml = _BuildVDAHtml -Machines @() -Groups @{}
                HasIssues   = $false
                IssueCount  = 0
                Summary     = 'No VDAs found'
                Duration    = "$([math]::Round($stopwatch.Elapsed.TotalSeconds,1))s"
                Error       = $null
            }
        }

        # Group machines by Delivery Group
        $groups = $allMachines | Group-Object -Property DesktopGroupName

        # Count issues (anything that is not Registered and powered on normally)
        $unregistered = @($allMachines | Where-Object { $_.RegistrationState -ne 'Registered' })
        $maintenance  = @($allMachines | Where-Object { $_.InMaintenanceMode -eq $true })
        $issueCount   = $unregistered.Count

        $stopwatch.Stop()

        return [PSCustomObject]@{
            CheckName   = $checkName
            SectionHtml = _BuildVDAHtml -Machines $allMachines -Groups $groups -Unregistered $unregistered -Maintenance $maintenance
            HasIssues   = ($issueCount -gt 0)
            IssueCount  = $issueCount
            Summary     = "$($allMachines.Count) VDA(s) - $($unregistered.Count) unregistered, $($maintenance.Count) in maintenance"
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
function _BuildVDAHtml {
    param(
        [array]$Machines,
        [array]$Groups,
        [array]$Unregistered,
        [array]$Maintenance
    )

    $totalCount     = $Machines.Count
    $unreg          = if ($Unregistered) { $Unregistered.Count } else { 0 }
    $maint          = if ($Maintenance)  { $Maintenance.Count  } else { 0 }
    $registered     = $totalCount - $unreg
    $hasIssues      = $unreg -gt 0
    $badgeColour    = if ($hasIssues) { '#e74c3c' } else { '#27ae60' }
    $badgeText      = if ($hasIssues) { 'ISSUES FOUND' } else { 'ALL OK' }

    # Summary bar
    $summaryBar = @"
    <div style='display:flex;gap:20px;padding:12px 16px;background:#f8f9fa;border-bottom:1px solid #eee;flex-wrap:wrap'>
      <div style='text-align:center'>
        <div style='font-size:22px;font-weight:700;color:#2c3e50'>$totalCount</div>
        <div style='font-size:11px;color:#777'>Total VDAs</div>
      </div>
      <div style='text-align:center'>
        <div style='font-size:22px;font-weight:700;color:#27ae60'>$registered</div>
        <div style='font-size:11px;color:#777'>Registered</div>
      </div>
      <div style='text-align:center'>
        <div style='font-size:22px;font-weight:700;color:$(if($unreg -gt 0){"#e74c3c"}else{"#27ae60"})'>$unreg</div>
        <div style='font-size:11px;color:#777'>Unregistered</div>
      </div>
      <div style='text-align:center'>
        <div style='font-size:22px;font-weight:700;color:$(if($maint -gt 0){"#f39c12"}else{"#27ae60"})'>$maint</div>
        <div style='font-size:11px;color:#777'>Maintenance</div>
      </div>
    </div>
"@

    # Per-group table
    $groupRows = foreach ($group in ($Groups | Sort-Object Name)) {
        $groupName    = if ($group.Name) { $group.Name } else { '(No Delivery Group)' }
        $members      = $group.Group
        $regCount     = @($members | Where-Object { $_.RegistrationState -eq 'Registered' }).Count
        $unregCount   = @($members | Where-Object { $_.RegistrationState -ne 'Registered' }).Count
        $maintCount   = @($members | Where-Object { $_.InMaintenanceMode -eq $true }).Count
        $total        = $members.Count
        $pct          = if ($total -gt 0) { [math]::Round(($regCount / $total) * 100) } else { 0 }
        $barColor     = if ($pct -lt 80) { '#e74c3c' } elseif ($pct -lt 100) { '#f39c12' } else { '#27ae60' }
        $rowBg        = if ($unregCount -gt 0) { '#fff9f9' } else { '#fff' }

        @"
        <tr style='background:$rowBg'>
          <td style='padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;font-weight:500'>$groupName</td>
          <td style='padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;text-align:center'>$total</td>
          <td style='padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;text-align:center;color:#27ae60;font-weight:bold'>$regCount</td>
          <td style='padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;text-align:center;color:$(if($unregCount -gt 0){"#e74c3c"}else{"#555"});font-weight:$(if($unregCount -gt 0){"bold"}else{"normal"})'>$unregCount</td>
          <td style='padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;text-align:center;color:$(if($maintCount -gt 0){"#f39c12"}else{"#555"})'>$maintCount</td>
          <td style='padding:8px 12px;border-bottom:1px solid #f0f0f0'>
            <div style='display:flex;align-items:center;gap:8px'>
              <div style='flex:1;background:#ecf0f1;border-radius:4px;height:8px'>
                <div style='width:$pct%;background:$barColor;height:8px;border-radius:4px'></div>
              </div>
              <span style='font-size:12px;color:#555;min-width:32px'>$pct%</span>
            </div>
          </td>
        </tr>
"@
    }

    # Unregistered machine detail table - grouped by Delivery Group with cx-sub collapse
    $unregDetail = ''
    if ($unreg -gt 0) {
        $dgOrder = [System.Collections.Generic.List[string]]::new()
        foreach ($vm in $Unregistered) {
            $dg = if ($vm.DesktopGroupName) { $vm.DesktopGroupName } else { '(No Delivery Group)' }
            if (-not $dgOrder.Contains($dg)) { $dgOrder.Add($dg) }
        }

        $dgBlocks = foreach ($dgName in ($dgOrder | Sort-Object)) {
            $dgMachines = @($Unregistered | Where-Object {
                $vm = $_
                ($vm.DesktopGroupName -eq $dgName) -or (-not $vm.DesktopGroupName -and $dgName -eq '(No Delivery Group)')
            })
            $dgRows = foreach ($m in ($dgMachines | Sort-Object MachineName)) {
                $machineName = $m.MachineName -replace '^.*\\', ''
                $catalog     = if ($m.CatalogName) { $m.CatalogName } else { '-' }
                $power       = if ($m.PowerState)  { $m.PowerState }  else { 'Unknown' }
                $regState    = $m.RegistrationState
                $stateColor  = switch ($regState) {
                    'Unregistered'        { '#e74c3c' }
                    'AgentNotContactable' { '#e74c3c' }
                    'Initializing'        { '#f39c12' }
                    default               { '#95a5a6' }
                }
                @"
              <tr>
                <td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px'>$machineName</td>
                <td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#777'>$catalog</td>
                <td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;color:$stateColor;font-weight:bold'>$regState</td>
                <td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px'>$power</td>
              </tr>
"@
            }
            @"
        <div class='cx-sub' data-collapsed='0' style='margin-bottom:6px;border:1px solid #fddede;border-radius:5px;overflow:hidden'>
          <div style='background:#fdf2f2;padding:7px 12px;display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid #fddede'>
            <span style='font-size:13px;font-weight:600;color:#c0392b'>$dgName</span>
            <span style='font-size:11px;color:#e74c3c;font-weight:700'>$($dgMachines.Count) unregistered</span>
          </div>
          <div>
            <table style='width:100%;border-collapse:collapse'>
              <thead><tr style='background:#f9f9f9'>
                <th style='padding:6px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Machine</th>
                <th style='padding:6px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Catalog</th>
                <th style='padding:6px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>State</th>
                <th style='padding:6px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Power</th>
              </tr></thead>
              <tbody>$dgRows</tbody>
            </table>
          </div>
        </div>
"@
        }

        $unregDetail = @"
      <div style='margin-top:12px'>
        <div style='font-size:13px;font-weight:600;color:#c0392b;padding:8px 12px;background:#fff0f0;border-radius:4px;margin-bottom:8px'>
          &#9888; Unregistered VDAs ($unreg)
        </div>
        $dgBlocks
      </div>
"@
    }

    return @"
<div style='margin-bottom:24px;background:#fff;border-radius:6px;border:1px solid #dde1e7;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.06)'>
  <div style='background:#2c3e50;color:#fff;padding:12px 18px;display:flex;justify-content:space-between;align-items:center'>
    <span style='font-size:16px;font-weight:700'>&#128187; VDA Health</span>
    <span style='font-size:12px;background:$badgeColour;padding:4px 12px;border-radius:12px;font-weight:700'>$badgeText</span>
  </div>
  $summaryBar
  <div style='padding:16px'>
    <table style='width:100%;border-collapse:collapse'>
      <thead>
        <tr style='background:#f4f6f8'>
          <th style='padding:8px 12px;text-align:left;color:#555;font-size:12px;font-weight:600'>Delivery Group</th>
          <th style='padding:8px 12px;text-align:center;color:#555;font-size:12px;font-weight:600'>Total</th>
          <th style='padding:8px 12px;text-align:center;color:#555;font-size:12px;font-weight:600'>Registered</th>
          <th style='padding:8px 12px;text-align:center;color:#555;font-size:12px;font-weight:600'>Unregistered</th>
          <th style='padding:8px 12px;text-align:center;color:#555;font-size:12px;font-weight:600'>Maintenance</th>
          <th style='padding:8px 12px;text-align:left;color:#555;font-size:12px;font-weight:600'>Registration %</th>
        </tr>
      </thead>
      <tbody>$groupRows</tbody>
    </table>
    $unregDetail
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
    $result = Invoke-VDAHealthCheck -Config $cfg -Verbose
    Write-Host "`n[$($result.CheckName)] $($result.Summary) | Duration: $($result.Duration)" -ForegroundColor $(if ($result.HasIssues) { 'Red' } else { 'Green' })
}

