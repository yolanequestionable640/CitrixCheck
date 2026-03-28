#Requires -Version 5.1
<#
.SYNOPSIS
    Citrix Provisioning Services (PVS) health check.

.DESCRIPTION
    Connects to a Citrix PVS farm using the Citrix PVS PowerShell snap-in
    (Citrix.PVS.SnapIn) and reports on:

        1. PVS server status - online/offline state and active device connections
           for each of the four provisioning servers (PVS05-08).
        2. Stream service performance - active sessions, retry counts, and
           connection status per server.
        3. vDisk version status - highlights vDisks with pending merges, test
           versions or maintenance versions that are not yet promoted to production.
        4. Target device connectivity - total booted device count across the farm
           and devices in an abnormal state (e.g. active on wrong server).

    Falls back to a service-only reachability check when the PVS SDK snap-in is
    not available on the machine running the script.

    Can be run standalone or dot-sourced by Invoke-DailyReport.ps1.

.PARAMETER Config
    PSCustomObject parsed from config.json. When omitted the script loads config.json
    from its own parent directory (standalone mode).

.EXAMPLE
    PS C:\> .\checks\Check-PVS.ps1
    Runs the PVS health check and prints a summary to the console.

.EXAMPLE
    # Used by the master orchestrator:
    . .\checks\Check-PVS.ps1
    $result = Invoke-PVSCheck -Config $config

.INPUTS
    None. All input comes from config.json or the -Config parameter.

.OUTPUTS
    [PSCustomObject] with properties:
        CheckName   [string]  - Display name of this check.
        SectionHtml [string]  - HTML fragment to embed in the daily report.
        HasIssues   [bool]    - $true when servers are offline or vDisk issues exist.
        IssueCount  [int]     - Number of individual issues found.
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
        - Citrix PVS PowerShell snap-in (Citrix.PVS.SnapIn).
          Installed with Citrix Provisioning Console or the PVS Remote SDK.
          Snap-in path: C:\Program Files\Citrix\Provisioning Services Console\
        - Network access and WinRM to all PVS servers listed in config.json.
        - PVS Read-Only Administrator role or higher.
        - Fallback mode (service check only) requires WinRM access.

    PVS servers monitored:
        CTX-PVS01.ad.example.com
        CTX-PVS02.ad.example.com
        CTX-PVS03.ad.example.com
        CTX-PVS04.ad.example.com

    Scheduling:
        Run daily via Windows Task Scheduler or call through Invoke-DailyReport.ps1.
#>

# =============================================================================
# Exported function
# =============================================================================
function Invoke-PVSCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $checkName = 'Provisioning Services (PVS)'

    # PVS server list from config
    $pvsServers = if ($Config.PVS -and $Config.PVS.Servers) {
        @($Config.PVS.Servers)
    }
    else {
        # Fallback: derive from Servers array by role
        @($Config.Servers | Where-Object { $_.Role -eq 'Provisioning Services' } | Select-Object -ExpandProperty Name)
    }
    $primaryPVS = if ($Config.PVS -and $Config.PVS.PrimaryServer) { $Config.PVS.PrimaryServer } else { $pvsServers[0] }

    # == Try SDK path ==========================================================
    $sdkAvailable = $false
    if (-not (Get-PSSnapin -Name Citrix.PVS.SnapIn -ErrorAction SilentlyContinue)) {
        try {
            Add-PSSnapin -Name Citrix.PVS.SnapIn -ErrorAction Stop
            $sdkAvailable = $true
        }
        catch {
            Write-Verbose "PVS snap-in not available - falling back to service check. ($_)"
        }
    }
    else {
        $sdkAvailable = $true
    }

    if (-not $sdkAvailable) {
        return _RunPVSServiceFallback -PvsServers $pvsServers -Config $Config -Stopwatch $stopwatch -CheckName $checkName
    }

    # SDK beschikbaar: probeer SOAP (alle servers) → WinRM → service-fallback
    try {
        return _RunPVSFullCheck -PrimaryPVS $primaryPVS -PvsServers $pvsServers -Stopwatch $stopwatch -CheckName $checkName
    }
    catch {
        Write-Verbose "PVS full check failed ($($_.Exception.Message)) - falling back to service check"
        return _RunPVSServiceFallback -PvsServers $pvsServers -Config $Config -Stopwatch $stopwatch -CheckName $checkName -SdkError $_.Exception.Message
    }
}

