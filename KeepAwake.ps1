Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# =============================================================================
# KeepAwake
# =============================================================================

$mutexName     = "KeepAwakeMutex_Antonio_01"
$showEventName = "KeepAwakeShowEvent_Antonio_01"
$ackEventName  = "KeepAwakeAckEvent_Antonio_01"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$settingsPath = Join-Path $scriptDir "KeepAwake.settings.json"
$vbsPath      = Join-Path $scriptDir "KeepAwake.vbs"

$iconOnPath  = Join-Path $scriptDir "KeepAwake_On.ico"
$iconOffPath = Join-Path $scriptDir "KeepAwake_Off.ico"

$launcherShortcut = Join-Path $scriptDir "KeepAwake.lnk"

$startupDir =
    [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::Startup
    )

$startupShortcut =
    Join-Path $startupDir "KeepAwake.lnk"

$instanceFile =
    Join-Path $env:TEMP "KeepAwake.instance.json"

$heartbeatTimeoutSeconds = 10


# =============================================================================
# Windows API
# =============================================================================

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class SleepManager
{
    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
"@

$ES_CONTINUOUS =
    [Convert]::ToUInt32("80000000", 16)

$ACTIVE_FLAGS =
    [Convert]::ToUInt32("80000003", 16)


# =============================================================================
# Instance helpers
# =============================================================================

function Read-InstanceInfo
{
    if (-not (Test-Path -LiteralPath $instanceFile))
    {
        return $null
    }

    try
    {
        return (
            Get-Content `
                -LiteralPath $instanceFile `
                -Raw |
            ConvertFrom-Json
        )
    }
    catch
    {
        return $null
    }
}


function Find-KeepAwakeProcesses
{
    $result = @()

    try
    {
        $processes =
            Get-CimInstance Win32_Process `
                -ErrorAction Stop |
            Where-Object {
                (
                    $_.Name -ieq "powershell.exe" -or
                    $_.Name -ieq "pwsh.exe"
                ) -and
                $_.ProcessId -ne $PID -and
                $null -ne $_.CommandLine
            }

        foreach ($process in $processes)
        {
            if (
                $process.CommandLine.IndexOf(
                    $PSCommandPath,
                    [System.StringComparison]::OrdinalIgnoreCase
                ) -ge 0
            )
            {
                $result +=
                    [int]$process.ProcessId
            }
        }
    }
    catch
    {
    }

    return $result
}


function Stop-StaleKeepAwakeInstance
{
    $info =
        Read-InstanceInfo

    $candidatePids =
        New-Object System.Collections.Generic.List[int]


    if ($null -ne $info)
    {
        try
        {
            $storedPid =
                [int]$info.PID

            if (
                $storedPid -gt 0 -and
                $storedPid -ne $PID
            )
            {
                $candidatePids.Add(
                    $storedPid
                )
            }
        }
        catch
        {
        }
    }


    foreach ($processId in (Find-KeepAwakeProcesses))
    {
        if (-not $candidatePids.Contains($processId))
        {
            $candidatePids.Add(
                $processId
            )
        }
    }


    foreach ($processId in $candidatePids)
    {
        try
        {
            $process =
                Get-Process `
                    -Id $processId `
                    -ErrorAction Stop

            $isKeepAwake =
                $false


            try
            {
                $cim =
                    Get-CimInstance `
                        Win32_Process `
                        -Filter "ProcessId = $processId" `
                        -ErrorAction Stop

                if (
                    $null -ne $cim.CommandLine -and
                    $cim.CommandLine.IndexOf(
                        $PSCommandPath,
                        [System.StringComparison]::OrdinalIgnoreCase
                    ) -ge 0
                )
                {
                    $isKeepAwake =
                        $true
                }
            }
            catch
            {
                # Se il PID arriva dal file dell'istanza
                # possiamo comunque confrontare la StartTime.
                if ($null -ne $info)
                {
                    try
                    {
                        if (
                            [int]$info.PID -eq $processId
                        )
                        {
                            $savedStart =
                                [DateTime]::Parse(
                                    [string]$info.StartTimeUtc
                                ).ToUniversalTime()

                            $realStart =
                                $process.StartTime.ToUniversalTime()

                            if (
                                [math]::Abs(
                                    (
                                        $realStart -
                                        $savedStart
                                    ).TotalSeconds
                                ) -lt 5
                            )
                            {
                                $isKeepAwake =
                                    $true
                            }
                        }
                    }
                    catch
                    {
                    }
                }
            }


            if ($isKeepAwake)
            {
                Stop-Process `
                    -Id $processId `
                    -Force `
                    -ErrorAction Stop
            }
        }
        catch
        {
        }
    }
}


function Try-ActivateExistingInstance
{
    try
    {
        $showEvent =
            [System.Threading.EventWaitHandle]::OpenExisting(
                $showEventName
            )

        $ackEvent =
            [System.Threading.EventWaitHandle]::OpenExisting(
                $ackEventName
            )


        # Elimina eventuale ACK precedente.
        while ($ackEvent.WaitOne(0))
        {
        }


        $showEvent.Set() |
            Out-Null


        $ackReceived =
            $ackEvent.WaitOne(2500)


        $showEvent.Dispose()
        $ackEvent.Dispose()


        return $ackReceived
    }
    catch
    {
        return $false
    }
}


function ExistingInstanceIsStale
{
    $info =
        Read-InstanceInfo


    if ($null -eq $info)
    {
        return $true
    }


    try
    {
        $heartbeat =
            [DateTime]::Parse(
                [string]$info.HeartbeatUtc
            ).ToUniversalTime()

        $age =
            (
                [DateTime]::UtcNow -
                $heartbeat
            ).TotalSeconds


        return (
            $age -gt
            $heartbeatTimeoutSeconds
        )
    }
    catch
    {
        return $true
    }
}


# =============================================================================
# Single instance / activation
# =============================================================================

$createdNew =
    $false

$mutex =
    [System.Threading.Mutex]::new(
        $true,
        $mutexName,
        [ref]$createdNew
    )


if (-not $createdNew)
{
    # -------------------------------------------------------------------------
    # Existing instance responds:
    # just open Settings in that instance.
    # -------------------------------------------------------------------------

    if (Try-ActivateExistingInstance)
    {
        $mutex.Dispose()
        exit
    }


    # -------------------------------------------------------------------------
    # No response.
    # Only kill it when it is actually stale.
    # -------------------------------------------------------------------------

    if (ExistingInstanceIsStale)
    {
        Stop-StaleKeepAwakeInstance

        Start-Sleep `
            -Milliseconds 750


        try
        {
            $mutex.Dispose()
        }
        catch
        {
        }


        $acquired =
            $false


        for ($attempt = 0; $attempt -lt 20; $attempt++)
        {
            $createdNew =
                $false

            $mutex =
                [System.Threading.Mutex]::new(
                    $true,
                    $mutexName,
                    [ref]$createdNew
                )


            if ($createdNew)
            {
                $acquired =
                    $true

                break
            }


            $mutex.Dispose()

            Start-Sleep `
                -Milliseconds 250
        }


        if (-not $acquired)
        {
            exit
        }
    }
    else
    {
        # Instance is alive but temporarily busy.
        # Do not kill a healthy process.
        $mutex.Dispose()
        exit
    }
}


# =============================================================================
# Inter-process events
# =============================================================================

$showEventCreated =
    $false

$showEvent =
    [System.Threading.EventWaitHandle]::new(
        $false,
        [System.Threading.EventResetMode]::AutoReset,
        $showEventName,
        [ref]$showEventCreated
    )


$ackEventCreated =
    $false

$ackEvent =
    [System.Threading.EventWaitHandle]::new(
        $false,
        [System.Threading.EventResetMode]::AutoReset,
        $ackEventName,
        [ref]$ackEventCreated
    )


# =============================================================================
# Runtime state
# =============================================================================

$script:sessionStart =
    Get-Date

$script:settings =
    $null

$script:isEnabled =
    $false

$script:deadline =
    $null

$script:exitRequested =
    $false

$script:iconOn =
    $null

$script:iconOff =
    $null

$script:lastExecutionResult =
    $null

$script:lastExecutionAction =
    "Nessuna"

$script:lastExecutionTime =
    $null

$script:logLines =
    New-Object System.Collections.Generic.List[string]


$script:UI =
@{
    SettingsForm = $null

    EnabledCheck = $null
    AutoCheck    = $null
    MinutesBox   = $null
    StartupCheck = $null
    CurrentLabel = $null

    DebugForm = $null
    DebugText = $null
}


# =============================================================================
# Logging
# =============================================================================

function Add-Log
{
    param(
        [string]$Message,

        [string]$Level = "INFO"
    )


    $line =
        "{0} [{1}] {2}" -f `
            (Get-Date).ToString("HH:mm:ss"),
            $Level,
            $Message


    $script:logLines.Add(
        $line
    )


    while ($script:logLines.Count -gt 500)
    {
        $script:logLines.RemoveAt(0)
    }
}


# =============================================================================
# Instance heartbeat
# =============================================================================

function Update-InstanceHeartbeat
{
    try
    {
        $process =
            Get-Process `
                -Id $PID `
                -ErrorAction Stop


        $info =
            [PSCustomObject]@{
                PID =
                    $PID

                ScriptPath =
                    $PSCommandPath

                StartTimeUtc =
                    $process.StartTime.ToUniversalTime().ToString("o")

                HeartbeatUtc =
                    [DateTime]::UtcNow.ToString("o")
            }


        $info |
            ConvertTo-Json |
            Set-Content `
                -LiteralPath $instanceFile `
                -Encoding UTF8
    }
    catch
    {
    }
}


# =============================================================================
# Icons
# =============================================================================

try
{
    if (Test-Path -LiteralPath $iconOnPath)
    {
        $script:iconOn =
            New-Object System.Drawing.Icon(
                $iconOnPath
            )
    }
}
catch
{
    Add-Log `
        "Errore caricamento KeepAwake_On.ico: $($_.Exception.Message)" `
        "WARN"
}


try
{
    if (Test-Path -LiteralPath $iconOffPath)
    {
        $script:iconOff =
            New-Object System.Drawing.Icon(
                $iconOffPath
            )
    }
}
catch
{
    Add-Log `
        "Errore caricamento KeepAwake_Off.ico: $($_.Exception.Message)" `
        "WARN"
}


# =============================================================================
# Settings
# =============================================================================

function Get-DefaultSettings
{
    return [PSCustomObject]@{
        Enabled            = $true
        AutoDisable        = $false
        AutoDisableMinutes = 60
        StartWithWindows   = $false
    }
}


function Load-Settings
{
    $defaults =
        Get-DefaultSettings


    if (-not (Test-Path -LiteralPath $settingsPath))
    {
        return $defaults
    }


    try
    {
        $loaded =
            Get-Content `
                -LiteralPath $settingsPath `
                -Raw |
            ConvertFrom-Json


        $enabled =
            $defaults.Enabled

        $autoDisable =
            $defaults.AutoDisable

        $autoDisableMinutes =
            $defaults.AutoDisableMinutes

        $startWithWindows =
            $defaults.StartWithWindows


        if ($null -ne $loaded.PSObject.Properties["Enabled"])
        {
            $enabled =
                [bool]$loaded.Enabled
        }


        if ($null -ne $loaded.PSObject.Properties["AutoDisable"])
        {
            $autoDisable =
                [bool]$loaded.AutoDisable
        }


        if (
            $null -ne
            $loaded.PSObject.Properties["AutoDisableMinutes"]
        )
        {
            try
            {
                $minutes =
                    [int]$loaded.AutoDisableMinutes

                if ($minutes -ge 1)
                {
                    $autoDisableMinutes =
                        $minutes
                }
            }
            catch
            {
            }
        }


        if (
            $null -ne
            $loaded.PSObject.Properties["StartWithWindows"]
        )
        {
            $startWithWindows =
                [bool]$loaded.StartWithWindows
        }


        return [PSCustomObject]@{
            Enabled            = $enabled
            AutoDisable        = $autoDisable
            AutoDisableMinutes = $autoDisableMinutes
            StartWithWindows   = $startWithWindows
        }
    }
    catch
    {
        return $defaults
    }
}


function Save-Settings
{
    try
    {
        $script:settings |
            ConvertTo-Json `
                -Depth 3 |
            Set-Content `
                -LiteralPath $settingsPath `
                -Encoding UTF8


        Add-Log `
            "Impostazioni salvate."
    }
    catch
    {
        Add-Log `
            "Errore salvataggio impostazioni: $($_.Exception.Message)" `
            "ERROR"
    }
}


# =============================================================================
# Shortcuts
# =============================================================================

function New-KeepAwakeShortcut
{
    param(
        [string]$Destination
    )


    $shell =
        New-Object -ComObject WScript.Shell


    $shortcut =
        $shell.CreateShortcut(
            $Destination
        )


    $shortcut.TargetPath =
        "$env:SystemRoot\System32\wscript.exe"


    $shortcut.Arguments =
        "`"$vbsPath`""


    $shortcut.WorkingDirectory =
        $scriptDir


    if (Test-Path -LiteralPath $iconOnPath)
    {
        $shortcut.IconLocation =
            "$iconOnPath,0"
    }


    $shortcut.Description =
        "KeepAwake"


    $shortcut.Save()
}


function Sync-LauncherShortcut
{
    try
    {
        New-KeepAwakeShortcut `
            $launcherShortcut


        Add-Log `
            "Launcher locale verificato."
    }
    catch
    {
        Add-Log `
            "Errore launcher locale: $($_.Exception.Message)" `
            "ERROR"
    }
}


function Sync-StartupShortcut
{
    try
    {
        if ([bool]$script:settings.StartWithWindows)
        {
            if (-not (Test-Path -LiteralPath $startupDir))
            {
                throw "Cartella Startup non trovata."
            }


            New-KeepAwakeShortcut `
                $startupShortcut


            Add-Log `
                "Avvio con Windows attivato."
        }
        else
        {
            if (Test-Path -LiteralPath $startupShortcut)
            {
                Remove-Item `
                    -LiteralPath $startupShortcut `
                    -Force
            }


            Add-Log `
                "Avvio con Windows disattivato."
        }
    }
    catch
    {
        Add-Log `
            "Errore Startup Windows: $($_.Exception.Message)" `
            "ERROR"
    }
}


function Get-ShortcutInfo
{
    param(
        [string]$Path
    )


    if (-not (Test-Path -LiteralPath $Path))
    {
        return $null
    }


    try
    {
        $shell =
            New-Object -ComObject WScript.Shell


        $shortcut =
            $shell.CreateShortcut(
                $Path
            )


        return [PSCustomObject]@{
            TargetPath =
                $shortcut.TargetPath

            Arguments =
                $shortcut.Arguments

            WorkingDirectory =
                $shortcut.WorkingDirectory

            IconLocation =
                $shortcut.IconLocation
        }
    }
    catch
    {
        return $null
    }
}


# =============================================================================
# Windows execution state
# =============================================================================

function Invoke-ExecutionState
{
    param(
        [bool]$Enabled
    )


    if ($Enabled)
    {
        $flags =
            $ACTIVE_FLAGS

        $description =
            "ES_CONTINUOUS + ES_SYSTEM_REQUIRED + ES_DISPLAY_REQUIRED"
    }
    else
    {
        $flags =
            $ES_CONTINUOUS

        $description =
            "ES_CONTINUOUS"
    }


    try
    {
        [uint32]$result =
            [SleepManager]::SetThreadExecutionState(
                $flags
            )


        $script:lastExecutionResult =
            $result

        $script:lastExecutionAction =
            $description

        $script:lastExecutionTime =
            Get-Date


        if ($result -eq 0)
        {
            Add-Log `
                "SetThreadExecutionState FALLITA: $description" `
                "ERROR"

            return $false
        }


        Add-Log `
            "SetThreadExecutionState OK: $description"


        return $true
    }
    catch
    {
        Add-Log `
            "Errore SetThreadExecutionState: $($_.Exception.Message)" `
            "ERROR"

        return $false
    }
}


# =============================================================================
# Timer
# =============================================================================

function Start-ConfiguredTimer
{
    if (
        $script:isEnabled -and
        [bool]$script:settings.AutoDisable
    )
    {
        $minutes =
            [int]$script:settings.AutoDisableMinutes


        if ($minutes -lt 1)
        {
            $minutes =
                1
        }


        $script:deadline =
            (Get-Date).AddMinutes(
                $minutes
            )


        Add-Log `
            "Timer automatico avviato: $minutes minuto/i. Scadenza $($script:deadline.ToString('HH:mm:ss'))."
    }
    else
    {
        $script:deadline =
            $null


        if ($script:isEnabled)
        {
            Add-Log `
                "KeepAwake attivo senza limite."
        }
    }
}


function Format-Duration
{
    param(
        [TimeSpan]$Span
    )


    if ($Span.TotalSeconds -lt 0)
    {
        $Span =
            [TimeSpan]::Zero
    }


    if ($Span.TotalHours -ge 1)
    {
        return "{0}h {1:00}m" -f `
            [math]::Floor($Span.TotalHours),
            $Span.Minutes
    }


    if ($Span.TotalMinutes -ge 1)
    {
        return "{0}m {1:00}s" -f `
            [math]::Floor($Span.TotalMinutes),
            $Span.Seconds
    }


    return "{0}s" -f `
        [math]::Max(
            0,
            $Span.Seconds
        )
}


# =============================================================================
# Tray menu
# =============================================================================

$menu =
    New-Object System.Windows.Forms.ContextMenuStrip


$statusItem =
    New-Object System.Windows.Forms.ToolStripMenuItem

$statusItem.Enabled =
    $false

[void]$menu.Items.Add(
    $statusItem
)


[void]$menu.Items.Add(
    (New-Object System.Windows.Forms.ToolStripSeparator)
)


$toggleItem =
    New-Object System.Windows.Forms.ToolStripMenuItem

[void]$menu.Items.Add(
    $toggleItem
)


[void]$menu.Items.Add(
    (New-Object System.Windows.Forms.ToolStripSeparator)
)


$settingsItem =
    New-Object System.Windows.Forms.ToolStripMenuItem

$settingsItem.Text =
    "Impostazioni..."

[void]$menu.Items.Add(
    $settingsItem
)


$folderItem =
    New-Object System.Windows.Forms.ToolStripMenuItem

$folderItem.Text =
    "Apri cartella"

[void]$menu.Items.Add(
    $folderItem
)


[void]$menu.Items.Add(
    (New-Object System.Windows.Forms.ToolStripSeparator)
)


$exitItem =
    New-Object System.Windows.Forms.ToolStripMenuItem

$exitItem.Text =
    "Esci"

[void]$menu.Items.Add(
    $exitItem
)


$notifyIcon =
    New-Object System.Windows.Forms.NotifyIcon

$notifyIcon.ContextMenuStrip =
    $menu

$notifyIcon.Visible =
    $true


# =============================================================================
# UI synchronization
# =============================================================================

function Update-Tray
{
    if ($script:isEnabled)
    {
        if ($null -ne $script:iconOn)
        {
            $notifyIcon.Icon =
                $script:iconOn
        }
        else
        {
            $notifyIcon.Icon =
                [System.Drawing.SystemIcons]::Information
        }


        $toggleItem.Text =
            "Disattiva KeepAwake"

        $toggleItem.Checked =
            $true


        if ($null -ne $script:deadline)
        {
            $remaining =
                $script:deadline -
                (Get-Date)


            if ($remaining.TotalSeconds -lt 0)
            {
                $remaining =
                    [TimeSpan]::Zero
            }


            $end =
                $script:deadline.ToString(
                    "HH:mm"
                )


            $remainingText =
                Format-Duration `
                    $remaining


            $statusItem.Text =
                "Attivo - fine $end - $remainingText"


            $tip =
                "KeepAwake - Attivo - fine $end ($remainingText)"


            if ($tip.Length -gt 63)
            {
                $tip =
                    $tip.Substring(
                        0,
                        63
                    )
            }


            $notifyIcon.Text =
                $tip
        }
        else
        {
            $statusItem.Text =
                "Attivo - senza limite"

            $notifyIcon.Text =
                "KeepAwake - Attivo - senza limite"
        }
    }
    else
    {
        if ($null -ne $script:iconOff)
        {
            $notifyIcon.Icon =
                $script:iconOff
        }
        else
        {
            $notifyIcon.Icon =
                [System.Drawing.SystemIcons]::Application
        }


        $toggleItem.Text =
            "Attiva KeepAwake"

        $toggleItem.Checked =
            $false

        $statusItem.Text =
            "Disattivato"

        $notifyIcon.Text =
            "KeepAwake - Disattivato"
    }
}


function Sync-SettingsState
{
    $form =
        $script:UI.SettingsForm


    if (
        $null -eq $form -or
        $form.IsDisposed
    )
    {
        return
    }


    if ($null -ne $script:UI.EnabledCheck)
    {
        $script:UI.EnabledCheck.Checked =
            $script:isEnabled
    }


    if ($script:isEnabled)
    {
        if ($null -ne $script:iconOn)
        {
            $form.Icon =
                $script:iconOn
        }
    }
    else
    {
        if ($null -ne $script:iconOff)
        {
            $form.Icon =
                $script:iconOff
        }
    }
}


function Update-CurrentStatus
{
    $label =
        $script:UI.CurrentLabel


    if (
        $null -eq $label -or
        $label.IsDisposed
    )
    {
        return
    }


    if (
        $script:isEnabled -and
        $null -ne $script:deadline
    )
    {
        $remaining =
            $script:deadline -
            (Get-Date)


        if ($remaining.TotalSeconds -lt 0)
        {
            $remaining =
                [TimeSpan]::Zero
        }


        $label.Text =
            "KeepAwake attivo - fine " +
            $script:deadline.ToString("HH:mm:ss") +
            " - " +
            (Format-Duration $remaining)
    }
    elseif ($script:isEnabled)
    {
        $label.Text =
            "KeepAwake attivo - senza limite"
    }
    else
    {
        $label.Text =
            "KeepAwake disattivato"
    }
}


# =============================================================================
# State changes
# =============================================================================

function Set-KeepAwakeState
{
    param(
        [bool]$Enabled,
        [bool]$SaveState = $true,
        [bool]$UseConfiguredTimer = $true
    )


    $script:isEnabled =
        $Enabled


    if ($Enabled)
    {
        Invoke-ExecutionState `
            $true |
        Out-Null


        if ($UseConfiguredTimer)
        {
            Start-ConfiguredTimer
        }
    }
    else
    {
        Invoke-ExecutionState `
            $false |
        Out-Null


        $script:deadline =
            $null


        Add-Log `
            "KeepAwake disattivato."
    }


    if ($SaveState)
    {
        $script:settings.Enabled =
            $Enabled

        Save-Settings
    }


    Update-Tray
    Sync-SettingsState
    Update-CurrentStatus
}


# =============================================================================
# Open folder
# =============================================================================

function Open-ScriptFolder
{
    try
    {
        Start-Process `
            explorer.exe `
            -ArgumentList "`"$scriptDir`""
    }
    catch
    {
        Add-Log `
            "Errore apertura cartella: $($_.Exception.Message)" `
            "ERROR"
    }
}


# =============================================================================
# Debug
# =============================================================================

function Get-DiagnosticsText
{
    $lines =
        New-Object System.Collections.Generic.List[string]


    $lines.Add(
        "============================================================"
    )

    $lines.Add(
        " KeepAwake - Diagnostica"
    )

    $lines.Add(
        "============================================================"
    )

    $lines.Add("")


    $lines.Add(
        "Ora:                    " +
        (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    )

    $lines.Add(
        "PID:                    $PID"
    )

    $lines.Add(
        "KeepAwake attivo:       $script:isEnabled"
    )

    $lines.Add(
        "AutoDisable:            $($script:settings.AutoDisable)"
    )

    $lines.Add(
        "AutoDisableMinutes:     $($script:settings.AutoDisableMinutes)"
    )

    $lines.Add(
        "StartWithWindows:       $($script:settings.StartWithWindows)"
    )


    if ($null -ne $script:deadline)
    {
        $lines.Add(
            "Deadline:               " +
            $script:deadline.ToString(
                "yyyy-MM-dd HH:mm:ss"
            )
        )

        $lines.Add(
            "Tempo residuo:          " +
            (
                Format-Duration (
                    $script:deadline -
                    (Get-Date)
                )
            )
        )
    }
    else
    {
        $lines.Add(
            "Deadline:               NESSUNA"
        )
    }


    $lines.Add("")

    $lines.Add(
        "--- WINDOWS API ---"
    )

    $lines.Add(
        "Ultima richiesta:        $script:lastExecutionAction"
    )


    if ($null -ne $script:lastExecutionResult)
    {
        $lines.Add(
            "Return API:             0x" +
            $script:lastExecutionResult.ToString("X8")
        )
    }
    else
    {
        $lines.Add(
            "Return API:             N/D"
        )
    }


    $lines.Add("")

    $lines.Add(
        "--- AVVIO CON WINDOWS ---"
    )

    $lines.Add(
        "Startup folder:          $startupDir"
    )

    $lines.Add(
        "Shortcut presente:       " +
        (Test-Path -LiteralPath $startupShortcut)
    )


    $startupInfo =
        Get-ShortcutInfo `
            $startupShortcut


    if ($null -ne $startupInfo)
    {
        $lines.Add(
            "Target:                 $($startupInfo.TargetPath)"
        )

        $lines.Add(
            "Arguments:              $($startupInfo.Arguments)"
        )

        $lines.Add(
            "Working directory:      $($startupInfo.WorkingDirectory)"
        )

        $lines.Add(
            "Icon:                   $($startupInfo.IconLocation)"
        )
    }


    $lines.Add("")

    $lines.Add(
        "--- ISTANZA ---"
    )

    $lines.Add(
        "Instance file:           $instanceFile"
    )

    $lines.Add(
        "Heartbeat timeout:       $heartbeatTimeoutSeconds s"
    )


    $lines.Add("")

    $lines.Add(
        "--- LOG ---"
    )


    foreach ($line in $script:logLines)
    {
        $lines.Add(
            $line
        )
    }


    return (
        $lines -join
        [Environment]::NewLine
    )
}


function Update-DebugWindow
{
    $text =
        $script:UI.DebugText


    if (
        $null -eq $text -or
        $text.IsDisposed
    )
    {
        return
    }


    try
    {
        $text.Text =
            Get-DiagnosticsText


        $text.SelectionStart =
            $text.Text.Length


        $text.ScrollToCaret()
    }
    catch
    {
    }
}


function Run-SelfTest
{
    Add-Log `
        "========== SELF TEST =========="


    if (
        $script:isEnabled -and
        $script:settings.AutoDisable
    )
    {
        if ($null -eq $script:deadline)
        {
            Add-Log `
                "TEST timer: FAIL - AutoDisable attivo ma deadline NULL." `
                "ERROR"
        }
        elseif ($script:deadline -gt (Get-Date))
        {
            Add-Log `
                "TEST timer: PASS - scadenza $($script:deadline.ToString('HH:mm:ss'))."
        }
        else
        {
            Add-Log `
                "TEST timer: WARN - deadline scaduta." `
                "WARN"
        }
    }
    elseif ($null -ne $script:deadline)
    {
        Add-Log `
            "TEST timer: FAIL - deadline presente senza AutoDisable." `
            "ERROR"
    }
    else
    {
        Add-Log `
            "TEST timer: PASS."
    }


    if (Invoke-ExecutionState $script:isEnabled)
    {
        Add-Log `
            "TEST API Windows: PASS."
    }
    else
    {
        Add-Log `
            "TEST API Windows: FAIL." `
            "ERROR"
    }


    if ($script:settings.StartWithWindows)
    {
        $info =
            Get-ShortcutInfo `
                $startupShortcut


        if ($null -eq $info)
        {
            Add-Log `
                "TEST Startup: FAIL - shortcut assente o illeggibile." `
                "ERROR"
        }
        else
        {
            $expectedTarget =
                "$env:SystemRoot\System32\wscript.exe"

            $expectedArguments =
                "`"$vbsPath`""


            $targetOK =
                $info.TargetPath -ieq
                $expectedTarget

            $argumentsOK =
                $info.Arguments -eq
                $expectedArguments

            $workingOK =
                $info.WorkingDirectory -ieq
                $scriptDir


            if (
                $targetOK -and
                $argumentsOK -and
                $workingOK
            )
            {
                Add-Log `
                    "TEST Startup: PASS."
            }
            else
            {
                Add-Log `
                    "TEST Startup: FAIL - Target=$targetOK Arguments=$argumentsOK WorkingDir=$workingOK." `
                    "ERROR"
            }
        }
    }
    else
    {
        if (Test-Path -LiteralPath $startupShortcut)
        {
            Add-Log `
                "TEST Startup: WARN - disabilitato ma shortcut presente." `
                "WARN"
        }
        else
        {
            Add-Log `
                "TEST Startup: PASS - disabilitato."
        }
    }


    Add-Log `
        "========== FINE SELF TEST =========="


    Update-DebugWindow
}


function Show-DebugWindow
{
    if (
        $null -ne $script:UI.DebugForm -and
        -not $script:UI.DebugForm.IsDisposed
    )
    {
        Update-DebugWindow

        $script:UI.DebugForm.Show()

        $script:UI.DebugForm.WindowState =
            [System.Windows.Forms.FormWindowState]::Normal

        $script:UI.DebugForm.Activate()

        return
    }


    $form =
        New-Object System.Windows.Forms.Form


    $script:UI.DebugForm =
        $form


    $form.Text =
        "KeepAwake - Debug"

    $form.StartPosition =
        "CenterScreen"

    $form.Size =
        New-Object System.Drawing.Size(
            800,
            600
        )

    $form.MinimumSize =
        New-Object System.Drawing.Size(
            650,
            450
        )


    if ($null -ne $script:iconOn)
    {
        $form.Icon =
            $script:iconOn
    }


    $text =
        New-Object System.Windows.Forms.TextBox


    $script:UI.DebugText =
        $text


    $text.Multiline =
        $true

    $text.ReadOnly =
        $true

    $text.ScrollBars =
        "Both"

    $text.WordWrap =
        $false

    $text.Font =
        New-Object System.Drawing.Font(
            "Consolas",
            9
        )

    $text.Location =
        New-Object System.Drawing.Point(
            12,
            12
        )

    $text.Size =
        New-Object System.Drawing.Size(
            758,
            490
        )

    $text.Anchor =
        "Top,Bottom,Left,Right"


    $form.Controls.Add(
        $text
    )


    $refreshButton =
        New-Object System.Windows.Forms.Button

    $refreshButton.Text =
        "Aggiorna"

    $refreshButton.Location =
        New-Object System.Drawing.Point(
            12,
            515
        )

    $refreshButton.Size =
        New-Object System.Drawing.Size(
            100,
            32
        )

    $refreshButton.Anchor =
        "Bottom,Left"

    $refreshButton.Add_Click(
    {
        Update-DebugWindow
    })

    $form.Controls.Add(
        $refreshButton
    )


    $testButton =
        New-Object System.Windows.Forms.Button

    $testButton.Text =
        "Self Test"

    $testButton.Location =
        New-Object System.Drawing.Point(
            122,
            515
        )

    $testButton.Size =
        New-Object System.Drawing.Size(
            100,
            32
        )

    $testButton.Anchor =
        "Bottom,Left"

    $testButton.Add_Click(
    {
        Run-SelfTest
    })

    $form.Controls.Add(
        $testButton
    )


    $copyButton =
        New-Object System.Windows.Forms.Button

    $copyButton.Text =
        "Copia log"

    $copyButton.Location =
        New-Object System.Drawing.Point(
            232,
            515
        )

    $copyButton.Size =
        New-Object System.Drawing.Size(
            100,
            32
        )

    $copyButton.Anchor =
        "Bottom,Left"


    $copyButton.Add_Click(
    {
        try
        {
            $diagnostics =
                Get-DiagnosticsText

            [System.Windows.Forms.Clipboard]::SetText(
                [string]$diagnostics
            )
        }
        catch
        {
        }
    })


    $form.Controls.Add(
        $copyButton
    )


    $closeButton =
        New-Object System.Windows.Forms.Button

    $closeButton.Text =
        "Chiudi"

    $closeButton.Location =
        New-Object System.Drawing.Point(
            670,
            515
        )

    $closeButton.Size =
        New-Object System.Drawing.Size(
            100,
            32
        )

    $closeButton.Anchor =
        "Bottom,Right"

    $closeButton.Add_Click(
    {
        $script:UI.DebugForm.Hide()
    })

    $form.Controls.Add(
        $closeButton
    )


    $form.Add_FormClosing(
    {
        param(
            $sender,
            $eventArgs
        )


        if (-not $script:exitRequested)
        {
            $eventArgs.Cancel =
                $true

            $sender.Hide()
        }
    })


    Update-DebugWindow

    $form.Show()
    $form.Activate()
}


# =============================================================================
# Settings
# =============================================================================

function Show-Settings
{
    if (
        $null -ne $script:UI.SettingsForm -and
        -not $script:UI.SettingsForm.IsDisposed
    )
    {
        $script:UI.SettingsForm.Show()

        $script:UI.SettingsForm.WindowState =
            [System.Windows.Forms.FormWindowState]::Normal

        Sync-SettingsState
        Update-CurrentStatus

        $script:UI.SettingsForm.Activate()

        return
    }


    $form =
        New-Object System.Windows.Forms.Form


    $script:UI.SettingsForm =
        $form


    $form.Text =
        "KeepAwake - Impostazioni"

    $form.StartPosition =
        "CenterScreen"

    $form.FormBorderStyle =
        "FixedDialog"

    $form.MaximizeBox =
        $false

    $form.MinimizeBox =
        $true

    $form.ShowInTaskbar =
        $true

    $form.ClientSize =
        New-Object System.Drawing.Size(
            500,
            290
        )


    if ($script:isEnabled)
    {
        if ($null -ne $script:iconOn)
        {
            $form.Icon =
                $script:iconOn
        }
    }
    else
    {
        if ($null -ne $script:iconOff)
        {
            $form.Icon =
                $script:iconOff
        }
    }


    $form.Add_FormClosing(
    {
        param(
            $sender,
            $eventArgs
        )


        if (-not $script:exitRequested)
        {
            $eventArgs.Cancel =
                $true

            $sender.Hide()
        }
    })


    # -------------------------------------------------------------------------
    # Enabled
    # -------------------------------------------------------------------------

    $enabledCheck =
        New-Object System.Windows.Forms.CheckBox


    $script:UI.EnabledCheck =
        $enabledCheck


    $enabledCheck.Text =
        "KeepAwake attivo"

    $enabledCheck.AutoSize =
        $true

    $enabledCheck.Location =
        New-Object System.Drawing.Point(
            20,
            20
        )

    $enabledCheck.Checked =
        $script:isEnabled


    $form.Controls.Add(
        $enabledCheck
    )


    # -------------------------------------------------------------------------
    # Auto disable
    # -------------------------------------------------------------------------

    $autoCheck =
        New-Object System.Windows.Forms.CheckBox


    $script:UI.AutoCheck =
        $autoCheck


    $autoCheck.Text =
        "Disattiva automaticamente KeepAwake"

    $autoCheck.AutoSize =
        $true

    $autoCheck.Location =
        New-Object System.Drawing.Point(
            20,
            58
        )

    $autoCheck.Checked =
        [bool]$script:settings.AutoDisable


    $form.Controls.Add(
        $autoCheck
    )


    $minutesLabel =
        New-Object System.Windows.Forms.Label

    $minutesLabel.Text =
        "Dopo:"

    $minutesLabel.AutoSize =
        $true

    $minutesLabel.Location =
        New-Object System.Drawing.Point(
            42,
            99
        )

    $form.Controls.Add(
        $minutesLabel
    )


    $minutesBox =
        New-Object System.Windows.Forms.NumericUpDown


    $script:UI.MinutesBox =
        $minutesBox


    $minutesBox.Minimum =
        1

    $minutesBox.Maximum =
        10080

    $minutesBox.Value =
        [decimal][math]::Max(
            1,
            [int]$script:settings.AutoDisableMinutes
        )

    $minutesBox.Location =
        New-Object System.Drawing.Point(
            94,
            95
        )

    $minutesBox.Size =
        New-Object System.Drawing.Size(
            85,
            23
        )

    $minutesBox.Enabled =
        $autoCheck.Checked


    $form.Controls.Add(
        $minutesBox
    )


    $unitLabel =
        New-Object System.Windows.Forms.Label

    $unitLabel.Text =
        "minuti"

    $unitLabel.AutoSize =
        $true

    $unitLabel.Location =
        New-Object System.Drawing.Point(
            190,
            99
        )

    $form.Controls.Add(
        $unitLabel
    )


    $autoCheck.Add_CheckedChanged(
    {
        $script:UI.MinutesBox.Enabled =
            $script:UI.AutoCheck.Checked
    })


    # -------------------------------------------------------------------------
    # Startup
    # -------------------------------------------------------------------------

    $startupCheck =
        New-Object System.Windows.Forms.CheckBox


    $script:UI.StartupCheck =
        $startupCheck


    $startupCheck.Text =
        "Avvia con Windows"

    $startupCheck.AutoSize =
        $true

    $startupCheck.Location =
        New-Object System.Drawing.Point(
            20,
            140
        )

    $startupCheck.Checked =
        [bool]$script:settings.StartWithWindows


    $form.Controls.Add(
        $startupCheck
    )


    # -------------------------------------------------------------------------
    # Status
    # -------------------------------------------------------------------------

    $currentLabel =
        New-Object System.Windows.Forms.Label


    $script:UI.CurrentLabel =
        $currentLabel


    $currentLabel.AutoSize =
        $true

    $currentLabel.Location =
        New-Object System.Drawing.Point(
            20,
            180
        )


    $form.Controls.Add(
        $currentLabel
    )


    # -------------------------------------------------------------------------
    # Buttons
    # -------------------------------------------------------------------------

    $folderButton =
        New-Object System.Windows.Forms.Button

    $folderButton.Text =
        "Apri cartella"

    $folderButton.Size =
        New-Object System.Drawing.Size(
            105,
            34
        )

    $folderButton.Location =
        New-Object System.Drawing.Point(
            20,
            225
        )

    $folderButton.Add_Click(
    {
        Open-ScriptFolder
    })


    $form.Controls.Add(
        $folderButton
    )


    $debugButton =
        New-Object System.Windows.Forms.Button

    $debugButton.Text =
        "Debug"

    $debugButton.Size =
        New-Object System.Drawing.Size(
            90,
            34
        )

    $debugButton.Location =
        New-Object System.Drawing.Point(
            135,
            225
        )

    $debugButton.Add_Click(
    {
        Show-DebugWindow
    })


    $form.Controls.Add(
        $debugButton
    )


    $applyButton =
        New-Object System.Windows.Forms.Button

    $applyButton.Text =
        "Applica"

    $applyButton.Size =
        New-Object System.Drawing.Size(
            105,
            34
        )

    $applyButton.Location =
        New-Object System.Drawing.Point(
            270,
            225
        )


    $form.Controls.Add(
        $applyButton
    )


    $exitButton =
        New-Object System.Windows.Forms.Button

    $exitButton.Text =
        "Esci"

    $exitButton.Size =
        New-Object System.Drawing.Size(
            105,
            34
        )

    $exitButton.Location =
        New-Object System.Drawing.Point(
            385,
            225
        )


    $form.Controls.Add(
        $exitButton
    )


    # -------------------------------------------------------------------------
    # Apply
    # -------------------------------------------------------------------------

    $applyButton.Add_Click(
    {
        $script:settings =
            [PSCustomObject]@{
                Enabled =
                    [bool]$script:UI.EnabledCheck.Checked

                AutoDisable =
                    [bool]$script:UI.AutoCheck.Checked

                AutoDisableMinutes =
                    [int]$script:UI.MinutesBox.Value

                StartWithWindows =
                    [bool]$script:UI.StartupCheck.Checked
            }


        Add-Log `
            "Applica: Enabled=$($script:settings.Enabled), AutoDisable=$($script:settings.AutoDisable), Minutes=$($script:settings.AutoDisableMinutes), Startup=$($script:settings.StartWithWindows)."


        Save-Settings

        Sync-LauncherShortcut
        Sync-StartupShortcut


        Set-KeepAwakeState `
            ([bool]$script:settings.Enabled) `
            $false `
            $true


        Update-DebugWindow
    })


    # -------------------------------------------------------------------------
    # Exit
    # -------------------------------------------------------------------------

    $exitButton.Add_Click(
    {
        Add-Log `
            "Uscita richiesta."


        $script:exitRequested =
            $true


        [System.Windows.Forms.Application]::Exit()
    })


    Sync-SettingsState
    Update-CurrentStatus


    $form.Show()
    $form.Activate()
}


# =============================================================================
# Tray events
# =============================================================================

$toggleItem.Add_Click(
{
    Add-Log `
        "Cambio stato dalla tray."


    Set-KeepAwakeState `
        (-not $script:isEnabled) `
        $true `
        $true
})


$settingsItem.Add_Click(
{
    Show-Settings
})


$folderItem.Add_Click(
{
    Open-ScriptFolder
})


$exitItem.Add_Click(
{
    Add-Log `
        "Uscita dalla tray."


    $script:exitRequested =
        $true


    [System.Windows.Forms.Application]::Exit()
})


$notifyIcon.Add_DoubleClick(
{
    Show-Settings
})


# =============================================================================
# Initialize
# =============================================================================

$script:settings =
    Load-Settings


$script:isEnabled =
    [bool]$script:settings.Enabled


Add-Log `
    "KeepAwake avviato. PID=$PID."


Add-Log `
    "Enabled=$($script:settings.Enabled), AutoDisable=$($script:settings.AutoDisable), Minutes=$($script:settings.AutoDisableMinutes), Startup=$($script:settings.StartWithWindows)."


Sync-LauncherShortcut
Sync-StartupShortcut


Set-KeepAwakeState `
    $script:isEnabled `
    $false `
    $true


Update-InstanceHeartbeat


# =============================================================================
# Main timer
# =============================================================================

$timer =
    New-Object System.Windows.Forms.Timer


$timer.Interval =
    1000


$timer.Add_Tick(
{
    # -------------------------------------------------------------------------
    # Heartbeat
    # -------------------------------------------------------------------------

    Update-InstanceHeartbeat


    # -------------------------------------------------------------------------
    # Another launch requested Settings
    # -------------------------------------------------------------------------

    if ($showEvent.WaitOne(0))
    {
        Add-Log `
            "Richiesta apertura Impostazioni ricevuta da una seconda istanza."


        Show-Settings


        $ackEvent.Set() |
            Out-Null
    }


    # -------------------------------------------------------------------------
    # Automatic timer
    # -------------------------------------------------------------------------

    if (
        $script:isEnabled -and
        $null -ne $script:deadline -and
        (Get-Date) -ge $script:deadline
    )
    {
        Add-Log `
            "Timer automatico scaduto."


        Set-KeepAwakeState `
            $false `
            $true `
            $false
    }


    Update-Tray
    Update-CurrentStatus
    Update-DebugWindow
})


$timer.Start()


# =============================================================================
# Message loop
# =============================================================================

try
{
    [System.Windows.Forms.Application]::Run()
}
finally
{
    try
    {
        $timer.Stop()
        $timer.Dispose()
    }
    catch
    {
    }


    try
    {
        Invoke-ExecutionState `
            $false |
        Out-Null
    }
    catch
    {
    }


    try
    {
        $notifyIcon.Visible =
            $false

        $notifyIcon.Dispose()
    }
    catch
    {
    }


    try
    {
        $menu.Dispose()
    }
    catch
    {
    }


    try
    {
        $showEvent.Dispose()
        $ackEvent.Dispose()
    }
    catch
    {
    }


    try
    {
        $info =
            Read-InstanceInfo


        if (
            $null -ne $info -and
            [int]$info.PID -eq $PID
        )
        {
            Remove-Item `
                -LiteralPath $instanceFile `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
    catch
    {
    }


    try
    {
        if ($null -ne $script:iconOn)
        {
            $script:iconOn.Dispose()
        }
    }
    catch
    {
    }


    try
    {
        if ($null -ne $script:iconOff)
        {
            $script:iconOff.Dispose()
        }
    }
    catch
    {
    }


    try
    {
        $mutex.ReleaseMutex()
    }
    catch
    {
    }


    try
    {
        $mutex.Dispose()
    }
    catch
    {
    }
}