#!/usr/bin/env bash
#
# keep_awake.sh - Keep this Windows 11 machine awake from inside WSL.
#
# Usage:
#   ./keep_awake.sh [idle_seconds] [--method mouse|f15] [--for DURATION]
#                   [--letters-only] [--plain]
#   ./keep_awake.sh --help
#
# Examples:
#   ./keep_awake.sh                  # intervene after 60s idle, until Ctrl+C
#   ./keep_awake.sh 30               # intervene after 30s idle, until Ctrl+C
#   ./keep_awake.sh --for 2h         # stop automatically after 2 hours
#   ./keep_awake.sh 30 --for 1h30m   # 30s idle threshold, stop after 90 minutes
#   ./keep_awake.sh --method f15     # explicitly use F15 instead of mouse pulses
#   ./keep_awake.sh --letters-only    # show falling letters without status text
#   ./keep_awake.sh --plain           # use timestamped lines, no animation
#
# DURATION takes h/m/s parts (2h, 90m, 45s, 1h30m) or a bare number of seconds.
# Interactive terminals show a Helion-colored falling-letter dashboard. Use
# --plain, NO_COLOR, or redirected output to select timestamped text instead.
#
# Checks Windows activity every 5s (or idle_seconds, if shorter). Recent input
# skips the pulse. Once idle, sends a zero-distance mouse movement via WSL
# interop to reset the idle timer without typing keys or moving the cursor.
# Mouse-aware applications may still notice the event. F15 is opt-in only.
# Set the threshold below your screensaver/lock timeout, allowing for the
# check interval and PowerShell startup time. Start before Windows locks.
#
# Only effective while running. Press Ctrl+C to stop early; normal power and
# screensaver behavior resume immediately.

set -uo pipefail

readonly DEFAULT_IDLE_SECONDS=60
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

idle_threshold=''
method=mouse
duration_spec=''
plain_output=0
letters_only=0
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
	--method)
		shift
		if (($# == 0)); then
			echo "keep_awake: --method needs mouse or f15" >&2
			exit 2
		fi
		method="$1"
		;;
	--method=*)
		method="${1#--method=}"
		;;
	--plain)
		plain_output=1
		;;
	--letters-only)
		letters_only=1
		;;
	-*)
		echo "keep_awake: unknown option '$1' (try --help)" >&2
		exit 2
		;;
	*)
		if [[ -n "$idle_threshold" ]]; then
			echo "keep_awake: unexpected extra argument '$1' (try --help)" >&2
			exit 2
		fi
		idle_threshold="$1"
		;;
	esac
	shift
done

