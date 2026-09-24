Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# =============================================================================
# KeepAwake
# =============================================================================

$mutexName = "KeepAwakeMutex_Antonio_01"

$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$settingsPath = Join-Path $scriptDir "KeepAwake.settings.json"
$vbsPath      = Join-Path $scriptDir "KeepAwake.vbs"

$iconOnPath  = Join-Path $scriptDir "KeepAwake_On.ico"
$iconOffPath = Join-Path $scriptDir "KeepAwake_Off.ico"

$launcherShortcut = Join-Path $scriptDir "KeepAwake.lnk"

$startupDir      = [Environment]::GetFolderPath("Startup")
$startupShortcut = Join-Path $startupDir "KeepAwake.lnk"


# =============================================================================
# Icons
# =============================================================================

$script:iconOn  = $null
$script:iconOff = $null

try
{
    if (Test-Path -LiteralPath $iconOnPath)
    {
        $script:iconOn = New-Object System.Drawing.Icon($iconOnPath)
    }
}
catch
{
}

try
{
    if (Test-Path -LiteralPath $iconOffPath)
    {
        $script:iconOff = New-Object System.Drawing.Icon($iconOffPath)
    }
}
catch
{
}


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

$ES_CONTINUOUS = [Convert]::ToUInt32("80000000", 16)
$ACTIVE_FLAGS  = [Convert]::ToUInt32("80000003", 16)


# =============================================================================
# Default settings
# =============================================================================

function Get-DefaultSettings
{
    return [PSCustomObject]@{
        Enabled            = $true
        AutoDisable        = $false
        AutoDisableMinutes = 60
        StartWithWindows   = $false
        QuickTimerPresets  = @(30, 60, 120, 240)
    }
}


# =============================================================================
# Load / save settings
# =============================================================================