# =============================================================================
# Scriptblock voor PVS data-collectie — uitgevoerd lokaal (direct SOAP)
# OF remote via Invoke-Command (WinRM naar PVS-server zelf).
# Vereist een actieve Set-PvsConnection vóór aanroep (lokaal), of
# verbindt zelf op localhost (remote pad).
# =============================================================================
$script:_pvs_collect = {
    param([bool]$Remote = $false)
    if ($Remote) {
        if (-not (Get-PSSnapin Citrix.PVS.SnapIn -ErrorAction SilentlyContinue)) {
            Add-PSSnapin Citrix.PVS.SnapIn -ErrorAction Stop
        }
        Set-PvsConnection -Server localhost -ErrorAction Stop | Out-Null
    }

    $srvObjects   = @(Get-PvsServer      -ErrorAction SilentlyContinue)
    $diskLocators = @(Get-PvsDiskLocator -ErrorAction SilentlyContinue)
    $devices      = @(Get-PvsDeviceInfo  -ErrorAction SilentlyContinue)

    # Per-server status + device count
    $srvStatus = foreach ($s in $srvObjects) {
        $st  = Get-PvsServerStatus -ServerName $s.ServerName -ErrorAction SilentlyContinue
        $dc  = @($devices | Where-Object { $_.ServerName -eq $s.ServerName }).Count
        $ap  = if ($st) { $st.PSObject.Properties['Active'] } else { $null }
        $act = ($ap -and [bool]$ap.Value) -or $dc -gt 0
        [PSCustomObject]@{
            ServerName  = $s.ServerName
            AddrList    = if ($s.PSObject.Properties['AddrList'] -and $s.AddrList) { @($s.AddrList) } else { @() }
            Active      = $act
            DeviceCount = $dc
        }
    }

    # Per-locator: versies + inventaris
    $diskVersions = [System.Collections.Generic.List[object]]::new()
    $diskInventory = foreach ($dl in $diskLocators) {
        $dvs      = @(Get-PvsDiskVersion -DiskLocatorId $dl.DiskLocatorId -ErrorAction SilentlyContinue)
        $dlVers   = [System.Collections.Generic.List[object]]::new()
        if ($dvs) { foreach ($dv in $dvs) { $dlVers.Add($dv) } }
        foreach ($dv in $dlVers) { $diskVersions.Add($dv) }

        $accMap  = @{ 1 = 'Maint'; 2 = 'Test'; 3 = 'Merge' }
        $prod    = $null
        $nonProd = [System.Collections.Generic.List[object]]::new()
        foreach ($dv in $dlVers) {
            if ([int]$dv.Access -eq 0) {
                if (-not $prod -or [int]$dv.Version -gt [int]$prod.Version) { $prod = $dv }
            } else { $nonProd.Add($dv) }
        }
        $storeVal = if ($dl.PSObject.Properties['StoreName'] -and $dl.StoreName) { $dl.StoreName } else { '-' }
        $nonProdDetail = if ($nonProd.Count -gt 0) {
            ($nonProd | ForEach-Object {
                $at = if ($accMap.ContainsKey([int]$_.Access)) { $accMap[[int]$_.Access] } else { '?' }
                "v$($_.Version):$at"
            }) -join ', '
        } else { '' }
        [PSCustomObject]@{
            Name          = $dl.DiskLocatorName
            Store         = $storeVal
            ProdVersion   = if ($prod) { [int]$prod.Version } else { '-' }
            TotalVersions = $dlVers.Count
            HasNonProd    = ($nonProd.Count -gt 0)
            NonProdDetail = $nonProdDetail
        }
    }

    # Streaming distribution (avoid passing full device objects over WinRM)
    $totalDevices = $devices.Count
    $streamDistrib = if ($totalDevices -gt 0) {
        @($devices | Group-Object -Property DiskLocatorName |
            ForEach-Object { [PSCustomObject]@{ VDisk = $_.Name; DeviceCount = $_.Count } } |
            Sort-Object DeviceCount -Descending)
    } else { @() }

    [PSCustomObject]@{
        SrvStatus     = @($srvStatus)
        DiskInventory = @($diskInventory)
        DiskVersions  = @($diskVersions)
        TotalDevices  = $totalDevices
        StreamDistrib = @($streamDistrib)
    }
}

