# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single bash script, `keep_awake.sh`, run from a WSL2 shell to keep the host
Windows 11 machine awake and stop the screensaver from activating. There is no
build step, no dependencies, and no test framework.

## Environment requirement

The script only functions under WSL2 on Windows with interop enabled — it works
by launching `powershell.exe` as a real Windows process. It cannot be
meaningfully tested on Linux, in a container, or over SSH with no desktop
session: the keep-awake effect depends on an active, unlocked Windows session
whose idle timer can be reset.

`command -v powershell.exe` is tried first, falling back to
`/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe`. If both fail
the script exits 1 with instructions for the `[interop]` section of
`/etc/wsl.conf`.

## Load-bearing design decision: do not switch to SetThreadExecutionState

The script synthesizes an F15 keypress via `SendKeys` on each tick. This looks
like a hack next to Windows' purpose-built `SetThreadExecutionState` API, and
that API is the obvious "cleanup" refactor. **Do not make it.** Microsoft
documents that `SetThreadExecutionState` does not suppress the screensaver, and
suppressing the screensaver is this script's reason to exist. Simulated input is
the only approach that blocks the screensaver, the lock screen, and sleep
together, because Windows cannot distinguish it from a real user.

F15 specifically is chosen because effectively no application binds it, so ticks
are invisible in practice.

Consequence worth preserving in any rework: the script must be started *before*
the machine locks. Synthesized input cannot cross onto the Windows secure
desktop, so it holds an unlocked session open but will not unlock a locked one.

## Structure

Everything lives in `keep_awake.sh` (~220 lines), in this order: constants,
three helpers (`usage`, `parse_duration`, `fmt_duration`), argument parsing,
validation, PowerShell discovery, `send_tick`, the signal trap, then the main
loop. Two variables drive the behavior:

- `interval` — seconds between ticks, default 60.
- `end_epoch` — absolute deadline, or empty string for indefinite mode. Nearly
  every conditional in the second half of the script branches on whether this is
  empty, including the startup banner, the heartbeat format, and the wording of
  the exit message.

## Shell conventions

- Indentation is **tabs** (124 lines; no space-indented lines).
- `set -uo pipefail`, deliberately **without** `-e`. Do not add `-e`: arithmetic
  like `((total += num * 3600))` returns a nonzero exit status whenever the
  result is `0`, which would abort the script under `-e`. Existing code uses
  `total=$((total + ...))` form in the parser for the same reason.
- The tick sleeps as `sleep "$nap" & wait $!` rather than a plain foreground
  `sleep`, so `SIGTERM` is handled immediately instead of after the current sleep
  expires.
- `TICK_SCRIPT` begins with `$ProgressPreference="SilentlyContinue"`. Without it,
  PowerShell emits a `#< CLIXML` progress blob on stderr that pollutes
  `send_tick`'s captured output.
- Invariant: the final sleep is clamped to the time remaining (`nap="$remaining"`)
  so a timed run never sleeps past its own deadline and leaves the last stretch
  unguarded.

## Verifying a change

There is no test suite. Run the script directly, and prefer short intervals and
durations so a check takes seconds:

```bash
./keep_awake.sh --help
./keep_awake.sh 2 --for 7s          # expect 3 ticks with countdown, exits ~7.2s, code 0
time ./keep_awake.sh 2 --for 7s     # confirms deadline clamping did not overshoot
```

Argument handling is worth re-checking after any parser change; each of these
must exit 2 with a specific message:

```bash
./keep_awake.sh abc                 # bad interval
./keep_awake.sh --for 2x            # bad duration
./keep_awake.sh --for               # missing duration
./keep_awake.sh --forever           # unknown option
./keep_awake.sh 30 40               # extra positional
```

`1h30m`, `90m`, and `5400` must all normalize to the same `1h30m` label.

### Proving the machine actually stays awake

Printing ticks proves nothing about Windows' idle timer. To verify the effect is
real, read `GetLastInputInfo` before and after a tick — idle time should collapse
to near zero. Two traps make this awkward:

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
