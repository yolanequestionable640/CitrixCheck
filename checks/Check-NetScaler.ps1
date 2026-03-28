#Requires -Version 5.1
<#
.SYNOPSIS
    NetScaler (Citrix ADC) health check via NITRO REST API - multi-instance.

.DESCRIPTION
    Iterates over every NetScaler instance defined in the config.json NetScaler
    array (EXT, INT, LB, …) and for each appliance performs the following checks
    using a single authenticated NITRO REST API session:

        1. High Availability (HA) state - primary/secondary sync status.
        2. Load Balancing virtual server states (UP / DOWN / OUT OF SERVICE).
        3. Content Switching virtual server states.
        4. Citrix Gateway (VPN) virtual server states and active session count.
        5. SSL certificate expiry - warns when a bound certificate is within the
           configured threshold (default: 30 days warning / 7 days critical).

    All NetScaler instances share the same AES-256-encrypted credentials stored in config.json
    (NetScalerCredentials section). The AES key is stored in ns_key.bin (same directory).
    Credentials are configured once with Initialize-CitrixCheck.ps1.

    Can be run standalone or dot-sourced by Invoke-DailyReport.ps1.

.PARAMETER Config
    PSCustomObject parsed from config.json. When omitted the script loads config.json
    from its own parent directory (standalone mode).

.EXAMPLE
    PS C:\> .\checks\Check-NetScaler.ps1
    Queries all configured NetScaler instances and prints a summary per appliance.

.EXAMPLE
    # Credentials instellen (eenmalig, interactief):
    .\Initialize-CitrixCheck.ps1 -SkipCVAD -SkipSMTP -SkipXenServer -SkipFasAgents

.EXAMPLE
    # Used by the master orchestrator:
    . .\checks\Check-NetScaler.ps1
    $result = Invoke-NetScalerCheck -Config $config

.INPUTS
    None. All input comes from config.json or the -Config parameter.

.OUTPUTS
    [PSCustomObject] with properties:
        CheckName   [string]  - Display name of this check.
        SectionHtml [string]  - HTML fragment to embed in the daily report.
        HasIssues   [bool]    - $true when any vServer is DOWN or a cert is near expiry.
        IssueCount  [int]     - Total number of individual issues across all instances.
        Summary     [string]  - One-line plain-text summary.
        Duration    [string]  - Elapsed time formatted as "X.Xs".
        Error       [string]  - Error message if the check itself failed, else $null.

.NOTES
    Author:     Ufuk Kocak
    Website:    https://horizonconsulting.it
    LinkedIn:   https://www.linkedin.com/in/ufukkocak
    Created:    2026-03-15
    Version:    1.2.0

    Changelog:
        1.0.0 - 2026-03-15 - Initial release.
        1.1.0 - 2026-03-15 - Multi-instance support; Config.NetScaler is now an array
                              covering CTX-NS-EXT (192.168.1.100),
                              CTX-NS-INT (10.0.0.51) and
                              CTX-NS-LB  (10.0.0.66).
        1.2.0 - 2026-03-23 - Switched from ns_cred.xml/Export-Clixml to DPAPI credentials
                              in config.json (NetScalerCredentials section). Per-request
                              error handling via _NitroGet helper; StrictMode-safe property
                              access via PSObject.Properties; TLS 1.2 enforced.

    Requirements:
        - PowerShell 5.1 or higher.
        - Network access to each NetScaler management IP on port 443 (or 80).
        - NetScaler credentials configured via Initialize-CitrixCheck.ps1 (AES-256-encrypted
          in config.json, NetScalerCredentials section; key in ns_key.bin).
        - SkipCertificateCheck: true in config.json when an appliance uses a
          self-signed management certificate.

    NITRO API endpoints used per instance:
        POST   /nitro/v1/config/login       - authentication
        GET    /nitro/v1/config/hanode      - HA node state
        GET    /nitro/v1/stat/lbvserver     - LB virtual servers
        GET    /nitro/v1/stat/csvserver     - Content Switching virtual servers
        GET    /nitro/v1/stat/vpnvserver    - Gateway virtual servers
        GET    /nitro/v1/config/sslcertkey  - SSL certificate inventory
        POST   /nitro/v1/config/logout      - session cleanup

    Scheduling:
        Run daily via Windows Task Scheduler or call through Invoke-DailyReport.ps1.
#>