# =============================================================================
# Full SDK check
# =============================================================================
function _RunPVSFullCheck {
    param($PrimaryPVS, $PvsServers, $Stopwatch, $CheckName)

    # -- Tier 1: probeer SOAP-verbinding op elke PVS-server in volgorde --------
    $raw        = $null
    $lastError  = ''
    $attemptOrder = @($PrimaryPVS) + @($PvsServers | Where-Object { $_ -ne $PrimaryPVS })

    foreach ($srv in $attemptOrder) {
        try {
            Write-Verbose "PVS: SOAP verbinding naar $srv"
            Set-PvsConnection -Server $srv -ErrorAction Stop | Out-Null
            $raw = & $script:_pvs_collect $false
            break
        }
        catch {
            $lastError = $_.Exception.Message
            Write-Verbose "PVS: SOAP to $srv failed — $lastError"
        }
    }

    # -- Tier 2: WinRM to primary PVS server (Set-PvsConnection -Server localhost) --
    if (-not $raw) {
        Write-Verbose "PVS: all SOAP connections failed — WinRM to $PrimaryPVS"
        $sessionOpts = New-PSSessionOption -OpenTimeout 15000 -OperationTimeout 60000
        $raw = Invoke-Command -ComputerName $PrimaryPVS `
                              -ScriptBlock $script:_pvs_collect `
                              -ArgumentList $true `
                              -SessionOption $sessionOpts `
                              -ErrorAction Stop
    }

    # -- Data verwerken (zelfde pad voor SOAP en WinRM) ------------------------
    $serverData  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $issueCount  = 0
    foreach ($s in $raw.SrvStatus | Sort-Object ServerName) {
        if (-not $s.Active) { $issueCount++ }
        $serverData.Add([PSCustomObject]@{
            Name        = $s.ServerName
            IP          = if ($s.AddrList -and @($s.AddrList).Count -gt 0) { (@($s.AddrList) -join ', ') } else { '-' }
            Active      = $s.Active
            DeviceCount = $s.DeviceCount
        })
    }

    $vdiskIssues   = [System.Collections.Generic.List[PSCustomObject]]::new()
    $accessMapFull = @{ 0 = 'Production'; 1 = 'Maintenance'; 2 = 'Test'; 3 = 'Pending Merge' }
    foreach ($dv in $raw.DiskVersions) {
        if ([int]$dv.Access -ne 0) {
            $issueCount++
            $vdiskIssues.Add([PSCustomObject]@{
                DiskName = $dv.DiskFileName
                Version  = $dv.Version
                Access   = if ($accessMapFull.ContainsKey([int]$dv.Access)) { $accessMapFull[[int]$dv.Access] } else { "Unknown ($($dv.Access))" }
                Created  = if ($dv.CreateDate) { try { ([datetime]$dv.CreateDate).ToString('dd-MM-yyyy') } catch { '-' } } else { '-' }
            })
        }
    }

    $stopwatch.Stop()

    return [PSCustomObject]@{
        CheckName   = $CheckName
        SectionHtml = _BuildPVSHtml -ServerData $serverData -VdiskIssues $vdiskIssues -DiskInventory $raw.DiskInventory -TotalDevices $raw.TotalDevices -StreamDistrib $raw.StreamDistrib -Mode 'Full'
        HasIssues   = ($issueCount -gt 0)
        IssueCount  = $issueCount
        Summary     = "$($serverData.Count) PVS server(s) - $(@($serverData | Where-Object {-not $_.Active}).Count) offline | $($raw.TotalDevices) device(s) active | $($vdiskIssues.Count) vDisk issue(s)"
        Duration    = "$([math]::Round($stopwatch.Elapsed.TotalSeconds,1))s"
        Error       = $null
    }
}

