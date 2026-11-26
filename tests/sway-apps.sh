#!/bin/bash
# Intent apps on Intent OS, in headless sway with two screens:
#   1. Intent opens on workspace 1; the top bar lists the installed apps.
#   2. Opening two apps gives three workspaces, one window each. One app gets
#      its title late, as an Electron window can (the title rule moves it).
#   3. Super+Right/Left step through Intent and the apps on a screen.
#   4. Opening an open app from the other screen focuses its window; no
#      second window opens. The top bar lists both apps as open.
#   5. Closing an app window removes its workspace; focus goes back.
# The session scripts run from this checkout: the sway config, the window
# service, the top bar and the apps helper.
#
# Intent is a stand-in (tests/sway/stand-in-intent) that sets the window
# titles and app_ids of spec "Window identity" until the Intent build has
# the open-app entry. INTENT_CMD=<path> runs another build: it must accept
# --open-app <id> and read INTENT_OS_APPS_FILE (the stand-in apps.json).
#
# Artifacts in the out dir: NN-<step>.json (sway tree), NN-<step>-<output>.png,
# apps-NN-<step>.json (apps helper list), sway.log, result.txt.
# Needs: sway, swaymsg, grim, jq, python3-gi with Gtk 3 and GtkLayerShell.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
FILES=$ROOT/packages/intent-os-session/files
OUT=${1:-out/sway-apps}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
rm -f "$OUT"/*.json "$OUT"/*.png "$OUT"/*.log "$OUT"/result.txt
INTENT_CMD=${INTENT_CMD:-$HERE/sway/stand-in-intent}

result() { echo "$1" | tee "$OUT/result.txt"; }
fail() {
  result "FAIL: $1"
  [[ -n ${SWAYSOCK:-} ]] && swaymsg -r -t get_tree >"$OUT/fail-tree.json" 2>/dev/null
  exit 1
}
step() { echo "== $*"; }

RUN=$(mktemp -d)
export XDG_RUNTIME_DIR=$RUN/runtime HOME=$RUN/home XDG_STATE_HOME=$RUN/home/.local/state
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_STATE_HOME/intent"
chmod 0700 "$XDG_RUNTIME_DIR"
export INTENT_OS_APPS_FILE=$XDG_STATE_HOME/intent/apps.json INTENT_OS_INTENT=$INTENT_CMD
export WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=2 WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman
export GDK_BACKEND=wayland NO_AT_BRIDGE=1 GTK_A11Y=none
unset DISPLAY WAYLAND_DISPLAY SWAYSOCK I3SOCK
pids=()
cleanup() {
  local pid
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  [[ -n ${SWAY_PID:-} ]] && kill "$SWAY_PID" 2>/dev/null
  wait 2>/dev/null || true
  rm -rf "$RUN"
}
trap cleanup EXIT

# An icon for one app; the other has none (the bar shows its first letter).
python3 - "$RUN/notes.png" <<'EOF'
import sys
import gi
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf
icon = GdkPixbuf.Pixbuf.new(GdkPixbuf.Colorspace.RGB, True, 8, 64, 64)
icon.fill(0xddec61ff)
icon.savev(sys.argv[1], "png", [], [])
EOF
cat >"$INTENT_OS_APPS_FILE" <<EOF
{"version": 1, "apps": [
  {"id": "notes", "name": "Notes", "icon": "$RUN/notes.png", "windowTitle": "Intent App: Notes"},
  {"id": "timer", "name": "Timer", "icon": null, "windowTitle": "Intent App: Timer",
   "standIn": {"lateTitle": true, "appId": "electron-standin"}}
]}
EOF

# The session's sway config, with the test's screens instead of session-start.
grep -v '^exec /usr/lib/intent-os/session-start' "$FILES/usr/share/intent-os/sway/config" >"$RUN/sway.conf"
cat >>"$RUN/sway.conf" <<EOF
output HEADLESS-1 resolution 1280x800 position 0 0
output HEADLESS-2 resolution 1280x800 position 1280 0
EOF
# Headless with the pixman renderer: no GPU is used, so a GPU driver check
# (an Nvidia host) does not apply.
sway --unsupported-gpu --validate -c "$RUN/sway.conf" >/dev/null || fail "sway config does not validate"
sway --unsupported-gpu -c "$RUN/sway.conf" >"$OUT/sway.log" 2>&1 &
SWAY_PID=$!
for _ in $(seq 100); do
  SWAYSOCK=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'sway-ipc.*.sock' -print -quit)
  [[ -n $SWAYSOCK ]] && swaymsg -s "$SWAYSOCK" -t get_version >/dev/null 2>&1 && break
  SWAYSOCK=""
  sleep 0.1
done
[[ -n $SWAYSOCK ]] || fail "sway did not start (see sway.log)"
export SWAYSOCK
WAYLAND_DISPLAY=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' -printf '%f\n' -quit)
export WAYLAND_DISPLAY
[[ $(swaymsg -r -t get_outputs | jq '[.[] | select(.active)] | length') == 2 ]] ||
  fail "sway does not have two screens"

bg() { "$@" >>"$OUT/clients.log" 2>&1 & pids+=($!); }
bg "$FILES/usr/lib/intent-os/windows"
bg "$FILES/usr/lib/intent-os/top-bar"
BAR_PID=${pids[-1]}
sleep 1

tree() { swaymsg -r -t get_tree; }
# Workspace name of the window with title $1 ("" when not open).
ws_of() {
  tree | jq -r --arg t "$1" 'first(.. | objects | select(.type? == "workspace")
    | select(any(.. | objects; .name? == $t and .pid? != null)) | .name) // ""'
}
output_of() {
  swaymsg -r -t get_workspaces | jq -r --arg w "$1" '.[] | select(.name == $w) | .output'
}
windows_on() {
  tree | jq --arg w "$1" '[.. | objects | select(.type? == "workspace" and .name == $w)
    | .. | objects | select(.pid? != null and (.type == "con" or .type == "floating_con"))] | length'
}
count_titled() {
  tree | jq --arg t "$1" '[.. | objects | select(.name? == $t and .pid? != null)] | length'
}
focused_title() { tree | jq -r 'first(.. | objects | select(.focused? == true)) | .name // ""'; }
wait_for() { # wait_for <seconds> <command...>
  local limit=$(( $1 * 10 )) i
  shift
  for (( i = 0; i < limit; i++ )); do "$@" && return 0; sleep 0.1; done
  return 1
}
is_on_own_ws() { local w; w=$(ws_of "$1"); [[ -n $w && $(windows_on "$w") == 1 ]]; }
is_focused() { [[ $(focused_title) == "$1" ]]; }
is_closed() { [[ $(count_titled "$1") == 0 ]]; }
apps() { "$FILES/usr/lib/intent-os/apps" "$@"; }

n=0
snap() { # snap <step name>: tree dump, apps list, one screenshot per screen
  local name out
  n=$((n + 1))
  name=$(printf '%02d-%s' "$n" "$1")
  sleep 0.3
  tree >"$OUT/$name.json"
  apps list | jq . >"$OUT/apps-$name.json"
  for out in HEADLESS-1 HEADLESS-2; do grim -o "$out" "$OUT/$name-$out.png"; done
}

step "Intent opens on workspace 1"
bg "$INTENT_CMD"
wait_for 10 is_on_own_ws "Intent" || fail "the Intent window did not open alone"
[[ $(ws_of "Intent") == 1 && $(output_of 1) == HEADLESS-1 ]] || fail "Intent is not on workspace 1 of the first screen"
[[ $(apps list | jq -c '[.[] | [.id, .open]]') == '[["notes",false],["timer",false]]' ]] ||
  fail "apps list does not show the two installed apps as not open"
snap intent

step "Open Notes from the first screen"
apps open notes
wait_for 10 is_on_own_ws "Intent App: Notes" || fail "Notes did not get a workspace of its own"
notes_ws=$(ws_of "Intent App: Notes")
[[ $notes_ws != 1 && $(output_of "$notes_ws") == HEADLESS-1 ]] ||
  fail "Notes is on workspace $notes_ws ($(output_of "$notes_ws")), not a new one on the first screen"
wait_for 5 is_focused "Intent App: Notes" || fail "Notes does not have focus"
snap notes-open

step "Open Timer (late title) from the Notes workspace"
apps open timer
wait_for 10 is_on_own_ws "Intent App: Timer" || fail "Timer did not get a workspace of its own"
timer_ws=$(ws_of "Intent App: Timer")
[[ $timer_ws != 1 && $timer_ws != "$notes_ws" ]] || fail "Timer shares workspace $timer_ws"
is_on_own_ws "Intent App: Notes" || fail "Notes no longer has its own workspace"
wait_for 5 is_focused "Intent App: Timer" || fail "Timer does not have focus"
[[ $(tree | jq '[.. | objects | select(.type? == "workspace" and (.num // -1) >= 0)
  | select(any(.. | objects; .pid? != null))] | length') == 3 ]] || fail "not three workspaces with windows"
[[ $(apps list | jq -c '[.[] | [.id, .open]]') == '[["notes",true],["timer",true]]' ]] ||
  fail "apps list does not show both apps as open"
snap timer-open

step "Super+Left/Right step through Intent and the apps"
swaymsg -q "workspace number 1"
swaymsg -q "workspace next_on_output"
is_focused "Intent App: Notes" || fail "Super+Right from Intent did not show Notes"
swaymsg -q "workspace next_on_output"
is_focused "Intent App: Timer" || fail "Super+Right from Notes did not show Timer"
swaymsg -q "workspace prev_on_output; workspace prev_on_output"
is_focused "Intent" || fail "Super+Left twice did not go back to Intent"
snap switch

step "Open Notes again from the second screen: focus, no second window"
swaymsg -q "focus output HEADLESS-2"
[[ $(swaymsg -r -t get_workspaces | jq -r '.[] | select(.focused) | .output') == HEADLESS-2 ]] ||
  fail "could not focus the second screen"
apps open notes
wait_for 5 is_focused "Intent App: Notes" || fail "opening an open app did not focus it"
sleep 1
[[ $(count_titled "Intent App: Notes") == 1 ]] || fail "a second Notes window opened"
snap focus-open-app

step "Top bar: both apps listed, open ones marked"
# The volume keys show the bar briefly (SIGUSR1). Headless sway has no pointer
# device, so the test cannot click; a click runs "apps open <id>", as above.
swaymsg -q "workspace number 1"
kill -USR1 "$BAR_PID"
sleep 0.5
grim -o HEADLESS-1 "$OUT/top-bar-HEADLESS-1.png"
python3 - "$OUT/top-bar-HEADLESS-1.png" <<'EOF' || fail "the top bar does not show Notes (icon) and Timer, both marked open"
import sys
import gi
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf
img = GdkPixbuf.Pixbuf.new_from_file(sys.argv[1])
rs, ch, px = img.get_rowstride(), img.get_n_channels(), img.get_pixels()
def near(c, rgb):
    return all(abs(a - b) < 12 for a, b in zip(c, rgb))
band = [tuple(px[y * rs + x * ch:y * rs + x * ch + 3]) for y in range(4, 24) for x in range(110, 420)]
icon = sum(near(c, (0xdd, 0xec, 0x61)) for c in band)   # the Notes icon
dots = sum(near(c, (0x71, 0x74, 0x53)) for c in band)   # light accent: open dots
print(f"top bar: icon pixels {icon}, open-dot pixels {dots}")
sys.exit(0 if icon > 100 and dots > 4 else 1)
EOF
snap top-bar

step "Close Timer: its workspace goes, focus goes back"
swaymsg -q "[title=\"^Intent App: Timer$\"] focus"
swaymsg -q "[title=\"^Intent App: Timer$\"] kill"
wait_for 10 is_closed "Intent App: Timer" || fail "Timer did not close"
sleep 0.5
swaymsg -r -t get_workspaces | jq -e --arg w "$timer_ws" 'all(.[]; .name != $w)' >/dev/null ||
  fail "the Timer workspace $timer_ws remains"
[[ $(swaymsg -r -t get_workspaces | jq -r '.[] | select(.focused) | .representation // ""') != "" ]] ||
  fail "an empty workspace has focus after Timer closed"
snap timer-closed

step "Close Notes"
swaymsg -q "[title=\"^Intent App: Notes$\"] focus"
swaymsg -q "[title=\"^Intent App: Notes$\"] kill"
wait_for 10 is_closed "Intent App: Notes" || fail "Notes did not close"
sleep 0.5
swaymsg -r -t get_workspaces | jq -e --arg w "$notes_ws" 'all(.[]; .name != $w)' >/dev/null ||
  fail "the Notes workspace $notes_ws remains"
is_focused "Intent" || fail "Intent does not have focus after the apps closed"
[[ $(apps list | jq -c '[.[] | [.id, .open]]') == '[["notes",false],["timer",false]]' ]] ||
  fail "apps list still shows an app as open"
snap all-closed

step "Open Notes again: a new workspace"
apps open notes
wait_for 10 is_on_own_ws "Intent App: Notes" || fail "Notes did not open again on its own workspace"
snap notes-reopen

result "PASS: Intent and two apps on three workspaces; switch, focus an open app, top bar entries, close"
