#Requires -Version 5.1
<#
.SYNOPSIS
    Registers the FAS Certificate Check Scheduled Task on one or more FAS servers.

.DESCRIPTION
    Copies Run-FasCertCheck.ps1 to C:\Scripts\ on each FAS server and registers
    a daily Scheduled Task that runs at 06:00 under the specified service account.

    Run this script once from the monitoring server (or manually per FAS server).

.PARAMETER FasServers
    Array of FAS server FQDNs. Default: servers from config.json.

.PARAMETER ConfigPath
    Path to config.json. Default: config.json in the parent directory of this script.

.PARAMETER TaskUser
    Service account for the scheduled task (e.g. 'EXAMPLE\svc-citrix').
    If not provided, a credential prompt will appear.

.EXAMPLE
    .\Register-FasScheduledTask.ps1
    Reads FAS servers from config.json and registers the task on all FAS servers.

.EXAMPLE
    .\Register-FasScheduledTask.ps1 -FasServers @('CTX-FAS01.ad.example.com') -TaskUser 'EXAMPLE\svc-citrix'

.NOTES
    Author:     Ufuk Kocak
    Website:    https://horizonconsulting.it
    LinkedIn:   https://www.linkedin.com/in/ufukkocak
    Created:    2026-03-19
    Version:    1.0.0

    Requirements:
        - Admin rights on the target servers (to copy to C$\Scripts and register the task)
        - WinRM access to the FAS servers
        - Run-FasCertCheck.ps1 in the same directory as this script
#>

[CmdletBinding()]
param(
    [string[]]$FasServers = @(),
    [string]$ConfigPath   = '',
    [string]$TaskUser     = ''
)

$scriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$agentScript   = Join-Path $scriptDir 'Run-FasCertCheck.ps1'
$remoteScript  = 'C:\Scripts\Run-FasCertCheck.ps1'
$taskName      = 'FAS Authorization Certificate Check'
$taskPath      = '\Citrix\'

if (-not (Test-Path $agentScript)) {
    Write-Error "Run-FasCertCheck.ps1 not found in: $scriptDir"
    exit 1
}

# Read FAS servers from config.json if not specified
if ($FasServers.Count -eq 0) {
    $configFile = if ($ConfigPath) { $ConfigPath } else { Join-Path (Split-Path $scriptDir) 'config.json' }
    if (-not (Test-Path $configFile)) {
        Write-Error "config.json not found: $configFile"
        exit 1
    }
    $cfg        = Get-Content $configFile -Raw | ConvertFrom-Json
    $FasServers = @(if ($cfg.FAS -and $cfg.FAS.Servers) { $cfg.FAS.Servers } else {
        @($cfg.Servers | Where-Object { $_.Role -eq 'Federated Authentication Service' } | Select-Object -ExpandProperty Name)
    })
}

if ($FasServers.Count -eq 0) {
    Write-Error 'No FAS servers found.'
    exit 1
}

# Prompt for credentials
$cred = if ($TaskUser) {
    Get-Credential -UserName $TaskUser -Message "Enter password for: $TaskUser"
} else {
    Get-Credential -Message 'Service account for the Scheduled Task (e.g. EXAMPLE\svc-citrix)'
}

if (-not $cred) {
    Write-Error 'No credential provided.'
    exit 1
}

$plainPassword = $cred.GetNetworkCredential().Password

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host '  FAS Scheduled Task registration' -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan

foreach ($server in $FasServers) {
    Write-Host "`n  Server: $server" -ForegroundColor White

    # Copy script to C:\Scripts on the FAS server
    $destDir    = "\\$server\C$\Scripts"
    $destScript = "\\$server\C$\Scripts\Run-FasCertCheck.ps1"

    try {
        if (-not (Test-Path $destDir)) {
            New-Item -Path $destDir -ItemType Directory -Force | Out-Null
        }
        Copy-Item -Path $agentScript -Destination $destScript -Force -ErrorAction Stop
        Write-Host "  OK  Script copied to: $destScript" -ForegroundColor Green
    }
    catch {
        Write-Host "  XX  Copy failed: $($_.Exception.Message)" -ForegroundColor Red
        continue
    }

    # Register Scheduled Task via Invoke-Command (WinRM)
    try {
        Invoke-Command -ComputerName $server -ErrorAction Stop -ScriptBlock {
            param($TaskName, $TaskPath, $ScriptPath, $User, $Password)

            $action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
                            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
            $trigger  = New-ScheduledTaskTrigger -Daily -At '06:00'
            $settings = New-ScheduledTaskSettingsSet `
                            -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
                            -StartWhenAvailable `
                            -RestartCount 1 `
                            -RestartInterval (New-TimeSpan -Minutes 5)

            if (Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
            }

            Register-ScheduledTask `
                -TaskName    $TaskName `
                -TaskPath    $TaskPath `
                -Action      $action `
                -Trigger     $trigger `
                -Settings    $settings `
                -User        $User `
                -Password    $Password `
                -RunLevel    Highest `
                -Description 'Checks FAS authorization certificates daily and writes output to C:\Windows\Logs\FAS_AuthorizationCert_Check.json' `
                -ErrorAction Stop | Out-Null

        } -ArgumentList $taskName, $taskPath, $remoteScript, $cred.UserName, $plainPassword

        Write-Host "  OK  Scheduled Task registered: $taskPath$taskName" -ForegroundColor Green
    }
    catch {
        Write-Host "  XX  Scheduled Task registration failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host '  Done. Run a manual test with:' -ForegroundColor Cyan
Write-Host "  Invoke-Command -ComputerName <fasserver> -ScriptBlock { Start-ScheduledTask -TaskName '$taskName' -TaskPath '$taskPath' }" -ForegroundColor White
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ''

