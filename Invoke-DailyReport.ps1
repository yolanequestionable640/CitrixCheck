#Requires -Version 5.1
<#
.SYNOPSIS
    Master orchestrator for the Citrix daily infrastructure report.

.DESCRIPTION
    Dot-sources all check scripts located in the .\checks\ subdirectory, executes
    each check sequentially, and combines the HTML section fragments into a single
    styled email that is sent to the address(es) defined in config.json.

    A plain-text log entry is written for every check and the report is optionally
    saved as an HTML file in .\reports\ for archival purposes.

    Checks executed (in order):
        1.  Infrastructure Services  - Windows service status on all Citrix servers
        2.  VDA Health               - VDA registration state per Delivery Group
        3.  Session Monitor          - Active / disconnected / long-idle sessions
        4.  License Usage            - Citrix license consumption vs. capacity
        5.  PVS                      - Provisioning Services server state and vDisk versions
        6.  FAS                      - Federated Authentication Service rules and certificates
        7.  NetScaler                - Citrix ADC HA, vServer states and SSL certificate expiry
        8.  XenServer                - Hypervisor pool, host metrics and storage repository health
        9.  Disk Space               - Free disk space on all Citrix servers
        10. Event Log                - Errors and warnings from the last 24 hours

    Each check can also be run independently as a standalone script.

.PARAMETER ConfigPath
    Full path to config.json. Defaults to config.json in the same directory as
    this script.

.PARAMETER SaveReport
    When specified, saves the generated HTML report to .\reports\CitrixReport_<date>.html.

.PARAMETER SkipChecks
    Comma-separated list of check names to skip. Valid values:
        Infrastructure, VDAHealth, Sessions, LicenseUsage, PVS, FAS, NetScaler, XenServer, DiskSpace, EventLog

.EXAMPLE
    PS C:\> .\Invoke-DailyReport.ps1
    Runs all checks and sends the combined email report.

.EXAMPLE
    PS C:\> .\Invoke-DailyReport.ps1 -SaveReport
    Runs all checks, sends the email, and saves the HTML report to .\reports\.

.EXAMPLE
    PS C:\> .\Invoke-DailyReport.ps1 -SkipChecks 'LicenseUsage'
    Runs all checks except LicenseUsage.

.EXAMPLE
    PS C:\> .\Invoke-DailyReport.ps1 -ConfigPath 'D:\MyConfig\config.json' -SaveReport
    Uses a custom config path and saves the report.

.INPUTS
    None.

.OUTPUTS
    None. Side effects: email sent, log written, optional HTML file saved.

.NOTES
    Author:     Ufuk Kocak
    Website:    https://horizonconsulting.it
    LinkedIn:   https://www.linkedin.com/in/ufukkocak
    Created:    2026-03-15
    Version:    1.2.0

    Changelog:
        1.0.0 - 2026-03-15 - Initial release.
        1.1.0 - 2026-03-15 - Added PVS and FAS checks; NetScaler multi-instance support (EXT/INT/LB).
        1.2.0 - 2026-03-23 - Added NetScaler and XenServer checks to $checkDefs; updated SkipChecks
                              documentation; all credential setup centralised in Initialize-CitrixCheck.ps1.

    Requirements:
        - PowerShell 5.1 or higher.
        - All scripts in .\checks\ must be present.
        - config.json filled in with correct server names and credentials (see Initialize-CitrixCheck.ps1).
        - For VDA/Session checks: Citrix Broker PowerShell SDK (Citrix Studio / Remote SDK).
        - For License check: WMI access to the Citrix License Server.
        - For NetScaler checks: network access to each ADC management IP (port 443).
        - For XenServer checks: XenServer PowerShell SDK and network access to pool masters (port 443).
        - SMTP access for email delivery.

    First-time setup (run once, interactively, as the service account):
        PS> .\Initialize-CitrixCheck.ps1

    Scheduling (Windows Task Scheduler):
        Program:   powershell.exe
        Arguments: -NonInteractive -ExecutionPolicy Bypass -File "E:\Scripts\CitrixCheck\Invoke-DailyReport.ps1" -SaveReport
        Trigger:   Daily at 07:00
#>