# =============================================================================
# Exported function
# =============================================================================
function Invoke-NetScalerCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $stopwatch  = [System.Diagnostics.Stopwatch]::StartNew()
    $checkName  = 'NetScaler (Citrix ADC)'
    $warnDays   = if ($Config.Thresholds.SSLCertExpiryWarningDays)  { $Config.Thresholds.SSLCertExpiryWarningDays  } else { 60 }
    $critDays   = if ($Config.Thresholds.SSLCertExpiryCriticalDays) { $Config.Thresholds.SSLCertExpiryCriticalDays } else { 7  }

    # Normalise - Config.NetScaler can be a single object or an array
    $nsInstances = @($Config.NetScaler)

    # Voeg gedeelde credentials toe aan elke instantie
    $nsCreds = $Config.NetScalerCredentials
    foreach ($inst in $nsInstances) {
        Add-Member -InputObject $inst -NotePropertyName 'Credentials' -NotePropertyValue $nsCreds -Force
    }

    $instanceResults = [System.Collections.Generic.List[PSCustomObject]]::new()
    $totalIssues     = 0

    try {
        foreach ($nsCfg in $nsInstances) {
            Write-Verbose "Querying NetScaler instance: $($nsCfg.Name) [$($nsCfg.HostName)]"
            $instResult = _QueryNSInstance -NsCfg $nsCfg -WarnDays $warnDays -CritDays $critDays -ScriptDir (Split-Path $PSScriptRoot)
            $totalIssues += $instResult.IssueCount
            $instanceResults.Add($instResult)
        }

        $stopwatch.Stop()

        $combinedHtml = _BuildCombinedNSHtml -InstanceResults $instanceResults
        $summaryParts = $instanceResults | ForEach-Object { "$($_.Name): $($_.ShortSummary)" }

        return [PSCustomObject]@{
            CheckName   = $checkName
            SectionHtml = $combinedHtml
            HasIssues   = ($totalIssues -gt 0)
            IssueCount  = $totalIssues
            Summary     = ($summaryParts -join ' | ')
            Duration    = "$([math]::Round($stopwatch.Elapsed.TotalSeconds,1))s"
            Error       = $null
        }
    }
    catch {
        $stopwatch.Stop()
        return [PSCustomObject]@{
            CheckName   = $checkName
            SectionHtml = _BuildNSErrorHtml -CheckName $checkName -Message $_.Exception.Message
            HasIssues   = $true
            IssueCount  = 1
            Summary     = "Check failed: $($_.Exception.Message)"
            Duration    = "$([math]::Round($stopwatch.Elapsed.TotalSeconds,1))s"
            Error       = $_.Exception.Message
        }
    }
}

