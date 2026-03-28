#Requires -Version 5.1
<#
.SYNOPSIS
    One-time setup script for CitrixCheck — configures all credentials and settings.

.DESCRIPTION
    Performs all one-time configuration steps required before Invoke-DailyReport.ps1
    can be run:

        1. Set execution policy (Bypass for the current session)
        2. Configure CVAD SDK on-premises authentication profile
        3. Encrypt and store SMTP credentials in config.json
        4. Encrypt and store NetScaler credentials in config.json
        5. Encrypt and store XenServer credentials in config.json
        6. Deploy FAS agent scripts to FAS servers

    Each step can be skipped individually. The script automatically updates config.json
    and creates all required key files.

    All credentials are encrypted with AES-256 key files (smtp_key.bin, ns_key.bin,
    xen_key.bin). This makes decryption account-independent — the script can run
    under any service account as long as the key files are present in the script
    directory.

.PARAMETER ConfigPath
    Full path to config.json. Default: config.json in the same directory as this script.

.PARAMETER SkipCVAD
    Skip the CVAD SDK on-premises profile configuration.

.PARAMETER SkipSMTP
    Skip SMTP credential configuration.

.PARAMETER SkipNetScaler
    Skip NetScaler credential configuration.

.PARAMETER SkipXenServer
    Skip XenServer credential configuration.

.PARAMETER SkipFasAgents
    Skip FAS agent deployment.

.EXAMPLE
    PS C:\Scripts\CitrixCheck> .\Initialize-CitrixCheck.ps1
    Runs all steps interactively.

.EXAMPLE
    PS C:\Scripts\CitrixCheck> .\Initialize-CitrixCheck.ps1 -SkipNetScaler -SkipXenServer
    Configures CVAD and SMTP only.

.NOTES
    Author:     Ufuk Kocak
    Website:    https://horizonconsulting.it
    LinkedIn:   https://www.linkedin.com/in/ufukkocak
    Created:    2026-03-19
    Version:    1.0.0

    Requirements:
        - Run as the service account that will execute Invoke-DailyReport.ps1
          (or as administrator for the CVAD step).
        - config.json must be present and filled in with server names.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath    = '',
    [switch]$SkipCVAD,
    [switch]$SkipSMTP,
    [switch]$SkipNetScaler,
    [switch]$SkipXenServer,
    [switch]$SkipFasAgents
)

# --- Execution policy (set automatically, no prompt) --------------------------
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# --- Paths --------------------------------------------------------------------
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$configFile = if ($ConfigPath) { $ConfigPath } else { Join-Path $scriptDir 'config.json' }