[CmdletBinding()]
param(
    [string]$ConfigPath  = '',
    [switch]$SaveReport,
    [string]$SkipChecks  = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# Paths
# =============================================================================
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile  = if ($ConfigPath) { $ConfigPath } else { Join-Path $ScriptDir 'config.json' }
$ChecksDir   = Join-Path $ScriptDir 'checks'
$LogDir      = Join-Path $ScriptDir 'logs'
$ReportDir   = Join-Path $ScriptDir 'reports'
$LogFile     = Join-Path $LogDir "DailyReport_$(Get-Date -Format 'yyyyMMdd').log"

foreach ($dir in @($LogDir, $ReportDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
}

# =============================================================================
# Logging
# =============================================================================
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    $line | Tee-Object -FilePath $LogFile -Append | Write-Host
}

# =============================================================================
# Load config
# =============================================================================
Write-Log '======================================================='
Write-Log 'Citrix Daily Infrastructure Report - started'
Write-Log '======================================================='

if (-not (Test-Path $ConfigFile)) {
    Write-Log "config.json not found: $ConfigFile" 'ERROR'
    exit 1
}

$Config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
Write-Log "Configuration loaded from: $ConfigFile"

# =============================================================================
# Load suppressions (optional - create suppressions.json to silence known issues)
# =============================================================================
$SuppressFile = Join-Path $ScriptDir 'suppressions.json'
$Suppressions = @()
if (Test-Path $SuppressFile) {
    try {
        $today        = (Get-Date).Date
        $rawSup       = @(Get-Content $SuppressFile -Raw | ConvertFrom-Json)
        $Suppressions = @(foreach ($s in $rawSup) {
            if (-not $s.Until) { $s; continue }
            $d = [datetime]::MinValue
            if ([datetime]::TryParseExact($s.Until.Trim(), 'yyyy-MM-dd', $null, [System.Globalization.DateTimeStyles]::None, [ref]$d)) {
                if ($d -ge $today) { $s }
            }
            # Invalid date format: silently skip this suppression entry
        })
        if ($Suppressions.Count -gt 0) {
            Write-Log "Loaded $($Suppressions.Count) active suppression(s) from suppressions.json"
        }
    }
    catch { Write-Log "Could not load suppressions.json: $($_.Exception.Message)" 'WARN' }
}

# Build skip list
$skipList = if ($SkipChecks) { $SkipChecks -split ',' | ForEach-Object { $_.Trim() } } else { @() }

# =============================================================================
# Check definitions (name → script file → function)
# =============================================================================
$checkDefs = @(
    [PSCustomObject]@{ Key = 'Infrastructure'; Script = 'Check-Infrastructure.ps1'; Function = 'Invoke-InfrastructureCheck' }
    [PSCustomObject]@{ Key = 'VDAHealth';      Script = 'Check-VDAHealth.ps1';      Function = 'Invoke-VDAHealthCheck'      }
    [PSCustomObject]@{ Key = 'Sessions';       Script = 'Check-Sessions.ps1';       Function = 'Invoke-SessionCheck'        }
    [PSCustomObject]@{ Key = 'LicenseUsage';   Script = 'Check-LicenseUsage.ps1';   Function = 'Invoke-LicenseUsageCheck'   }
    [PSCustomObject]@{ Key = 'PVS';            Script = 'Check-PVS.ps1';            Function = 'Invoke-PVSCheck'            }
    [PSCustomObject]@{ Key = 'FAS';            Script = 'Check-FAS.ps1';            Function = 'Invoke-FASCheck'            }
    [PSCustomObject]@{ Key = 'NetScaler';      Script = 'Check-NetScaler.ps1';      Function = 'Invoke-NetScalerCheck'      }
    [PSCustomObject]@{ Key = 'XenServer';      Script = 'Check-XenServer.ps1';      Function = 'Invoke-XenServerCheck'      }
    [PSCustomObject]@{ Key = 'DiskSpace';      Script = 'Check-DiskSpace.ps1';      Function = 'Invoke-DiskSpaceCheck'      }
    [PSCustomObject]@{ Key = 'EventLog';       Script = 'Check-EventLog.ps1';       Function = 'Invoke-EventLogCheck'       }
)

# =============================================================================
# Run all checks
# =============================================================================
$results       = [System.Collections.Generic.List[PSCustomObject]]::new()
$overallIssues = $false

# =============================================================================
# Run all checks in parallel via a runspace pool
# =============================================================================
$activeChecks = @($checkDefs | Where-Object { $_.Key -notin $skipList -and (Test-Path (Join-Path $ChecksDir $_.Script)) })
foreach ($def in $checkDefs) {
    if ($def.Key -in $skipList)                                            { Write-Log "Skipping check: $($def.Key)" }
    elseif (-not (Test-Path (Join-Path $ChecksDir $def.Script)))           { Write-Log "Check script not found, skipping: $(Join-Path $ChecksDir $def.Script)" 'WARN' }
}

$rsPool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, [Math]::Max($activeChecks.Count, 2))
$rsPool.Open()

$runspaceJobs = [System.Collections.Generic.List[hashtable]]::new()
foreach ($def in $activeChecks) {
    Write-Log "Queuing check: $($def.Key) ..."
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.RunspacePool = $rsPool
    [void]$ps.AddScript({
        param($ScriptPath, $FunctionName, $Config)
        . $ScriptPath
        & $FunctionName -Config $Config
    })
    [void]$ps.AddArgument((Join-Path $ChecksDir $def.Script))
    [void]$ps.AddArgument($def.Function)
    [void]$ps.AddArgument($Config)
    $runspaceJobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); Def = $def })
}

# Collect results in original check order (wait per job, max 3 min per check)
$checkTimeoutMs = 180000
foreach ($jobInfo in $runspaceJobs) {
    $def = $jobInfo.Def
    try {
        $completed = $jobInfo.Handle.AsyncWaitHandle.WaitOne($checkTimeoutMs)
        if (-not $completed) {
            try { $jobInfo.PS.Stop() }    catch { }
            try { $jobInfo.PS.Dispose() } catch { }
            throw "Check time-out na $($checkTimeoutMs / 1000)s — mogelijk ontbrekende rechten of netwerkprobleem"
        }
        $rsOutput = @($jobInfo.PS.EndInvoke($jobInfo.Handle))
        $rsErrors = @($jobInfo.PS.Streams.Error)
        $jobInfo.PS.Dispose()

        if ($rsErrors.Count -gt 0 -and $rsOutput.Count -eq 0) {
            throw ($rsErrors | ForEach-Object { $_.Exception.Message }) -join '; '
        }
        $result = if ($rsOutput.Count -gt 0) { $rsOutput[0] } else { throw "No result returned from $($def.Key)" }
        $result | Add-Member -NotePropertyName SectionKey -NotePropertyValue $def.Key -Force
        if ($result.HasIssues) { $overallIssues = $true }
        $results.Add($result)
        Write-Log "  [$($result.CheckName)] $($result.Summary) | $($result.Duration)" $(if ($result.HasIssues) { 'WARN' } else { 'INFO' })
    }
    catch {
        try { $jobInfo.PS.Dispose() } catch { }
        $overallIssues = $true
        $errMsg = $_.Exception.Message
        $errResult = [PSCustomObject]@{
            CheckName   = $def.Key
            SectionKey  = $def.Key
            SectionHtml = "<div style='margin-bottom:24px;background:#fff;border-radius:6px;border:1px solid #e74c3c;overflow:hidden'><div style='background:#e74c3c;color:#fff;padding:12px 18px;font-size:16px;font-weight:700'>&#9888; $($def.Key) - Script Error</div><div style='padding:16px;color:#c0392b;font-size:13px'>$errMsg</div></div>"
            HasIssues   = $true
            IssueCount  = 1
            Summary     = "Script error: $errMsg"
            Duration    = '0s'
            Error       = $errMsg
        }
        $results.Add($errResult)
        Write-Log "  [$($def.Key)] FAILED: $errMsg" 'ERROR'
    }
}