# =============================================================================
# Service-only fallback (no SDK)
# =============================================================================
function _RunPVSServiceFallback {
    param($PvsServers, $Config, $Stopwatch, $CheckName, [string]$SdkError = '')

    Write-Verbose 'PVS SDK not available or failed - running service-only fallback'
    $pvsServices = @('StreamService', 'soapserver')
    $serverData  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $issueCount  = 0

    foreach ($srvName in $PvsServers) {
        $reachable = Test-Connection -ComputerName $srvName -Count 1 -Quiet -ErrorAction SilentlyContinue
        $svcResults = [System.Collections.Generic.List[PSCustomObject]]::new()

        if ($reachable) {
            foreach ($svc in $pvsServices) {
                try {
                    $obj    = Get-Service -ComputerName $srvName -Name $svc -ErrorAction Stop
                    $status = if ($obj.Status -eq 'Running') { 'RUNNING' } else { $obj.Status.ToString().ToUpper() }
                    if ($status -ne 'RUNNING') { $issueCount++ }
                    $svcResults.Add([PSCustomObject]@{ Service = $svc; Status = $status })
                }
                catch {
                    $issueCount++
                    $svcResults.Add([PSCustomObject]@{ Service = $svc; Status = 'ERROR' })
                }
            }
        }
        else {
            $issueCount++
        }

        $serverData.Add([PSCustomObject]@{
            Name      = $srvName
            Reachable = $reachable
            Services  = $svcResults
        })
    }

    $stopwatch.Stop()

    return [PSCustomObject]@{
        CheckName   = $CheckName
        SectionHtml = _BuildPVSHtml -ServerData $serverData -VdiskIssues @() -TotalDevices 0 -StreamDistrib @() -Mode 'Fallback' -SdkError $SdkError
        HasIssues   = ($issueCount -gt 0)
        IssueCount  = $issueCount
        Summary     = "$($PvsServers.Count) PVS server(s) checked (service mode$(if ($SdkError) { ' - SDK timeout' } else { ' - SDK unavailable' })) - $issueCount issue(s)"
        Duration    = "$([math]::Round($stopwatch.Elapsed.TotalSeconds,1))s"
        Error       = $null
    }
}

