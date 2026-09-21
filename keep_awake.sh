#!/usr/bin/env bash
#
# keep_awake.sh - Keep this Windows 11 machine awake from inside WSL.
#
# Usage:
#   ./keep_awake.sh [interval_seconds] [--for DURATION] [--plain]
#   ./keep_awake.sh --help
#
# Examples:
#   ./keep_awake.sh                  # tick every 60s, until Ctrl+C
#   ./keep_awake.sh 30               # tick every 30s, until Ctrl+C
#   ./keep_awake.sh --for 2h         # stop automatically after 2 hours
#   ./keep_awake.sh 30 --for 1h30m   # 30s ticks, stop after 90 minutes
#   ./keep_awake.sh --plain           # use timestamped lines, no animation
#
# DURATION takes h/m/s parts (2h, 90m, 45s, 1h30m) or a bare number of seconds.
# Interactive terminals show a Helion-colored falling-letter dashboard. Use
# --plain, NO_COLOR, or redirected output to select timestamped text instead.
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
plain_output=0
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
	--plain)
		plain_output=1
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
dashboard=0
dashboard_active=0
resize_pending=0
start_epoch=''
next_tick=''
last_error=''
frame=0
term_rows=24
term_cols=80
panel_top=1
panel_width=0

readonly ESC=$'\033'
readonly HELION_BG="${ESC}[48;2;28;43;68m"
readonly HELION_BLUE="${ESC}[22;38;2;98;144;204m"
readonly HELION_PINK="${ESC}[22;38;2;205;38;131m"
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
	next_label="$(fmt_duration "$((next_tick > now ? next_tick - now : 0))")"

	if ((term_cols < 40 || term_rows < 12)); then
		minimal_line="KEEP AWAKE  |  TICKS $ticks  |  NEXT $next_label"
		minimal_line="${minimal_line:0:term_cols}"
		draw_buf+="${ESC}[$((term_rows / 2));1H${HELION_PINK}${minimal_line}"
		minimal_line="ELAPSED $elapsed_label  |  REMAINING $remaining_label"
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
				color="$HELION_WHITE"
			elif ((j == 1 && (i + frame) % 7 == 0)); then
				color="$HELION_PINK"
			elif ((j < 3)); then
				color="$HELION_BLUE"
			else
				color="$HELION_MUTED${ESC}[2m"
			fi
			draw_buf+="${ESC}[${row};${col}H${color}${glyph}"
		done
	done

	panel_width=$((term_cols - 4))
	((panel_width > 70)) && panel_width=70
	panel_top=$(((term_rows - 8) / 2 + 1))
	inner=$((panel_width - 2))
	printf -v border '%*s' "$inner" ''
	border=${border// /-}
	draw_buf+="${ESC}[${panel_top};$(((term_cols - panel_width) / 2 + 1))H${HELION_BG}${HELION_BLUE}+${border}+"
	panel_row "$((panel_top + 1))" 'H E L I O N   //   K E E P   A W A K E' "$HELION_PINK"
	panel_row "$((panel_top + 2))" 'STATUS  ONLINE' "$HELION_WHITE"
	panel_row "$((panel_top + 3))" "TICKS  $ticks     ELAPSED  $elapsed_label     NEXT  $next_label" "$HELION_WHITE"
	panel_row "$((panel_top + 4))" "REMAINING  $remaining_label" "$HELION_MUTED"
	if [[ -n "$last_error" ]]; then
		status_text="LAST ERROR  $last_error"
	else
		status_text='F15 PULSE ACTIVE  //  WINDOWS SESSION HELD OPEN'
	fi
	panel_row "$((panel_top + 5))" "$status_text" "$HELION_PINK"
	panel_row "$((panel_top + 6))" 'CTRL+C TO STOP' "$HELION_MUTED"
	draw_buf+="${ESC}[$((panel_top + 7));$(((term_cols - panel_width) / 2 + 1))H${HELION_BG}${HELION_BLUE}+${border}+"
	printf '%s' "$draw_buf"
	frame=$((frame + 1))
}

on_signal() {
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
elif [[ -n "$end_epoch" ]]; then
	echo "keep_awake: holding this machine awake for $duration_label (tick every ${interval}s). Ctrl+C to stop early."
else
	echo "keep_awake: holding this machine awake (tick every ${interval}s). Ctrl+C to stop."
fi

ticks=0
remaining=0
start_epoch=$EPOCHSECONDS
next_tick=$start_epoch
while :; do
	now=$EPOCHSECONDS
	if [[ -n "$end_epoch" ]]; then
		remaining=$((end_epoch - now))
		((remaining > 0)) || break
	fi

	if ((now >= next_tick)); then
		if ! output="$(send_tick)"; then
			output="${output//$'\r'/ }"
			output="${output//$'\n'/ }"
			output="${output//$'\033'/}"
			if ((ticks == 0)); then
				cleanup_dashboard
				echo "keep_awake: first tick failed, aborting. PowerShell said:" >&2
				echo "${output:-<no output>}" >&2
				exit 1
			fi
			last_error="${output:-<no output>}"
			if ((dashboard == 0)); then
				echo "[$(date +%H:%M:%S)] tick failed: ${output:-<no output>}" >&2
			fi
		else
			((ticks++))
			if ((dashboard == 0)); then
				if [[ -n "$end_epoch" ]]; then
					printf '[%s] awake tick %d sent (%s left)\n' \
						"$(date +%H:%M:%S)" "$ticks" "$(fmt_duration "$remaining")"
				else
					printf '[%s] awake tick %d sent\n' "$(date +%H:%M:%S)" "$ticks"
				fi
			fi
		fi
		now=$EPOCHSECONDS
		next_tick=$((now + interval))
	fi

	if ((dashboard)); then
		render_dashboard "$now"
		sleep 0.1 &
		wait $! || true
	else
		# Never sleep past the deadline, or the last stretch would go unguarded.
		nap=$((next_tick - now))
		if [[ -n "$end_epoch" ]] && ((remaining < nap)); then
			nap="$remaining"
		fi
		((nap > 0)) || nap=1
		sleep "$nap" &
		wait $! || true
	fi
done

cleanup_dashboard
echo "keep_awake: $duration_label elapsed - $resumed_msg"
