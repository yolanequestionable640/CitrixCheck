#Requires -Version 5.1
<#
.SYNOPSIS
    Citrix Federated Authentication Service (FAS) health check.

.DESCRIPTION
    Connects to each FAS server defined in config.json and checks:

    Always checked (no SDK required):
        1. Service availability - CitrixFederatedAuthenticationService Windows service
           via WinRM (Get-Service).
        2. Authorization certificates - expiry and validity of the FAS Registration
           Authority (RA) certificates. Read from a JSON file written by the local
           FAS agent (fas-agents\Run-FasCertCheck.ps1) running as a Scheduled Task
           (daily 06:00) on each FAS server. This is the primary visible output in
           the report.

    Attempted via FAS WCF SDK (net.tcp://; only if accessible from monitoring server):
        3. FAS server version - via Get-FasServer.
        4. FAS rules - enabled/disabled state via Get-FasRule. Only shown in the
           report when one or more rules are returned.
        5. User certificate counts - total issued, near-expiry and failed certificates
           via Get-FasUserCertificate. Counts are used for issue detection only;
           the individual certificates are not listed in the report HTML.

    Falls back to service-only check (items 1 + 2) when the FAS snap-in or WCF
    endpoint is not accessible from the monitoring server.

    Can be run standalone or dot-sourced by Invoke-DailyReport.ps1.

.PARAMETER Config
    PSCustomObject parsed from config.json. When omitted the script loads config.json
    from its own parent directory (standalone mode).

.EXAMPLE
    PS C:\> .\checks\Check-FAS.ps1
    Runs the FAS health check and prints a summary to the console.

.EXAMPLE
    # Used by the master orchestrator:
    . .\checks\Check-FAS.ps1
    $result = Invoke-FASCheck -Config $config

.INPUTS
    None. All input comes from config.json or the -Config parameter.

.OUTPUTS
    [PSCustomObject] with properties:
        CheckName   [string]  - Display name of this check.
        SectionHtml [string]  - HTML fragment to embed in the daily report.
        HasIssues   [bool]    - $true when FAS service is down or CA unreachable.
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
        - Citrix FAS PowerShell snap-in (Citrix.Authentication.FederatedAuthenticationService.V1)
          or the Citrix Virtual Apps and Desktops PowerShell SDK.
          Default module location:
            C:\Program Files\Citrix\Federated Authentication Service\PowerShell\
        - WinRM access to both FAS servers for service checks (Get-Service via WinRM).
        - Admin share access (\\server\C$) to read the authorization certificate JSON:
            C:\Windows\Logs\FAS_AuthorizationCert_Check.json
          This JSON is written by fas-agents\Run-FasCertCheck.ps1, deployed via
          Initialize-CitrixCheck.ps1 (step 6: FAS agent deployment).
        - FAS Administrator role or FAS Read-Only Administrator.

    FAS servers monitored:
        CTX-FAS01.ad.example.com
        CTX-FAS02.ad.example.com

    Scheduling:
        Run daily via Windows Task Scheduler or call through Invoke-DailyReport.ps1.
#>

# =============================================================================
# Exported function
# =============================================================================
function Invoke-FASCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $stopwatch  = [System.Diagnostics.Stopwatch]::StartNew()
    $checkName  = 'Federated Authentication Service (FAS)'

    # FAS server list from config
    $fasServers = if ($Config.FAS -and $Config.FAS.Servers) {
        @($Config.FAS.Servers)
    }
    else {
        @($Config.Servers | Where-Object { $_.Role -eq 'Federated Authentication Service' } | Select-Object -ExpandProperty Name)
    }

    # == Try loading FAS PowerShell snap-in / module ===========================
    $fasModuleAvailable = $false
    $fasSnapinName      = 'Citrix.Authentication.FederatedAuthenticationService.V1'

    # 1. PSSnapin (installed with FAS management tools or remote SDK)
    if (-not $fasModuleAvailable) {
        if (Get-PSSnapin -Name $fasSnapinName -ErrorAction SilentlyContinue) {
            $fasModuleAvailable = $true
            Write-Verbose 'FAS snap-in already loaded'
        }
        else {
            try {
                Add-PSSnapin -Name $fasSnapinName -ErrorAction Stop
                $fasModuleAvailable = $true
                Write-Verbose 'FAS snap-in loaded via Add-PSSnapin'
            }
            catch { Write-Verbose "FAS snap-in not registered: $($_.Exception.Message)" }
        }
    }

    # 2. PSModule (if installed as module instead of snap-in)
    if (-not $fasModuleAvailable) {
        try {
            Import-Module $fasSnapinName -ErrorAction Stop
            $fasModuleAvailable = $true
            Write-Verbose 'FAS module loaded from PSModulePath'
        }
        catch { Write-Verbose 'FAS module not found in PSModulePath' }
    }

    # 3. Direct path fallback
    if (-not $fasModuleAvailable) {
        $fasModulePaths = @(
            'C:\Program Files\Citrix\Federated Authentication Service\PowerShell',
            'C:\Program Files\Citrix\Virtual Desktop Agent\FAS'
        )
        foreach ($modPath in $fasModulePaths) {
            $modFile = Join-Path $modPath "$fasSnapinName.psm1"
            if (Test-Path $modFile) {
                try {
                    Import-Module $modFile -ErrorAction Stop
                    $fasModuleAvailable = $true
                    Write-Verbose "FAS module loaded from path: $modPath"
                    break
                }
                catch { Write-Verbose "Failed to load FAS module from $($modPath): $($_.Exception.Message)" }
            }
        }
    }

    try {
        if ($fasModuleAvailable) {
            return _RunFASFullCheck -FasServers $fasServers -Stopwatch $stopwatch -CheckName $checkName
        }
        else {
            return _RunFASServiceFallback -FasServers $fasServers -Stopwatch $stopwatch -CheckName $checkName
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
# Full SDK check
# =============================================================================
function _RunFASFullCheck {
    param($FasServers, $Stopwatch, $CheckName)

    $serverData = [System.Collections.Generic.List[PSCustomObject]]::new()
    $issueCount = 0

    foreach ($fasHost in $FasServers) {
        Write-Verbose "Connecting to FAS server: $fasHost"
        $address = "net.tcp://$fasHost/Citrix/Authentication/FederatedAuthenticationService"

        # Step 1: reachability + service check (authoritative for Online status)
        $pingOk = Test-Connection -ComputerName $fasHost -Count 1 -Quiet -ErrorAction SilentlyContinue
        $svcOk  = $false
        if ($pingOk) {
            try {
                $svc   = Get-Service -ComputerName $fasHost -Name 'CitrixFederatedAuthenticationService' -ErrorAction Stop
                $svcOk = ($svc.Status -eq 'Running')
            } catch {}
        }

        if (-not $pingOk -or -not $svcOk) {
            $issueCount++
            $serverData.Add([PSCustomObject]@{
                Name              = $fasHost
                Online            = $false
                Version           = '-'
                Rules             = @()
                DisabledRules     = @()
                AuthCerts         = @()
                AuthCertsExpiring = 0
                TotalUserCerts    = 0
                ExpiringUserCerts = 0
                FailedUserCerts   = 0
                GpoWarning        = $null
                Error             = if (-not $pingOk) { 'Server not reachable (ping failed)' } else { 'Citrix Federated Authentication Service is not running' }
            })
            continue
        }

        # Step 2: SDK calls — service is running
        $fasInfo    = $null
        $rules      = @()
        $authCerts  = @()
        $userCerts  = @()
        $gpoWarning = $null
        $sdkError   = $null

        # Step 1: Read auth cert data from JSON written by the local FAS agent script
        #         (Run-FasCertCheck.ps1 runs as a scheduled task on each FAS server)
        $jsonPath = "\\$fasHost\C$\Windows\Logs\FAS_AuthorizationCert_Check.json"
        try {
            if (Test-Path $jsonPath) {
                $authCerts = @(Get-Content $jsonPath -Raw -ErrorAction Stop | ConvertFrom-Json)
                Write-Verbose "  Read $($authCerts.Count) authorization certificate(s) from JSON: $jsonPath"
            } else {
                $authCerts = @()
                Write-Verbose "  JSON not found (agent not yet run?): $jsonPath"
            }
        } catch {
            $authCerts = @()
            Write-Verbose "  Failed to read JSON from $jsonPath`: $($_.Exception.Message)"
        }

        # Step 2: Retrieve FAS server info, rules and user certificates
        try {
            $fasInfo   = Get-FasServer         -Address $address -ErrorAction Stop
            $rules     = Get-FasRule           -Address $address -ErrorAction SilentlyContinue
            $userCerts = @(Get-FasUserCertificate -Address $address -MaxRecordCount 5000 -ErrorAction SilentlyContinue)
        }
        catch {
            $rawMsg = $_.Exception.Message
            if ($rawMsg -like '*No Federated Authentication Service configured*') {
                $gpoWarning = 'FAS service is running but not yet configured via GPO on the domain controllers.'
            } else {
                $sdkError = $rawMsg
            }
        }

        $authCertExpiring = @($authCerts | Where-Object {
            $notAfter = _GetFasCertExpiry $_
            $notAfter -and (New-TimeSpan -Start (Get-Date) -End $notAfter).TotalDays -le 30
        })
        $certExpiringSoon = @($userCerts | Where-Object {
            $ep = $_.PSObject.Properties['ExpiryDate']
            $ep -and $ep.Value -and (New-TimeSpan -Start (Get-Date) -End $ep.Value).TotalDays -le 30
        })
        $certFailed    = @($userCerts | Where-Object { $_.State -ne 'Good' })
        $disabledRules = @($rules | Where-Object { -not $_.Enabled })

        if ($disabledRules.Count    -gt 0) { $issueCount += $disabledRules.Count    }
        if ($certFailed.Count       -gt 0) { $issueCount += $certFailed.Count       }
        if ($authCertExpiring.Count -gt 0) { $issueCount += $authCertExpiring.Count }

        $serverData.Add([PSCustomObject]@{
            Name              = $fasHost
            Online            = $true
            Version           = if ($fasInfo -and $fasInfo.Version) { $fasInfo.Version } else { 'Unknown' }
            Rules             = $rules
            DisabledRules     = $disabledRules
            AuthCerts         = $authCerts
            AuthCertsExpiring = $authCertExpiring.Count
            TotalUserCerts    = @($userCerts).Count
            ExpiringUserCerts = $certExpiringSoon.Count
            FailedUserCerts   = $certFailed.Count
            GpoWarning        = $gpoWarning
            Error             = $sdkError
        })
    }

    $stopwatch.Stop()
    return [PSCustomObject]@{
        CheckName   = $CheckName
        SectionHtml = _BuildFASHtml -ServerData $serverData -Mode 'Full'
        HasIssues   = ($issueCount -gt 0)
        IssueCount  = $issueCount
        Summary     = "$($FasServers.Count) FAS server(s) - $(@($serverData | Where-Object {-not $_.Online}).Count) offline | $issueCount issue(s)"
        Duration    = "$([math]::Round($stopwatch.Elapsed.TotalSeconds,1))s"
        Error       = $null
    }
}

# =============================================================================
# Service-only fallback
# =============================================================================
function _RunFASServiceFallback {
    param($FasServers, $Stopwatch, $CheckName)

    Write-Verbose 'FAS module not available - running service-only fallback'
    $serverData = [System.Collections.Generic.List[PSCustomObject]]::new()
    $issueCount = 0

    foreach ($fasHost in $FasServers) {
        $reachable = Test-Connection -ComputerName $fasHost -Count 1 -Quiet -ErrorAction SilentlyContinue
        $svcStatus = 'UNKNOWN'
        $svcError  = ''

        if ($reachable) {
            try {
                $svc       = Get-Service -ComputerName $fasHost -Name 'CitrixFederatedAuthenticationService' -ErrorAction Stop
                $svcStatus = if ($svc.Status -eq 'Running') { 'RUNNING' } else { $svc.Status.ToString().ToUpper() }
                if ($svcStatus -ne 'RUNNING') { $issueCount++ }
            }
            catch {
                $svcStatus = 'ERROR'
                $svcError  = $_.Exception.Message
                $issueCount++
            }
        }
        else {
            $issueCount++
        }

        # Read auth cert JSON even in fallback mode - no SDK required
        $jsonPath  = "\\$fasHost\C$\Windows\Logs\FAS_AuthorizationCert_Check.json"
        $authCerts = @()
        try {
            if (Test-Path $jsonPath) {
                $authCerts = @(Get-Content $jsonPath -Raw -ErrorAction Stop | ConvertFrom-Json)
            }
        } catch { }

        $serverData.Add([PSCustomObject]@{
            Name      = $fasHost
            Reachable = $reachable
            SvcStatus = $svcStatus
            SvcError  = $svcError
            AuthCerts = $authCerts
        })
    }

    $stopwatch.Stop()
    return [PSCustomObject]@{
        CheckName   = $CheckName
        SectionHtml = _BuildFASHtml -ServerData $serverData -Mode 'Fallback'
        HasIssues   = ($issueCount -gt 0)
        IssueCount  = $issueCount
        Summary     = "$($FasServers.Count) FAS server(s) checked (service mode - FAS module unavailable) - $issueCount issue(s)"
        Duration    = "$([math]::Round($stopwatch.Elapsed.TotalSeconds,1))s"
        Error       = $null
    }
}

# =============================================================================
# Private helpers
# =============================================================================
function _BuildAuthCertTable {
    param([array]$AuthCerts)
    if (-not $AuthCerts -or @($AuthCerts).Count -eq 0) { return '' }

    $acRows = foreach ($ac in $AuthCerts) {
        $notAfter = _GetFasCertExpiry $ac
        $days     = if ($notAfter) { [math]::Round((New-TimeSpan -Start (Get-Date) -End $notAfter).TotalDays) } else { $null }
        $expDate  = if ($notAfter) { $notAfter.ToString('dd-MM-yyyy') } else { '-' }
        $dText    = if ($null -ne $days) { "$days days" } else { '-' }
        $dCol     = if ($null -ne $days -and $days -le 7) { '#e74c3c' } elseif ($null -ne $days -and $days -le 30) { '#f39c12' } else { '#27ae60' }
        $rowBg    = if ($null -ne $days -and $days -le 7) { 'background:#fff5f5;' } elseif ($null -ne $days -and $days -le 30) { 'background:#fffdf0;' } else { '' }
        $tp       = _GetFasCertThumbprint $ac
        $tpShort  = if ($tp -ne '-' -and $tp.Length -ge 12) { "$($tp.Substring(0,8))...$($tp.Substring($tp.Length-4))" } else { $tp }
        $status   = _GetFasCertStatus $ac
        $stCol    = if ($status -eq 'Ok') { '#27ae60' } else { '#e74c3c' }
        $ca       = _GetFasCertCA $ac
        "<tr style='$rowBg'><td style='padding:6px 10px;border-bottom:1px solid #f5f5f5;font-size:14px;font-weight:700;color:$dCol'>$expDate</td><td style='padding:6px 10px;border-bottom:1px solid #f5f5f5;font-size:13px;font-weight:bold;color:$dCol;text-align:center'>$dText</td><td style='padding:6px 10px;border-bottom:1px solid #f5f5f5;font-size:12px;color:$stCol;font-weight:bold;text-align:center'>$status</td><td style='padding:6px 10px;border-bottom:1px solid #f5f5f5;font-size:12px;color:#555'>$ca</td><td style='padding:6px 10px;border-bottom:1px solid #f5f5f5;font-size:11px;font-family:monospace;color:#888'>$tpShort</td></tr>"
    }

    return @"
<div style='margin-top:8px'>
  <div style='font-size:12px;font-weight:600;color:#2c3e50;margin-bottom:4px'>&#128273; Authorization Certificates (RA)</div>
  <table style='width:100%;border-collapse:collapse'>
    <thead><tr style='background:#f4f6f8'>
      <th style='padding:5px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Expiry Date</th>
      <th style='padding:5px 10px;text-align:center;color:#555;font-size:11px;font-weight:600'>Days left</th>
      <th style='padding:5px 10px;text-align:center;color:#555;font-size:11px;font-weight:600'>Status</th>
      <th style='padding:5px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Issued by (CA)</th>
      <th style='padding:5px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Thumbprint</th>
    </tr></thead>
    <tbody>$acRows</tbody>
  </table>
</div>
"@
}

function _GetFasCertExpiry {
    param($ac)
    # FAS SDK returns ExpiryDate as top-level property (DateTime or string)
    $ep = $ac.PSObject.Properties['ExpiryDate']
    if ($ep -and $ep.Value) { try { return [datetime]$ep.Value } catch { } }
    # Fallback: NotAfter at top level
    $na = $ac.PSObject.Properties['NotAfter']
    if ($na -and $na.Value) { try { return [datetime]$na.Value } catch { } }
    return $null
}

function _GetFasCertThumbprint {
    param($ac)
    # FAS SDK uses 'ThumbPrint' (capital P)
    foreach ($propName in @('ThumbPrint','Thumbprint','CertificateThumbprint')) {
        $p = $ac.PSObject.Properties[$propName]
        if ($p -and $p.Value) { return $p.Value }
    }
    return '-'
}

function _GetFasCertStatus {
    param($ac)
    foreach ($propName in @('Status','CertificateStatus','State')) {
        $p = $ac.PSObject.Properties[$propName]
        if ($p -and $p.Value) { return $p.Value.ToString() }
    }
    return '-'
}

function _GetFasCertCA {
    param($ac)
    # FAS SDK 'Address' contains the CA path (e.g. server\CA Name)
    $a = $ac.PSObject.Properties['Address']
    if ($a -and $a.Value) { return $a.Value.ToString() }
    return '-'
}

# =============================================================================
# HTML builders
# =============================================================================
function _BuildFASHtml {
    param(
        [array]$ServerData,
        [string]$Mode
    )

    $hasIssue    = $ServerData | Where-Object { ($Mode -eq 'Full' -and (-not $_.Online -or $_.FailedUserCerts -gt 0 -or $_.DisabledRules.Count -gt 0 -or $_.AuthCertsExpiring -gt 0)) -or ($Mode -eq 'Fallback' -and (-not $_.Reachable -or $_.SvcStatus -ne 'RUNNING')) }
    $badgeColour = if ($hasIssue) { '#e74c3c' } else { '#27ae60' }
    $badgeText   = if ($hasIssue) { 'ISSUES FOUND' } else { 'ALL OK' }
    $modeNote    = if ($Mode -eq 'Fallback') { " <span style='font-size:11px;background:#f39c12;color:#fff;padding:2px 8px;border-radius:10px;margin-left:6px'>Service check only - FAS module unavailable</span>" } else { '' }

    $serverBlocks = foreach ($srv in $ServerData) {

        if ($Mode -eq 'Fallback') {
            $rc    = if ($srv.Reachable) { '#27ae60' } else { '#e74c3c' }
            $rct   = if ($srv.Reachable) { 'Reachable' } else { 'UNREACHABLE' }
            $sc    = if ($srv.SvcStatus -eq 'RUNNING') { '#27ae60' } else { '#e74c3c' }
            $rowBg = if (-not $srv.Reachable -or $srv.SvcStatus -ne 'RUNNING') { 'background:#fff5f5;' } else { '' }

            # Auth cert table from JSON (available regardless of SDK)
            $fbCertHtml = _BuildAuthCertTable -AuthCerts $srv.AuthCerts

            @"
        <div style='margin-bottom:12px;border:1px solid #dde1e7;border-radius:4px;overflow:hidden;${rowBg}'>
          <div style='padding:9px 14px;display:flex;justify-content:space-between;align-items:center;background:#f8f9fa;border-bottom:1px solid #eee'>
            <span style='font-size:13px;font-weight:600'>$($srv.Name)</span>
          </div>
          <div style='padding:8px 14px;font-size:13px'>
            Reachability: <strong style='color:$rc'>$rct</strong> &nbsp;|&nbsp;
            Service: <strong style='color:$sc'>$($srv.SvcStatus)</strong>
            $(if ($srv.SvcError) { "<br><small style='color:#e74c3c'>$($srv.SvcError)</small>" })
          </div>
          $(if ($fbCertHtml) { "<div style='padding:0 14px 10px'>$fbCertHtml</div>" })
        </div>
"@
        }
        else {
            $stateCol  = if ($srv.Online) { '#27ae60' } else { '#e74c3c' }
            $stateTxt  = if ($srv.Online) { '&#10003; Online' } else { '&#10007; OFFLINE' }
            $rowBg     = if (-not $srv.Online) { '#fff5f5' } else { '#fff' }

            # Rules
            $rulesHtml = ''
            if ($srv.Rules -and $srv.Rules.Count -gt 0) {
                $ruleRows = foreach ($r in $srv.Rules) {
                    $enCol = if ($r.Enabled) { '#27ae60' } else { '#e74c3c' }
                    $enTxt = if ($r.Enabled) { 'Enabled' } else { 'DISABLED' }
                    "<tr><td style='padding:5px 10px;border-bottom:1px solid #f5f5f5;font-size:12px'>$($r.Name)</td><td style='padding:5px 10px;border-bottom:1px solid #f5f5f5;font-size:12px;color:$enCol;font-weight:bold'>$enTxt</td><td style='padding:5px 10px;border-bottom:1px solid #f5f5f5;font-size:12px;color:#777'>$($r.CertificateDefinition)</td></tr>"
                }
                $rulesHtml = @"
            <div style='margin-top:8px'>
              <div style='font-size:12px;font-weight:600;color:#2c3e50;margin-bottom:4px'>Authorization Rules</div>
              <table style='width:100%;border-collapse:collapse'>
                <thead><tr style='background:#f4f6f8'><th style='padding:5px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Rule</th><th style='padding:5px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>State</th><th style='padding:5px 10px;text-align:left;color:#555;font-size:11px;font-weight:600'>Certificate Definition</th></tr></thead>
                <tbody>$ruleRows</tbody>
              </table>
            </div>
"@
            }

            # Authorization (RA) certificate table
            $authCertHtml = _BuildAuthCertTable -AuthCerts $srv.AuthCerts

            @"
        <div style='margin-bottom:12px;border:1px solid #dde1e7;border-radius:4px;overflow:hidden'>
          <div style='padding:9px 14px;display:flex;justify-content:space-between;align-items:center;background:#f8f9fa;border-bottom:1px solid #eee'>
            <span style='font-size:13px;font-weight:600'>$($srv.Name)</span>
            <div>
              <span style='font-size:12px;color:$stateCol;font-weight:bold'>$stateTxt</span>
              $(if ($srv.Version -and $srv.Version -ne '-' -and $srv.Version -ne 'Unknown') { " &nbsp;<span style='font-size:11px;color:#777'>v$($srv.Version)</span>" })
            </div>
          </div>
          <div style='padding:8px 14px;background:$rowBg'>
            $(if ($srv.Error) { "<div style='color:#e74c3c;font-size:12px;margin-bottom:6px'>$($srv.Error)</div>" })
            $authCertHtml
            $rulesHtml
          </div>
        </div>
"@
        }
    }

    return @"
<div style='margin-bottom:24px;background:#fff;border-radius:6px;border:1px solid #dde1e7;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.06)'>
  <div style='background:#2c3e50;color:#fff;padding:12px 18px;display:flex;justify-content:space-between;align-items:center'>
    <span style='font-size:16px;font-weight:700'>&#128274; Federated Authentication Service (FAS)$modeNote</span>
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
    $result = Invoke-FASCheck -Config $cfg -Verbose
    Write-Host "`n[$($result.CheckName)] $($result.Summary) | Duration: $($result.Duration)" -ForegroundColor $(if ($result.HasIssues) { 'Red' } else { 'Green' })
}