$rsPool.Close()
$rsPool.Dispose()

# =============================================================================
# Build combined HTML email
# =============================================================================
Write-Log 'Building HTML report...'

# =============================================================================
# Suppressions - mark suppressed results so they don't affect overall status
# =============================================================================
foreach ($r in $results) {
    $sup = $Suppressions | Where-Object { $_.CheckName -eq $r.CheckName }
    if ($sup) {
        $r | Add-Member -NotePropertyName Suppressed       -NotePropertyValue $true              -Force
        $r | Add-Member -NotePropertyName SuppressionReason -NotePropertyValue $sup.Reason        -Force
    } else {
        $r | Add-Member -NotePropertyName Suppressed       -NotePropertyValue $false             -Force
        $r | Add-Member -NotePropertyName SuppressionReason -NotePropertyValue $null              -Force
    }
}

# =============================================================================
# Issue history - trend tracking (append today's counts; load yesterday's)
# =============================================================================
$HistoryCsv = Join-Path $LogDir 'IssueHistory.csv'

function _AppendHistory {
    param([System.Collections.Generic.List[PSCustomObject]]$Results, [string]$Path)
    $today = Get-Date -Format 'yyyy-MM-dd'
    if (-not (Test-Path $Path)) { "Date,CheckName,IssueCount" | Out-File $Path -Encoding UTF8 }
    foreach ($r in $Results) {
        "$today,$($r.CheckName -replace ',',';'),$($r.IssueCount)" | Out-File $Path -Encoding UTF8 -Append
    }
}

function _LoadPrevCounts {
    param([string]$Path)
    $prev = @{}
    if (-not (Test-Path $Path)) { return $prev }
    try {
        $today = Get-Date -Format 'yyyy-MM-dd'
        # Read all historical rows; last write per CheckName before today = yesterday's value
        Import-Csv $Path | Where-Object { $_.Date -ne $today } |
            ForEach-Object { $prev[$_.CheckName] = [int]$_.IssueCount }
    } catch { }
    return $prev
}

$prevCounts = _LoadPrevCounts -Path $HistoryCsv
_AppendHistory -Results $results -Path $HistoryCsv
Write-Log "Issue history updated: $HistoryCsv"

function _TrendBadge {
    param([string]$CheckName, [int]$Current, [hashtable]$Prev)
    if (-not $Prev.ContainsKey($CheckName)) { return '' }
    $d = $Current - $Prev[$CheckName]
    if ($d -gt 0) { return "<span style='color:#e74c3c;font-size:10px'>&#9650;+$d vs gisteren</span>" }
    if ($d -lt 0) { return "<span style='color:#27ae60;font-size:10px'>&#9660;$d vs gisteren</span>" }
    return "<span style='color:#aaa;font-size:10px'>= gisteren</span>"
}

# =============================================================================
# Build management summary (must be outside the here-string)
# =============================================================================
function _MgmtCard {
    param($Title, $MainVal, $MainCol, $Sub1, $Sub2, $Sub3, $Href = '', $Trend = '')
    $s1 = if ($Sub1)  { "<div style='font-size:11px;color:#777;margin-top:3px'>$Sub1</div>" } else { '' }
    $s2 = if ($Sub2)  { "<div style='font-size:11px;margin-top:2px'>$Sub2</div>" }           else { '' }
    $s3 = if ($Sub3)  { "<div style='font-size:11px;margin-top:2px'>$Sub3</div>" }           else { '' }
    $s4 = if ($Trend) { "<div style='margin-top:4px'>$Trend</div>" }                         else { '' }
    $cardStyle   = "flex:1;min-width:140px;border:1px solid #e8eaf0;border-radius:6px;padding:10px 13px"
    $cardContent = "<div style='font-size:10px;color:#aaa;font-weight:700;letter-spacing:.8px;text-transform:uppercase;margin-bottom:5px'>$Title</div>" +
                   "<div style='font-size:20px;font-weight:700;color:$MainCol;line-height:1.1'>$MainVal</div>" +
                   "$s1$s2$s3$s4"
    if ($Href) {
        return "<a href='$Href' style='$cardStyle;display:block;text-decoration:none;color:inherit'>$cardContent</a>"
    }
    return "<div style='$cardStyle'>$cardContent</div>"
}

$rInfr = $results | Where-Object { $_.CheckName -eq 'Infrastructure Services' }
$rVda  = $results | Where-Object { $_.CheckName -eq 'VDA Health' }
$rSess = $results | Where-Object { $_.CheckName -eq 'Session Monitor' }
$rLic  = $results | Where-Object { $_.CheckName -eq 'License Usage' }
$rPvs  = $results | Where-Object { $_.CheckName -eq 'Provisioning Services (PVS)' }
$rFas  = $results | Where-Object { $_.CheckName -eq 'Federated Authentication Service (FAS)' }
$rNs   = $results | Where-Object { $_.CheckName -eq 'NetScaler (Citrix ADC)' }
$rXen  = $results | Where-Object { $_.CheckName -eq 'XenServer Hosts' }
$rDisk = $results | Where-Object { $_.CheckName -eq 'Disk Space' }
$rEvt  = $results | Where-Object { $_.CheckName -eq 'Event Log' }

