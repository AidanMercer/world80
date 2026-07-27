#!/usr/bin/env bash
# rice-demo.sh — one-command world80 showcase reel, ~1 minute.
#
# starts a wf-recorder capture of the focused monitor, opens on the lyrics for
# a bit, then plays a RANDOM pick from a library of choreographed clips until
# the time budget is spent — every run is a different mix. the library:
#
#   desktop            just the desktop
#   sysinfo            pin the sysinfo panels
#   launcher           app launcher
#   popup_tabs         super+M control popup, flip through all 5 tabs fast
#   shortcuts_tabs     super+/ sheet, flip through all 4 tabs
#   overview           super+tab exposé with scripted navigation
#   lock               lock screen preview
#   pulse              open pulse, wander the process list
#   mica_vellum        open mica, find world80.md by name, open it -> vellum
#   beryl_search       open beryl, go to google.com, search something, close
#
#   rice-demo.sh                          ~60s reel, focused monitor
#   rice-demo.sh --check                  preflight + library status, no recording
#   TARGET=45 rice-demo.sh                shorter reel (seconds)
#   CLIPS="mica_vellum beryl_search"      force exactly these clips, in order
#   SPEED=0.5 rice-demo.sh                slower pacing (default 0.25 = very fast)
#   MONITOR=DP-9  AUDIO=1                 output / desktop-audio capture
#
# safety: never touches the qs process, refuses to run while locked, app clips
# self-disable when that app already has a window open (never stomps a live
# session), only windows spawned here get closed (address+pid), and the exit
# trap restores theme/wallpaper-variant/workspace even on ctrl-c.

set -u

