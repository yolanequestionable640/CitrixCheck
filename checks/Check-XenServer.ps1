#Requires -Version 5.1
<#
.SYNOPSIS
    XenServer / Citrix Hypervisor pool health check.

.DESCRIPTION
    Connects to each configured XenServer pool master using the XenServer PowerShell SDK
    and collects:

        1. Pool status - pool name, master host, HA configuration.
        2. Host metrics - uptime, CPU utilisation, memory usage, enabled/disabled state,
           running VM count, and role (pool master vs. slave).
        3. Storage Repositories - capacity, utilisation, and type for all shared/block SRs.
        4. Issue detection - hosts offline or in maintenance, high CPU, high memory,
           near-full storage repositories.

    Uses AES-256-encrypted credentials stored in config.json (set up with Initialize-CitrixCheck.ps1).
    The AES key is stored in xen_key.bin (same directory as the script).

    Requires the XenServer PowerShell SDK module (Import-Module XenServer) or a path to the
    module DLL configured in Config.XenServer.ModulePath.

.PARAMETER Config
    PSCustomObject parsed from config.json. When omitted the script loads config.json
    from its own parent directory (standalone mode).

.EXAMPLE
    PS C:\> .\checks\Check-XenServer.ps1
    Runs the check standalone and prints the result summary to the console.

.EXAMPLE
    # Used by the master orchestrator:
    . .\checks\Check-XenServer.ps1
    $result = Invoke-XenServerCheck -Config $config

.INPUTS
    None. All input comes from config.json or the -Config parameter.

.OUTPUTS
    [PSCustomObject] with properties:
        CheckName   [string]  - Display name of this check.
        SectionHtml [string]  - HTML fragment to embed in the daily report.
        HasIssues   [bool]    - $true when one or more issues are detected.
        IssueCount  [int]     - Total number of issues found across all pools.
        Summary     [string]  - One-line plain-text summary.
        Duration    [string]  - Elapsed time formatted as "X.Xs".
        Error       [string]  - Error message if the check itself failed, else $null.

.NOTES
    Author:     Ufuk Kocak
    Website:    https://horizonconsulting.it
    LinkedIn:   https://www.linkedin.com/in/ufukkocak
    Created:    2026-03-19
    Version:    1.2.0

    Changelog:
        1.0.0 - 2026-03-19 - Initial release.
        1.1.0 - 2026-03-20 - Switched from AES key file to DPAPI credentials (Initialize-CitrixCheck.ps1);
                              Connect-XenServer with -SetDefaultSession -PassThru; per-host RRD CPU query;
                              Get-XenHostMetrics via -Ref $h.metrics; StrictMode-safe session access.
        1.2.0 - 2026-03-23 - Credential setup verwijzing gecorrigeerd naar Initialize-CitrixCheck.ps1.

    Requirements:
        - PowerShell 5.1 or higher.
        - XenServer PowerShell SDK (Module 'XenServer') installed on the machine running this script.
          Install from: https://www.citrix.com/downloads/citrix-hypervisor/ (SDK download)
          Or: Install-Module XenServer (if published to a local PSGallery)
          Or set Config.XenServer.ModulePath to the full path of XenServerPSModule.psd1 / .dll
        - XenServer credentials configured via Initialize-CitrixCheck.ps1 (AES-256-encrypted in config.json; key in xen_key.bin).
        - Network access (HTTPS/443) from the script host to each XenServer pool master.

    Credential setup (run once, interactively):
        PS> .\Initialize-CitrixCheck.ps1

    Scheduling:
        Run daily via Windows Task Scheduler or call through Invoke-DailyReport.ps1.
#>

