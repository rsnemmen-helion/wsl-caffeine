# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single bash script, `keep_awake.sh`, run from a WSL2 shell to keep the host
Windows 11 machine awake and stop the screensaver from activating. There is no
build step or extra runtime dependencies. Regression tests use Python's standard
library; the actual keep-awake effect must also be checked on Windows.

## Environment requirement

The script only functions under WSL2 on Windows with interop enabled — it works
by launching `powershell.exe` as a real Windows process. It cannot be
meaningfully tested on Linux, in a container, or over SSH with no desktop
session: the keep-awake effect depends on an active, unlocked Windows session
whose idle timer can be reset. Mocked tests can check Bash behavior on Linux.

`command -v powershell.exe` is tried first, falling back to
`/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe`. If both fail
the script exits 1 with instructions for the `[interop]` section of
`/etc/wsl.conf`.

## Load-bearing design decision: do not switch to SetThreadExecutionState

The script reads `GetLastInputInfo` and sends input only after the idle
threshold. By default, `SendInput` sends one relative mouse movement with
`dx = dy = 0`, no buttons, and no wheel activity. Mouse-aware applications may
still see it. `--method f15` explicitly selects the older `SendKeys` behavior;
F15 can interrupt terminal applications. Never automatically fall back to keys.

Do not switch to `SetThreadExecutionState`: Microsoft documents that it does
not suppress the screensaver, which is part of this script's purpose. Avoid
claiming injected input is indistinguishable from physical input or overrides
every Windows security/session policy.

Consequence worth preserving in any rework: the script must be started *before*
the machine locks. Synthesized input cannot cross onto the Windows secure
desktop, so it holds an unlocked session open but will not unlock a locked one.

## Structure

Everything lives in `keep_awake.sh`, in this order: constants,
three helpers (`usage`, `parse_duration`, `fmt_duration`), argument parsing,
validation, PowerShell discovery, the embedded `CHECK_SCRIPT`, dashboard helpers,
signal traps, then the main loop. Key variables:

- `idle_threshold` — seconds without input before intervention, default 60.
- `check_interval` — polling cadence, `min(5, idle_threshold)` seconds.
- `method` — `mouse` by default, or explicitly `f15`.
- `pulses` — input events actually sent; skips do not increment this.
- `successful_checks` — includes skips, so a later error before the first pulse
  does not incorrectly trigger initial-check failure handling.
- `end_epoch` — absolute deadline, or empty string for indefinite mode. Nearly
  every conditional in the second half of the script branches on whether this is
  empty, including the startup banner, the heartbeat format, and the wording of
  the exit message.

Each short-lived PowerShell call compiles the native declarations, optionally
loads WinForms for F15, checks the deadline, then reads idle time immediately
before deciding whether to inject input. Unsigned tick subtraction handles
the Windows tick counter wrapping. Native `INPUT` alignment must work on both
32-bit and 64-bit Windows. Successful output is `sent MILLISECONDS`,
`skipped MILLISECONDS`, or `expired 0`; errors exit nonzero. Unexpected output
is also a failed check. Never send input after an activity-detection error.

## Shell conventions

- Bash indentation is **tabs**. The PowerShell heredoc strips leading tabs;
  keep its C# here-string terminator at column zero after stripping.
- `set -uo pipefail`, deliberately **without** `-e`. Do not add `-e`: arithmetic
  like `((total += num * 3600))` returns a nonzero exit status whenever the
  result is `0`, which would abort the script under `-e`. Existing code uses
  `total=$((total + ...))` form in the parser for the same reason.
- The loop sleeps as `sleep "$nap" & wait $!` rather than a plain foreground
  `sleep`, so `SIGTERM` is handled immediately instead of after the current sleep
  expires. Signal cleanup kills and reaps the background sleep using the job
  table, including the race before its PID could be saved, so output pipes
  close promptly.
- `CHECK_SCRIPT` sets `$ProgressPreference='SilentlyContinue'`. Without it,
  PowerShell emits a `#< CLIXML` progress blob on stderr that pollutes
  `check_activity`'s captured output.
- Recompute remaining time after Windows calls and clamp the final sleep to it.
  The PowerShell deadline check avoids injection if startup outlasts `--for`.
  An in-flight Windows call can still delay process exit slightly.

## Verifying a change

Run regression tests without invoking Windows, then do a short Windows check:

```bash
python3 -B -m unittest discover -s tests -v
bash -n keep_awake.sh
./keep_awake.sh --help
./keep_awake.sh 2 --for 7s --plain # pulses only after 2s idle; recent input skips
time ./keep_awake.sh 2 --for 7s --plain
```

Argument handling is worth re-checking after any parser change; each of these
must exit 2 with a specific message:

```bash
./keep_awake.sh abc                 # bad idle threshold
./keep_awake.sh --for 2x            # bad duration
./keep_awake.sh --for               # missing duration
./keep_awake.sh --forever           # unknown option
./keep_awake.sh 30 40               # extra positional
./keep_awake.sh --method other      # invalid method
./keep_awake.sh --method            # missing method
```

`1h30m`, `90m`, and `5400` must all normalize to the same `1h30m` label.

### Proving the machine actually stays awake

Printing ticks proves nothing about Windows' idle timer. To verify the effect is
real, read `GetLastInputInfo` before and after a mouse pulse — idle time should
collapse to near zero. Also read `GetCursorPos` and verify unchanged coordinates.
Verify recent keyboard and mouse activity suppress pulses, including at startup.
Check the user's affected terminal and a mouse-aware terminal application;
zero displacement does not guarantee no observable mouse event. Two traps make
the idle probe awkward:

1. `powershell.exe -Command -` (script on stdin) silently produces **no output**
   from WSL. Pass the probe with `-EncodedCommand` instead, base64 of UTF-16LE:
   `iconv -f UTF-8 -t UTF-16LE probe.ps1 | base64 -w0`.
2. Include a control measurement. Sleep a few seconds with no input first and
   confirm idle time *grows* by that amount; otherwise a low reading afterward
   could just be ambient mouse movement rather than the script working.

### Testing the signal traps

Send the signal to the script directly (`kill -TERM <pid>`, or bare
`timeout 3 ./keep_awake.sh 2`). Do **not** pipe it — `timeout 3 ./keep_awake.sh 2 | tail -1`
reports exit 143 and swallows the trap's output, which looks exactly like a
broken trap but is an artifact of SIGTERM hitting both ends of the pipeline.
Redirect to a file when you need to inspect the last line.

Both exit paths should be checked, since the message is context-aware: Ctrl+C
during a timed run says "stopped early", indefinite mode says just "stopped",
and a completed timed run reports the elapsed duration.