# ---------------------------------------------------------------- config ----
MONITOR=${MONITOR:-$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .name')}
SPEED=${SPEED:-0.25}
TARGET=${TARGET:-60}
AUDIO=${AUDIO:-0}
CLIPS=${CLIPS:-}
OUTDIR=${OUTDIR:-"$HOME/Videos"}
OUT=${OUT:-"$OUTDIR/rice-demo-$(date +%Y%m%d-%H%M%S).mp4"}
DEMO_DIR="$HOME/.cache/world80/demo-home"

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

# --------------------------------------------------------------- helpers ----
say()   { printf '[%s] %s\n' "$(date +%M:%S)" "$*"; }
ipc()   { qs ipc call "$@" >/dev/null 2>&1; }
ipcget(){ qs ipc call "$@" 2>/dev/null; }
dwell() { sleep "$(awk -v t="$1" -v s="$SPEED" 'BEGIN{printf "%.2f", t*s}')"; }

REC_PID=""
SPAWNED_ADDRS=(); SPAWNED_PIDS=()
SYSINFO_PINNED=0
OPEN_TOGGLE=""          # overlay opened by us that toggles closed
DEMO_WS=""

open_overlay()  { OPEN_TOGGLE="$1"; ipc "$1" toggle; }
close_overlay() { ipc "$OPEN_TOGGLE" toggle; OPEN_TOGGLE=""; }

class_open() { hyprctl clients -j | jq -e --arg c "$1" 'any(.[]; .class == $c)' >/dev/null 2>&1; }
addrs_of()   { hyprctl clients -j | jq -r --arg c "$1" '.[] | select(.class == $c) | .address'; }

wait_new() {  # wait_new <class> <timeout> "<pre-existing addrs>" -> "addr pid"
    local class=$1 timeout=$2 before=$3 t=0 row
    while (( t < timeout * 4 )); do
        row=$(hyprctl clients -j | jq -r --arg c "$class" --arg ex "$before" \
            'first(.[] | select(.class == $c and ((($ex | split(" ")) | index(.address)) | not)))
             | "\(.address) \(.pid)"' 2>/dev/null)
        [[ -n "$row" && "$row" != "null null" ]] && { echo "$row"; return 0; }
        sleep 0.25; t=$((t + 1))
    done
    return 1
}

# launch_app <class> <cmd> [arg] — sets LAUNCHED_ADDR + registers for cleanup.
# NOT usable in $(...): registration must happen in this shell, not a subshell.
LAUNCHED_ADDR=""
launch_app() {
    local class=$1 cmd=$2 arg=${3:-} before row
    LAUNCHED_ADDR=""
    before=$(addrs_of "$class" | tr '\n' ' ')
    hyprctl dispatch workspace "$DEMO_WS" >/dev/null
    if [[ -n "$arg" ]]; then "$cmd" "$arg" & else "$cmd" & fi
    row=$(wait_new "$class" 20 "$before") || { say "  $class never mapped a window"; return 1; }
    SPAWNED_ADDRS+=("${row%% *}"); SPAWNED_PIDS+=("${row##* }")
    hyprctl dispatch focuswindow "address:${row%% *}" >/dev/null
    # real-time boot settle, NOT SPEED-scaled: the window maps before its UI and
    # key focus are live — keystrokes sent too early get eaten (or worse, land
    # as normal-mode commands once the app catches up)
    sleep 1.2
    LAUNCHED_ADDR=${row%% *}
}

register_window() { SPAWNED_ADDRS+=("$1"); SPAWNED_PIDS+=("$2"); }

close_window() {  # close_window <addr> <pid> — graceful, then kill only our pid
    hyprctl dispatch closewindow "address:$1" >/dev/null 2>&1
    for _ in $(seq 1 16); do
        hyprctl clients -j | jq -e --arg a "$1" 'any(.[]; .address == $a)' >/dev/null 2>&1 || return
        sleep 0.25
    done
    kill "$2" 2>/dev/null
}

pop_close() {  # close the most recently spawned window
    local n=${#SPAWNED_ADDRS[@]}; (( n )) || return
    close_window "${SPAWNED_ADDRS[n-1]}" "${SPAWNED_PIDS[n-1]}"
    unset "SPAWNED_ADDRS[n-1]" "SPAWNED_PIDS[n-1]"
    SPAWNED_ADDRS=("${SPAWNED_ADDRS[@]}"); SPAWNED_PIDS=("${SPAWNED_PIDS[@]}")
}

close_all_spawned() { while (( ${#SPAWNED_ADDRS[@]} )); do pop_close; done; }

poke() {  # poke <addr> <key> [key...] — keystrokes at our own window only
    local addr=$1; shift
    for k in "$@"; do
        hyprctl dispatch sendshortcut ",$k,address:$addr" >/dev/null 2>&1
        sleep 0.18   # real time, not SPEED-scaled — faster drops keystrokes
    done
}

type_text() {  # type_text <addr> <string> — char-by-char, faster than poke
    local addr=$1 s=$2 ch key i
    for (( i = 0; i < ${#s}; i++ )); do
        ch=${s:i:1}
        case "$ch" in
            .) key=period ;; ' ') key=space ;; /) key=slash ;; -) key=minus ;; *) key=$ch ;;
        esac
        hyprctl dispatch sendshortcut ",$key,address:$addr" >/dev/null 2>&1
        sleep 0.06   # real time, not SPEED-scaled — faster drops keystrokes
    done
}

# ------------------------------------------------------------- preflight ----
fail() { echo "rice-demo: $*" >&2; exit 1; }

for bin in wf-recorder jq hyprctl awww shuf; do
    command -v "$bin" >/dev/null || fail "missing $bin"
done
[[ -n "$MONITOR" ]] || fail "could not resolve a monitor to record"
[[ "$(ipcget lock isLocked)" == "true" ]] && fail "session is locked — unlock first"
ORIG_THEME=$(ipcget theme current)
[[ -n "$ORIG_THEME" ]] || fail "qs is not answering IPC — is the shell running?"

ORIG_WS=$(hyprctl activeworkspace -j | jq -r .id)
WALL_MARKER="$HOME/.cache/world80/last-wallpaper"
ORIG_WALL=$(cat "$WALL_MARKER" 2>/dev/null || true)

MPRIS_PLAYER=$(busctl --user list --no-pager 2>/dev/null \
    | awk '/org\.mpris\.MediaPlayer2\./ {print $1; exit}')

# ---------------------------------------------------------- clip library ----
# rough on-camera seconds per clip AT SPEED=1 — real time is cost*SPEED
declare -A CLIP_COST=(
    [desktop]=5 [sysinfo]=6 [launcher]=4
    [popup_tabs]=9 [shortcuts_tabs]=9 [overview]=6
    [lock]=8 [pulse]=6 [mica_vellum]=17 [beryl_search]=15
)

# clip_ready <name> — checked at pick time (windows come and go during the run)
clip_ready() {
    case "$1" in
        pulse)             ! class_open pulse ;;
        mica_vellum)       ! class_open mica ;;
        beryl_search)      ! class_open beryl ;;
        *)                 true ;;
    esac
}

clip_desktop()  { dwell 5; }
clip_launcher() { open_overlay launcher; dwell 3; close_overlay; dwell 0.5; }
clip_lock()     { ipc lock preview; dwell 6.5; ipc lock previewClose; dwell 1; }

clip_sysinfo() {
    ipc sysinfo toggle; SYSINFO_PINNED=1
    dwell 5
    ipc sysinfo toggle; SYSINFO_PINNED=0
    dwell 0.5
}

clip_popup_tabs() {  # super+M, then flip through network/sound/bt/power/display
    open_overlay controlPopup
    dwell 1.8
    for _ in 1 2 3 4; do ipc controlPopup tab 1; dwell 0.8; done
    close_overlay
    dwell 0.5
}

clip_shortcuts_tabs() {  # super+/, then cheatsheet -> settings -> market -> extensions
    open_overlay shortcuts
    dwell 2
    ipc shortcuts settings;    dwell 1.4
    ipc shortcuts marketplace; dwell 1.4
    ipc shortcuts extensions;  dwell 1.4
    close_overlay
    dwell 0.5
}

clip_overview() {
    open_overlay workspaceOverview
    dwell 1.5
    for d in right down left; do ipc workspaceOverview nav "$d"; dwell 0.6; done
    close_overlay
    dwell 0.5
}

clip_pulse() {  # ~3s on screen
    local addr
    launch_app pulse "$HOME/dev/pulse/pulse.sh" || return
    addr=$LAUNCHED_ADDR
    dwell 2.5
    poke "$addr" j j j k
    dwell 2
    pop_close
    dwell 0.5
}

clip_mica_vellum() {  # browse in mica, find world80.md, open it -> lands in vellum
    local addr vbefore vrow
    launch_app mica "$HOME/dev/mica/mica.sh" "$DEMO_DIR" || return
    addr=$LAUNCHED_ADDR
    dwell 2
    poke "$addr" j j k                       # wander the columns
    poke "$addr" f                           # find by name
    type_text "$addr" "world80"
    dwell 0.4
    poke "$addr" Return                      # jump to the hit
    vbefore=$(addrs_of vellum | tr '\n' ' ')
    poke "$addr" l                           # xdg-open -> vellum
    if vrow=$(wait_new vellum 12 "$vbefore"); then
        register_window "${vrow%% *}" "${vrow##* }"
        hyprctl dispatch focuswindow "address:${vrow%% *}" >/dev/null
        dwell 4.5
        pop_close                            # vellum
        dwell 1
    fi
    pop_close                                # mica
    dwell 0.5
}

clip_beryl_search() {
    local addr
    launch_app beryl "$HOME/dev/beryl/beryl.sh" || return
    addr=$LAUNCHED_ADDR
    dwell 2.5                                # start page
    poke "$addr" o
    type_text "$addr" "google.com"
    poke "$addr" Return
    dwell 3.5
    poke "$addr" o
    type_text "$addr" "world80 hyprland rice"
    poke "$addr" Return
    dwell 3.5
    pop_close
    dwell 0.5
}

# ------------------------------------------------------ preflight report ----
say "monitor: $MONITOR   theme now: $ORIG_THEME   target: ~${TARGET}s"
say "output:  $OUT"
[[ -n "$MPRIS_PLAYER" ]] \
    && say "music:   $MPRIS_PLAYER — opening on the lyrics" \
    || say "music:   no MPRIS player — lyric opener becomes a desktop beat"
AVAIL=""; BLOCKED=""
for c in "${!CLIP_COST[@]}"; do
    clip_ready "$c" && AVAIL+="$c " || BLOCKED+="$c "
done
say "library: $AVAIL"
[[ -n "$BLOCKED" ]] && say "blocked: $BLOCKED(app window already open / no music)"

if (( CHECK_ONLY )); then
    say "--check: preflight ok, nothing recorded (mix is rolled at runtime)"
    exit 0
fi

# --------------------------------------------------------------- cleanup ----
cleanup() {
    trap - EXIT INT TERM
    say "cleaning up..."
    # stop the recorder first so none of the restore work lands in the video
    if [[ -n "$REC_PID" ]] && kill -0 "$REC_PID" 2>/dev/null; then
        kill -INT "$REC_PID"; wait "$REC_PID" 2>/dev/null
    fi
    ipc lock previewClose
    [[ -n "$OPEN_TOGGLE" ]] && close_overlay
    (( SYSINFO_PINNED )) && ipc sysinfo toggle
    close_all_spawned
    [[ "$(ipcget theme current)" != "$ORIG_THEME" ]] && ipc theme apply "$ORIG_THEME"
    # theme apply lands on the theme's default wallpaper — put back the exact
    # variant that was up (VideoWall re-resolves stills to video on its own)
    if [[ -n "$ORIG_WALL" && "$(cat "$WALL_MARKER" 2>/dev/null)" != "$ORIG_WALL" ]]; then
        sleep 2
        awww img "$ORIG_WALL" >/dev/null 2>&1
        echo "$ORIG_WALL" > "$WALL_MARKER"
    fi
    hyprctl dispatch workspace "$ORIG_WS" >/dev/null
    if [[ -s "$OUT" ]]; then
        say "done — $OUT ($(du -h "$OUT" | cut -f1))"
    else
        say "no recording was written"
    fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- action ----
mkdir -p "$OUTDIR" "$DEMO_DIR"/{projects,notes,music}
cat > "$DEMO_DIR/world80.md" <<'MD'
# world80

a rice that ships its own apps.

- **mica** — miller-column file manager (you just came from it)
- **vellum** — editor + pdf reader (you're in it)
- **pulse** — /proc-direct system monitor
- **beryl** — hardened vim-first browser
- **frostify** — the music layer underneath it all

everything re-themes itself live when the wallpaper changes.
no restarts. no config reloads.

> github.com/AidanMercer/world80
MD

# get the launch terminal off camera before the recorder starts
hyprctl dispatch workspace empty >/dev/null
DEMO_WS=$(hyprctl activeworkspace -j | jq -r .id)
sleep 1

say "recording $MONITOR -> $OUT"
if [[ "$AUDIO" == "1" ]]; then
    wf-recorder -o "$MONITOR" -a -f "$OUT" >/dev/null 2>&1 &
else
    wf-recorder -o "$MONITOR" -f "$OUT" >/dev/null 2>&1 &
fi
REC_PID=$!
sleep 1.5
kill -0 "$REC_PID" 2>/dev/null || { REC_PID=""; fail "wf-recorder died on startup"; }

# --- fixed opener: the lyrics, for a bit ---
if [[ -n "$MPRIS_PLAYER" ]]; then
    say "opener: lyrics"
    busctl --user call "$MPRIS_PLAYER" /org/mpris/MediaPlayer2 \
        org.mpris.MediaPlayer2.Player Play >/dev/null 2>&1
    LYRIC_COST=13; dwell 13
else
    say "opener: desktop (no music)"
    LYRIC_COST=4; dwell 4
fi

# --- the reel: forced clip list, or random picks packed into the budget ---
PLAYED=""
if [[ -n "$CLIPS" ]]; then
    for c in $CLIPS; do
        [[ -n "${CLIP_COST[$c]:-}" ]] || { say "unknown clip: $c"; continue; }
        clip_ready "$c" || { say "clip $c blocked — skipping"; continue; }
        say "clip: $c"
        "clip_$c"
        PLAYED+="$c "
    done
else
    # costs are seconds at SPEED=1 — scale to real seconds so TARGET holds
    BUDGET=$(awk -v t="$TARGET" -v l="$LYRIC_COST" -v s="$SPEED" 'BEGIN{printf "%d", t - l*s}')
    for c in $(printf '%s\n' "${!CLIP_COST[@]}" | shuf); do
        cost=$(awk -v c="${CLIP_COST[$c]}" -v s="$SPEED" 'BEGIN{printf "%d", c*s + 0.5}')
        (( BUDGET < cost )) && continue
        clip_ready "$c" || continue
        say "clip: $c (~${cost}s, ${BUDGET}s left)"
        "clip_$c"
        BUDGET=$(( BUDGET - cost ))
        PLAYED+="$c "
    done
fi
say "reel: lyrics $PLAYED"

# recorder stop + theme/wallpaper/workspace restore happen off-camera in cleanup
exit 0
