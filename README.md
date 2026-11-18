# Tray Stats

A small macOS menu bar app that shows CPU, memory, disk and CPU temperature at a glance.

```
CPU 12%  MEM 68%  DSK 41%  TMP 64°
```

## Features

- CPU, memory, disk and CPU temperature in the menu bar. You can hide any of them, but at least one always stays visible.
- A menu with details: CPU user and system split, used and total memory, free disk space, and CPU temperature.
- The top 5 processes by CPU and by memory, updated while the menu is open.
- Refresh every 2, 5, 10 or 30 seconds.
- Launch at login.
- Optional [plugins](#plugins), each in its own submenu.

## Plugins

Each plugin opens as a submenu and loads its data when you open it. Tart Runners and Codex refresh while the submenu stays open. Claude Code loads once per open and reuses a result under a minute old. You can show or hide each plugin from the menu.

| Plugin | What it shows |
| --- | --- |
| Tart Runners | The state of a local [Tart](https://tart.run) CI runner VM: running or stopped, busy or idle, the current job, guest memory and load, and when the runner was last active. |
| Codex | Your [Codex](https://github.com/openai/codex) usage: the 5 hour and weekly limits, when each one renews, the reset credits you have and when they expire, your plan and paid credits. It asks the local `codex app-server`, so it needs the Codex CLI installed and signed in. |
| Claude Code | Your Claude Code plan limits: each limit with its usage and renewal, the share of a model's weekly allowance, and whether extra usage is on. It reads the Claude Code login from the Keychain, so macOS asks for access the first time and again after each new build. It calls an undocumented Claude account usage endpoint, which can change. When the login has expired, open Claude Code to refresh it. |

## Requirements

- macOS 14 or later
- Swift 6 toolchain (Xcode 16 or later)
- Apple Silicon for the temperature reading

## Build and run

```sh
make run       # build the app bundle and open it
make install   # copy it to /Applications and open it
make verify    # check formatting, build with warnings as errors, run tests
```

Run `make` to see all targets.

## How the temperature works

macOS has no public API for CPU temperature. Tray Stats reads the CPU die sensors through the private IOKit HID event system, the same approach other monitoring tools use. It shows the hottest sensor in degrees Celsius. It needs no root access.

Because the API is private, a future macOS update could break it. If that happens, the menu bar shows `TMP –°` and the rest of the app keeps working.