# Infrastructure - DDC / StoreFront / License Server (separate cards)
function _InfrRoleCard {
    param($Label, $Href, $RoleKey, $InfrResult)
    if (-not $InfrResult -or -not $InfrResult.RoleData -or -not $InfrResult.RoleData.ContainsKey($RoleKey)) {
        return _MgmtCard $Label '-' '#95a5a6' $null $null $null $Href
    }
    $rd  = $InfrResult.RoleData[$RoleKey]
    $txt = if ($rd.Issues -eq 0) { 'All OK' } else { "$($rd.Issues) issue(s)" }
    $col = if ($rd.Issues -eq 0) { '#27ae60' } else { '#e74c3c' }
    return _MgmtCard $Label $txt $col "$($rd.Servers) server(s)" $null $null $Href
}
# Kaartlabels: alles kort en consistent (text-transform:uppercase in CSS)
$cDDC    = _InfrRoleCard 'DDC'      '#section-Infrastructure' 'Delivery Controller' $rInfr
$cSF     = _InfrRoleCard 'SF'       '#section-Infrastructure' 'StoreFront'          $rInfr
$cLicSrv = _InfrRoleCard 'Lic. Server' '#section-Infrastructure' 'License Server'   $rInfr

# VDA
$mVda    = if ($rVda) { [regex]::Match($rVda.Summary, '(\d+) VDA.+?(\d+) unregistered, (\d+) in maintenance') } else { $null }
$vdaT    = if ($mVda -and $mVda.Success) { [int]$mVda.Groups[1].Value } else { 0 }
$vdaU    = if ($mVda -and $mVda.Success) { [int]$mVda.Groups[2].Value } else { 0 }
$vdaM    = if ($mVda -and $mVda.Success) { [int]$mVda.Groups[3].Value } else { 0 }
$vdaR    = $vdaT - $vdaU
$vdaPct  = if ($vdaT -gt 0) { [math]::Round(($vdaR / $vdaT) * 100) } else { 0 }
$vdaCol  = if ($vdaPct -ge 95) { '#27ae60' } elseif ($vdaPct -ge 85) { '#f39c12' } else { '#e74c3c' }
$vdaSub2 = if ($vdaU -gt 0) { "<span style='color:#e74c3c;font-weight:600'>$vdaU unregistered</span>" } else { $null }
$vdaSub3 = if ($vdaM -gt 0) { "<span style='color:#f39c12'>$vdaM in maintenance</span>" } else { $null }
$infoCardBadge = "<span style='font-size:10px;background:#3498db;color:#fff;padding:1px 5px;border-radius:6px;font-weight:700'>informational</span>"
$cVda    = _MgmtCard 'VDA' "$vdaPct% reg." $vdaCol "$vdaR / $vdaT registered" $vdaSub2 $vdaSub3 '#section-VDAHealth' ("$infoCardBadge " + (_TrendBadge 'VDA Health' $vdaU $prevCounts))

# Sessions
$mSess    = if ($rSess) { [regex]::Match($rSess.Summary, '(\d+) session.+?(\d+) active, (\d+) disconnected, (\d+) idle') } else { $null }
$sT       = if ($mSess -and $mSess.Success) { $mSess.Groups[1].Value } else { '-' }
$sA       = if ($mSess -and $mSess.Success) { $mSess.Groups[2].Value } else { '-' }
$sD       = if ($mSess -and $mSess.Success) { $mSess.Groups[3].Value } else { '-' }
$sI       = if ($mSess -and $mSess.Success) { [int]$mSess.Groups[4].Value } else { 0 }
$sessSub2 = if ($sI -gt 0) { "<span style='color:#e74c3c;font-weight:600'>$sI idle &gt;480 min</span>" } else { $null }
$cSess    = _MgmtCard 'Sessions' $sT '#2c3e50' "<span style='color:#27ae60;font-weight:600'>$sA active</span>  $sD disconnected" $sessSub2 $null '#section-Sessions' ("$infoCardBadge " + (_TrendBadge 'Session Monitor' $(if ($rSess) { $rSess.IssueCount } else { 0 }) $prevCounts))

# Lic. Usage
$mLic   = if ($rLic) { [regex]::Match($rLic.Summary, '(\d+) license type.+?(\d+) above') } else { $null }
$licT   = if ($mLic -and $mLic.Success) { $mLic.Groups[1].Value } else { '-' }
$licI   = if ($mLic -and $mLic.Success) { [int]$mLic.Groups[2].Value } else { -1 }
$licTxt = if ($licI -lt 0) { if ($rLic -and $rLic.HasIssues) { 'Check failed' } else { 'Unknown' } } elseif ($licI -eq 0) { 'OK' } else { "$licI over threshold" }
$licCol = if ($licI -eq 0) { '#27ae60' } elseif ($licI -gt 0) { '#e74c3c' } else { '#95a5a6' }
$licSub = if ($licT -ne '-') { "$licT type(s)" } else { $null }
$cLic   = _MgmtCard 'Lic. Usage' $licTxt $licCol $licSub $null $null '#section-LicenseUsage' (_TrendBadge 'License Usage' $(if ($rLic) { $rLic.IssueCount } else { 0 }) $prevCounts)

