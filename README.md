# KeepAwake

KeepAwake is a lightweight Windows tray utility that prevents the computer and display from entering sleep mode.

It runs silently in the background, can be enabled or disabled from the system tray, supports automatic deactivation after a configurable amount of time, and remembers its state between executions.

No installation is required.

## Features

- Prevents Windows from putting the PC to sleep
- Prevents the display from turning off
- Runs silently in the Windows system tray
- Enable or disable KeepAwake at any time
- Separate custom icons for active and inactive states
- Optional automatic deactivation after a configurable number of minutes
- Shows the expiration time and remaining time when automatic deactivation is active
- Remembers the previous active/inactive state
- Optional automatic startup with Windows
- Single-instance execution
- Persistent local configuration
- Automatically creates a launcher shortcut
- No external dependencies
- No notifications or popup messages during normal operation

## Requirements

- Windows
- Windows PowerShell
- .NET Framework / Windows Forms

Administrator privileges are not required.

## Project structure

```text
KeepAwake/
├── .gitignore
├── README.md
├── KeepAwake.ps1
├── KeepAwake.vbs
├── KeepAwake_On.ico
└── KeepAwake_Off.ico
```

The following files are automatically generated at runtime and should not be committed:

```text
KeepAwake.lnk
KeepAwake.settings.json
```

## Files

### `KeepAwake.ps1`

Main application.

It handles:

- sleep prevention
- system tray interface
- settings window
- automatic deactivation
- persistent configuration
- startup configuration
- custom icons
- launcher creation

### `KeepAwake.vbs`

Silent launcher used to start the PowerShell application without displaying a PowerShell console window.

### `KeepAwake_On.ico`

Icon used when KeepAwake is active.

It is also used for the generated launcher and Windows startup shortcut.

### `KeepAwake_Off.ico`

Icon used when KeepAwake is inactive.

### `KeepAwake.lnk`

Automatically generated launcher.

It starts `KeepAwake.vbs` through Windows Script Host and uses the custom KeepAwake icon.

### `KeepAwake.settings.json`

Automatically generated configuration file containing the current application settings.

## Installation

Clone the repository:

```powershell
git clone https://github.com/<username>/KeepAwake.git
```

or download the repository as a ZIP archive.

Keep these files together in the same directory:

```text
KeepAwake.ps1
KeepAwake.vbs
KeepAwake_On.ico
KeepAwake_Off.ico
```

Start the application by opening:

```text
KeepAwake.vbs
```

On startup, KeepAwake automatically creates:

```text
KeepAwake.lnk
```

The generated shortcut can then be used as the normal launcher.

## Usage

Once started, KeepAwake runs in the Windows system tray.

The tray icon reflects the current state:

- `KeepAwake_On.ico` — KeepAwake is active
- `KeepAwake_Off.ico` — KeepAwake is inactive

Right-click the tray icon to access:

```text
Active / inactive status
Enable / disable KeepAwake
Settings
Open folder
Exit
```

Double-click the tray icon to open the settings window.

## Settings

The settings window provides the following options.

### KeepAwake active

Enables or disables KeepAwake.

When active, Windows is instructed to keep both the system and display awake.

### Automatic deactivation

When enabled, KeepAwake automatically disables itself after the configured number of minutes.

When a timer is running, the current status displays:

- the expected expiration time
- the remaining duration

No popup or notification is displayed when the timer expires.

### Start with Windows

When enabled, KeepAwake creates a shortcut in the current user's Windows Startup folder.

The application will start automatically when the user signs in.

Disabling the option removes the startup shortcut.

## Settings window behavior

Changes made in the settings window are applied only when clicking:

```text
Applica
```

The window remains open after applying the changes.

Clicking the window's `X` button does not close KeepAwake.

Instead, the settings window is hidden and the application continues running in the system tray.

To completely terminate KeepAwake, use:

```text
Esci
```

either from the settings window or from the tray menu.

## Persistent state

KeepAwake remembers whether it was active or inactive when the application was previously closed.

The next time it starts, that state is restored automatically.

Configuration is stored in:

```text
KeepAwake.settings.json
```

Example:

```json
{
    "Enabled": true,
    "AutoDisable": false,
    "AutoDisableMinutes": 60,
    "StartWithWindows": false
}
```

The file is created and managed automatically.

Manual editing is not required.

## How it works

KeepAwake uses the Windows API:

```text
SetThreadExecutionState
```

While active, it requests the following execution states:

```text
ES_CONTINUOUS
ES_SYSTEM_REQUIRED
ES_DISPLAY_REQUIRED
```

This tells Windows that both the system and display are required.

When KeepAwake is disabled or the application exits, the execution state is restored.

KeepAwake does not simulate keyboard input or mouse movement.

## Single instance

KeepAwake uses a named Windows mutex to ensure that only one instance can run at a time.

Opening the launcher while KeepAwake is already running does not create another background process.

## Automatic launcher

KeepAwake automatically creates:

```text
KeepAwake.lnk
```

in the application directory.

The shortcut:

- launches `KeepAwake.vbs`
- uses `KeepAwake_On.ico`
- hides the PowerShell console
- can be used as the normal user-facing launcher

## Start with Windows

When enabled, another `KeepAwake.lnk` shortcut is created in:

```text
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
```

No Windows registry modification is required.

## `.gitignore`

Recommended `.gitignore`:

```gitignore
# User configuration
KeepAwake.settings.json

# Generated launcher
KeepAwake.lnk

# Windows
Thumbs.db
Desktop.ini
```

## Design goals

KeepAwake is intentionally built using standard Windows components:

- PowerShell
- Windows Forms
- Windows Script Host
- Windows API
- Windows shortcuts

The goal is to keep the project:

- lightweight
- portable
- transparent
- easy to modify
- dependency-free

## License

Add the license of your choice to the repository.

For an open-source utility like KeepAwake, the MIT License is a common option.