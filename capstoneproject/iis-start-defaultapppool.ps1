Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LogDirectory = 'C:\Logs'
$LogPath = Join-Path -Path $LogDirectory -ChildPath 'iis-start-defaultapppool.log'
$AppPoolName = 'DefaultAppPool'

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('INFO', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogPath -Value $entry
    Write-Output $entry
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

try {
    if (-not (Test-Administrator)) {
        throw 'This script must be run as Administrator.'
    }

    if (-not (Test-Path -Path $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path -Path $LogPath)) {
        New-Item -Path $LogPath -ItemType File -Force | Out-Null
    }

    Import-Module -Name WebAdministration -ErrorAction Stop
    Write-Log -Message 'WebAdministration module loaded.'

    $currentState = (Get-WebAppPoolState -Name $AppPoolName -ErrorAction Stop).Value
    Write-Log -Message "Current state for '$AppPoolName' is '$currentState'."

    Start-WebAppPool -Name $AppPoolName -ErrorAction Stop
    Write-Log -Message "Start-WebAppPool executed for '$AppPoolName'."

    $newState = (Get-WebAppPoolState -Name $AppPoolName -ErrorAction Stop).Value
    Write-Log -Message "New state for '$AppPoolName' is '$newState'."
}
catch {
    Write-Log -Level 'ERROR' -Message "Script failed: $($_.Exception.Message)"
    throw
}