# PVS
$pvsTxt  = if ($rPvs) { if ($rPvs.HasIssues) { "$($rPvs.IssueCount) issue(s)" } else { 'All OK' } } else { '-' }
$pvsCol  = if ($rPvs -and -not $rPvs.HasIssues) { '#27ae60' } else { '#e74c3c' }
$pvsMat  = if ($rPvs) { [regex]::Match($rPvs.Summary, '(\d+) PVS server') } else { $null }
$pvsSub  = if ($pvsMat -and $pvsMat.Success) { "$($pvsMat.Groups[1].Value) PVS servers" } else { $null }
$pvsDevM = if ($rPvs) { [regex]::Match($rPvs.Summary, '(\d+) device') } else { $null }
$pvsSub2 = if ($pvsDevM -and $pvsDevM.Success) { "$($pvsDevM.Groups[1].Value) devices active" } else { $null }
$cPvs    = _MgmtCard 'PVS' $pvsTxt $pvsCol $pvsSub $pvsSub2 $null '#section-PVS' (_TrendBadge 'Provisioning Services (PVS)' $(if ($rPvs) { $rPvs.IssueCount } else { 0 }) $prevCounts)

# FAS
$fasTxt = if ($rFas) { if ($rFas.HasIssues) { "$($rFas.IssueCount) issue(s)" } else { 'All OK' } } else { '-' }
$fasCol = if ($rFas -and -not $rFas.HasIssues) { '#27ae60' } else { '#e74c3c' }
$fasMat = if ($rFas) { [regex]::Match($rFas.Summary, '(\d+) FAS server') } else { $null }
$fasSub = if ($fasMat -and $fasMat.Success) { "$($fasMat.Groups[1].Value) FAS servers" } else { $null }
$cFas   = _MgmtCard 'FAS' $fasTxt $fasCol $fasSub $null $null '#section-FAS' (_TrendBadge 'Federated Authentication Service (FAS)' $(if ($rFas) { $rFas.IssueCount } else { 0 }) $prevCounts)

# XenServer
$xenTxt = if ($rXen) { if ($rXen.HasIssues) { "$($rXen.IssueCount) issue(s)" } else { 'All OK' } } else { '-' }
$xenCol = if ($rXen -and -not $rXen.HasIssues) { '#27ae60' } else { '#e74c3c' }
$xenMat = if ($rXen) { [regex]::Match($rXen.Summary, '(\d+) host.+?(\d+) running VM') } else { $null }
$xenSub = if ($xenMat -and $xenMat.Success) { "$($xenMat.Groups[1].Value) hosts | $($xenMat.Groups[2].Value) VMs" } else { $null }
$cXen   = _MgmtCard 'XenServer' $xenTxt $xenCol $xenSub $null $null '#section-XenServer' (_TrendBadge 'XenServer Hosts' $(if ($rXen) { $rXen.IssueCount } else { 0 }) $prevCounts)

# Disk
$mDisk  = if ($rDisk) { [regex]::Match($rDisk.Summary, '(\d+) server.+?(\d+) drive') } else { $null }
$dkSrvs = if ($mDisk -and $mDisk.Success) { $mDisk.Groups[1].Value } else { '-' }
$dkIss  = if ($mDisk -and $mDisk.Success) { [int]$mDisk.Groups[2].Value } else { 0 }
$dkTxt  = if ($dkIss -eq 0) { 'All OK' } else { "$dkIss drive(s) low" }
$dkCol  = if ($dkIss -eq 0) { '#27ae60' } else { '#e74c3c' }
$cDisk  = _MgmtCard 'Disk' $dkTxt $dkCol "$dkSrvs servers" $null $null '#section-DiskSpace' (_TrendBadge 'Disk Space' $(if ($rDisk) { $rDisk.IssueCount } else { 0 }) $prevCounts)

# NetScaler
$nsTxt  = if ($rNs) { if ($rNs.HasIssues) { "$($rNs.IssueCount) issue(s)" } else { 'All OK' } } else { '-' }
$nsCol  = if ($rNs -and -not $rNs.HasIssues) { '#27ae60' } elseif ($rNs) { '#e74c3c' } else { '#95a5a6' }
$nsCnt  = if ($rNs -and $rNs.Summary) { (@($rNs.Summary -split '\|')).Count } else { 0 }
$nsSub  = if ($nsCnt -gt 0) { "$nsCnt instance(s)" } else { $null }
$cNs    = _MgmtCard 'NetScaler' $nsTxt $nsCol $nsSub $null $null '#section-NetScaler' (_TrendBadge 'NetScaler (Citrix ADC)' $(if ($rNs) { $rNs.IssueCount } else { 0 }) $prevCounts)

# Events
$mEvt   = if ($rEvt) { [regex]::Match($rEvt.Summary, '(\d+) server.+?(\d+) error') } else { $null }
$evtE   = if ($mEvt -and $mEvt.Success) { [int]$mEvt.Groups[2].Value } else { 0 }
$evtTxt = if ($evtE -eq 0) { 'No errors' } else { "$evtE error(s)" }
$evtCol = if ($evtE -eq 0) { '#27ae60' } elseif ($evtE -le 20) { '#f39c12' } else { '#e74c3c' }
$cEvt   = _MgmtCard 'Events' $evtTxt $evtCol '24h scan' $null $null '#section-EventLog' (_TrendBadge 'Event Log' $(if ($rEvt) { $rEvt.IssueCount } else { 0 }) $prevCounts)

# Suppression notice bar (only shown when suppressions are active)
$supNotice = ''
$activeSups = @($results | Where-Object { $_.Suppressed -and $_.HasIssues })
if ($activeSups.Count -gt 0) {
    $supNames  = ($activeSups | ForEach-Object { $_.CheckName }) -join ', '
    $supNotice = "<div style='font-size:11px;color:#856404;background:#fff3cd;border:1px solid #ffc107;border-radius:4px;padding:6px 10px;margin-top:8px'>&#9888; $($activeSups.Count) check(s) suppressed (not counted): $supNames</div>"
}

