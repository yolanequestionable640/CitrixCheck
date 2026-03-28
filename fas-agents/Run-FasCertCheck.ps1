#Requires -Version 5.1
<#
.SYNOPSIS
    Local FAS Authorization Certificate Check — runs on the FAS server itself.

.DESCRIPTION
    Loads the Citrix FAS PowerShell snap-in, retrieves all authorization certificates
    via Get-FasAuthorizationCertificate -Address localhost and saves the results as
    JSON to C:\Windows\Logs\FAS_AuthorizationCert_Check.json.

    This JSON file is subsequently read by Check-FAS.ps1 on the monitoring server
    via the UNC path \\<fasserver>\C$\Windows\Logs\.

    This script runs as a Scheduled Task on each FAS server (daily at 06:00).
    See Register-FasScheduledTask.ps1 for task registration.

.NOTES
    Author:     Ufuk Kocak
    Website:    https://horizonconsulting.it
    LinkedIn:   https://www.linkedin.com/in/ufukkocak
    Created:    2026-03-19
    Version:    1.0.0

    Output:
        C:\Windows\Logs\FAS_AuthorizationCert_Check.json
        C:\Windows\Logs\FAS_AuthorizationCert_Check.log

    Requirements:
        - Citrix FAS PowerShell snap-in
          (Citrix.Authentication.FederatedAuthenticationService.V1)
        - Local execution on the FAS server
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$LogDir  = 'C:\Windows\Logs'
$LogFile = Join-Path $LogDir 'FAS_AuthorizationCert_Check.log'
$JsonFile = Join-Path $LogDir 'FAS_AuthorizationCert_Check.json'

if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    $line | Tee-Object -FilePath $LogFile -Append | Write-Host
}

Write-Log '=================================================='
Write-Log "FAS Authorization Certificate Check START - $env:COMPUTERNAME"
Write-Log '=================================================='

# Load snap-in
try {
    if (-not (Get-PSSnapin -Name 'Citrix.Authentication.FederatedAuthenticationService.V1' -ErrorAction SilentlyContinue)) {
        Add-PSSnapin 'Citrix.Authentication.FederatedAuthenticationService.V1' -ErrorAction Stop
    }
    Write-Log 'FAS PowerShell snap-in loaded.'
}
catch {
    Write-Log "ERROR: FAS snap-in could not be loaded: $($_.Exception.Message)" 'ERROR'
    @() | ConvertTo-Json | Set-Content -Path $JsonFile -Encoding UTF8
    exit 1
}

# Retrieve certificates
$certInfo = $null
try {
    $certInfo = @(Get-FasAuthorizationCertificate -Address localhost -FullCertInfo -ErrorAction Stop)
    Write-Log "Found: $($certInfo.Count) authorization certificate(s)."
}
catch {
    Write-Log "ERROR: failed to retrieve authorization certificates: $($_.Exception.Message)" 'ERROR'
    @() | ConvertTo-Json | Set-Content -Path $JsonFile -Encoding UTF8
    exit 2
}

if ($certInfo.Count -eq 0) {
    Write-Log 'No authorization certificates found.' 'WARN'
    @() | ConvertTo-Json | Set-Content -Path $JsonFile -Encoding UTF8
    Write-Log '=================================================='
    Write-Log 'FAS Authorization Certificate Check END'
    Write-Log '=================================================='
    exit 0
}

$now    = Get-Date
$output = foreach ($cert in $certInfo) {
    $expiryDate  = $null
    $daysLeft    = $null
    $expiresSoon = $false

    if ($cert.ExpiryDate) {
        try {
            $expiryDate  = [datetime]$cert.ExpiryDate
            $daysLeft    = [math]::Round(($expiryDate - $now).TotalDays)
            $expiresSoon = $expiryDate -lt $now.AddDays(30)
        }
        catch {
            $expiryDate = $cert.ExpiryDate
        }
    }

    $statusOk = ($cert.Status -eq 'Ok')

    if (-not $statusOk)   { Write-Log "WARNING: certificate status is NOT OK ($($cert.Status))" 'WARN' }
    if ($expiresSoon)      { Write-Log "WARNING: certificate expires within 30 days ($daysLeft day(s) remaining)" 'WARN' }

    Write-Log "  Id=$($cert.Id) | Status=$($cert.Status) | Expires=$expiryDate | Remaining=$daysLeft days | CA=$($cert.Address)"

    [PSCustomObject]@{
        ComputerName         = $env:COMPUTERNAME
        Id                   = $cert.Id
        Status               = $cert.Status
        Thumbprint           = $cert.ThumbPrint
        ExpiryDate           = if ($expiryDate -is [datetime]) { $expiryDate.ToString('o') } else { $expiryDate }
        DaysLeft             = $daysLeft
        ExpiresSoon          = $expiresSoon
        Address              = $cert.Address
        CertificateRequestId = $cert.CertificateRequestId
        PrivateKeyProvider   = $cert.PrivateKeyProvider
        PrivateKeyIsCng      = $cert.PrivateKeyIsCng
        KeyLength            = $cert.KeyLength
        Exportable           = $cert.Exportable
        TrustArea            = $cert.TrustArea
    }
}

try {
    @($output) | ConvertTo-Json -Depth 5 | Set-Content -Path $JsonFile -Encoding UTF8
    Write-Log "JSON written: $JsonFile"
}
catch {
    Write-Log "ERROR: JSON could not be written: $($_.Exception.Message)" 'ERROR'
    exit 3
}

Write-Log '=================================================='
Write-Log 'FAS Authorization Certificate Check END'
Write-Log '=================================================='
exit 0

