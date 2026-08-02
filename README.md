# keep_awake

Keep a Windows 11 machine awake — no screensaver, no lock screen, no sleep —
from inside a WSL2 shell.

A single bash script with no dependencies. On each tick it sends a harmless
F15 keypress to Windows through WSL interop. Windows counts synthesized input
as real user activity, so the idle timer resets and the machine stays awake
for as long as the script runs. Stop it and normal power and screensaver
behavior resume immediately.

## Requirements

- Windows 11 (or 10) with WSL2 and interop enabled, so the script can launch
  `powershell.exe`. If interop is off, the script exits with instructions for
  the `[interop]` section of `/etc/wsl.conf`.
- An **active, unlocked** Windows session. Start the script *before* the
  machine locks: synthesized input cannot reach the Windows secure desktop, so
  the script holds an unlocked session open but cannot unlock a locked one.

## Usage

```bash
./keep_awake.sh [interval_seconds] [--for DURATION]
```

| Invocation | Effect |
|---|---|
| `./keep_awake.sh` | Tick every 60 s until Ctrl+C |
| `./keep_awake.sh 30` | Tick every 30 s until Ctrl+C |
| `./keep_awake.sh --for 2h` | Stop automatically after 2 hours |
| `./keep_awake.sh 30 --for 1h30m` | 30 s ticks, stop after 90 minutes |

`DURATION` takes `h`/`m`/`s` parts (`2h`, `90m`, `45s`, `1h30m`) or a bare
number of seconds (`5400`).

Each tick prints a timestamped line; timed runs also show the time remaining:

```
keep_awake: holding this machine awake for 1h30m (tick every 30s). Ctrl+C to stop early.
[14:02:10] awake tick 1 sent (1h30m left)
[14:02:40] awake tick 2 sent (1h29m left)
```

Intervals above 240 s trigger a warning — if ticks arrive slower than your
screensaver or lock timeout, they can't prevent it. 60 s or less is
recommended.

## Why simulated keypresses instead of `SetThreadExecutionState`?

Windows has a purpose-built API for keeping the system awake, but Microsoft
documents that `SetThreadExecutionState` **does not suppress the
screensaver** — and suppressing the screensaver (and the lock screen that
follows it) is this script's reason to exist. Simulated input is the only
approach that blocks the screensaver, the lock screen, and sleep together,
because Windows cannot distinguish it from a real user.

F15 specifically is used because effectively no application binds it, so the
ticks are invisible in practice — nothing types into your editor, nothing
triggers shortcuts.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Completed its duration, or stopped with Ctrl+C / SIGTERM |
| 1 | `powershell.exe` not found, or the first tick failed |
| 2 | Bad arguments |

After the first successful tick, transient tick failures are logged but do not
stop the script.