# =============================================================================
# Helper functions
# =============================================================================
function Write-Step  { param([int]$n, [string]$msg) Write-Host "`n[$n/6] $msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$msg) Write-Host "  OK  $msg" -ForegroundColor Green }
function Write-Skip  { param([string]$msg) Write-Host "  --  $msg (skipped)" -ForegroundColor DarkGray }
function Write-Warn  { param([string]$msg) Write-Host "  !! $msg" -ForegroundColor Yellow }
function Write-Fail  { param([string]$msg) Write-Host "  XX $msg" -ForegroundColor Red }

function Confirm-Step {
    param([string]$Prompt)
    $ans = Read-Host "$Prompt [Y/n]"
    return ($ans -eq '' -or $ans -match '^[yY]')
}

function Save-AesKey {
    param([string]$Path)
    $key = New-Object Byte[] 32
    [Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($key)
    [System.IO.File]::WriteAllBytes($Path, $key)
    return $key
}

function Update-ConfigJson {
    param([string]$Path, [scriptblock]$Mutate)
    $json   = Get-Content $Path -Raw | ConvertFrom-Json
    & $Mutate $json
    $json | ConvertTo-Json -Depth 10 | Out-File $Path -Encoding UTF8 -Force
}

# =============================================================================
# Banner
# =============================================================================
Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host '  CitrixCheck — One-time setup and credential configuration' -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host "  Script dir : $scriptDir"
Write-Host "  Config     : $configFile"
Write-Host ''

if (-not (Test-Path $configFile)) {
    Write-Fail "config.json not found: $configFile"
    Write-Host '  Fill in config.json based on the template and re-run this script.' -ForegroundColor Yellow
    exit 1
}

# =============================================================================
# Step 1 — Execution policy (already set above, notification only)
# =============================================================================
Write-Step 1 'Execution policy (Bypass for current session)'
Write-Ok 'Execution policy set to Bypass for this session.'

# =============================================================================
# Step 2 — CVAD SDK on-premises authentication profile
# =============================================================================
Write-Step 2 'CVAD SDK on-premises authentication profile'

if ($SkipCVAD) {
    Write-Skip 'CVAD SDK configuration'
}
else {
    if (Confirm-Step 'Configure CVAD on-premises profile?') {
        $snapin = 'Citrix.Broker.Admin.V2'
        $loaded = $false

        if (Get-PSSnapin -Name $snapin -ErrorAction SilentlyContinue) {
            $loaded = $true
        }
        else {
            try {
                Add-PSSnapin -Name $snapin -ErrorAction Stop
                $loaded = $true
            }
            catch {
                Write-Warn "Citrix Broker snap-in not found: $($_.Exception.Message)"
                Write-Host '  Install the Citrix Virtual Apps and Desktops Remote PowerShell SDK and re-run this script.' -ForegroundColor Yellow
            }
        }

        if ($loaded) {
            try {
                Set-XDCredentials -ProfileType OnPrem -StoreAs Default -ErrorAction Stop
                Write-Ok 'On-premises profile set as Default (Set-XDCredentials).'
            }
            catch {
                # Older SDK — try Set-ConfigSite
                Write-Warn "Set-XDCredentials not available, trying Set-ConfigSite..."
                try {
                    $config   = Get-Content $configFile -Raw | ConvertFrom-Json
                    $primary  = $config.CVAD.PrimaryController
                    Set-ConfigSite -AdminAddress $primary -ErrorAction Stop
                    Write-Ok "ConfigSite set to $primary (older SDK)."
                }
                catch {
                    Write-Fail "CVAD configuration failed: $($_.Exception.Message)"
                }
            }
        }
    }
    else {
        Write-Skip 'CVAD SDK configuration'
    }
}

# =============================================================================
# Step 3 — SMTP credentials
# =============================================================================
Write-Step 3 'SMTP credentials'

if ($SkipSMTP) {
    Write-Skip 'SMTP credentials'
}
else {
    $smtpKeyFile = Join-Path $scriptDir 'smtp_key.bin'
    $alreadySet  = $false

    try {
        $cfgCheck = Get-Content $configFile -Raw | ConvertFrom-Json
        $alreadySet = ($cfgCheck.Email.SmtpPassword -and
                       $cfgCheck.Email.SmtpPassword -notlike '*<run*' -and
                       $cfgCheck.Email.SmtpPassword.Length -gt 20)
    }
    catch { }

    $doSmtp = $true
    if ($alreadySet) {
        Write-Warn 'SMTP password appears to be already configured in config.json.'
        $doSmtp = Confirm-Step '  Reconfigure?'
        if (-not $doSmtp) { Write-Skip 'SMTP credentials' }
    }
    elseif (-not (Confirm-Step 'Configure SMTP credentials?')) {
        $doSmtp = $false
        Write-Skip 'SMTP credentials'
    }

    if ($doSmtp) {
        # Always create a new AES key on reconfiguration
        $smtpKey = Save-AesKey -Path $smtpKeyFile
        Write-Ok "AES key created: $smtpKeyFile"

        $smtpCred = Get-Credential -Message 'Enter SMTP account (e.g. svc-citrix@example.com)'
        if (-not $smtpCred) {
            Write-Fail 'No credential entered — SMTP skipped.'
        }
        else {
            $encPw = $smtpCred.Password | ConvertFrom-SecureString -Key $smtpKey

            Update-ConfigJson -Path $configFile -Mutate {
                param($json)
                $json.Email.SmtpUsername = $smtpCred.UserName
                $json.Email.SmtpPassword = $encPw
                $json.Email.SmtpKeyFile  = 'smtp_key.bin'
            }

            Write-Ok 'SMTP credentials saved to config.json.'
        }
    }
}

# =============================================================================
# Step 4 — NetScaler credentials
# =============================================================================
Write-Step 4 'NetScaler credentials'

if ($SkipNetScaler) {
    Write-Skip 'NetScaler credentials'
}
else {
    $cfg        = Get-Content $configFile -Raw | ConvertFrom-Json
    $nsAlreadyOk = ($cfg.NetScalerCredentials.Username -and $cfg.NetScalerCredentials.Username -notlike '*<run*')

    if ($nsAlreadyOk) {
        Write-Warn "NetScaler credentials already configured (user: $($cfg.NetScalerCredentials.Username))"
        $overwrite = Confirm-Step '  Reconfigure?'
        if (-not $overwrite) { Write-Skip 'NetScaler credentials'; $skipNs = $true } else { $skipNs = $false }
    }
    else { $skipNs = $false }

    if (-not $skipNs) {
        if (Confirm-Step 'Save NetScaler credentials?') {
            $nsKeyFile = Join-Path $scriptDir 'ns_key.bin'
            $nsKey     = Save-AesKey -Path $nsKeyFile
            Write-Ok "AES key created: $nsKeyFile"

            $nsUser = Read-Host 'NetScaler username (e.g. admin@example.com)'
            $nsPass = Read-Host 'Password' -AsSecureString
            if (-not $nsUser -or $nsPass.Length -eq 0) {
                Write-Fail 'No credentials entered — NetScaler skipped.'
            }
            else {
                $encNsPass = ConvertFrom-SecureString $nsPass -Key $nsKey
                Update-ConfigJson -Path $configFile -Mutate {
                    param($json)
                    $json.NetScalerCredentials.Username          = $nsUser
                    $json.NetScalerCredentials.EncryptedPassword = $encNsPass
                    $json.NetScalerCredentials.NsKeyFile         = 'ns_key.bin'
                }
                Write-Ok "NetScaler credentials saved to config.json (AES-256)"
            }
        }
        else {
            Write-Skip 'NetScaler credentials'
        }
    }
}

# =============================================================================
# Step 5 — XenServer credentials
# =============================================================================
Write-Step 5 'XenServer credentials'

if ($SkipXenServer) {
    Write-Skip 'XenServer credentials'
}
else {
    $alreadySet = $false
    try {
        $cfgCheck   = Get-Content $configFile -Raw | ConvertFrom-Json
        $alreadySet = ($cfgCheck.XenServer.EncryptedPassword -and
                       $cfgCheck.XenServer.EncryptedPassword -notlike '*<run*' -and
                       $cfgCheck.XenServer.EncryptedPassword.Length -gt 20)
    }
    catch { }

    if ($alreadySet) {
        Write-Warn 'XenServer password appears to be already configured in config.json.'
        $overwrite = Confirm-Step '  Reconfigure?'
        if (-not $overwrite) { Write-Skip 'XenServer credentials'; $skipXen = $true } else { $skipXen = $false }
    }
    else { $skipXen = $false }

    if (-not $skipXen) {
        if (Confirm-Step 'Configure XenServer credentials?') {
            # Verify that the XenServer section exists in config.json
            $cfgCheck = Get-Content $configFile -Raw | ConvertFrom-Json
            if (-not $cfgCheck.PSObject.Properties['XenServer']) {
                Write-Fail "The 'XenServer' section is missing from config.json."
                Write-Host '  Add the XenServer section to config.json (see README.md) and re-run this script.' -ForegroundColor Yellow
            }
            else {
                # Use Read-Host to prevent Get-Credential from modifying the username
                Write-Host '  XenServer username (e.g. admin@ad.example.com):' -ForegroundColor White
                $xenUsername = Read-Host '  Username'
                if (-not $xenUsername) {
                    Write-Fail 'No username entered — XenServer skipped.'
                }
                else {
                    $xenPassword = Read-Host '  Password' -AsSecureString
                    if (-not $xenPassword -or $xenPassword.Length -eq 0) {
                        Write-Fail 'No password entered — XenServer skipped.'
                    }
                    else {
                        $xenKeyFile = Join-Path $scriptDir 'xen_key.bin'
                        $xenKey     = Save-AesKey -Path $xenKeyFile
                        Write-Ok "AES key created: $xenKeyFile"

                        $encPassword = ConvertFrom-SecureString $xenPassword -Key $xenKey

                        Update-ConfigJson -Path $configFile -Mutate {
                            param($json)
                            $json.XenServer.Username          = $xenUsername
                            $json.XenServer.EncryptedPassword = $encPassword
                            $json.XenServer.XenKeyFile        = 'xen_key.bin'
                        }

                        Write-Ok "XenServer credentials saved to config.json (AES-256)."
                        Write-Host "  User: $xenUsername" -ForegroundColor DarkGray
                    }
                }
            }
        }
        else {
            Write-Skip 'XenServer credentials'
        }
    }
}

# =============================================================================
# Step 6 — Deploy FAS agent scripts to FAS servers
# =============================================================================
Write-Step 6 'FAS agent — deploy to FAS servers'

if ($SkipFasAgents) {
    Write-Skip 'FAS agent deployment'
}
else {
    $agentScript = Join-Path $scriptDir 'fas-agents\Register-FasScheduledTask.ps1'
    if (-not (Test-Path $agentScript)) {
        Write-Warn "fas-agents\Register-FasScheduledTask.ps1 not found — skipping."
    }
    elseif (Confirm-Step 'Deploy FAS agent to FAS servers (copies Run-FasCertCheck.ps1 + registers Scheduled Task)?') {
        try {
            & $agentScript -ConfigPath $configFile -ErrorAction Stop
        }
        catch {
            Write-Fail "FAS agent deployment failed: $($_.Exception.Message)"
        }
    }
    else {
        Write-Skip 'FAS agent deployment'
        Write-Host "  To deploy manually: .\fas-agents\Register-FasScheduledTask.ps1" -ForegroundColor DarkGray
    }
}

# =============================================================================
# Done
# =============================================================================
Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host '  Setup complete.' -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Next step — manual test:'
Write-Host "    .\Invoke-DailyReport.ps1 -SaveReport -Verbose" -ForegroundColor White
Write-Host ''
Write-Host '  Keep the key files safe (AES-256, account-independent):'
Write-Host "    smtp_key.bin  - SMTP password key" -ForegroundColor Yellow
Write-Host "    ns_key.bin    - NetScaler password key" -ForegroundColor Yellow
Write-Host "    xen_key.bin   - XenServer password key" -ForegroundColor Yellow
Write-Host "    config.json   - contains AES-encrypted passwords (SMTP, NetScaler, XenServer)" -ForegroundColor Yellow
Write-Host ''