# =============================================================================
# HTML builders
# =============================================================================
function _BuildPVSHtml {
    param(
        [array]$ServerData,
        [array]$VdiskIssues,
        [array]$DiskInventory,
        [int]$TotalDevices,
        [array]$StreamDistrib,
        [string]$Mode,
        [string]$SdkError = ''
    )

    $hasIssues   = ($ServerData | Where-Object { ($Mode -eq 'Full' -and -not $_.Active) -or ($Mode -eq 'Fallback' -and -not $_.Reachable) }) -or $VdiskIssues.Count -gt 0
    $badgeColour = if ($hasIssues) { '#e74c3c' } else { '#27ae60' }
    $badgeText   = if ($hasIssues) { 'ISSUES FOUND' } else { 'ALL OK' }
    $modeLabel   = if ($SdkError) { "SDK timeout - service check only" } else { "Service check only - PVS SDK unavailable" }
    $modeNote    = if ($Mode -eq 'Fallback') { " <span style='font-size:11px;background:#f39c12;color:#fff;padding:2px 8px;border-radius:10px;margin-left:6px'>$modeLabel</span>" } else { '' }
    $sdkErrNote  = if ($Mode -eq 'Fallback' -and $SdkError) { "<div style='padding:6px 12px;font-size:11px;color:#856404;background:#fff3cd;border-bottom:1px solid #ffc107'>SDK-fout: $SdkError</div>" } else { '' }

    # == Server table ==========================================================
    $serverRows = if ($Mode -eq 'Full') {
        foreach ($s in $ServerData) {
            $stateCol = if ($s.Active) { '#27ae60' } else { '#e74c3c' }
            $stateIco = if ($s.Active) { '&#10003; Online' } else { '&#10007; OFFLINE' }
            $rowBg    = if (-not $s.Active) { '#fff5f5' } else { '' }
            "<tr style='background:$rowBg'><td style='padding:7px 12px;border-bottom:1px solid #f0f0f0;font-size:13px'>$($s.Name)</td><td style='padding:7px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;color:$stateCol;font-weight:bold'>$stateIco</td><td style='padding:7px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;text-align:center'>$($s.DeviceCount)</td></tr>"
        }
    }
    else {
        foreach ($s in $ServerData) {
            $reach = if ($s.Reachable) { '#27ae60' } else { '#e74c3c' }
            $reachTxt = if ($s.Reachable) { 'Reachable' } else { 'UNREACHABLE' }
            $rowBg = if (-not $s.Reachable) { '#fff5f5' } else { '' }
            $svcCells = if ($s.Services) {
                $s.Services | ForEach-Object {
                    $sc = if ($_.Status -eq 'RUNNING') { '#27ae60' } else { '#e74c3c' }
                    "<span style='color:$sc;font-size:11px;margin-right:8px'>$($_.Service): $($_.Status)</span>"
                }
            }
            "<tr style='background:$rowBg'><td style='padding:7px 12px;border-bottom:1px solid #f0f0f0;font-size:13px'>$($s.Name)</td><td style='padding:7px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;color:$reach;font-weight:bold'>$reachTxt</td><td style='padding:7px 12px;border-bottom:1px solid #f0f0f0;font-size:12px'>$($svcCells -join '')</td></tr>"
        }
    }

    $serverTableHeaders = if ($Mode -eq 'Full') {
        "<tr style='background:#f4f6f8'><th style='padding:7px 12px;text-align:left;color:#555;font-size:12px;font-weight:600'>Server</th><th style='padding:7px 12px;text-align:left;color:#555;font-size:12px;font-weight:600'>State</th><th style='padding:7px 12px;text-align:center;color:#555;font-size:12px;font-weight:600'>Active Devices</th></tr>"
    } else {
        "<tr style='background:#f4f6f8'><th style='padding:7px 12px;text-align:left;color:#555;font-size:12px;font-weight:600'>Server</th><th style='padding:7px 12px;text-align:left;color:#555;font-size:12px;font-weight:600'>Reachability</th><th style='padding:7px 12px;text-align:left;color:#555;font-size:12px;font-weight:600'>Services</th></tr>"
    }

    # == Device summary (Full mode only) =======================================
    $deviceSummary = if ($Mode -eq 'Full') {
        "<div style='padding:8px 12px;font-size:12px;color:#555;background:#f8f9fa;border-bottom:1px solid #eee'>Total active devices across farm: <strong>$TotalDevices</strong></div>"
    } else { '' }

    # == Disk inventory (Full mode) ============================================
    $diskInventorySection = ''
    if ($Mode -eq 'Full' -and $DiskInventory -and $DiskInventory.Count -gt 0) {
        $invRows = foreach ($d in ($DiskInventory | Sort-Object Name)) {
            $rowBg = if ($d.HasNonProd) { "background:#fffdf0;" } else { "" }
            $statusHtml = if ($d.HasNonProd) {
                "<span style='color:#f39c12;font-weight:bold'>&#9888; $($d.NonProdDetail)</span>"
            } else {
                "<span style='color:#27ae60'>&#10003; Production</span>"
            }
            "<tr style='$rowBg'><td style='padding:5px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;font-weight:500'>$($d.Name)</td><td style='padding:5px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#777'>$($d.Store)</td><td style='padding:5px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;text-align:center'>$($d.ProdVersion)</td><td style='padding:5px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;text-align:center;color:#777'>$($d.TotalVersions)</td><td style='padding:5px 10px;border-bottom:1px solid #f0f0f0;font-size:12px'>$statusHtml</td></tr>"
        }
        $diskInventorySection = @"
      <div style='margin-top:12px'>
        <div style='font-size:13px;font-weight:600;color:#2c3e50;padding:8px 12px;background:#f8f9fa;border-radius:4px;margin-bottom:4px'>
          &#128191; vDisk Inventory ($($DiskInventory.Count) disk(s))
        </div>
        <table style='width:100%;border-collapse:collapse'>
          <thead><tr style='background:#f4f6f8'>
            <th style='padding:5px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Disk Name</th>
            <th style='padding:5px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Store</th>
            <th style='padding:5px 10px;text-align:center;color:#555;font-size:11px;font-weight:600'>Prod Version</th>
            <th style='padding:5px 10px;text-align:center;color:#555;font-size:11px;font-weight:600'>Versions</th>
            <th style='padding:5px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Status</th>
          </tr></thead>
          <tbody>$invRows</tbody>
        </table>
      </div>
"@
    }

    # == Streaming distribution per vDisk (Full mode) =========================
    $streamSection = ''
    if ($Mode -eq 'Full' -and $StreamDistrib -and $StreamDistrib.Count -gt 0) {
        $sdRows = foreach ($sd in $StreamDistrib) {
            $pct    = if ($TotalDevices -gt 0) { [math]::Round(($sd.DeviceCount / $TotalDevices) * 100) } else { 0 }
            "<tr><td style='padding:5px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;font-weight:500'>$(if($sd.VDisk){$sd.VDisk}else{'(unknown)'})</td><td style='padding:5px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;text-align:center;font-weight:bold;color:#2c3e50'>$($sd.DeviceCount)</td><td style='padding:5px 10px;border-bottom:1px solid #f0f0f0'><div style='display:flex;align-items:center;gap:6px'><div style='width:80px;background:#ecf0f1;border-radius:3px;height:6px'><div style='width:$pct%;background:#3498db;height:6px;border-radius:3px'></div></div><span style='font-size:11px;color:#777'>$pct%</span></div></td></tr>"
        }
        $streamSection = @"
      <div style='margin-top:12px'>
        <div style='font-size:13px;font-weight:600;color:#2c3e50;padding:8px 12px;background:#f0f6ff;border-radius:4px;margin-bottom:4px'>
          &#9654; Streaming Distribution ($($StreamDistrib.Count) vDisk(s), $TotalDevices devices)
        </div>
        <table style='width:100%;border-collapse:collapse'>
          <thead><tr style='background:#f4f6f8'>
            <th style='padding:5px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>vDisk</th>
            <th style='padding:5px 10px;text-align:center;color:#555;font-size:11px;font-weight:600'>Devices</th>
            <th style='padding:5px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Distribution</th>
          </tr></thead>
          <tbody>$sdRows</tbody>
        </table>
      </div>
"@
    }

    # == vDisk issues ==========================================================
    $vdiskSection = ''
    if ($VdiskIssues.Count -gt 0) {
        $vdiskRows = foreach ($v in $VdiskIssues) {
            $accessCol = switch ($v.Access) {
                'Maintenance'   { '#f39c12' }
                'Test'          { '#3498db' }
                'Pending Merge' { '#e74c3c' }
                default         { '#95a5a6' }
            }
            "<tr><td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px'>$($v.DiskName)</td><td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;text-align:center'>$($v.Version)</td><td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;color:$accessCol;font-weight:bold'>$($v.Access)</td><td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#777'>$($v.Created)</td></tr>"
        }
        $vdiskSection = @"
      <div style='margin-top:12px'>
        <div style='font-size:13px;font-weight:600;color:#d35400;padding:8px 12px;background:#fff8ee;border-radius:4px;margin-bottom:8px'>
          &#9888; vDisk versions not in Production ($($VdiskIssues.Count))
        </div>
        <table style='width:100%;border-collapse:collapse'>
          <thead><tr style='background:#f4f6f8'>
            <th style='padding:6px 10px;text-align:left;color:#555;font-size:12px;font-weight:600'>vDisk</th>
            <th style='padding:6px 10px;text-align:center;color:#555;font-size:12px;font-weight:600'>Version</th>
            <th style='padding:6px 10px;text-align:left;color:#555;font-size:12px;font-weight:600'>Access</th>
            <th style='padding:6px 10px;text-align:left;color:#555;font-size:12px;font-weight:600'>Created</th>
          </tr></thead>
          <tbody>$vdiskRows</tbody>
        </table>
      </div>
"@
    }

    return @"
<div style='margin-bottom:24px;background:#fff;border-radius:6px;border:1px solid #dde1e7;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.06)'>
  <div style='background:#2c3e50;color:#fff;padding:12px 18px;display:flex;justify-content:space-between;align-items:center'>
    <span style='font-size:16px;font-weight:700'>&#128190; Provisioning Services (PVS)$modeNote</span>
    <span style='font-size:12px;background:$badgeColour;padding:4px 12px;border-radius:12px;font-weight:700'>$badgeText</span>
  </div>
  $sdkErrNote
  $deviceSummary
  <div style='padding:16px'>
    <table style='width:100%;border-collapse:collapse'>
      <thead>$serverTableHeaders</thead>
      <tbody>$serverRows</tbody>
    </table>
    $diskInventorySection
    $streamSection
    $vdiskSection
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
    $result = Invoke-PVSCheck -Config $cfg -Verbose
    Write-Host "`n[$($result.CheckName)] $($result.Summary) | Duration: $($result.Duration)" -ForegroundColor $(if ($result.HasIssues) { 'Red' } else { 'Green' })
}

