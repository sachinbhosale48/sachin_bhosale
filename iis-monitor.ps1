param(
    [switch]$DryRun,
    [int]$PollIntervalSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LogDirectory = 'C:\Logs'
$LogPath = Join-Path $LogDirectory 'iis-monitor.log'
$script:ContinueMonitoring = $true
$script:RollbackInvoked = $false
$script:InitialPoolStates = @{}
$script:ExitEventSubscriber = $null

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogPath -Value $line
    Write-Output $line
}

function Test-Administrator {
    try {
        $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        throw "Failed to determine elevation state. $($_.Exception.Message)"
    }
}

function Get-IisErrorEvent {
    param(
        [datetime]$Since = (Get-Date).AddMinutes(-10)
    )

    $allEvents = @()
    foreach ($logName in @('Application', 'System')) {
        try {
            $events = Get-WinEvent -FilterHashtable @{
                LogName = $logName
                Level = 2
                StartTime = $Since
            } -ErrorAction Stop |
            Where-Object {
                $_.ProviderName -match 'IIS|WAS|W3SVC|WWW' -or $_.Message -match 'application pool|IIS|WAS|W3SVC'
            }

            $allEvents += $events
        }
        catch {
            Write-Log -Level 'ERROR' -Message "Failed to read $logName event log: $($_.Exception.Message)"
        }
    }

    return $allEvents | Sort-Object TimeCreated
}

function Initialize-AppPoolBaseline {
    try {
        $appPools = Get-ChildItem IIS:\AppPools
    }
    catch {
        throw "Failed to enumerate IIS app pools: $($_.Exception.Message)"
    }

    foreach ($pool in $appPools) {
        try {
            $state = (Get-WebAppPoolState -Name $pool.Name).Value
            $script:InitialPoolStates[$pool.Name] = $state
            Write-Log -Message "Baseline captured: pool '$($pool.Name)' state '$state'."
        }
        catch {
            Write-Log -Level 'ERROR' -Message "Failed to capture baseline for pool '$($pool.Name)': $($_.Exception.Message)"
        }
    }
}

function Restore-AppPoolState {
    if ($script:RollbackInvoked) {
        return
    }

    $script:RollbackInvoked = $true
    Write-Log -Level 'WARN' -Message 'Rollback started: restoring IIS application pool baseline states.'

    foreach ($entry in $script:InitialPoolStates.GetEnumerator()) {
        $poolName = $entry.Key
        $targetState = [string]$entry.Value

        try {
            $currentState = (Get-WebAppPoolState -Name $poolName).Value
        }
        catch {
            Write-Log -Level 'ERROR' -Message "Rollback could not read state for pool '$poolName': $($_.Exception.Message)"
            continue
        }

        if ($currentState -eq $targetState) {
            Write-Log -Message "Rollback skipped for pool '$poolName': already '$currentState'."
            continue
        }

        try {
            if ($DryRun) {
                Write-Log -Level 'WARN' -Message "[DryRun] Rollback would set pool '$poolName' from '$currentState' to '$targetState'."
                continue
            }

            if ($targetState -eq 'Started') {
                Start-WebAppPool -Name $poolName -ErrorAction Stop
                Write-Log -Message "Rollback started pool '$poolName'."
            }
            else {
                Stop-WebAppPool -Name $poolName -ErrorAction Stop
                Write-Log -Message "Rollback stopped pool '$poolName'."
            }
        }
        catch {
            Write-Log -Level 'ERROR' -Message "Rollback failed for pool '$poolName': $($_.Exception.Message)"
        }
    }

    Write-Log -Level 'WARN' -Message 'Rollback complete.'
}

function Stop-MonitoringLoop {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [string]$Reason
    )

    if (-not $script:ContinueMonitoring) {
        return
    }

    if ($PSCmdlet.ShouldProcess('IIS app pool monitoring loop', "Stop monitoring loop. Reason: $Reason")) {
        $script:ContinueMonitoring = $false
        Write-Log -Level 'WARN' -Message "Monitoring stop requested: $Reason"
        Restore-AppPoolState
    }
}