# =============================================================================
# Helper: query a single XenServer host's RRD endpoint for realtime CPU%
# Each host only exposes its own metrics; query per-host for accurate data.
# Returns cpu percentage (0-100) or $null on failure.
# =============================================================================
function _GetXenRrdHostCpu {
    param(
        [string]$HostName,
        [string]$SessionRef
    )
    try {
        $now   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $start = $now - 60
        $url   = "https://$HostName/rrd_updates?start=$start&cf=AVERAGE&host=true&session_id=$SessionRef"

        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $wc  = New-Object Net.WebClient
        $xml = [xml]$wc.DownloadString($url)

        if (-not $xml.xport.meta.legend) { return $null }

        $legends = @($xml.xport.meta.legend.entry)
        $lastRow = $xml.xport.data.row | Select-Object -Last 1
        if (-not $lastRow) { return $null }
        $vals = @($lastRow.v)

        $cpuSum   = 0.0
        $cpuCount = 0

        for ($i = 0; $i -lt $legends.Count; $i++) {
            $val = $vals[$i]
            if ($null -eq $val -or $val -eq 'NaN') { continue }
            # cpu_usage (single) OR cpu0, cpu1, ... (per-core)
            if ($legends[$i] -match ':cpu_usage$' -or $legends[$i] -match ':cpu\d+$') {
                $cpuSum   += [double]$val
                $cpuCount += 1
            }
        }

        if ($cpuCount -gt 0) { return [math]::Round(($cpuSum / $cpuCount) * 100) }
    }
    catch { }
    return $null
}

