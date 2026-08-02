#!/usr/bin/env bash
#
# keep_awake.sh - Keep this Windows 11 machine awake from inside WSL.
#
# Usage:
#   ./keep_awake.sh [interval_seconds] [--for DURATION]
#   ./keep_awake.sh --help
#
# Examples:
#   ./keep_awake.sh                  # tick every 60s, until Ctrl+C
#   ./keep_awake.sh 30               # tick every 30s, until Ctrl+C
#   ./keep_awake.sh --for 2h         # stop automatically after 2 hours
#   ./keep_awake.sh 30 --for 1h30m   # 30s ticks, stop after 90 minutes
#
# DURATION takes h/m/s parts (2h, 90m, 45s, 1h30m) or a bare number of seconds.
#
# Sends a harmless F15 keypress to Windows on each tick via WSL interop.
# Windows counts synthesized input as real user activity, so this resets the
# idle timer and prevents the screensaver, the lock screen, and sleep.
#
# Only effective while running. Press Ctrl+C to stop early; normal power and
# screensaver behavior resume immediately.

set -uo pipefail

readonly DEFAULT_INTERVAL=60
readonly PS_FALLBACK='/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'

usage() {
	awk 'NR>2 && /^#/ {sub(/^# ?/, ""); print; next} NR>2 {exit}' "$0"
}

# "1h30m" -> 5400. Bare digits are treated as seconds. Echoes total seconds,
# returns 1 if the spec is malformed or adds up to zero.
parse_duration() {
	local spec="${1,,}" total=0 num unit

	if [[ "$spec" =~ ^[0-9]+$ ]]; then
		((spec > 0)) || return 1
		echo "$spec"
		return 0
	fi

	while [[ -n "$spec" ]]; do
		[[ "$spec" =~ ^([0-9]+)([hms])(.*)$ ]] || return 1
		num="${BASH_REMATCH[1]}"
		unit="${BASH_REMATCH[2]}"
		spec="${BASH_REMATCH[3]}"
		case "$unit" in
		h) total=$((total + num * 3600)) ;;
		m) total=$((total + num * 60)) ;;
		s) total=$((total + num)) ;;
		esac
	done

	((total > 0)) || return 1
	echo "$total"
}

# 5400 -> "1h30m", 90 -> "1m30s", 45 -> "45s"
fmt_duration() {
	local secs="$1" h m s
	h=$((secs / 3600))
	m=$(((secs % 3600) / 60))
	s=$((secs % 60))
	if ((h > 0)); then
		printf '%dh%02dm' "$h" "$m"
	elif ((m > 0)); then
		printf '%dm%02ds' "$m" "$s"
	else
		printf '%ds' "$s"
	fi
}

interval=''
duration_spec=''
while (($# > 0)); do
	case "$1" in
	--help | -h)
		usage
		exit 0
		;;
	--for)
		shift
		if (($# == 0)); then
			echo "keep_awake: --for needs a duration, e.g. --for 2h" >&2
			exit 2
		fi
		duration_spec="$1"
		;;
	--for=*)
		duration_spec="${1#--for=}"
		;;
	-*)
		echo "keep_awake: unknown option '$1' (try --help)" >&2
		exit 2
		;;
	*)
		if [[ -n "$interval" ]]; then
			echo "keep_awake: unexpected extra argument '$1' (try --help)" >&2
			exit 2
		fi
		interval="$1"
		;;
	esac
	shift
done

interval="${interval:-$DEFAULT_INTERVAL}"
if ! [[ "$interval" =~ ^[0-9]+$ ]] || ((interval < 1)); then
	echo "keep_awake: interval must be a positive whole number of seconds (got '$interval')" >&2
	exit 2
fi

# Windows locks the screen well before most screensaver timeouts if we tick too
# slowly, and ticking faster than once a second is pointless.
if ((interval > 240)); then
	echo "keep_awake: warning: an interval of ${interval}s may be longer than your" >&2
	echo "            screensaver or lock timeout; 60s or less is recommended." >&2
fi

end_epoch=''
duration_label=''
if [[ -n "$duration_spec" ]]; then
	if ! duration_secs="$(parse_duration "$duration_spec")"; then
		echo "keep_awake: cannot read duration '$duration_spec'." >&2
		echo "            Use h/m/s parts (2h, 90m, 1h30m) or bare seconds (5400)." >&2
		exit 2
	fi
	duration_label="$(fmt_duration "$duration_secs")"
	end_epoch=$(($(date +%s) + duration_secs))
fi

powershell="$(command -v powershell.exe 2>/dev/null || true)"
if [[ -z "$powershell" ]]; then
	if [[ -x "$PS_FALLBACK" ]]; then
		powershell="$PS_FALLBACK"
	else
		cat >&2 <<-'EOF'
			keep_awake: cannot find powershell.exe.

			This script needs WSL interop to reach Windows. Check that /etc/wsl.conf
			does not disable it:

			    [interop]
			    enabled = true
			    appendWindowsPath = true

			After editing, run `wsl --shutdown` from Windows and reopen your shell.
		EOF
		exit 1
	fi
fi

# SendKeys needs a WinForms context; silencing the progress stream keeps PowerShell
# from emitting CLIXML noise on stderr when its output is captured.
readonly TICK_SCRIPT='$ProgressPreference="SilentlyContinue"; Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.SendKeys]::SendWait("{F15}")'

send_tick() {
	"$powershell" -NoProfile -NonInteractive -Command "$TICK_SCRIPT" 2>&1
}

resumed_msg='normal sleep and screensaver behavior resumed.'

on_signal() {
	echo
	# "early" only means something when there was a deadline to fall short of.
	if [[ -n "$end_epoch" ]]; then
		echo "keep_awake: stopped early - $resumed_msg"
	else
		echo "keep_awake: stopped - $resumed_msg"
	fi
	exit 0
}
trap on_signal INT TERM

if [[ -n "$end_epoch" ]]; then
	echo "keep_awake: holding this machine awake for $duration_label (tick every ${interval}s). Ctrl+C to stop early."
else
	echo "keep_awake: holding this machine awake (tick every ${interval}s). Ctrl+C to stop."
fi

ticks=0
remaining=0
while :; do
	if [[ -n "$end_epoch" ]]; then
		remaining=$((end_epoch - $(date +%s)))
		((remaining > 0)) || break
	fi

	if ! output="$(send_tick)"; then
		if ((ticks == 0)); then
			echo "keep_awake: first tick failed, aborting. PowerShell said:" >&2
			echo "${output:-<no output>}" >&2
			exit 1
		fi
		echo "[$(date +%H:%M:%S)] tick failed: ${output:-<no output>}" >&2
	else
		((ticks++))
		if [[ -n "$end_epoch" ]]; then
			printf '[%s] awake tick %d sent (%s left)\n' \
				"$(date +%H:%M:%S)" "$ticks" "$(fmt_duration "$remaining")"
		else
			printf '[%s] awake tick %d sent\n' "$(date +%H:%M:%S)" "$ticks"
		fi
	fi

	# Never sleep past the deadline, or the last stretch would go unguarded.
	nap="$interval"
	if [[ -n "$end_epoch" ]] && ((remaining < nap)); then
		nap="$remaining"
	fi

	# Backgrounded sleep so SIGTERM is handled promptly, not after the sleep.
	sleep "$nap" &
	wait $! || true
done

echo "keep_awake: $duration_label elapsed - $resumed_msg"