idle_threshold="${idle_threshold:-$DEFAULT_IDLE_SECONDS}"
if ! [[ "$idle_threshold" =~ ^[0-9]+$ ]] || ((10#$idle_threshold < 1)); then
	echo "keep_awake: idle threshold must be a positive whole number of seconds (got '$idle_threshold')" >&2
	exit 2
fi
idle_threshold=$((10#$idle_threshold))
if [[ "$method" != mouse && "$method" != f15 ]]; then
	echo "keep_awake: method must be mouse or f15 (got '$method')" >&2
	exit 2
fi
check_interval=5
((idle_threshold < check_interval)) && check_interval="$idle_threshold"

# Leave room for polling and PowerShell startup before the Windows idle timeout.
if ((idle_threshold > 240)); then
	echo "keep_awake: warning: an idle threshold of ${idle_threshold}s may be longer than your" >&2
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

# Compile the native declarations before reading idle time, so activity during
# PowerShell startup is included. No keyboard assembly is loaded in mouse mode.
# Suppress the progress stream to avoid CLIXML noise in captured output.
read -r -d '' CHECK_SCRIPT <<-'POWERSHELL'
	& {
		param([UInt64]$IdleSeconds, [string]$Method, [long]$EndEpoch)
		$ProgressPreference = 'SilentlyContinue'
		$ErrorActionPreference = 'Stop'
		try {
			Add-Type @'
	using System;
	using System.Runtime.InteropServices;
	public static class AwakeInput {
	    [StructLayout(LayoutKind.Sequential)]
	    private struct LASTINPUTINFO { public uint cbSize, dwTime; }
	    [StructLayout(LayoutKind.Sequential)]
	    private struct MOUSEINPUT {
	        public int dx, dy;
	        public uint mouseData, dwFlags, time;
	        public UIntPtr dwExtraInfo;
	    }
	    [StructLayout(LayoutKind.Sequential)]
	    private struct KEYBDINPUT {
	        public ushort wVk, wScan;
	        public uint dwFlags, time;
	        public UIntPtr dwExtraInfo;
	    }
	    [StructLayout(LayoutKind.Sequential)]
	    private struct HARDWAREINPUT {
	        public uint uMsg;
	        public ushort wParamL, wParamH;
	    }
	    [StructLayout(LayoutKind.Explicit)]
	    private struct INPUTUNION {
	        [FieldOffset(0)] public MOUSEINPUT mi;
	        [FieldOffset(0)] public KEYBDINPUT ki;
	        [FieldOffset(0)] public HARDWAREINPUT hi;
	    }
	    [StructLayout(LayoutKind.Sequential)]
	    private struct INPUT { public uint type; public INPUTUNION data; }
	    [DllImport("user32.dll", SetLastError = true)]
	    private static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
	    [DllImport("kernel32.dll")]
	    private static extern uint GetTickCount();
	    [DllImport("user32.dll", SetLastError = true)]
	    private static extern uint SendInput(uint count, INPUT[] inputs, int size);
	    public static uint IdleMilliseconds() {
	        LASTINPUTINFO info = new LASTINPUTINFO();
	        info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
	        if (!GetLastInputInfo(ref info))
	            throw new InvalidOperationException("GetLastInputInfo failed (Win32 error " + Marshal.GetLastWin32Error() + ").");
	        return unchecked(GetTickCount() - info.dwTime);
	    }
	    public static void PulseMouse() {
	        INPUT[] inputs = new INPUT[1];
	        inputs[0].type = 0; // INPUT_MOUSE
	        inputs[0].data.mi.dwFlags = 0x0001; // MOUSEEVENTF_MOVE, dx = dy = 0
	        if (SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT))) != 1)
	            throw new InvalidOperationException("SendInput did not accept the mouse pulse (Win32 error " + Marshal.GetLastWin32Error() + ").");
	    }
	}
	'@
			if ($Method -eq 'f15') { Add-Type -AssemblyName System.Windows.Forms }
			# Startup may outlast a short --for duration. Never send past it.
			if ($EndEpoch -gt 0 -and [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -ge $EndEpoch) {
				'expired 0'
				return
			}
			$idle = [AwakeInput]::IdleMilliseconds()
			if ([UInt64]$idle -lt $IdleSeconds * 1000) {
				"skipped $idle"
			} else {
				if ($Method -eq 'mouse') { [AwakeInput]::PulseMouse() }
				else { [System.Windows.Forms.SendKeys]::SendWait('{F15}') }
				"sent $idle"
			}
		} catch {
			[Console]::Error.WriteLine($_.Exception.Message)
			exit 1
		}
	}
POWERSHELL
readonly CHECK_SCRIPT

check_activity() {
	"$powershell" -NoProfile -NonInteractive -Command "$CHECK_SCRIPT" \
		"$idle_threshold" "$method" "${end_epoch:-0}" 2>&1
}

resumed_msg='normal sleep and screensaver behavior resumed.'
dashboard=0
dashboard_active=0
resize_pending=0
start_epoch=''
next_check=''
activity_status='WAITING FOR FIRST CHECK'
last_error=''
frame=0
term_rows=24
term_cols=80
panel_top=1
panel_width=0

readonly ESC=$'\033'
readonly HELION_BG="${ESC}[48;2;28;43;68m"
readonly HELION_BLUE="${ESC}[22;38;2;98;144;204m"
readonly HELION_PINK_LIGHT="${ESC}[22;38;2;218;120;177m"
readonly HELION_PINK="${ESC}[22;38;2;205;38;131m"
readonly HELION_PINK_MID="${ESC}[22;38;2;152;40;112m"
readonly HELION_PINK_DARK="${ESC}[22;38;2;99;41;93m"
readonly HELION_WHITE="${ESC}[22;38;2;238;242;245m"
readonly HELION_MUTED="${ESC}[22;38;2;207;207;223m"
readonly MATRIX_CHARS='ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789HELIONENERGYFUSION'

declare -a stream_y stream_speed stream_trail

read_terminal_size() {
	local size
	size="$(stty size < /dev/tty 2>/dev/null || true)"
	if [[ "$size" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
		term_rows="${BASH_REMATCH[1]}"
		term_cols="${BASH_REMATCH[2]}"
	else
		term_rows="${LINES:-24}"
		term_cols="${COLUMNS:-80}"
	fi
	((term_rows > 0)) || term_rows=24
	((term_cols > 0)) || term_cols=80
}

init_streams() {
	local count i
	read_terminal_size
	stream_y=()
	stream_speed=()
	stream_trail=()
	count=$((term_cols / 2))
	for ((i = 0; i < count; i++)); do
		stream_y[i]=$((-RANDOM % (term_rows + 1)))
		stream_speed[i]=$((RANDOM % 3 + 1))
		stream_trail[i]=$((RANDOM % 6 + 3))
	done
	resize_pending=0
}

on_resize() {
	resize_pending=1
}

setup_dashboard() {
	dashboard_active=1
	printf '%s[?1049h%s[?25l%s%s[2J%s[H' \
		"$ESC" "$ESC" "$HELION_BG" "$ESC" "$ESC"
	init_streams
}

cleanup_dashboard() {
	if ((dashboard_active)); then
		printf '%s[0m%s[?25h%s[?1049l' "$ESC" "$ESC" "$ESC"
		dashboard_active=0
	fi
}

# Append one centered dashboard row to draw_buf. Bash uses dynamic scope here,
# so the renderer can build a frame and send it to the terminal in one write.
panel_row() {
	local row="$1" text="$2" color="$3" inner left right content
	inner=$((panel_width - 2))
	text="${text:0:inner}"
	left=$(((inner - ${#text}) / 2))
	right=$((inner - ${#text} - left))
	printf -v content '%*s%s%*s' "$left" '' "$text" "$right" ''
	draw_buf+="${ESC}[${row};$(((term_cols - panel_width) / 2 + 1))H${HELION_BG}${HELION_BLUE}|${color}${content}${HELION_BLUE}|"
}

render_dashboard() {
	local now="$1" remaining_label elapsed_label next_label status_text
	local count i j row col idx glyph color border inner minimal_line
	local draw_buf="${HELION_BG}${ESC}[2J${ESC}[H"

	if ((resize_pending)); then
		init_streams
	fi

	elapsed_label="$(fmt_duration "$((now - start_epoch))")"
	if [[ -n "$end_epoch" ]]; then
		remaining_label="$(fmt_duration "$((end_epoch > now ? end_epoch - now : 0))")"
	else
		remaining_label='UNLIMITED'
	fi
	next_label="$(fmt_duration "$((next_check > now ? next_check - now : 0))")"

	if ((letters_only == 0 && (term_cols < 40 || term_rows < 12))); then
		minimal_line="${method^^} | PULSES $pulses | CHECK $next_label"
		minimal_line="${minimal_line:0:term_cols}"
		draw_buf+="${ESC}[$((term_rows / 2));1H${HELION_PINK}${minimal_line}"
		minimal_line="${last_error:-$activity_status}"
		minimal_line="${minimal_line:0:term_cols}"
		draw_buf+="${ESC}[$((term_rows / 2 + 1));1H${HELION_WHITE}${minimal_line}"
		printf '%s' "$draw_buf"
		return
	fi

	count=${#stream_y[@]}
	for ((i = 0; i < count; i++)); do
		if ((frame % stream_speed[i] == 0)); then
			stream_y[i]=$((stream_y[i] + 1))
		fi
		if ((stream_y[i] - stream_trail[i] > term_rows)); then
			stream_y[i]=$((-RANDOM % (term_rows / 2 + 1)))
			stream_speed[i]=$((RANDOM % 3 + 1))
			stream_trail[i]=$((RANDOM % 6 + 3))
		fi

		col=$((i * 2 + 1))
		for ((j = stream_trail[i] - 1; j >= 0; j--)); do
			row=$((stream_y[i] - j))
			((row >= 1 && row <= term_rows)) || continue
			idx=$((RANDOM % ${#MATRIX_CHARS}))
			glyph="${MATRIX_CHARS:idx:1}"
			if ((j == 0)); then
				color="$HELION_PINK_LIGHT"
			elif ((j == 1)); then
				color="$HELION_PINK"
			elif ((j < 4)); then
				color="$HELION_PINK_MID"
			else
				color="$HELION_PINK_DARK"
			fi
			draw_buf+="${ESC}[${row};${col}H${color}${glyph}"
		done
	done

	if ((letters_only)); then
		printf '%s' "$draw_buf"
		frame=$((frame + 1))
		return
	fi

	panel_width=$((term_cols - 4))
	((panel_width > 70)) && panel_width=70
	panel_top=$(((term_rows - 8) / 2 + 1))
	inner=$((panel_width - 2))
	printf -v border '%*s' "$inner" ''
	border=${border// /-}
	draw_buf+="${ESC}[${panel_top};$(((term_cols - panel_width) / 2 + 1))H${HELION_BG}${HELION_BLUE}+${border}+"
	panel_row "$((panel_top + 1))" 'H E L I O N   //   K E E P   A W A K E' "$HELION_PINK"
	panel_row "$((panel_top + 2))" "METHOD  ${method^^}  //  IDLE THRESHOLD  ${idle_threshold}s" "$HELION_WHITE"
	panel_row "$((panel_top + 3))" "PULSES  $pulses     ELAPSED  $elapsed_label     CHECK  $next_label" "$HELION_WHITE"
	panel_row "$((panel_top + 4))" "REMAINING  $remaining_label  //  $activity_status" "$HELION_MUTED"
	if [[ -n "$last_error" ]]; then
		status_text="LAST ERROR  $last_error"
	else
		status_text='RECENT KEYBOARD OR MOUSE INPUT SKIPS THE PULSE'
	fi
	panel_row "$((panel_top + 5))" "$status_text" "$HELION_PINK"
	panel_row "$((panel_top + 6))" 'CTRL+C TO STOP' "$HELION_MUTED"
	draw_buf+="${ESC}[$((panel_top + 7));$(((term_cols - panel_width) / 2 + 1))H${HELION_BG}${HELION_BLUE}+${border}+"
	printf '%s' "$draw_buf"
	frame=$((frame + 1))
}

pause_for() {
	sleep "$1" &
	wait $! || true
}

on_signal() {
	local sleeper
	# Loop sleeps are our only background jobs. Query the job table because a
	# signal can arrive between spawning a sleep and saving its PID.
	for sleeper in $(jobs -pr); do
		kill "$sleeper" 2>/dev/null || true
		wait "$sleeper" 2>/dev/null || true
	done
	cleanup_dashboard
	((dashboard)) || echo
	# "early" only means something when there was a deadline to fall short of.
	if [[ -n "$end_epoch" ]]; then
		echo "keep_awake: stopped early - $resumed_msg"
	else
		echo "keep_awake: stopped - $resumed_msg"
	fi
	exit 0
}
trap on_signal INT TERM
trap on_resize WINCH
trap cleanup_dashboard EXIT

if ((plain_output == 0)) && [[ -t 1 && "${TERM:-dumb}" != dumb && ! -v NO_COLOR ]]; then
	dashboard=1
fi

if ((dashboard)); then
	setup_dashboard
else
	echo "keep_awake: holding this machine awake${duration_label:+ for $duration_label} (method $method, idle threshold ${idle_threshold}s, check every ${check_interval}s). Ctrl+C to stop."
fi

pulses=0
successful_checks=0
remaining=0
start_epoch=$EPOCHSECONDS
next_check=$start_epoch
while :; do
	now=$EPOCHSECONDS
	if [[ -n "$end_epoch" ]]; then
		remaining=$((end_epoch - now))
		((remaining > 0)) || break
	fi

	if ((now >= next_check)); then
		next_check=$((now + check_interval))
		check_ok=0
		if output="$(check_activity)"; then
			output="${output//$'\r'/}"
			if [[ "$output" =~ ^(sent|skipped|expired)\ ([0-9]+)$ ]]; then
				check_ok=1
				result="${BASH_REMATCH[1]}"
				idle_seconds=$((10#${BASH_REMATCH[2]} / 1000))
			else
				output="unexpected PowerShell response: ${output:-<no output>}"
			fi
		fi
		now=$EPOCHSECONDS
		if [[ -n "$end_epoch" ]]; then
			remaining=$((end_epoch > now ? end_epoch - now : 0))
		fi
		if ((check_ok == 0)); then
			output="${output//$'\r'/ }"
			output="${output//$'\n'/ }"
			output="${output//$'\033'/}"
			if ((successful_checks == 0)); then
				cleanup_dashboard
				echo "keep_awake: first activity check failed, aborting. PowerShell said:" >&2
				echo "${output:-<no output>}" >&2
				exit 1
			fi
			last_error="${output:-<no output>}"
			if ((dashboard == 0)); then
				echo "[$(date +%H:%M:%S)] activity check failed: $last_error" >&2
			fi
		else
			[[ "$result" == expired ]] && break
			((successful_checks++))
			last_error=''
			if [[ "$result" == sent ]]; then
				((pulses++))
				activity_status="PULSE SENT AFTER ${idle_seconds}s IDLE"
				message="$method pulse $pulses sent (idle ${idle_seconds}s)"
			else
				activity_status="RECENT INPUT: IDLE ${idle_seconds}s"
				message="pulse skipped: recent input (idle ${idle_seconds}s)"
			fi
			if ((dashboard == 0)); then
				[[ -n "$end_epoch" ]] && message+=" ($(fmt_duration "$remaining") left)"
				printf '[%s] %s\n' "$(date +%H:%M:%S)" "$message"
			fi
		fi
	fi
	[[ -n "$end_epoch" ]] && ((remaining == 0)) && break

	if ((dashboard)); then
		render_dashboard "$now"
		pause_for 0.1
	else
		# Never sleep past the deadline, or the last stretch would go unguarded.
		nap=$((next_check - now))
		if [[ -n "$end_epoch" ]] && ((remaining < nap)); then
			nap="$remaining"
		fi
		((nap > 0)) || continue
		pause_for "$nap"
	fi
done

cleanup_dashboard
echo "keep_awake: $duration_label elapsed - $resumed_msg"