function Invoke-AppPoolMonitor {
    while ($script:ContinueMonitoring) {
        try {
            $appPools = Get-ChildItem IIS:\AppPools
        }
        catch {
            Write-Log -Level 'ERROR' -Message "Failed to enumerate IIS app pools: $($_.Exception.Message)"
            break
        }

        foreach ($pool in $appPools) {
            $poolName = $pool.Name

            try {
                $state = (Get-WebAppPoolState -Name $poolName).Value
            }
            catch {
                Write-Log -Level 'ERROR' -Message "Failed to read state for pool '$poolName': $($_.Exception.Message)"
                continue
            }

            if ($state -ne 'Stopped') {
                Write-Log -Message "Pool '$poolName' is '$state'."
                continue
            }

            Write-Log -Level 'WARN' -Message "Pool '$poolName' is Stopped. Collecting last 10 minutes of IIS-related error events."
            $events = Get-IisErrorEvent -Since (Get-Date).AddMinutes(-10)

            if (-not $events -or $events.Count -eq 0) {
                Write-Log -Message "No IIS-related error events found in the last 10 minutes for pool '$poolName'."
            }
            else {
                foreach ($evt in $events) {
                    $messageOneLine = ($evt.Message -replace "`r`n", ' ')
                    Write-Log -Level 'ERROR' -Message "Event $($evt.Id) [$($evt.ProviderName)] at $($evt.TimeCreated): $messageOneLine"
                }
            }

            try {
                # Idempotency guard: verify current state before restart action.
                $latestState = (Get-WebAppPoolState -Name $poolName).Value
                if ($latestState -eq 'Started') {
                    Write-Log -Message "Pool '$poolName' already running; restart skipped."
                    continue
                }

                if ($DryRun) {
                    Write-Log -Level 'WARN' -Message "[DryRun] Would restart stopped pool '$poolName'."
                    continue
                }

                Start-WebAppPool -Name $poolName -ErrorAction Stop
                Write-Log -Message "Restart attempted for pool '$poolName'."
            }
            catch {
                Write-Log -Level 'ERROR' -Message "Failed to restart pool '$poolName': $($_.Exception.Message)"
            }
        }

        try {
            Start-Sleep -Seconds $PollIntervalSeconds
        }
        catch {
            Write-Log -Level 'WARN' -Message "Sleep interrupted: $($_.Exception.Message)"
            break
        }
    }
}

try {
    Import-Module WebAdministration -ErrorAction Stop

    if (-not (Test-Administrator)) {
        throw 'This script must be run as Administrator.'
    }

    if (-not (Test-Path -Path $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path -Path $LogPath)) {
        New-Item -Path $LogPath -ItemType File -Force | Out-Null
    }

    $script:ExitEventSubscriber = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        Stop-MonitoringLoop -Reason 'PowerShell.Exiting event received (including Ctrl+C session exit).' -Confirm:$false
    }

    Write-Log -Message "IIS monitor started. Poll interval: $PollIntervalSeconds second(s). DryRun: $DryRun"
    Initialize-AppPoolBaseline
    Invoke-AppPoolMonitor
}
catch [System.Management.Automation.PipelineStoppedException] {
    Write-Log -Level 'WARN' -Message 'Monitoring interrupted (Ctrl+C or pipeline stop).'
}
catch {
    Write-Log -Level 'ERROR' -Message "Fatal error: $($_.Exception.Message)"
}
finally {
    Stop-MonitoringLoop -Reason 'Script finalization.' -Confirm:$false

    if ($script:ExitEventSubscriber) {
        Unregister-Event -SubscriptionId $script:ExitEventSubscriber.Id -ErrorAction SilentlyContinue
    }

    Write-Log -Message 'IIS monitor exited cleanly.'
}