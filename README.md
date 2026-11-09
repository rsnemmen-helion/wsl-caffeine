# keep_awake

Keep a Windows 11 machine awake — no screensaver, no lock screen, no sleep —
from inside a WSL2 shell.

A single bash script with no extra dependencies. It checks Windows' keyboard
and mouse activity and sends a **zero-distance mouse pulse only when idle**.
The pulse resets the idle timer without typing keys or changing the cursor
position. Stop the script and normal power and screensaver behavior resume.

## Requirements

- Windows 11 (or 10) with WSL2 and interop enabled, so the script can launch
  `powershell.exe`. If interop is off, the script exits with instructions for
  the `[interop]` section of `/etc/wsl.conf`.
- An **active, unlocked** Windows session. Start the script *before* the
  machine locks: synthesized input cannot reach the Windows secure desktop, so
  the script holds an unlocked session open but cannot unlock a locked one.

## Usage

```bash
./keep_awake.sh [idle_seconds] [--method mouse|f15] [--for DURATION] [--letters-only] [--plain]
```

| Invocation | Effect |
|---|---|
| `./keep_awake.sh` | Intervene after 60 s without input, until Ctrl+C |
| `./keep_awake.sh 30` | Intervene after 30 s without input, until Ctrl+C |
| `./keep_awake.sh --for 2h` | Stop automatically after 2 hours |
| `./keep_awake.sh 30 --for 1h30m` | 30 s idle threshold, stop after 90 minutes |
| `./keep_awake.sh --method f15` | Explicitly use F15 pulses, still only when idle |
| `./keep_awake.sh --letters-only` | Show only the falling letters, without the status panel |
| `./keep_awake.sh --plain` | Use timestamped text instead of the dashboard |

`DURATION` takes `h`/`m`/`s` parts (`2h`, `90m`, `45s`, `1h30m`) or a bare
number of seconds (`5400`).

The positional number now sets an **idle threshold**, rather than an
unconditional keypress interval. Activity is checked immediately at startup,
then every 5 s (or the threshold, if shorter). A check sends nothing if recent
keyboard or mouse input has already kept Windows active. PowerShell startup
adds some overhead; choose a threshold comfortably below your screensaver or
lock timeout, allowing for polling and startup. Thresholds above 240 s trigger
a warning; 60 s or less is recommended.

In an interactive terminal, the script displays a full-screen falling-letter
dashboard with letter trails shaded from Helion's `#CD2683` pink. Navy, blue,
and off-white frame the status panel, which shows the selected method, idle
threshold, actual pulse count, activity state, elapsed time, next check,
remaining duration, and latest error. Skipped checks do not count as pulses.
The display adapts when the terminal is resized and restores the screen and
cursor when the script exits.

Pass `--letters-only` to hide the status panel and let the falling letters fill
the entire terminal. This option affects the interactive dashboard only.

Use `--plain` for timestamped lines. Plain output is also selected automatically
when output is redirected, `TERM` is unset or `dumb`, or `NO_COLOR` is set:

```
keep_awake: holding this machine awake for 1h30m (method mouse, idle threshold 30s, check every 5s). Ctrl+C to stop.
[14:02:10] pulse skipped: recent input (idle 0s) (1h30m left)
[14:02:40] mouse pulse 1 sent (idle 30s) (1h29m left)
```

The default mouse method never falls back to keyboard input. Mouse-aware
applications can still observe a synthetic movement event, even with zero
displacement. Use `--method f15` (or `--method=f15`) only if needed for
compatibility: terminals and applications may interpret F15 as input. Neither
method unlocks Windows or overrides every Windows session or security policy.

## Why simulated input instead of `SetThreadExecutionState`?

Windows has a purpose-built API for keeping the system awake, but Microsoft
documents that [`SetThreadExecutionState` does not suppress the
screensaver](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setthreadexecutionstate).
This script uses [`GetLastInputInfo`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getlastinputinfo)
to detect inactivity and [`SendInput`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)
to reset that session's input idle timer. Mouse mode sends no buttons, wheel
events, or keys, and requests no cursor displacement.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Completed its duration, or stopped with Ctrl+C / SIGTERM |
| 1 | `powershell.exe` not found, or the first activity check failed |
| 2 | Bad arguments |

After the first successful activity check (including a skipped pulse),
transient failures are logged and retried. Activity-detection failures send
no input. A successful check clears the dashboard's latest error.

## Development checks

```bash
bash -n keep_awake.sh
python3 -B -m unittest discover -s tests -v
```

The regression tests use a fake `powershell.exe` and send no Windows input.
To verify the real effect, compare Windows' idle time and cursor position
before and after a mouse pulse, with an uninterrupted idle control period.