# =============================================================================
# Exported function
# =============================================================================
function Invoke-XenServerCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $checkName = 'XenServer Hosts'

    # Validate config section
    if (-not $Config.XenServer -or -not $Config.XenServer.Pools -or $Config.XenServer.Pools.Count -eq 0) {
        $stopwatch.Stop()
        return [PSCustomObject]@{
            CheckName   = $checkName
            SectionHtml = _BuildXenErrorHtml -CheckName $checkName -Message 'XenServer section missing in config.json. Add it and run New-XenCredential.ps1.'
            HasIssues   = $true
            IssueCount  = 1
            Summary     = 'XenServer configuration missing'
            Duration    = '0s'
            Error       = 'XenServer configuration missing'
        }
    }

    $plainPass = $null

    try {
        # Load XenServer PowerShell SDK
        $xenLoaded = (Get-Module -Name XenServer -ErrorAction SilentlyContinue) -or
                     (Get-Module -Name XenServerPSModule -ErrorAction SilentlyContinue)
        if (-not $xenLoaded) {
            # Build ordered list of paths/names to try
            $xenCandidates = [System.Collections.Generic.List[string]]::new()

            # 1. Explicit path from config (highest priority)
            if ($Config.XenServer.ModulePath) { $xenCandidates.Add($Config.XenServer.ModulePath) }

            # 2. Known installation paths
            $xenCandidates.Add('C:\Program Files\WindowsPowerShell\Modules\XenServerPSModule\XenServerPSModule.psd1')
            $xenCandidates.Add('C:\Windows\System32\WindowsPowerShell\v1.0\Modules\XenServerPSModule\XenServerPSModule.psd1')

            # 3. Module names (rely on PSModulePath)
            $xenCandidates.Add('XenServerPSModule')
            $xenCandidates.Add('XenServer')

            $imported = $false
            foreach ($candidate in $xenCandidates) {
                # Skip file-path candidates that don't exist on disk
                if ($candidate -like '*\*' -and -not (Test-Path $candidate)) { continue }
                try {
                    Import-Module $candidate -Force -ErrorAction Stop
                    $imported = $true
                    Write-Verbose "XenServer PS module loaded: $candidate"
                    break
                } catch { }
            }

            if (-not $imported) {
                throw 'XenServer PS module could not be loaded. Verify the module is installed and the DLLs are unblocked (Unblock-File).'
            }
        }

        # Load credentials via AES-256 sleutelbestand (accountonafhankelijk)
        if (-not $Config.XenServer.Username -or $Config.XenServer.Username -like '*<run*') {
            throw "XenServer credentials not configured - run Initialize-CitrixCheck.ps1 first."
        }
        $xenKeyPath = Join-Path (Split-Path $PSScriptRoot) $Config.XenServer.XenKeyFile
        if (-not (Test-Path $xenKeyPath)) {
            throw "XenServer key file not found: $xenKeyPath - run Initialize-CitrixCheck.ps1 first."
        }
        $xenKey     = [System.IO.File]::ReadAllBytes($xenKeyPath)
        $plainUser  = $Config.XenServer.Username
        $securePass = $Config.XenServer.EncryptedPassword | ConvertTo-SecureString -Key $xenKey
        $bstr       = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
        $plainPass  = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

        $thresholds = $Config.XenServer.Thresholds
        $cpuWarn    = if ($thresholds.CpuWarningPercent)     { [int]$thresholds.CpuWarningPercent }     else { 80 }
        $cpuCrit    = if ($thresholds.CpuCriticalPercent)    { [int]$thresholds.CpuCriticalPercent }    else { 90 }
        $memWarn    = if ($thresholds.MemoryWarningPercent)  { [int]$thresholds.MemoryWarningPercent }  else { 85 }
        $memCrit    = if ($thresholds.MemoryCriticalPercent) { [int]$thresholds.MemoryCriticalPercent } else { 95 }
        $storWarn   = if ($thresholds.StorageWarningPercent) { [int]$thresholds.StorageWarningPercent } else { 80 }
        $storCrit   = if ($thresholds.StorageCriticalPercent){ [int]$thresholds.StorageCriticalPercent} else { 90 }

        $poolResults  = [System.Collections.Generic.List[PSCustomObject]]::new()
        $totalIssues  = 0
        $totalHosts   = 0
        $totalVMs     = 0

        foreach ($poolDef in $Config.XenServer.Pools) {
            Write-Verbose "Connecting to pool: $($poolDef.Name) via $($poolDef.Master)"

            $poolResult = [PSCustomObject]@{
                Name       = $poolDef.Name
                Master     = $poolDef.Master
                Connected  = $false
                Error      = $null
                PoolLabel  = $poolDef.Name
                MasterName = $poolDef.Master
                HAEnabled  = $false
                Hosts      = @()
                SRs        = @()
                IssueCount = 0
            }

            try {
                # Connect — -PassThru geeft sessie-object terug voor RRD; -SetDefaultSession voor SDK cmdlets
                $xenSession = $null
                try {
                    $xenSession = Connect-XenServer -Server $poolDef.Master `
                        -UserName $plainUser -Password $plainPass `
                        -NoWarnCertificates -SetDefaultSession -PassThru -ErrorAction Stop
                } catch {
                    if ($_.Exception.Message -match 'NoWarnCertificates|PassThru|parameter') {
                        try {
                            $xenSession = Connect-XenServer -Server $poolDef.Master `
                                -UserName $plainUser -Password $plainPass `
                                -SetDefaultSession -PassThru -ErrorAction Stop
                        } catch {
                            Connect-XenServer -Server $poolDef.Master `
                                -UserName $plainUser -Password $plainPass `
                                -SetDefaultSession -ErrorAction Stop
                        }
                    } else {
                        throw
                    }
                }
                $poolResult.Connected = $true
                Write-Verbose "  Connected"

                # Retrieve OpaqueRef for RRD — via -PassThru result or module global
                # Use Get-Variable to avoid StrictMode exceptions
                $sessionRef = $null
                $sessionSources = [System.Collections.Generic.List[object]]::new()
                if ($xenSession) { $sessionSources.Add($xenSession) }
                $gv = Get-Variable -Name DefaultXenSession -Scope Global -ErrorAction SilentlyContinue
                if ($gv -and $gv.Value) { $sessionSources.Add($gv.Value) }

                foreach ($src in $sessionSources) {
                    foreach ($p in @('opaque_ref','SessionRef','OpaqueRef')) {
                        try { $v = $src.$p; if ($v -and $v -notmatch 'NULL$') { $sessionRef = $v; break } } catch { }
                    }
                    if ($sessionRef) { break }
                }

                # Pool info
                $pool = Get-XenPool | Select-Object -First 1
                if ($pool) {
                    $poolResult.PoolLabel = if ($pool.name_label) { $pool.name_label } else { $poolDef.Name }
                    $poolResult.HAEnabled = [bool]$pool.ha_enabled
                    try {
                        $masterHost = Get-XenHost -Ref $pool.master
                        $poolResult.MasterName = $masterHost.name_label
                    } catch { }
                }

                # Collect all data in one pass for efficiency
                $allXenHosts = @(Get-XenHost)
                $allVMs      = @(Get-XenVM | Where-Object { -not $_.is_a_template -and -not $_.is_control_domain })

                $hostDataList = [System.Collections.Generic.List[PSCustomObject]]::new()

                foreach ($h in ($allXenHosts | Sort-Object name_label)) {
                    Write-Verbose "  Host: $($h.name_label)"

                    # Pool master role
                    $masterRef = if ($pool) { $pool.master } else { $null }
                    $isMaster  = $false
                    if ($masterRef) {
                        try {
                            $masterOpaqueRef = if ($masterRef -is [string]) { $masterRef } else { $masterRef.opaque_ref }
                            $isMaster = ($h.opaque_ref -eq $masterOpaqueRef)
                        } catch { }
                    }

                    # Uptime from boot_time in other_config
                    $uptimeStr  = 'Unknown'
                    $uptimeDays = $null
                    try {
                        if ($h.other_config -and $h.other_config.ContainsKey('boot_time')) {
                            $bootEpoch  = [double]$h.other_config['boot_time']
                            $bootDt     = [System.DateTimeOffset]::FromUnixTimeSeconds([long]$bootEpoch).LocalDateTime
                            $ts         = New-TimeSpan -Start $bootDt -End (Get-Date)
                            $uptimeDays = [math]::Floor($ts.TotalDays)
                            $uptimeStr  = "$($uptimeDays)d $($ts.Hours)h $($ts.Minutes)m"
                        }
                    } catch { }

                    # Memory from host_metrics
                    $memPct    = $null
                    $memUsedGB = $null
                    $memTotGB  = $null
                    try {
                        $hm = Get-XenHostMetrics -Ref $h.metrics -ErrorAction SilentlyContinue
                        if ($hm -and $hm.memory_total -gt 0) {
                            $memTotGB  = [math]::Round($hm.memory_total / 1GB, 1)
                            $memFreeGB = [math]::Round($hm.memory_free  / 1GB, 1)
                            $memUsedGB = [math]::Round($memTotGB - $memFreeGB, 1)
                            $memPct    = [math]::Round(($memUsedGB / $memTotGB) * 100)
                        }
                    } catch { }

                    # CPU utilisation — realtime via RRD op de host zelf (elke host heeft eigen RRD)
                    $cpuPct = if ($sessionRef) { _GetXenRrdHostCpu -HostName $h.name_label -SessionRef $sessionRef } else { $null }

                    # Running VMs on this host
                    $runningVMs = @($allVMs | Where-Object {
                        $_.power_state -eq 'Running' -and $_.resident_on -eq $h.opaque_ref
                    })
                    $runningCount = $runningVMs.Count

                    # Halted / suspended VMs assigned to this host (affinity)
                    $haltedCount = @($allVMs | Where-Object {
                        $_.affinity -eq $h.opaque_ref -and $_.power_state -ne 'Running'
                    }).Count

                    # Issues
                    $hostIssues = [System.Collections.Generic.List[string]]::new()
                    if (-not $h.enabled)                               { $hostIssues.Add('Host disabled') }
                    if ($cpuPct -ne $null -and $cpuPct -ge $cpuCrit)  { $hostIssues.Add("CPU $cpuPct% (crit)") }
                    elseif ($cpuPct -ne $null -and $cpuPct -ge $cpuWarn) { $hostIssues.Add("CPU $cpuPct%") }
                    if ($memPct -ne $null -and $memPct -ge $memCrit)  { $hostIssues.Add("RAM $memPct% (crit)") }
                    elseif ($memPct -ne $null -and $memPct -ge $memWarn) { $hostIssues.Add("RAM $memPct%") }

                    $poolResult.IssueCount += $hostIssues.Count
                    $totalIssues           += $hostIssues.Count

                    $hostDataList.Add([PSCustomObject]@{
                        Name        = $h.name_label
                        IsMaster    = $isMaster
                        Enabled     = $h.enabled
                        Uptime      = $uptimeStr
                        UptimeDays  = $uptimeDays
                        CpuPct      = $cpuPct
                        MemPct      = $memPct
                        MemUsedGB   = $memUsedGB
                        MemTotGB    = $memTotGB
                        RunningVMs  = $runningCount
                        HaltedVMs   = $haltedCount
                        Issues      = $hostIssues.ToArray()
                    })

                    $totalVMs += $runningCount
                }

                $poolResult.Hosts = $hostDataList.ToArray()
                $totalHosts      += $hostDataList.Count

                # Storage Repositories
                $srDataList   = [System.Collections.Generic.List[PSCustomObject]]::new()
                $excludeTypes = @('udev', 'iso', 'cslg', 'tmpfs')

                foreach ($sr in (Get-XenSR | Where-Object {
                    $_.type -notin $excludeTypes -and
                    $_.physical_size -gt 0
                } | Sort-Object name_label)) {
                    $srTotGB  = [math]::Round($sr.physical_size        / 1GB, 1)
                    $srUsedGB = [math]::Round($sr.physical_utilisation / 1GB, 1)
                    $srPct    = if ($srTotGB -gt 0) { [math]::Round(($srUsedGB / $srTotGB) * 100) } else { 0 }

                    $srIssues = @()
                    if ($srPct -ge $storCrit) { $srIssues += "Storage $srPct% (crit)" }
                    elseif ($srPct -ge $storWarn) { $srIssues += "Storage $srPct%" }

                    $poolResult.IssueCount += $srIssues.Count
                    $totalIssues           += $srIssues.Count

                    $srDataList.Add([PSCustomObject]@{
                        Name    = $sr.name_label
                        Type    = $sr.type
                        Shared  = [bool]$sr.shared
                        TotGB   = $srTotGB
                        UsedGB  = $srUsedGB
                        FreeGB  = [math]::Round($srTotGB - $srUsedGB, 1)
                        Pct     = $srPct
                        Issues  = $srIssues
                    })
                }
                $poolResult.SRs = $srDataList.ToArray()
            }
            catch {
                $poolResult.Error      = $_.Exception.Message
                $poolResult.IssueCount++
                $totalIssues++
                Write-Warning "Pool $($poolDef.Name): $($_.Exception.Message)"
            }
            finally {
                try { Disconnect-XenServer -Server $poolDef.Master -ErrorAction SilentlyContinue } catch { }
            }

            $poolResults.Add($poolResult)
        }

        $plainPass = $null
        $plainUser = $null
        $stopwatch.Stop()

        return [PSCustomObject]@{
            CheckName   = $checkName
            SectionHtml = _BuildXenHtml -Pools $poolResults -TotalHosts $totalHosts -TotalVMs $totalVMs -IssueCount $totalIssues
            HasIssues   = ($totalIssues -gt 0)
            IssueCount  = $totalIssues
            Summary     = "$($poolResults.Count) pool(s) - $totalHosts host(s) - $totalVMs running VM(s) - $totalIssues issue(s)"
            Duration    = "$([math]::Round($stopwatch.Elapsed.TotalSeconds,1))s"
            Error       = $null
        }
    }
    catch {
        $plainPass = $null
        $plainUser = $null
        $stopwatch.Stop()
        return [PSCustomObject]@{
            CheckName   = $checkName
            SectionHtml = _BuildXenErrorHtml -CheckName $checkName -Message $_.Exception.Message
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
function _BuildXenHtml {
    param(
        [array]$Pools,
        [int]$TotalHosts,
        [int]$TotalVMs,
        [int]$IssueCount
    )

    $hasIssues   = $IssueCount -gt 0
    $badgeColour = if ($hasIssues) { '#e74c3c' } else { '#27ae60' }
    $badgeText   = if ($hasIssues) { "ISSUES ($IssueCount)" } else { 'ALL OK' }
    $poolCount   = $Pools.Count
    $offlinePools = @($Pools | Where-Object { -not $_.Connected }).Count

    # Summary bar
    $summaryBar = @"
    <div style='display:flex;gap:20px;padding:12px 16px;background:#f8f9fa;border-bottom:1px solid #eee;flex-wrap:wrap'>
      <div style='text-align:center'>
        <div style='font-size:22px;font-weight:700;color:#2c3e50'>$poolCount</div>
        <div style='font-size:11px;color:#777'>Pool(s)</div>
      </div>
      <div style='text-align:center'>
        <div style='font-size:22px;font-weight:700;color:#2c3e50'>$TotalHosts</div>
        <div style='font-size:11px;color:#777'>Hosts</div>
      </div>
      <div style='text-align:center'>
        <div style='font-size:22px;font-weight:700;color:#27ae60'>$TotalVMs</div>
        <div style='font-size:11px;color:#777'>Running VMs</div>
      </div>
      <div style='text-align:center'>
        <div style='font-size:22px;font-weight:700;color:$(if($IssueCount -gt 0){"#e74c3c"}else{"#27ae60"})'>$IssueCount</div>
        <div style='font-size:11px;color:#777'>Issues</div>
      </div>
      $(if ($offlinePools -gt 0) {
        "<div style='text-align:center'><div style='font-size:22px;font-weight:700;color:#e74c3c'>$offlinePools</div><div style='font-size:11px;color:#777'>Pool(s) offline</div></div>"
      })
    </div>
"@

    # Per-pool sections
    $poolSections = foreach ($pool in $Pools) {
        if (-not $pool.Connected) {
            @"
      <div style='margin-bottom:16px;border:1px solid #e74c3c;border-radius:4px;overflow:hidden'>
        <div style='background:#fdf2f2;padding:8px 14px;font-weight:600;color:#c0392b;font-size:13px'>
          &#9888; Pool: $($pool.Name) - Connection failed
        </div>
        <div style='padding:10px 14px;font-size:12px;color:#c0392b'>$($pool.Error)</div>
      </div>
"@
            continue
        }

        $haStatus   = if ($pool.HAEnabled) { "<span style='color:#27ae60;font-weight:600'>HA: Enabled</span>" } else { "<span style='color:#95a5a6'>HA: Disabled</span>" }
        $hostCount  = $pool.Hosts.Count
        $vmCount    = if ($pool.Hosts) { [int]($pool.Hosts | Measure-Object -Property RunningVMs -Sum).Sum } else { 0 }
        $poolIssues = $pool.IssueCount
        $poolBadge  = if ($poolIssues -gt 0) { "<span style='font-size:11px;background:#e74c3c;color:#fff;padding:2px 8px;border-radius:10px;font-weight:700'>$poolIssues issue(s)</span>" } else { "<span style='font-size:11px;background:#27ae60;color:#fff;padding:2px 8px;border-radius:10px;font-weight:700'>OK</span>" }

        # Host table rows
        $hostRows = foreach ($h in $pool.Hosts) {
            $roleLabel = if ($h.IsMaster) { "<span style='color:#8e44ad;font-weight:700'>&#9733; Master</span>" } else { "<span style='color:#7f8c8d'>Slave</span>" }
            $statusLabel = if ($h.Enabled) { "<span style='color:#27ae60'>&#10003; Online</span>" } else { "<span style='color:#e74c3c;font-weight:600'>&#10007; Disabled</span>" }

            # CPU bar
            $cpuDisplay = if ($null -ne $h.CpuPct) {
                $cpuCol = if ($h.CpuPct -ge 90) { '#e74c3c' } elseif ($h.CpuPct -ge 80) { '#f39c12' } elseif ($h.CpuPct -ge 60) { '#f39c12' } else { '#27ae60' }
                "<div style='display:flex;align-items:center;gap:5px'><div style='width:50px;background:#ecf0f1;border-radius:3px;height:6px'><div style='width:$($h.CpuPct)%;background:$cpuCol;height:6px;border-radius:3px'></div></div><span style='font-size:12px;color:$cpuCol;font-weight:$(if($h.CpuPct -ge 80){"bold"}else{"normal"})'>$($h.CpuPct)%</span></div>"
            } else { "<span style='color:#ccc;font-size:12px'>n/a</span>" }

            # RAM bar
            $memDisplay = if ($null -ne $h.MemPct) {
                $memCol = if ($h.MemPct -ge 95) { '#e74c3c' } elseif ($h.MemPct -ge 85) { '#f39c12' } else { '#27ae60' }
                $memLabel = if ($h.MemTotGB) { "$($h.MemUsedGB) / $($h.MemTotGB) GB" } else { "$($h.MemPct)%" }
                "<div style='display:flex;align-items:center;gap:5px'><div style='width:50px;background:#ecf0f1;border-radius:3px;height:6px'><div style='width:$($h.MemPct)%;background:$memCol;height:6px;border-radius:3px'></div></div><span style='font-size:12px;color:$memCol;font-weight:$(if($h.MemPct -ge 85){"bold"}else{"normal"})'>$memLabel</span></div>"
            } else { "<span style='color:#ccc;font-size:12px'>n/a</span>" }

            $issueText  = if ($h.Issues.Count -gt 0) { "<span style='color:#e74c3c;font-size:11px;font-weight:600'>$($h.Issues -join ', ')</span>" } else { '' }
            $uptimeCol  = if ($h.UptimeDays -ne $null -and $h.UptimeDays -gt 365) { 'color:#f39c12' } else { 'color:#555' }
            $rowBg      = if (-not $h.Enabled -or $h.Issues.Count -gt 0) { '#fff9f9' } else { '#fff' }

            @"
          <tr style='background:$rowBg'>
            <td style='padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:13px;font-weight:$(if($h.IsMaster){"700"}else{"normal"})'>$($h.Name)</td>
            <td style='padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:12px'>$roleLabel</td>
            <td style='padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:12px'>$statusLabel</td>
            <td style='padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;$uptimeCol'>$($h.Uptime)</td>
            <td style='padding:7px 10px;border-bottom:1px solid #f0f0f0'>$cpuDisplay</td>
            <td style='padding:7px 10px;border-bottom:1px solid #f0f0f0'>$memDisplay</td>
            <td style='padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:13px;text-align:center;font-weight:bold;color:#2c3e50'>$($h.RunningVMs)</td>
            <td style='padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:13px;text-align:center;color:#95a5a6'>$($h.HaltedVMs)</td>
            <td style='padding:7px 10px;border-bottom:1px solid #f0f0f0;font-size:12px'>$issueText</td>
          </tr>
"@
        }

        # Storage table rows
        $srRows = foreach ($sr in $pool.SRs) {
            $srCol     = if ($sr.Pct -ge 90) { '#e74c3c' } elseif ($sr.Pct -ge 80) { '#f39c12' } else { '#27ae60' }
            $srBg      = if ($sr.Pct -ge 80) { '#fff9f9' } else { '#fff' }
            $srShared  = if ($sr.Shared) { "<span style='color:#3498db'>Shared</span>" } else { "<span style='color:#95a5a6'>Local</span>" }
            @"
          <tr style='background:$srBg'>
            <td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px'>$($sr.Name)</td>
            <td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#777'>$($sr.Type)</td>
            <td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px'>$srShared</td>
            <td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#555'>$($sr.TotGB) GB</td>
            <td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#555'>$($sr.UsedGB) GB</td>
            <td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#27ae60'>$($sr.FreeGB) GB</td>
            <td style='padding:6px 10px;border-bottom:1px solid #f0f0f0'>
              <div style='display:flex;align-items:center;gap:6px'>
                <div style='width:60px;background:#ecf0f1;border-radius:3px;height:7px'>
                  <div style='width:$([math]::Min($sr.Pct,100))%;background:$srCol;height:7px;border-radius:3px'></div>
                </div>
                <span style='font-size:12px;color:$srCol;font-weight:$(if($sr.Pct -ge 80){"bold"}else{"normal"})'>$($sr.Pct)%</span>
              </div>
            </td>
          </tr>
"@
        }

        $srSection = ''
        if ($pool.SRs.Count -gt 0) {
            $srSection = @"
      <div style='margin-top:14px'>
        <div style='font-size:12px;font-weight:700;color:#555;text-transform:uppercase;letter-spacing:.5px;margin-bottom:6px;padding-bottom:4px;border-bottom:1px solid #eee'>
          Storage Repositories
        </div>
        <table style='width:100%;border-collapse:collapse'>
          <thead>
            <tr style='background:#f4f6f8'>
              <th style='padding:6px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Name</th>
              <th style='padding:6px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Type</th>
              <th style='padding:6px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Scope</th>
              <th style='padding:6px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Total</th>
              <th style='padding:6px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Used</th>
              <th style='padding:6px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Free</th>
              <th style='padding:6px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Usage</th>
            </tr>
          </thead>
          <tbody>$srRows</tbody>
        </table>
      </div>
"@
        }

        @"
      <div class='cx-sub' data-collapsed='0' style='margin-bottom:18px;border:1px solid #e8eaf0;border-radius:5px;overflow:hidden'>
        <div style='background:#f4f6f8;padding:9px 14px;display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid #e8eaf0'>
          <div style='font-size:14px;font-weight:700;color:#2c3e50'>
            &#128201; $($pool.PoolLabel)
            <span style='font-size:11px;font-weight:400;color:#777;margin-left:8px'>Master: $($pool.MasterName)</span>
          </div>
          <div style='display:flex;gap:12px;align-items:center;font-size:12px'>
            $haStatus
            <span style='color:#777'>$hostCount hosts</span>
            <span style='color:#777'>$vmCount running VMs</span>
            $poolBadge
          </div>
        </div>
        <div style='padding:12px 14px'>
          <table style='width:100%;border-collapse:collapse'>
            <thead>
              <tr style='background:#f9fafb'>
                <th style='padding:7px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Host</th>
                <th style='padding:7px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Role</th>
                <th style='padding:7px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Status</th>
                <th style='padding:7px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Uptime</th>
                <th style='padding:7px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>CPU</th>
                <th style='padding:7px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>RAM</th>
                <th style='padding:7px 10px;text-align:center;color:#555;font-size:11px;font-weight:600'>Running VMs</th>
                <th style='padding:7px 10px;text-align:center;color:#555;font-size:11px;font-weight:600'>Halted VMs</th>
                <th style='padding:7px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Issues</th>
              </tr>
            </thead>
            <tbody>$hostRows</tbody>
          </table>
          $srSection
        </div>
      </div>
"@
    }

    return @"
<div style='margin-bottom:24px;background:#fff;border-radius:6px;border:1px solid #dde1e7;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.06)'>
  <div style='background:#2c3e50;color:#fff;padding:12px 18px;display:flex;justify-content:space-between;align-items:center'>
    <span style='font-size:16px;font-weight:700'>&#128187; XenServer / Citrix Hypervisor</span>
    <span style='font-size:12px;background:$badgeColour;padding:4px 12px;border-radius:12px;font-weight:700'>$badgeText</span>
  </div>
  $summaryBar
  <div style='padding:16px'>
    $($poolSections -join "`n")
  </div>
</div>
"@
}

function _BuildXenErrorHtml {
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
    $result = Invoke-XenServerCheck -Config $cfg -Verbose
    Write-Host "`n[$($result.CheckName)] $($result.Summary) | Duration: $($result.Duration)" -ForegroundColor $(if ($result.HasIssues) { 'Red' } else { 'Green' })
}