# Order: infra servers first, then app checks, then services, then monitoring
$mgmtSummaryHtml = "<div style='background:#fff;border-left:1px solid #dde1e7;border-right:1px solid #dde1e7;border-bottom:1px solid #dde1e7;padding:14px 20px'>" +
    "<div style='font-size:10px;font-weight:700;color:#aaa;letter-spacing:1px;text-transform:uppercase;margin-bottom:10px'>Management Summary</div>" +
    "<div style='display:flex;gap:8px;flex-wrap:wrap'>$cDDC $cSF $cLicSrv $cLic $cVda $cSess $cPvs $cFas $cNs $cXen $cDisk $cEvt</div>" +
    "$supNotice</div>"

$reportDate       = Get-Date -Format 'dddd, d MMMM yyyy HH:mm'
$totalChecks      = $results.Count
# Checks that are purely informational - never count toward the issue total or header colour
$infoOnlyKeys     = @('VDAHealth', 'Sessions')
# Exclude suppressed checks and info-only checks from the headline issue count
$checksWithIssues = @($results | Where-Object { $_.HasIssues -and -not $_.Suppressed -and $_.SectionKey -notin $infoOnlyKeys }).Count
$issueCountColor  = if ($checksWithIssues -gt 0) { '#e74c3c' } else { '#27ae60' }

# Header colour: groen = alles OK, oranje = 1-2 checks met issues, rood = 3+ checks met issues
$headerColour = if ($checksWithIssues -eq 0) { '#27ae60' } elseif ($checksWithIssues -le 2) { '#f39c12' } else { '#e74c3c' }
$headerText   = if ($checksWithIssues -eq 0) { 'ALL SYSTEMS OK' } elseif ($checksWithIssues -le 2) { 'ATTENTION RECOMMENDED' } else { 'ATTENTION REQUIRED' }

# Summary table rows
$summaryRows = foreach ($r in $results) {
    $isSup      = $r.PSObject.Properties['Suppressed'] -and $r.Suppressed
    $isInfo     = $r.PSObject.Properties['SectionKey'] -and $r.SectionKey -in $infoOnlyKeys
    $icon       = if ($r.HasIssues -and -not $isInfo) { '&#10007;' } else { '&#10003;' }
    $iconColor  = if ($r.HasIssues -and -not $isSup -and -not $isInfo) { '#e74c3c' } elseif ($r.HasIssues -and -not $isInfo) { '#f39c12' } else { '#27ae60' }
    $rowBg      = if ($r.HasIssues -and -not $isSup -and -not $isInfo) { '#fff5f5' } elseif ($r.HasIssues -and -not $isInfo) { '#fffdf0' } else { '' }
    $resultText = if ($r.HasIssues -and $isSup) { "Issues found <span style='font-size:10px;background:#f39c12;color:#fff;padding:1px 6px;border-radius:8px;font-weight:700'>suppressed</span>" } elseif ($isInfo) { "OK <span style='font-size:10px;background:#3498db;color:#fff;padding:1px 6px;border-radius:8px;font-weight:700'>informational</span>" } elseif ($r.HasIssues) { 'Issues found' } else { 'OK' }
    $secHref    = if ($r.SectionKey) { "#section-$($r.SectionKey)" } else { '' }
    $nameCell   = if ($secHref) { "<a href='$secHref' style='color:#2c3e50;text-decoration:none;font-weight:500'>$($r.CheckName)</a>" } else { $r.CheckName }
    @"
        <tr style='background:$rowBg'>
          <td style='padding:7px 14px;border-bottom:1px solid #ecf0f1;font-size:13px'>$nameCell</td>
          <td style='padding:7px 14px;border-bottom:1px solid #ecf0f1;font-size:13px;color:$iconColor;font-weight:bold'>$icon $resultText</td>
          <td style='padding:7px 14px;border-bottom:1px solid #ecf0f1;font-size:12px;color:#777'>$($r.Summary)</td>
          <td style='padding:7px 14px;border-bottom:1px solid #ecf0f1;font-size:12px;color:#aaa'>$($r.Duration)</td>
        </tr>
"@
}

# Combine all section HTML - inject section ID, cx-section class and initial collapsed state
$allSections = ($results | ForEach-Object {
    $html      = $_.SectionHtml
    $secId     = if ($_.SectionKey) { "section-$($_.SectionKey)" } else { '' }
    $isInfoSec = $_.PSObject.Properties['SectionKey'] -and $_.SectionKey -in $infoOnlyKeys
    $initState = if ($_.HasIssues -and -not $isInfoSec) { '0' } else { '1' }   # info-only starts collapsed
    # Replace any status badge (red/orange/green) with blue INFORMATIONAL in section headers for info-only checks
    if ($isInfoSec) {
        $html = [regex]::Replace($html,
            "<span style='font-size:12px;background:#(?:e74c3c|f39c12|27ae60);padding:4px 12px;border-radius:12px;font-weight:700'>[^<]+</span>",
            "<span style='font-size:12px;background:#3498db;padding:4px 12px;border-radius:12px;font-weight:700'>INFORMATIONAL</span>")
    }
    $token = "<div style='margin-bottom:24px;"
    $pos   = $html.IndexOf($token)
    if ($pos -ge 0) {
        $idAttr = if ($secId) { " id='$secId'" } else { '' }
        $html = $html.Substring(0, $pos + 4) + "$idAttr class='cx-section' data-collapsed='$initState' " + $html.Substring($pos + 4)
    }
    $html
}) -join "`n"

