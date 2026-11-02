[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Enable', 'Disable', 'Status')][string]$Action,
    [Parameter(Mandatory)][string]$AgentExecutable,
    [Parameter(Mandatory)][string]$AgentConfig,
    [Parameter(Mandatory)][ValidatePattern('^S-1-[0-9-]+$')][string]$OwnerSid
)

$ErrorActionPreference = 'Stop'
$taskPath = '\QuireWire\'
$taskName = 'Agent'
$schema = 'quirewire.m6.startup-task.v1'
$description = "QuireWire owned task; schema=$schema; owner_sid=$OwnerSid"

function Encode-Text([string]$Value) {
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
}

function Write-Record([bool]$Ok, [bool]$Enabled, [string]$Message = '') {
    'QUIREWIRE_WINDOWS_V1'
    "ok=$($Ok.ToString().ToLowerInvariant())"
    "enabled=$($Enabled.ToString().ToLowerInvariant())"
    "owner_sid=$(Encode-Text $OwnerSid)"
    if ($Message) { "error_message=$(Encode-Text $Message)" }
}

function Expected-Arguments {
    if ($AgentConfig.IndexOfAny([char[]]"`r`n`"") -ge 0) {
        throw 'Agent configuration path contains an unsupported quote or newline.'
    }
    "run --config `"$AgentConfig`""
}

function Get-OwnedTask {
    $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) { return $null }
    $expectedArguments = Expected-Arguments
    $actionRecord = @($task.Actions)
    $principalSid = if ($task.Principal.UserId -match '^S-1-') {
        $task.Principal.UserId
    } else {
        ([Security.Principal.NTAccount]::new($task.Principal.UserId)).Translate(
            [Security.Principal.SecurityIdentifier]).Value
    }
    if ($task.Description -ne $description -or $principalSid -ne $OwnerSid -or
        $actionRecord.Count -ne 1 -or $actionRecord[0].Execute -ne $AgentExecutable -or
        $actionRecord[0].Arguments -ne $expectedArguments) {
        throw 'A colliding Task Scheduler entry is not exactly owned by this QuireWire installation.'
    }
    $task
}

try {
    switch ($Action) {
        'Enable' {
            if (-not (Test-Path -LiteralPath $AgentExecutable -PathType Leaf)) {
                throw "Agent executable does not exist: $AgentExecutable"
            }
            if (-not (Test-Path -LiteralPath $AgentConfig -PathType Leaf)) {
                throw "Agent configuration does not exist: $AgentConfig"
            }
            # Validate exact ownership before using -Force to converge settings.
            $existing = Get-OwnedTask
            $taskAction = New-ScheduledTaskAction -Execute $AgentExecutable -Argument (Expected-Arguments)
            $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $OwnerSid
            # This Windows build stores a repetition pattern on a LogonTrigger
            # but does not schedule a NextRunTime. Use the supported Once form
            # as the watchdog; IgnoreNew makes ticks no-ops while healthy.
            $watchdogTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                -RepetitionInterval (New-TimeSpan -Minutes 1) `
                -RepetitionDuration (New-TimeSpan -Days 3650)
            $principal = New-ScheduledTaskPrincipal -UserId $OwnerSid -LogonType Interactive -RunLevel Limited
            $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
                -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
                -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
            Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $taskAction `
                -Trigger @($logonTrigger, $watchdogTrigger) -Principal $principal -Settings $settings `
                -Description $description -Force | Out-Null
            $null = Get-OwnedTask
            Write-Record $true $true
        }
        'Disable' {
            $existing = Get-OwnedTask
            if ($existing) { Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false }
            Write-Record $true $false
        }
        'Status' {
            $existing = Get-OwnedTask
            Write-Record $true ([bool]$existing)
        }
    }
}
catch {
    Write-Record $false $false $_.Exception.Message
    exit 1
}