# =============================================================================
# Query a single NetScaler instance
# =============================================================================
function _QueryNSInstance {
    param(
        [PSCustomObject]$NsCfg,
        [int]$WarnDays,
        [int]$CritDays,
        [string]$ScriptDir
    )

    # SSL bypass voor self-signed/interne management-certificaten (PS5.1/.NET 4.x)
    # ICertificatePolicy werkt niet voor TLS in .NET 4.5+ — ServerCertificateValidationCallback is vereist
    if ($NsCfg.SkipCertificateCheck) {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }

    $baseUrl    = "$($NsCfg.Protocol)://$($NsCfg.HostName)/nitro/v1"
    $headers    = @{ 'Content-Type' = 'application/json' }
    $webSession = $null

    try {
        # Credentials via AES-256 sleutelbestand (accountonafhankelijk)
        $nsCreds = $NsCfg.Credentials
        if (-not $nsCreds -or $nsCreds.Username -like '*<run*') {
            throw "NetScaler credentials not configured - run Initialize-CitrixCheck.ps1 first."
        }
        $nsKeyPath = Join-Path $ScriptDir $nsCreds.NsKeyFile
        if (-not (Test-Path $nsKeyPath)) {
            throw "NetScaler key file not found: $nsKeyPath - run Initialize-CitrixCheck.ps1 first."
        }
        $nsKey      = [System.IO.File]::ReadAllBytes($nsKeyPath)
        $plainUser  = $nsCreds.Username
        $securePass = $nsCreds.EncryptedPassword | ConvertTo-SecureString -Key $nsKey
        $bstr       = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
        $password   = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

        # TLS 1.2 vereist voor NetScaler NITRO API
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        # Login
        $loginBody = @{ login = @{ username = $plainUser; password = $password } } | ConvertTo-Json
        Invoke-RestMethod -Uri "$baseUrl/config/login" -Method Post -Body $loginBody -Headers $headers -SessionVariable webSession -ErrorAction Stop | Out-Null

        function _NitroGet {
            param([string]$Url, [hashtable]$Hdrs, [Microsoft.PowerShell.Commands.WebRequestSession]$Session, [string]$Prop)
            try {
                $r = Invoke-RestMethod -Uri $Url -Headers $Hdrs -WebSession $Session -ErrorAction Stop
                if ($r -and $r.PSObject.Properties[$Prop]) { return @($r.$Prop) }
            } catch { }
            return @()
        }

        # HA state
        $haNodes  = @(_NitroGet "$baseUrl/config/hanode"     $headers $webSession 'hanode')
        # LB vServers
        $lbVSrvs  = @(_NitroGet "$baseUrl/stat/lbvserver"    $headers $webSession 'lbvserver')
        # CS vServers
        $csVSrvs  = @(_NitroGet "$baseUrl/stat/csvserver"    $headers $webSession 'csvserver')
        # Gateway vServers
        $vpnVSrvs = @(_NitroGet "$baseUrl/stat/vpnvserver"   $headers $webSession 'vpnvserver')
        # SSL Certificates
        $sslCerts = @(_NitroGet "$baseUrl/config/sslcertkey" $headers $webSession 'sslcertkey')

        # Logout
        try { Invoke-RestMethod -Uri "$baseUrl/config/logout" -Method Post -Headers $headers -WebSession $webSession -ErrorAction Stop | Out-Null } catch { }
        $webSession = $null   # markeer als uitgelogd zodat catch-block het niet opnieuw doet

        $downVSrvs    = @(($lbVSrvs + $csVSrvs + $vpnVSrvs) | Where-Object { $_.state -ne 'UP' })
        $expiringCerts = @($sslCerts | Where-Object { [int]$_.daystoexpiration -le $WarnDays })
        $issueCount    = $downVSrvs.Count + $expiringCerts.Count

        return [PSCustomObject]@{
            Name         = $NsCfg.Name
            HostName     = $NsCfg.HostName
            Success      = $true
            HaNodes      = $haNodes
            LbVSrvs      = $lbVSrvs
            CsVSrvs      = $csVSrvs
            VpnVSrvs     = $vpnVSrvs
            SslCerts     = $sslCerts
            IssueCount   = $issueCount
            ShortSummary = "$($lbVSrvs.Count + $csVSrvs.Count + $vpnVSrvs.Count) vSrv, $($downVSrvs.Count) down, $($expiringCerts.Count) cert expiring"
            ErrorMessage = $null
        }
    }
    catch {
        if ($webSession) {
            try { Invoke-RestMethod -Uri "$baseUrl/config/logout" -Method Post -Headers $headers -WebSession $webSession -ErrorAction Stop | Out-Null } catch {}
        }
        return [PSCustomObject]@{
            Name         = $NsCfg.Name
            HostName     = $NsCfg.HostName
            Success      = $false
            HaNodes      = @()
            LbVSrvs      = @()
            CsVSrvs      = @()
            VpnVSrvs     = @()
            SslCerts     = @()
            IssueCount   = 1
            ShortSummary = "FAILED: $($_.Exception.Message)"
            ErrorMessage = $_.Exception.Message
        }
    }
}

# =============================================================================
# Build combined HTML for all instances
# =============================================================================
function _BuildNSErrorHtml {
    param([string]$CheckName, [string]$Message)
    return @"
<div style='margin-bottom:24px;background:#fff;border-radius:6px;border:1px solid #e74c3c;overflow:hidden'>
  <div style='background:#e74c3c;color:#fff;padding:12px 18px;font-size:16px;font-weight:700'>&#9888; $CheckName - Script Error</div>
  <div style='padding:16px;color:#c0392b;font-size:13px'>$Message</div>
</div>
"@
}