$htmlReport = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Citrix Daily Report</title>
</head>
<body style='margin:0;padding:0;background:#f0f2f5;font-family:Segoe UI,Arial,sans-serif'>
  <div style='max-width:800px;margin:30px auto;padding:0 16px'>

    <!-- == Header =========================================================== -->
    <div style='background:$headerColour;color:#fff;padding:24px 28px;border-radius:8px 8px 0 0;text-align:center'>
      <div style='font-size:11px;letter-spacing:2px;text-transform:uppercase;opacity:.8;margin-bottom:4px'>
        YourOrganisation
      </div>
      <div style='font-size:26px;font-weight:700;letter-spacing:1px'>
        CITRIX DAILY INFRASTRUCTURE REPORT
      </div>
      <div style='margin-top:6px;font-size:13px;opacity:.9'>$reportDate</div>
      <div style='margin-top:16px;display:inline-block;background:rgba(255,255,255,.2);padding:7px 24px;border-radius:20px;font-weight:700;font-size:15px;letter-spacing:1px'>
        $headerText
      </div>
    </div>

    <!-- == Summary bar ====================================================== -->
    <div style='background:#fff;padding:16px 28px;border-left:1px solid #dde1e7;border-right:1px solid #dde1e7;display:flex;gap:32px;align-items:center'>
      <div style='text-align:center'>
        <div style='font-size:28px;font-weight:700;color:#2c3e50'>$totalChecks</div>
        <div style='font-size:11px;color:#777'>Checks run</div>
      </div>
      <div style='text-align:center'>
        <div style='font-size:28px;font-weight:700;color:#27ae60'>$($totalChecks - $checksWithIssues)</div>
        <div style='font-size:11px;color:#777'>Passed</div>
      </div>
      <div style='text-align:center'>
        <div style='font-size:28px;font-weight:700;color:$issueCountColor'>$checksWithIssues</div>
        <div style='font-size:11px;color:#777'>With issues</div>
      </div>
    </div>

    <!-- == Management summary =============================================== -->
    $mgmtSummaryHtml

    <!-- == Check summary table ============================================== -->
    <div style='background:#fff;border-left:1px solid #dde1e7;border-right:1px solid #dde1e7;border-bottom:1px solid #dde1e7'>
      <table style='width:100%;border-collapse:collapse'>
        <thead>
          <tr style='background:#f4f6f8'>
            <th style='padding:7px 14px;text-align:left;color:#555;font-size:12px;font-weight:600'>Check</th>
            <th style='padding:7px 14px;text-align:left;color:#555;font-size:12px;font-weight:600'>Result</th>
            <th style='padding:7px 14px;text-align:left;color:#555;font-size:12px;font-weight:600'>Summary</th>
            <th style='padding:7px 14px;text-align:left;color:#555;font-size:12px;font-weight:600'>Duration</th>
          </tr>
        </thead>
        <tbody>$summaryRows</tbody>
      </table>
    </div>

    <!-- == Spacer =========================================================== -->
    <div style='height:24px'></div>

    <!-- == Individual check sections ======================================= -->
    $allSections

    <!-- == Collapse script (browser only, ignored by email clients) ======= -->
    <script>
    (function(){
      function applyCollapsed(sec, collapsed) {
        sec.querySelectorAll(':scope > div:not(:first-child)').forEach(function(c){ c.style.display = collapsed ? 'none' : ''; });
        sec.setAttribute('data-collapsed', collapsed ? '1' : '0');
      }
      function addCollapse(selector, togCss, showExpandAll) {
        document.querySelectorAll(selector).forEach(function(sec){
          var hdr = sec.querySelector(':scope > div:first-child');
          if (!hdr) return;
          hdr.style.cursor = 'pointer';

          // Expand/collapse-all for outer sections (cx-section only)
          if (showExpandAll) {
            var allBtn = document.createElement('span');
            allBtn.style.cssText = 'float:right;font-size:10px;opacity:.5;font-weight:normal;margin-left:12px;cursor:pointer';
            allBtn.textContent = '\u2195 all';
            allBtn.title = 'Expand / collapse all sub-items';
            allBtn.addEventListener('click', function(e){
              e.stopPropagation();
              var subs = sec.querySelectorAll('.cx-sub');
              if (!subs.length) return;
              var anyOpen = Array.prototype.some.call(subs, function(s){ return s.getAttribute('data-collapsed') !== '1'; });
              subs.forEach(function(s){
                var st = anyOpen;
                applyCollapsed(s, st);
                var t = s.querySelector(':scope > div:first-child > span[data-tog]');
                if (t) t.textContent = st ? '\u25BC expand' : '\u25B2 collapse';
              });
            });
            hdr.appendChild(allBtn);
          }

          var tog = document.createElement('span');
          tog.setAttribute('data-tog','1');
          tog.style.cssText = togCss;
          var initCollapsed = sec.getAttribute('data-collapsed') === '1';
          tog.textContent = initCollapsed ? '\u25BC expand' : '\u25B2 collapse';
          hdr.appendChild(tog);

          // Apply initial state on load
          if (initCollapsed) applyCollapsed(sec, true);

          hdr.addEventListener('click', function(){
            var collapsed = sec.getAttribute('data-collapsed') === '1';
            applyCollapsed(sec, !collapsed);
            tog.textContent = !collapsed ? '\u25BC expand' : '\u25B2 collapse';
          });
        });
      }
      addCollapse('.cx-section', 'float:right;font-size:11px;opacity:.7;font-weight:normal;margin-left:8px', true);
      addCollapse('.cx-sub',     'float:right;font-size:10px;opacity:.6;font-weight:normal;margin-left:8px', false);
    })();
    </script>

    <!-- == Footer =========================================================== -->
    <div style='text-align:center;padding:20px;font-size:11px;color:#aaa;border-top:1px solid #e0e0e0;margin-top:8px'>
      Citrix Infrastructure Monitor &bull; YourOrganisation &bull; $reportDate<br>
      Generated by Invoke-DailyReport.ps1 &bull; PowerShell $($PSVersionTable.PSVersion)
    </div>

  </div>