function Load-Settings
{
    $defaults = Get-DefaultSettings

    if (-not (Test-Path -LiteralPath $settingsPath))
    {
        return $defaults
    }

    try
    {
        $loaded = Get-Content -LiteralPath $settingsPath -Raw |
            ConvertFrom-Json

        # ---------------------------------------------------------------------
        # IMPORTANT:
        # Never return the deserialized object directly.
        #
        # Older settings files may not contain all current properties.
        # We always create a new complete settings object instead.
        # ---------------------------------------------------------------------

        $enabled =
            $defaults.Enabled

        $autoDisable =
            $defaults.AutoDisable

        $autoDisableMinutes =
            $defaults.AutoDisableMinutes

        $startWithWindows =
            $defaults.StartWithWindows

        $quickTimerPresets =
            @($defaults.QuickTimerPresets)


        if (
            $null -ne $loaded.PSObject.Properties["Enabled"]
        )
        {
            $enabled =
                [bool]$loaded.Enabled
        }


        if (
            $null -ne $loaded.PSObject.Properties["AutoDisable"]
        )
        {
            $autoDisable =
                [bool]$loaded.AutoDisable
        }


        if (
            $null -ne $loaded.PSObject.Properties["AutoDisableMinutes"]
        )
        {
            try
            {
                $value =
                    [int]$loaded.AutoDisableMinutes

                if ($value -ge 1)
                {
                    $autoDisableMinutes =
                        $value
                }
            }
            catch
            {
            }
        }


        if (
            $null -ne $loaded.PSObject.Properties["StartWithWindows"]
        )
        {
            $startWithWindows =
                [bool]$loaded.StartWithWindows
        }


        if (
            $null -ne $loaded.PSObject.Properties["QuickTimerPresets"]
        )
        {
            try
            {
                $presets =
                    @($loaded.QuickTimerPresets)

                if ($presets.Count -eq 4)
                {
                    $valid = $true
                    $converted = @()

                    foreach ($preset in $presets)
                    {
                        try
                        {
                            $number = [int]$preset

                            if ($number -lt 1)
                            {
                                $valid = $false
                                break
                            }

                            $converted += $number
                        }
                        catch
                        {
                            $valid = $false
                            break
                        }
                    }

                    if ($valid)
                    {
                        $quickTimerPresets =
                            $converted
                    }
                }
            }
            catch
            {
            }
        }


        return [PSCustomObject]@{
            Enabled            = $enabled
            AutoDisable        = $autoDisable
            AutoDisableMinutes = $autoDisableMinutes
            StartWithWindows   = $startWithWindows
            QuickTimerPresets  = @($quickTimerPresets)
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
            ConvertTo-Json -Depth 4 |
            Set-Content `
                -LiteralPath $settingsPath `
                -Encoding UTF8
    }
    catch
    {
    }
}


# =============================================================================
# Launcher shortcut
# =============================================================================

function Sync-LauncherShortcut
{
    try
    {
        $shell =
            New-Object -ComObject WScript.Shell

        $shortcut =
            $shell.CreateShortcut(
                $launcherShortcut
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
    catch
    {
    }
}


# =============================================================================
# Startup shortcut
# =============================================================================

function Sync-StartupShortcut
{
    try
    {
        if ([bool]$script:settings.StartWithWindows)
        {
            $shell =
                New-Object -ComObject WScript.Shell

            $shortcut =
                $shell.CreateShortcut(
                    $startupShortcut
                )

            if (Test-Path -LiteralPath $vbsPath)
            {
                $shortcut.TargetPath =
                    "$env:SystemRoot\System32\wscript.exe"

                $shortcut.Arguments =
                    "`"$vbsPath`""
            }
            else
            {
                $shortcut.TargetPath =
                    "powershell.exe"

                $shortcut.Arguments =
                    "-NoProfile -WindowStyle Hidden -File `"$PSCommandPath`""
            }

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
        else
        {
            if (Test-Path -LiteralPath $startupShortcut)
            {
                Remove-Item `
                    -LiteralPath $startupShortcut `
                    -Force
            }
        }
    }
    catch
    {
    }
}


# =============================================================================
# Single instance
# =============================================================================

$createdNew = $false

$mutex =
    New-Object System.Threading.Mutex(
        $true,
        $mutexName,
        [ref]$createdNew
    )

if (-not $createdNew)
{
    try
    {
        $mutex.Close()
    }
    catch
    {
    }

    exit
}


# =============================================================================
# Runtime state
# =============================================================================

$script:settings =
    Load-Settings

$script:isEnabled =
    [bool]$script:settings.Enabled

$script:deadline =
    $null

$script:currentTimerMinutes =
    $null

$script:settingsForm =
    $null

$script:exitRequested =
    $false


# =============================================================================
# Keep Awake
# =============================================================================

function Start-ConfiguredTimer
{
    if (
        $script:isEnabled -and
        [bool]$script:settings.AutoDisable
    )
    {
        $script:currentTimerMinutes =
            [int]$script:settings.AutoDisableMinutes

        $script:deadline =
            (Get-Date).AddMinutes(
                $script:currentTimerMinutes
            )
    }
    else
    {
        $script:currentTimerMinutes =
            $null

        $script:deadline =
            $null
    }
}


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
        [SleepManager]::SetThreadExecutionState(
            $ACTIVE_FLAGS
        ) | Out-Null

        if ($UseConfiguredTimer)
        {
            Start-ConfiguredTimer
        }
    }
    else
    {
        [SleepManager]::SetThreadExecutionState(
            $ES_CONTINUOUS
        ) | Out-Null

        $script:deadline =
            $null

        $script:currentTimerMinutes =
            $null
    }

    if ($SaveState)
    {
        $script:settings.Enabled =
            $Enabled

        Save-Settings
    }

    Update-Tray
}


# =============================================================================
# Quick timer
# =============================================================================

function Start-QuickTimer
{
    param(
        [int]$Minutes
    )

    if ($Minutes -lt 1)
    {
        return
    }

    $script:isEnabled =
        $true

    $script:settings.Enabled =
        $true

    [SleepManager]::SetThreadExecutionState(
        $ACTIVE_FLAGS
    ) | Out-Null

    $script:currentTimerMinutes =
        $Minutes

    $script:deadline =
        (Get-Date).AddMinutes($Minutes)

    Save-Settings
    Update-Tray
}


function Set-NoLimit
{
    $script:isEnabled =
        $true

    $script:settings.Enabled =
        $true

    [SleepManager]::SetThreadExecutionState(
        $ACTIVE_FLAGS
    ) | Out-Null

    $script:currentTimerMinutes =
        $null

    $script:deadline =
        $null

    Save-Settings
    Update-Tray
}


function Reset-CurrentTimer
{
    if (
        $script:isEnabled -and
        $null -ne $script:currentTimerMinutes
    )
    {
        $script:deadline =
            (Get-Date).AddMinutes(
                [int]$script:currentTimerMinutes
            )

        Update-Tray
    }
}


# =============================================================================
# Formatting
# =============================================================================

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
        $hours =
            [math]::Floor(
                $Span.TotalHours
            )

        return "{0}h {1:00}m" -f `
            $hours,
            $Span.Minutes
    }

    if ($Span.TotalMinutes -ge 1)
    {
        return "{0}m {1:00}s" -f `
            $Span.Minutes,
            $Span.Seconds
    }

    return "{0}s" -f `
        [math]::Max(
            0,
            $Span.Seconds
        )
}


function Format-Preset
{
    param(
        [int]$Minutes
    )

    if (($Minutes % 60) -eq 0)
    {
        $hours =
            [int]($Minutes / 60)

        if ($hours -eq 1)
        {
            return "1 ora"
        }

        return "$hours ore"
    }

    if ($Minutes -gt 60)
    {
        return "{0}h {1}m" -f `
            [int]($Minutes / 60),
            ($Minutes % 60)
    }

    return "$Minutes min"
}