# =============================================================================
function _BuildCombinedNSHtml {
    param([System.Collections.Generic.List[PSCustomObject]]$InstanceResults)

    $anyIssue    = $InstanceResults | Where-Object { $_.IssueCount -gt 0 }
    $badgeColour = if ($anyIssue) { '#e74c3c' } else { '#27ae60' }
    $badgeText   = if ($anyIssue) { 'ISSUES FOUND' } else { 'ALL OK' }

    $instanceBlocks = foreach ($inst in $InstanceResults) {
        if (-not $inst.Success) {
            @"
      <div class='cx-sub' data-collapsed='0' style='margin-bottom:16px;border:1px solid #e74c3c;border-radius:6px;overflow:hidden'>
        <div style='background:#e74c3c;color:#fff;padding:9px 14px;display:flex;justify-content:space-between;align-items:center'>
          <span style='font-size:14px;font-weight:600'>&#9888; $($inst.Name)</span>
          <span style='font-size:11px;opacity:.8'>$($inst.HostName)</span>
        </div>
        <div style='padding:12px 14px;color:#c0392b;font-size:13px'>$($inst.ErrorMessage)</div>
      </div>
"@
            continue
        }

        $instHasIssue    = $inst.IssueCount -gt 0
        $instBadgeColour = if ($instHasIssue) { '#e74c3c' } else { '#27ae60' }
        $instBadgeText   = if ($instHasIssue) { 'ISSUES' } else { 'OK' }

        # == HA ================================================================
        $haSection = ''
        if (@($inst.HaNodes).Count -gt 0) {
            $haRows = foreach ($node in @($inst.HaNodes)) {
                # Veilige property-access: hanode response heeft niet altijd alle velden
                $nName  = if ($node.PSObject.Properties['name'])      { $node.name }      else { "Node $($node.id)" }
                $nState = if ($node.PSObject.Properties['state'])     { $node.state }     else { 'Unknown' }
                $nIp    = if ($node.PSObject.Properties['ipaddress']) { $node.ipaddress } else { '-' }
                $nSync  = if ($node.PSObject.Properties['hasync'])    { $node.hasync }    else { 'N/A' }
                $stateCol = if ($nState -eq 'Primary') { '#27ae60' } elseif ($nState -eq 'Secondary') { '#3498db' } else { '#e74c3c' }
                $syncOk   = $nSync -match 'ENABLED|SUCCESS' -or $nState -eq 'Primary'
                $syncCol  = if ($syncOk) { '#27ae60' } else { '#e74c3c' }
                "<tr><td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px'>$nName</td><td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;color:$stateCol;font-weight:bold'>$nState</td><td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px'>$nIp</td><td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;color:$syncCol'>$nSync</td></tr>"
            }
            $haSection = @"
          <div style='margin-bottom:12px'>
            <div style='font-size:12px;font-weight:600;color:#2c3e50;margin-bottom:4px'>High Availability</div>
            <table style='width:100%;border-collapse:collapse'>
              <thead><tr style='background:#f4f6f8'>
                <th style='padding:6px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Node</th>
                <th style='padding:6px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>State</th>
                <th style='padding:6px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>IP</th>
                <th style='padding:6px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Sync</th>
              </tr></thead>
              <tbody>$haRows</tbody>
            </table>
          </div>
"@
        }

        # == vServer helper ====================================================
        function _VSTable($title, $vSrvs, $showSessions) {
            if (-not $vSrvs -or @($vSrvs).Count -eq 0) { return '' }
            $rows = foreach ($vs in ($vSrvs | Sort-Object name)) {
                $vsName  = if ($vs.PSObject.Properties['name'])  { $vs.name }  else { '-' }
                $vsState = if ($vs.PSObject.Properties['state']) { $vs.state } else { 'UNKNOWN' }
                $sc = if ($vsState -eq 'UP') { '#27ae60' } elseif ($vsState -eq 'DOWN') { '#e74c3c' } else { '#f39c12' }
                $ic = if ($vsState -eq 'UP') { '&#10003;' } else { '&#10007;' }
                $bg = if ($vsState -ne 'UP') { "background:#fff5f5;" } else { '' }
                $extra = if ($showSessions -and $vs.PSObject.Properties['currentclientconnections'] -and $vs.currentclientconnections) { "$($vs.currentclientconnections) sess." } else { '-' }
                "<tr style='$bg'><td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px'>$vsName</td><td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;color:$sc;font-weight:bold'>$ic $vsState</td><td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#777'>$extra</td></tr>"
            }
            return @"
          <div style='margin-bottom:12px'>
            <div style='font-size:12px;font-weight:600;color:#2c3e50;margin-bottom:4px'>$title ($(@($vSrvs).Count))</div>
            <table style='width:100%;border-collapse:collapse'>
              <thead><tr style='background:#f4f6f8'>
                <th style='padding:6px 10px;text-align:left;color:#555;font-size:11px;font-weight:600;width:55%'>Name</th>
                <th style='padding:6px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>State</th>
                <th style='padding:6px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Info</th>
              </tr></thead>
              <tbody>$rows</tbody>
            </table>
          </div>
"@
        }

        $lbHtml  = _VSTable 'Load Balancing vServers'    @($inst.LbVSrvs)  $false
        $csHtml  = _VSTable 'Content Switching vServers' @($inst.CsVSrvs)  $false
        $vpnHtml = _VSTable 'Gateway (VPN) vServers'     @($inst.VpnVSrvs) $true

        # == SSL Certs =========================================================
        $sslSection = ''
        if (@($inst.SslCerts).Count -gt 0) {
            $sslRows = foreach ($c in (@($inst.SslCerts) | Sort-Object { [int]$_.daystoexpiration })) {
                $days = [int]$c.daystoexpiration
                $sev  = if ($days -le 7) { 'CRITICAL' } elseif ($days -le 30) { 'WARNING' } else { 'OK' }
                $dc   = switch ($sev) { 'CRITICAL' { '#e74c3c' } 'WARNING' { '#f39c12' } default { '#27ae60' } }
                $bg   = switch ($sev) { 'CRITICAL' { 'background:#fff5f5;' } 'WARNING' { 'background:#fffdf0;' } default { '' } }
                $subj = if ($c.subject.Length -gt 55) { $c.subject.Substring(0,55) + '…' } else { $c.subject }
                "<tr style='$bg'><td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;font-weight:500'>$($c.certkey)</td><td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:11px;color:#777'>$subj</td><td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;color:$dc;font-weight:bold;text-align:center'>$days d</td><td style='padding:6px 10px;border-bottom:1px solid #f0f0f0;font-size:12px;color:$dc;text-align:center'>$sev</td></tr>"
            }
            $sslSection = @"
          <div style='margin-bottom:12px'>
            <div style='font-size:12px;font-weight:600;color:#2c3e50;margin-bottom:4px'>SSL Certificates ($(@($inst.SslCerts).Count))</div>
            <table style='width:100%;border-collapse:collapse'>
              <thead><tr style='background:#f4f6f8'>
                <th style='padding:6px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Name</th>
                <th style='padding:6px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Subject</th>
                <th style='padding:6px 10px;text-align:center;color:#555;font-size:11px;font-weight:600'>Days left</th>
                <th style='padding:6px 10px;text-align:center;color:#555;font-size:11px;font-weight:600'>Status</th>
              </tr></thead>
              <tbody>$sslRows</tbody>
            </table>
          </div>
"@
        }

        @"
      <div class='cx-sub' data-collapsed='0' style='margin-bottom:16px;border:1px solid #dde1e7;border-radius:6px;overflow:hidden'>
        <div style='background:#34495e;color:#fff;padding:9px 14px;display:flex;justify-content:space-between;align-items:center'>
          <span style='font-size:14px;font-weight:600'>$($inst.Name)</span>
          <div style='display:flex;gap:8px;align-items:center'>
            <span style='font-size:11px;opacity:.7'>$($inst.HostName)</span>
            <span style='font-size:11px;background:$instBadgeColour;padding:2px 9px;border-radius:10px;font-weight:700'>$instBadgeText</span>
          </div>
        </div>
        <div style='padding:12px 14px'>
          $haSection
          $lbHtml
          $csHtml
          $vpnHtml
          $sslSection
        </div>
      </div>
"@
    }

    return @"
<div style='margin-bottom:24px;background:#fff;border-radius:6px;border:1px solid #dde1e7;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.06)'>
  <div style='background:#2c3e50;color:#fff;padding:12px 18px;display:flex;justify-content:space-between;align-items:center'>
    <span style='font-size:16px;font-weight:700'>&#127760; NetScaler (Citrix ADC)</span>
    <span style='font-size:12px;background:$badgeColour;padding:4px 12px;border-radius:12px;font-weight:700'>$badgeText</span>
  </div>
  <div style='padding:16px'>
    $instanceBlocks
  </div>
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
    $result = Invoke-NetScalerCheck -Config $cfg -Verbose
    Write-Host "`n[$($result.CheckName)] $($result.Summary) | Duration: $($result.Duration)" -ForegroundColor $(if ($result.HasIssues) { 'Red' } else { 'Green' })
}