</body>
</html>
"@

# =============================================================================
# Save report to disk (optional)
# =============================================================================
# Altijd opslaan (nodig als e-mailbijlage); bewaar alleen op schijf bij -SaveReport
$reportFile = Join-Path $ReportDir "CitrixReport_$(Get-Date -Format 'yyyyMMdd_HHmm').html"
$htmlReport | Out-File -FilePath $reportFile -Encoding UTF8 -Force
if ($SaveReport) { Write-Log "Report saved: $reportFile" }

# =============================================================================
# Send email
# =============================================================================
$subject = $Config.Email.Subject -replace '\{date\}', (Get-Date -Format 'dd-MM-yyyy')

Write-Log "Sending email to: $($Config.Email.To)"

try {
    # Build SMTP credential from encrypted password stored in config
    $smtpKeyFile = Join-Path $ScriptDir $Config.Email.SmtpKeyFile
    if (-not (Test-Path $smtpKeyFile)) {
        throw "SMTP key file not found: $smtpKeyFile. See setup instructions in the script header."
    }
    $smtpKey        = [System.IO.File]::ReadAllBytes($smtpKeyFile)
    $securePassword = $Config.Email.SmtpPassword | ConvertTo-SecureString -Key $smtpKey
    $smtpCredential = New-Object System.Management.Automation.PSCredential($Config.Email.SmtpUsername, $securePassword)

    # Dynamic priority: High when 3+ unsuppressed/non-info checks have issues; Low when all OK
    $issueCount     = @($results | Where-Object { $_.HasIssues -and $_.SectionKey -notin $infoOnlyKeys }).Count
    $mailPriority   = if ($Config.Email.Priority) { $Config.Email.Priority }
                      elseif ($issueCount -ge 3) { 'High' }
                      elseif ($issueCount -eq 0) { 'Low' }
                      else { 'Normal' }

    # Eenvoudige e-mailtekst — volledig rapport zit als bijlage
    # Gebruik dezelfde kleur/tekst als de rapport-header (groen/oranje/rood)
    $statusColor = $headerColour
    $statusLabel = if ($checksWithIssues -eq 0) { 'ALL OK' } elseif ($checksWithIssues -le 2) { "ATTENTION RECOMMENDED — $checksWithIssues check(s) with issues" } else { "ATTENTION REQUIRED — $checksWithIssues check(s) with issues" }
    $checkRows   = ($results | ForEach-Object {
        $isInfoRow = $_.PSObject.Properties['SectionKey'] -and $_.SectionKey -in $infoOnlyKeys
        $ico = if ($_.HasIssues -and -not $isInfoRow) { "<span style='color:#e74c3c'>&#10008; $($_.IssueCount) issue(s)</span>" } else { "<span style='color:#27ae60'>&#10004; OK</span>" }
        "<tr><td style='padding:6px 14px;border-bottom:1px solid #eee'>$($_.CheckName)</td>" +
        "<td style='padding:6px 14px;border-bottom:1px solid #eee'>$ico</td>" +
        "<td style='padding:6px 14px;border-bottom:1px solid #eee;color:#555;font-size:12px'>$($_.Summary)</td></tr>"
    }) -join ''
    $emailBody = @"
<html><body style='font-family:Arial,sans-serif;font-size:13px;color:#333;margin:0;padding:20px'>
<div style='background:$statusColor;color:#fff;padding:16px 24px;border-radius:6px;margin-bottom:20px'>
  <div style='font-size:11px;opacity:.8;margin-bottom:4px'>$($Config.Email.EnvironmentName)</div>
  <div style='font-size:20px;font-weight:700'>$statusLabel</div>
  <div style='font-size:12px;opacity:.8;margin-top:4px'>$(Get-Date -Format 'dddd, d MMMM yyyy HH:mm')</div>
</div>
<table style='border-collapse:collapse;width:100%;max-width:800px'>
  <tr style='background:#f5f6f8'>
    <th style='padding:8px 14px;text-align:left;font-size:11px;color:#888;font-weight:700;letter-spacing:.5px;text-transform:uppercase'>Check</th>
    <th style='padding:8px 14px;text-align:left;font-size:11px;color:#888;font-weight:700;letter-spacing:.5px;text-transform:uppercase'>Resultaat</th>
    <th style='padding:8px 14px;text-align:left;font-size:11px;color:#888;font-weight:700;letter-spacing:.5px;text-transform:uppercase'>Samenvatting</th>
  </tr>
  $checkRows
</table>
<p style='color:#aaa;font-size:11px;margin-top:24px'>Full report attached as HTML file. Open in a browser for the complete view.</p>
</body></html>
"@

    $mailParams = @{
        To          = $Config.Email.To
        From        = $Config.Email.From
        Subject     = $subject
        Body        = $emailBody
        BodyAsHtml  = $true
        Attachments = $reportFile
        SmtpServer  = $Config.Email.SmtpServer
        Port        = $Config.Email.SmtpPort
        Priority    = $mailPriority
        Credential  = $smtpCredential
    }
    if ($Config.Email.UseSSL) { $mailParams.UseSsl = $true }

    Send-MailMessage @mailParams
    Write-Log 'Email sent successfully.'
}
catch {
    Write-Log "Failed to send email: $($_.Exception.Message)" 'ERROR'
}
finally {
    # Remove temporary report file if -SaveReport was not specified
    if (-not $SaveReport -and $reportFile -and (Test-Path $reportFile)) {
        Remove-Item $reportFile -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# Final summary
# =============================================================================
$finalStatus = if ($overallIssues) { 'COMPLETED - ISSUES FOUND' } else { 'COMPLETED - ALL OK' }
Write-Log '======================================================='
Write-Log "Daily report $finalStatus"
Write-Log '======================================================='