# =============================================================================
# Open folder
# =============================================================================

function Open-ScriptFolder
{
    try
    {
        Start-Process `
            "explorer.exe" `
            -ArgumentList "`"$scriptDir`""
    }
    catch
    {
    }
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


# -----------------------------------------------------------------------------
# Enable / disable
# -----------------------------------------------------------------------------

$toggleItem =
    New-Object System.Windows.Forms.ToolStripMenuItem

$toggleItem.Add_Click(
{
    Set-KeepAwakeState `
        (-not $script:isEnabled) `
        $true `
        $true
})

[void]$menu.Items.Add(
    $toggleItem
)


# -----------------------------------------------------------------------------
# Quick timer
# -----------------------------------------------------------------------------

$quickTimerItem =
    New-Object System.Windows.Forms.ToolStripMenuItem

$quickTimerItem.Text =
    "Timer rapido"

[void]$menu.Items.Add(
    $quickTimerItem
)


function Rebuild-QuickTimerMenu
{
    $quickTimerItem.DropDownItems.Clear()

    foreach (
        $preset in
        $script:settings.QuickTimerPresets
    )
    {
        $item =
            New-Object System.Windows.Forms.ToolStripMenuItem

        $item.Text =
            Format-Preset ([int]$preset)

        $item.Tag =
            [int]$preset

        $item.Add_Click(
        {
            param(
                $sender,
                $eventArgs
            )

            Start-QuickTimer `
                ([int]$sender.Tag)
        })

        [void]$quickTimerItem.DropDownItems.Add(
            $item
        )
    }


    [void]$quickTimerItem.DropDownItems.Add(
        (New-Object System.Windows.Forms.ToolStripSeparator)
    )


    $noLimitItem =
        New-Object System.Windows.Forms.ToolStripMenuItem

    $noLimitItem.Text =
        "Senza limite"

    $noLimitItem.Add_Click(
    {
        Set-NoLimit
    })

    [void]$quickTimerItem.DropDownItems.Add(
        $noLimitItem
    )
}


# -----------------------------------------------------------------------------
# Reset timer
# -----------------------------------------------------------------------------

$resetTimerItem =
    New-Object System.Windows.Forms.ToolStripMenuItem

$resetTimerItem.Text =
    "Riavvia timer"

$resetTimerItem.Add_Click(
{
    Reset-CurrentTimer
})

[void]$menu.Items.Add(
    $resetTimerItem
)


[void]$menu.Items.Add(
    (New-Object System.Windows.Forms.ToolStripSeparator)
)


# -----------------------------------------------------------------------------
# Settings
# -----------------------------------------------------------------------------

$settingsItem =
    New-Object System.Windows.Forms.ToolStripMenuItem

$settingsItem.Text =
    "Impostazioni..."

[void]$menu.Items.Add(
    $settingsItem
)


# -----------------------------------------------------------------------------
# Open folder
# -----------------------------------------------------------------------------

$folderItem =
    New-Object System.Windows.Forms.ToolStripMenuItem

$folderItem.Text =
    "Apri cartella"

$folderItem.Add_Click(
{
    Open-ScriptFolder
})

[void]$menu.Items.Add(
    $folderItem
)


[void]$menu.Items.Add(
    (New-Object System.Windows.Forms.ToolStripSeparator)
)


# -----------------------------------------------------------------------------
# Exit
# -----------------------------------------------------------------------------

$exitItem =
    New-Object System.Windows.Forms.ToolStripMenuItem

$exitItem.Text =
    "Esci"

$exitItem.Add_Click(
{
    $script:exitRequested =
        $true

    [System.Windows.Forms.Application]::Exit()
})

[void]$menu.Items.Add(
    $exitItem
)


# =============================================================================
# Notify icon
# =============================================================================

$notifyIcon =
    New-Object System.Windows.Forms.NotifyIcon

$notifyIcon.ContextMenuStrip =
    $menu

$notifyIcon.Visible =
    $true


# =============================================================================
# Tray update
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
                $script:deadline - (Get-Date)

            if ($remaining.TotalSeconds -lt 0)
            {
                $remaining =
                    [TimeSpan]::Zero
            }

            $endText =
                $script:deadline.ToString(
                    "HH:mm"
                )

            $remainingText =
                Format-Duration $remaining

            $statusItem.Text =
                "Attivo - fine $endText - $remainingText"

            $tip =
                "KeepAwake - Attivo - fine $endText ($remainingText)"

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

            $resetTimerItem.Enabled =
                $true
        }
        else
        {
            $statusItem.Text =
                "Attivo - senza limite"

            $notifyIcon.Text =
                "KeepAwake - Attivo - senza limite"

            $resetTimerItem.Enabled =
                $false
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

        $resetTimerItem.Enabled =
            $false
    }
}


# =============================================================================
# Settings window
# =============================================================================

function Show-Settings
{
    # -------------------------------------------------------------------------
    # If the window already exists, just show it again
    # -------------------------------------------------------------------------

    if (
        $null -ne $script:settingsForm -and
        -not $script:settingsForm.IsDisposed
    )
    {
        $script:settingsForm.Show()

        $script:settingsForm.WindowState =
            [System.Windows.Forms.FormWindowState]::Normal

        $script:settingsForm.Activate()

        return
    }


    # -------------------------------------------------------------------------
    # Window
    # -------------------------------------------------------------------------

    $form =
        New-Object System.Windows.Forms.Form

    $script:settingsForm =
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
            430,
            330
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


    # -------------------------------------------------------------------------
    # X = hide window
    # -------------------------------------------------------------------------

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
    # KeepAwake enabled
    # -------------------------------------------------------------------------

    $enabledCheck =
        New-Object System.Windows.Forms.CheckBox

    $enabledCheck.Text =
        "KeepAwake attivo"

    $enabledCheck.AutoSize =
        $true

    $enabledCheck.Location =
        New-Object System.Drawing.Point(
            18,
            18
        )

    $enabledCheck.Checked =
        $script:isEnabled

    $form.Controls.Add(
        $enabledCheck
    )


    # -------------------------------------------------------------------------
    # Automatic disable
    # -------------------------------------------------------------------------

    $autoCheck =
        New-Object System.Windows.Forms.CheckBox

    $autoCheck.Text =
        "Disattiva automaticamente KeepAwake"

    $autoCheck.AutoSize =
        $true

    $autoCheck.Location =
        New-Object System.Drawing.Point(
            18,
            52
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
            36,
            89
        )

    $form.Controls.Add(
        $minutesLabel
    )


    $minutesBox =
        New-Object System.Windows.Forms.NumericUpDown

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
            88,
            85
        )

    $minutesBox.Size =
        New-Object System.Drawing.Size(
            88,
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
            184,
            89
        )

    $form.Controls.Add(
        $unitLabel
    )


    $autoCheck.Add_CheckedChanged(
    {
        $minutesBox.Enabled =
            $autoCheck.Checked
    }.GetNewClosure())


    # -------------------------------------------------------------------------
    # Start with Windows
    # -------------------------------------------------------------------------

    $startupCheck =
        New-Object System.Windows.Forms.CheckBox

    $startupCheck.Text =
        "Avvia con Windows"

    $startupCheck.AutoSize =
        $true

    $startupCheck.Location =
        New-Object System.Drawing.Point(
            18,
            126
        )

    $startupCheck.Checked =
        [bool]$script:settings.StartWithWindows

    $form.Controls.Add(
        $startupCheck
    )


    # -------------------------------------------------------------------------
    # Quick timer presets
    # -------------------------------------------------------------------------

    $presetLabel =
        New-Object System.Windows.Forms.Label

    $presetLabel.Text =
        "Preset Timer rapido (minuti):"

    $presetLabel.AutoSize =
        $true

    $presetLabel.Location =
        New-Object System.Drawing.Point(
            18,
            166
        )

    $form.Controls.Add(
        $presetLabel
    )


    $presetBoxes =
        New-Object System.Collections.ArrayList

    for ($i = 0; $i -lt 4; $i++)
    {
        $box =
            New-Object System.Windows.Forms.NumericUpDown

        $box.Minimum =
            1

        $box.Maximum =
            10080

        $box.Value =
            [decimal][math]::Max(
                1,
                [int]$script:settings.QuickTimerPresets[$i]
            )

        $box.Size =
            New-Object System.Drawing.Size(
                82,
                23
            )

        $box.Location =
            New-Object System.Drawing.Point(
                (18 + ($i * 96)),
                194
            )

        $form.Controls.Add(
            $box
        )

        [void]$presetBoxes.Add(
            $box
        )
    }


    # -------------------------------------------------------------------------
    # Current status
    # -------------------------------------------------------------------------

    $currentLabel =
        New-Object System.Windows.Forms.Label

    $currentLabel.AutoSize =
        $true

    $currentLabel.Location =
        New-Object System.Drawing.Point(
            18,
            232
        )


    $updateSettingsStatus =
    {
        if (
            $script:isEnabled -and
            $null -ne $script:deadline
        )
        {
            $currentLabel.Text =
                "Fine timer corrente: " +
                $script:deadline.ToString(
                    "HH:mm:ss"
                )
        }
        elseif ($script:isEnabled)
        {
            $currentLabel.Text =
                "Timer corrente: senza limite"
        }
        else
        {
            $currentLabel.Text =
                "KeepAwake attualmente disattivato"
        }

    }.GetNewClosure()


    & $updateSettingsStatus

    $form.Controls.Add(
        $currentLabel
    )


    # -------------------------------------------------------------------------
    # Open folder button
    # -------------------------------------------------------------------------

    $folderButton =
        New-Object System.Windows.Forms.Button

    $folderButton.Text =
        "Apri cartella"

    $folderButton.Size =
        New-Object System.Drawing.Size(
            130,
            32
        )

    $folderButton.Location =
        New-Object System.Drawing.Point(
            18,
            270
        )

    $folderButton.Add_Click(
    {
        Open-ScriptFolder
    })

    $form.Controls.Add(
        $folderButton
    )


    # -------------------------------------------------------------------------
    # Apply button
    # -------------------------------------------------------------------------

    $applyButton =
        New-Object System.Windows.Forms.Button

    $applyButton.Text =
        "Applica"

    $applyButton.Size =
        New-Object System.Drawing.Size(
            100,
            32
        )

    $applyButton.Location =
        New-Object System.Drawing.Point(
            204,
            270
        )

    $form.Controls.Add(
        $applyButton
    )


    # -------------------------------------------------------------------------
    # Exit button
    # -------------------------------------------------------------------------

    $exitButton =
        New-Object System.Windows.Forms.Button

    $exitButton.Text =
        "Esci"

    $exitButton.Size =
        New-Object System.Drawing.Size(
            100,
            32
        )

    $exitButton.Location =
        New-Object System.Drawing.Point(
            314,
            270
        )

    $form.Controls.Add(
        $exitButton
    )


    # -------------------------------------------------------------------------
    # Apply action
    # -------------------------------------------------------------------------

    $applyAction =
    {
        $newPresets =
            @(
                [int]$presetBoxes[0].Value
                [int]$presetBoxes[1].Value
                [int]$presetBoxes[2].Value
                [int]$presetBoxes[3].Value
            )


        # Always rebuild the settings object.
        # This also guarantees compatibility with old settings files.

        $script:settings =
            [PSCustomObject]@{
                Enabled =
                    [bool]$enabledCheck.Checked

                AutoDisable =
                    [bool]$autoCheck.Checked

                AutoDisableMinutes =
                    [int]$minutesBox.Value

                StartWithWindows =
                    [bool]$startupCheck.Checked

                QuickTimerPresets =
                    @($newPresets)
            }


        Save-Settings

        Sync-LauncherShortcut
        Sync-StartupShortcut

        Rebuild-QuickTimerMenu


        Set-KeepAwakeState `
            ([bool]$enabledCheck.Checked) `
            $true `
            $true


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


        & $updateSettingsStatus

    }.GetNewClosure()


    $applyButton.Add_Click(
        $applyAction
    )


    # -------------------------------------------------------------------------
    # Exit action
    # -------------------------------------------------------------------------

    $exitAction =
    {
        $script:exitRequested =
            $true

        [System.Windows.Forms.Application]::Exit()

    }.GetNewClosure()


    $exitButton.Add_Click(
        $exitAction
    )


    # -------------------------------------------------------------------------
    # Show
    # -------------------------------------------------------------------------

    $form.Show()
    $form.Activate()
}


# =============================================================================
# Settings events
# =============================================================================

$settingsItem.Add_Click(
{
    Show-Settings
})


$notifyIcon.Add_DoubleClick(
{
    Show-Settings
})


# =============================================================================
# Initialize
# =============================================================================

Rebuild-QuickTimerMenu

Sync-LauncherShortcut
Sync-StartupShortcut

Set-KeepAwakeState `
    $script:isEnabled `
    $false `
    $true


# =============================================================================
# Main timer
# =============================================================================

$timer =
    New-Object System.Windows.Forms.Timer

$timer.Interval =
    1000


$timer.Add_Tick(
{
    if ($script:isEnabled)
    {
        [SleepManager]::SetThreadExecutionState(
            $ACTIVE_FLAGS
        ) | Out-Null

        if (
            $null -ne $script:deadline -and
            (Get-Date) -ge $script:deadline
        )
        {
            Set-KeepAwakeState `
                $false `
                $true `
                $false
        }
    }

    Update-Tray
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
        if (
            $null -ne $script:settingsForm -and
            -not $script:settingsForm.IsDisposed
        )
        {
            $script:settingsForm.Dispose()
        }
    }
    catch
    {
    }


    try
    {
        [SleepManager]::SetThreadExecutionState(
            $ES_CONTINUOUS
        ) | Out-Null
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
        $mutex.Close()
    }
    catch
    {
    }
}