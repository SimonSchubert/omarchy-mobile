#!/usr/bin/env bash
# Check the mobile shell against its acceptance criteria, in the running VM.
#
#   ./scripts/vm-selftest.sh              every section
#   ./scripts/vm-selftest.sh A E S        only those (W A B C D E H S K settings)
#
# Every line of output names the AC it proves, from docs/spec/gestures.md,
# shade.md, windows.md and settings.md, so an AC with no check here is visible
# by its absence -- docs/acceptance.md is the other half of that ledger.
#
# It drives the guest the way a finger would, through scripts/vm-drag.sh, and
# reads back what the shell believes over IPC and what the compositor did over
# hyprctl. Both halves, because either alone has lied before: a state that says
# `open` cannot tell a sheet that followed the finger from one that jumped, and
# a screenshot cannot say why.
#
# ---------------------------------------------------------------------------
# Windows it did not open
# ---------------------------------------------------------------------------
# It opens its own test windows -- foot, with an app id of sel-<letter> -- and
# closes only those, plus the shell's own screens. It never closes a window it
# did not open, and it never flicks a carousel card that is not one of its own:
# the first version closed every window in the session and would have taken
# somebody's Moonlight session with it. The criteria that need an empty phone
# (A9, E6) are reported as SKIP while any such window is up.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"
. scripts/manifest.sh

USER_NAME=$(manifest_get guest user) || exit 1
PORT=$(manifest_get vm ssh_port)     || exit 1
SSH_OPTS=(
  -o UserKnownHostsFile=/dev/null
  -o StrictHostKeyChecking=no
  -o LogLevel=ERROR
  -o ConnectTimeout=5
)

# ------------------------------------------------------------------ plumbing
#
# One helper in the guest rather than a dozen quoted one-liners from here:
# every query below is jq over hyprctl, and three layers of quoting is where a
# check silently starts testing the wrong thing.
GUEST_HELPER=$(cat <<'HELPER'
#!/usr/bin/env bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export OMARCHY_PATH=/usr/share/omarchy
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t "$XDG_RUNTIME_DIR/hypr" | head -1)
sock=$(ls -t "$XDG_RUNTIME_DIR"/wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -n1)
export WAYLAND_DISPLAY=${sock##*/}

focus_ws() { hyprctl eval "hl.dispatch(hl.dsp.focus({ workspace = \"$1\" }))" >/dev/null; }
ours='(.class | startswith("sel-"))'
shells='(.class == "org.quickshell")'

case $1 in
  ipc) shift; omarchy-shell "$@" ;;
  ws_id) hyprctl -j activeworkspace | jq .id ;;
  ws_windows) hyprctl -j activeworkspace | jq .windows ;;
  nwin) hyprctl -j clients | jq length ;;
  foreign) hyprctl -j clients | jq "[.[] | select(($ours or $shells) | not)] | length" ;;
  active_class) hyprctl -j activewindow | jq -r '.class // ""' ;;
  active_title) hyprctl -j activewindow | jq -r '.title // ""' ;;
  distinct_ws) hyprctl -j clients | jq "[.[] | select($ours) | .workspace.id] | unique | length" ;;
  lowest_empty)
    hyprctl -j workspaces | jq '[.[] | select(.windows > 0) | .id] as $t
      | first(range(1; 100) | select(. as $n | ($t | any(. == $n)) | not))' ;;
  rect) hyprctl -j clients | jq -c --arg c "$2" \
          'first(.[] | select(.class == $c) | {at, size, fullscreen})' ;;
  # .[0], not first(.[]): on an empty array first() yields nothing, the object
  # is never built, and "no such window" came back as the empty string.
  titled) hyprctl -j clients | jq -c --arg t "$2" \
          '[.[] | select(.title | startswith($t))] | {n: length, class: (.[0].class // ""),
           ws: (.[0].workspace.id // 0), rect: ((.[0] // {}) | {at, size, fullscreen})}' ;;
  win_at) hyprctl -j clients | jq -r --arg t "$2" \
          'first(.[] | select(.title | startswith($t)) | "\(.at[0]) \(.at[1])")' ;;
  usable) hyprctl -j monitors | jq -c 'first(.[]) | (.width / .scale) as $w
          | (.height / .scale) as $h | .reserved as $r
          | {at: [$r[0], $r[1]], size: [$w - $r[0] - $r[2], $h - $r[1] - $r[3]], fullscreen: 0}' ;;
  # W6: "<default-opacity tags> <opacity> <opacity_inactive>" for the first
  # window whose title starts with $2, once it has mapped.
  opacity)
    for _ in $(seq 1 60); do
      a=$(hyprctl -j clients | jq -r --arg t "$2" 'first(.[] | select(.title | startswith($t)) | .address) // ""')
      [ -n "$a" ] && break
      sleep 0.1
    done
    [ -n "$a" ] || { echo "!! $2 never mapped" >&2; exit 1; }
    echo "$(hyprctl -j clients | jq --arg a "$a" \
            'first(.[] | select(.address == $a)) | [.tags[] | select(startswith("default-opacity"))] | length')" \
         "$(hyprctl getprop "address:$a" opacity)" "$(hyprctl getprop "address:$a" opacity_inactive)" ;;
  transform) hyprctl -j monitors | jq 'first(.[]).transform' ;;
  rotate_back)
    read -r name mode pos scale <<<"$(hyprctl -j monitors | jq -r 'first(.[]) |
      "\(.name) \(.width)x\(.height)@\(.refreshRate) \(.x)x\(.y) \(.scale)"')"
    hyprctl eval "hl.monitor({ output = \"$name\", mode = \"$mode\", position = \"$pos\", scale = $scale, transform = 0 })" >/dev/null ;;
  menu_mapped) hyprctl layers | grep -c 'namespace: omarchy-menu' ;;
  toasts) hyprctl layers | grep -c 'namespace: omarchy-notifications' ;;
  volume_view) echo "$(omarchy-shell shade tiles | grep -o 'volume=[a-z0-9]*') $(omarchy-shell shade target volume)" ;;
  radios) ls /sys/class/rfkill 2>/dev/null | wc -l ;;
  dnd) omarchy-shell notifications dndState ;;
  set_dnd) omarchy-shell notifications setDnd "$2" >/dev/null ;;
  notify) omarchy-notification-send "$2" "$3" >/dev/null 2>&1 ;;
  # S27's two senders: one whose click runs an argv, one under an app's name.
  notify_exec) shift; omarchy-notification-send "$1" "$2" --exec "${@:3}" >/dev/null 2>&1 ;;
  notify_as) omarchy-notification-send --app-name "$2" "$3" "$4" >/dev/null 2>&1 ;;
  pids) hyprctl -j clients | jq -r --arg c "$2" '[.[] | select(.class == $c) | .pid] | sort | join(" ")' ;;
  kill_pids) shift; [ $# -gt 0 ] && kill "$@" 2>/dev/null; true ;;
  focus_ws) focus_ws "$2" ;;
  focus_class) focus_ws "$(hyprctl -j clients | jq --arg c "$2" 'first(.[] | select(.class == $c) | .workspace.id)')" ;;
  open_app)
    # `sleep` rather than a shell, so the title stays the one given here and
    # a card's line in `recents list` says which app it is.
    setsid -f foot -a "$2" -T "$2" sleep 900 >/dev/null 2>&1
    for _ in $(seq 1 60); do
      hyprctl -j clients | jq -e --arg c "$2" 'any(.[]; .class == $c)' >/dev/null && { sleep 0.3; exit 0; }
      sleep 0.1
    done
    echo "!! $2 never mapped" >&2; exit 1 ;;
  close_all)
    # Toasts too, which this bar turns off (S24) but a guest whose Omarchy
    # predates the patch still has. The popups are an Overlay surface whose
    # input region is the toast column, above every sheet this shell draws -- a
    # toast left standing from an earlier section swallowed every drag that
    # started in the top 170px and failed H6 for a reason unrelated to H6.
    omarchy-shell notifications dismissAll >/dev/null
    omarchy-shell drawer close >/dev/null; omarchy-shell recents close >/dev/null
    omarchy-shell shade close >/dev/null
    omarchy-shell wifi quit >/dev/null; omarchy-shell bluetooth quit >/dev/null
    omarchy-shell settings quit >/dev/null; omarchy-shell settings dryRun 0 >/dev/null
    # Only the windows this suite opened.
    hyprctl -j clients | jq ".[] | select($ours) | .pid" | xargs -r kill 2>/dev/null
    for _ in $(seq 1 60); do
      [ "$(hyprctl -j clients | jq "[.[] | select($ours or $shells)] | length")" = 0 ] && break
      sleep 0.1
    done
    focus_ws empty; sleep 0.4 ;;
  # A command in the session's environment, for the Settings checks that
  # compare a row with the reader behind it. `bash -lc`, as Settings runs them.
  sh) shift; bash -lc "$*" </dev/null ;;
  *) echo "unknown: $1" >&2; exit 2 ;;
esac
HELPER
)

ssh "${SSH_OPTS[@]}" -p "$PORT" "$USER_NAME@127.0.0.1" \
  "cat >/tmp/omarchy-mobile-selftest && chmod +x /tmp/omarchy-mobile-selftest" <<<"$GUEST_HELPER" \
  || { echo "!! the VM is not answering on port $PORT -- ./scripts/vm-run.sh first" >&2; exit 1; }

# Arguments quoted for the remote shell, which re-splits the one string ssh
# hands it: `g notify "selftest 3" "Body"` arrived as four words, and every
# notification was summarised "selftest" with its number for a body.
g() { ssh "${SSH_OPTS[@]}" -p "$PORT" "$USER_NAME@127.0.0.1" \
        "/tmp/omarchy-mobile-selftest $(printf '%q ' "$@")" 2>/dev/null; }
ipc() { g ipc "$@"; }

# A gesture, then long enough for the release to settle: every sheet animates
# out over ~200ms, and state read inside that window reads the animation.
drag() { ./scripts/vm-drag.sh "$@" >/dev/null 2>&1; sleep 0.4; }
tap() { drag "$1" "$2" 0 1; }
hold() { HOLD=0.9 ./scripts/vm-drag.sh "$1" "$2" 0 1 >/dev/null 2>&1; sleep 0.8; }

PASSED=0
SKIPPED=0
FAILED=()
check() {
  local id=$1 what=$2; shift 2
  if "$@"; then
    printf '\033[32mPASS\033[0m %-5s %s\n' "$id" "$what"
    PASSED=$((PASSED + 1))
  else
    printf '\033[31mFAIL\033[0m %-5s %s\n' "$id" "$what"
    FAILED+=("$id")
  fi
}
skip() {
  printf '\033[33mSKIP\033[0m %-5s %s\n' "$1" "$2"
  SKIPPED=$((SKIPPED + 1))
}
is() { [ "$1" = "$2" ]; }

# Poll until a command prints the wanted value, for up to ~3s -- for the checks
# whose outcome arrives through an animation and then a client's own close. The
# first argument is word-split on purpose: `wait_for "g nwin" 2`.
wait_for() { local i; for i in $(seq 1 15); do [ "$($1)" = "$2" ] && return 0; sleep 0.2; done; return 1; }
reset_session() { g close_all; }

# The strip is the bottom 20 logical px; the carousel's travel is 324 (0.45 of
# 720) -- `gestures geometry` says so and section A asserts it.
STRIP_Y=710
MID_X=180

# Card n of the carousel, if and only if it is a window this suite opened or
# one of the shell's own screens. Never anybody else's.
own_card() {
  local line; line=$(ipc recents list | sed -n "$(( $1 + 1 ))p")
  [[ "$line" == sel-* || "$line" == mobile.* ]]
}

# ------------------------------------------------------------------ sections
section_W() {
  echo "-- W: the window area"
  reset_session
  g open_app sel-a && g open_app sel-b && g open_app sel-c
  check W0 "one app per workspace: three apps on three workspaces" is "$(g distinct_ws)" 3
  check W0 "and focus followed the last one" is "$(g active_class)" sel-c
  check W1 "a single app fills its workspace exactly ($(g rect sel-a))" \
    is "$(g rect sel-a)" "$(g usable)"
  # W1 is the behaviour; this is the file that causes it, the way moarchy's
  # W2 check reads pinephone.conf.
  check W2 "hypr/mobile.lua sets both gaps to zero" \
    bash -c "[ \"\$(ssh ${SSH_OPTS[*]} -p $PORT $USER_NAME@127.0.0.1 \"grep -c -E '^\\s*gaps_(in|out) = 0,' ~/.config/hypr/mobile.lua\")\" = 2 ]"
  check W5 "nothing is fullscreened on the user's behalf" \
    is "$(g rect sel-b | jq .fullscreen)" 0
  ipc settings open >/dev/null
  local opacity; opacity=$(g opacity Settings)
  check W6 "the shell's own screens draw opaque, as the bar does ($opacity)" \
    is "$opacity" "0 1 1"
  ipc settings quit >/dev/null
}

section_A() {
  echo "-- A: strip, swipe up"
  reset_session
  check A0 "the carousel travel is 0.45 of the screen" \
    bash -c "[[ '$(ipc gestures geometry)' == *travel=324* ]]"
  local drawer_opened=0

  if [ "$(g foreign)" = 0 ]; then
    drag $MID_X $STRIP_Y -200
    check A9 "with nothing open, an up-swipe does nothing" \
      is "$(ipc recents state) $(ipc drawer state)" "closed closed"
  else
    skip A9 "needs a phone with nothing open, and $(g foreign) window(s) this suite did not open are up"
  fi
  [ "$(ipc drawer state)" = open ] && drawer_opened=1

  g open_app sel-a && g open_app sel-b
  local ws; ws=$(g ws_id)
  drag $MID_X $STRIP_Y -30
  check A2 "released under 15% travel, the carousel springs back" \
    is "$(ipc recents state) $(g ws_id)" "closed $ws"
  [ "$(ipc drawer state)" = open ] && drawer_opened=1

  # Over 1.5 seconds, not the default 360ms. A trace sample is a rendered
  # frame, so the same drag leaves fewer of them on a slower renderer: this
  # check read 13 samples headless and 3-5 with the VM windowed while the Mac
  # was busy, for a carousel that followed the finger in both. The criterion is
  # "follows", and a slower drag still proves it. Every trace check below drags
  # for the same length, for the same reason.
  drag $MID_X $STRIP_Y -200 125 12
  local samples; samples=$(ipc recents dragTrace | wc -w | tr -d ' ')
  check A1 "the carousel follows the finger ($samples samples)" [ "$samples" -ge 8 ]
  check A3 "released between 15% and 75%, it stays open" is "$(ipc recents state)" open
  [ "$(ipc drawer state)" = open ] && drawer_opened=1

  drag $MID_X $STRIP_Y -200
  check A6 "with the carousel up, a second up-drag goes home" \
    is "$(g ws_windows) $(ipc recents state)" "0 closed"
  [ "$(ipc drawer state)" = open ] && drawer_opened=1

  g focus_class sel-a
  local cards; cards=$(ipc recents list | wc -l | tr -d ' ')
  drag $MID_X $STRIP_Y -300
  check A4 "released past 75%, focus lands on a home screen" \
    is "$(g ws_windows) $(ipc recents state)" "0 closed"
  check F1 "home is the lowest-numbered empty workspace" is "$(g ws_id)" "$(g lowest_empty)"
  check F2 "going home closes nothing ($cards cards before and after)" \
    is "$(ipc recents list | wc -l | tr -d ' ')" "$cards"
  local first; first=$(ipc recents retireTrace | awk '{print $1}')
  check F4 "the carousel retires from its thinned state (first frame $first)" \
    bash -c "[[ '$first' == *:* && '${first#*:}' != 0 ]]"
  [ "$(ipc drawer state)" = open ] && drawer_opened=1

  check A5 "no strip gesture above opened the drawer" is "$drawer_opened" 0

  ipc drawer open >/dev/null; sleep 0.4
  drag $MID_X $STRIP_Y -120
  check A7 "with the drawer open, an up-swipe closes it and opens nothing" \
    is "$(ipc drawer state) $(ipc recents state)" "closed closed"
}

section_B() {
  echo "-- B: strip, swipe sideways"
  reset_session
  g open_app sel-a && g open_app sel-b
  g focus_class sel-a
  local from; from=$(g ws_id)
  DX=-150 drag $MID_X $STRIP_Y 0
  local next; next=$(g ws_id)
  check B1 "swipe left goes to the next workspace ($from -> $next)" [ "$next" != "$from" ]
  DX=150 drag $MID_X $STRIP_Y 0
  check B1 "swipe right goes back ($next -> $(g ws_id))" is "$(g ws_id)" "$from"
  DX=-150 drag $MID_X $STRIP_Y -50
  check B2 "a swipe that drifts upward still resolves sideways" is "$(g ws_id)" "$next"
  ipc drawer open >/dev/null; sleep 0.4
  DX=150 drag $MID_X $STRIP_Y 0
  check B3 "the drawer is put away on the way" \
    is "$(ipc drawer state) $(g ws_id)" "closed $from"
}

section_C() {
  echo "-- C: strip, press and hold"
  reset_session
  g open_app sel-a
  local n ws; n=$(g nwin); ws=$(g ws_id)
  HOLD=2 drag $MID_X $STRIP_Y 0 1
  check C1 "a 2s press on the strip closes nothing and changes nothing" \
    is "$(g nwin) $(g ws_id) $(ipc recents state) $(ipc drawer state)" "$n $ws closed closed"
}

section_D() {
  echo "-- D: the home screen"
  reset_session
  local travel; travel=$(ipc drawer geometry | sed -n 's/.*travel=\([0-9]*\).*/\1/p')
  # 1.5s, for the reason A1 gives.
  drag $MID_X 560 -300 125 12
  local trace last; trace=$(ipc drawer dragTrace); last=${trace##* }
  local want=$(( 300 * 100 / travel ))
  check D1 "an up-drag on the wallpaper opens the drawer ($(wc -w <<<"$trace" | tr -d ' ') samples)" \
    bash -c "[ '$(ipc drawer state)' = open ] && [ $(wc -w <<<"$trace") -ge 8 ]"
  check D2a "the open drag is 1:1 -- 300px left it at $last%, want ~$want%" \
    bash -c "d=$(( last - want )); [ \${d#-} -le 3 ]"
  ipc drawer close >/dev/null; sleep 0.4
  drag $MID_X 560 -60
  check D2 "released short, the drawer springs back" is "$(ipc drawer state)" closed
  local ws; ws=$(g ws_id)
  DX=-150 drag $MID_X 400 0
  drag $MID_X 200 200
  check D4 "sideways and downward on the home screen do nothing" \
    is "$(ipc drawer state) $(g ws_id)" "closed $ws"
  g open_app sel-a
  drag $MID_X 400 -300
  check D3 "the same drag over an app does nothing to the shell" is "$(ipc drawer state)" closed
}

section_E() {
  echo "-- E: the carousel"
  reset_session
  g open_app sel-a && g open_app sel-b && g open_app sel-c
  g focus_class sel-b
  local left_from; left_from=$(g ws_id)
  drag $MID_X $STRIP_Y -200
  check E1 "one card per open window ($(ipc recents list | wc -l | tr -d ' ') of $(g nwin))" \
    is "$(ipc recents list | wc -l | tr -d ' ')" "$(g nwin)"
  check E1 "the app you just left leads" is "$(ipc recents list | head -1 | cut -d' ' -f1)" sel-b
  local next_card; next_card=$(ipc recents cardTarget 1)
  check E4 "the next card peeks in at the left edge (card 1 spans ${next_card#* * })" \
    bash -c "[ $(awk '{print $4}' <<<"$next_card") -gt 0 ]"

  tap $MID_X 650
  check E5 "tapping the scrim dismisses and changes no focus" \
    is "$(ipc recents state) $(g ws_id)" "closed $left_from"

  drag $MID_X $STRIP_Y -200
  local want; want=$(ipc recents list | sed -n 2p | cut -d' ' -f1)
  # Card 1 is the one peeking in at the left, so its centre is off-screen.
  # Aim at the middle of the part that shows.
  local r cx cy
  read -r cx cy _ r <<<"$(ipc recents cardTarget 1)"
  tap $(( r / 2 )) "$cy"
  check E2 "tapping card 1 focuses $want and closes the carousel" \
    is "$(g active_class) $(ipc recents state)" "$want closed"

  # Back to one of ours before flicking anything: card 0 is whatever was just
  # focused, and E2 may just have focused somebody else's window.
  g focus_class sel-a
  drag $MID_X $STRIP_Y -200
  wait_for "ipc recents state" open
  local before; before=$(g nwin)
  if own_card 0; then
    local victim; victim=$(ipc recents list | head -1 | cut -d' ' -f1)
    read -r cx cy _ <<<"$(ipc recents cardTarget 0)"
    drag "$cx" "$cy" -200
    wait_for "g nwin" "$((before - 1))"
    local seen; seen="$(ipc recents list | wc -l | tr -d ' ') $(g nwin)"
    check E3 "flicking a card up closes that app ($victim; cards and windows $seen, want $((before - 1)))" \
      is "$seen" "$((before - 1)) $((before - 1))"
  else
    check E3 "card 0 is one of this suite's own windows" false
  fi

  if [ "$(g foreign)" = 0 ]; then
    for _ in 1 2 3; do
      [ "$(ipc recents state)" = open ] || break
      own_card 0 || break
      read -r cx cy _ <<<"$(ipc recents cardTarget 0)"
      [ -n "$cx" ] && [ "$cx" != none ] || break
      local n0; n0=$(g nwin)
      drag "$cx" "$cy" -200
      wait_for "g nwin" "$((n0 - 1))"
    done
    wait_for "ipc recents state" closed
    local seen; seen="$(g nwin) $(g ws_windows) $(ipc recents state)"
    check E6 "closing the last card lands on a home screen (windows, here, carousel: $seen)" \
      is "$seen" "0 0 closed"
  else
    skip E6 "needs every card to be closable, and $(g foreign) window(s) this suite did not open are up"
    ipc recents close >/dev/null
  fi
}

section_H() {
  echo "-- H: closing the drawer by dragging it"
  reset_session
  ipc drawer open >/dev/null; sleep 0.4
  # 1.5s, for the reason A1 gives.
  drag $MID_X 400 400 125 12
  check H1 "a drag down on the sheet closes it ($(ipc drawer dragTrace | wc -w | tr -d ' ') samples)" \
    bash -c "[ '$(ipc drawer state)' = closed ] && [ $(ipc drawer dragTrace | wc -w) -ge 8 ]"
  ipc drawer open >/dev/null; sleep 0.4
  drag $MID_X 400 60
  check H3 "a drag that stops short springs back" is "$(ipc drawer state)" open
  drag $MID_X 39 400
  check H6 "the handle band still closes it" is "$(ipc drawer state)" closed

  ipc drawer open >/dev/null; sleep 0.4
  local i target=""
  for i in $(seq 0 40); do
    local t; t=$(ipc drawer cellTarget "$i")
    [ "$t" = none ] && break
    [ "${t#* * }" = Foot ] && { target=$t; break; }
  done
  local before pids_before; before=$(g nwin); pids_before=$(g pids foot)
  if [ -n "$target" ]; then
    read -r cx cy _ <<<"$target"
    tap "$cx" "$cy"
    for _ in $(seq 1 30); do [ "$(g nwin)" -gt "$before" ] && break; sleep 0.2; done
  fi
  check H4 "a tap on an icon still launches it (Foot at ${target% Foot})" \
    is "$(g nwin) $(ipc drawer state)" "$((before + 1)) closed"
  # Close the one foot this tap started, and only that one.
  local p new=()
  for p in $(g pids foot); do [[ " $pids_before " == *" $p "* ]] || new+=("$p"); done
  [ ${#new[@]} -gt 0 ] && g kill_pids "${new[@]}"
}

section_S() {
  echo "-- S: the shade"
  reset_session
  local dnd0; dnd0=$(g dnd)
  ipc notifications clear >/dev/null

  drag $MID_X 13 400 125 12
  local n; n=$(ipc shade dragTrace | wc -w | tr -d ' ')
  check S0 "a pull down the status bar opens the shade, following the finger ($n samples)" \
    bash -c "[ '$(ipc shade state)' = open ] && [ $n -ge 8 ]"

  drag $MID_X $STRIP_Y -120
  check A8 "with the shade down, an up-swipe from the strip puts it away and opens nothing" \
    is "$(ipc shade state) $(ipc recents state) $(ipc drawer state)" "closed closed closed"

  ipc shade open >/dev/null; sleep 0.6
  drag $MID_X 640 -300 125 12
  n=$(ipc shade dragTrace | wc -w | tr -d ' ')
  check H2 "an up-drag on the scrim closes it, following the finger ($n samples)" \
    bash -c "[ '$(ipc shade state)' = closed ] && [ $n -ge 8 ]"

  ipc shade open >/dev/null; sleep 0.6
  tap $MID_X 640
  check H2 "a tap on the scrim dismisses it" is "$(ipc shade state)" closed

  g open_app sel-a && g open_app sel-b
  local ws; ws=$(g ws_id)
  ipc shade open >/dev/null; sleep 0.6
  DX=-150 drag $MID_X $STRIP_Y 0
  check B3 "a sideways swipe puts the shade away on the way ($ws -> $(g ws_id))" \
    bash -c "[ '$(ipc shade state)' = closed ] && [ '$(g ws_id)' != '$ws' ]"

  local x y w
  ipc shade open >/dev/null; sleep 0.6
  read -r x y _ <<<"$(ipc shade target silent)"; tap "$x" "$y"
  local dnd1; dnd1=$(g dnd)
  check S7 "Silent toggles do-not-disturb ($dnd0 -> $dnd1), and the bar follows" \
    bash -c "[ '$dnd0' != '$dnd1' ] && [[ '$(ipc bar metrics)' == *dnd=$dnd1* ]]"
  tap "$x" "$y"

  read -r x y _ <<<"$(ipc shade target airplane)"; tap "$x" "$y"; sleep 1.2
  if [ "$(g radios)" = 0 ]; then
    check S8 "Airplane re-reads the real state: with no radio to block, it reads off again" \
      bash -c "[[ '$(ipc shade tiles)' == *airplane=0* ]]"
  else
    check S8 "Airplane blocks every radio" bash -c "[[ '$(ipc shade tiles)' == *airplane=1* ]]"
    tap "$x" "$y"; sleep 1.2
  fi

  read -r _ _ w <<<"$(ipc shade target silent)"
  if [[ "$(ipc shade tiles)" == *torch=absent* ]]; then
    check S10 "no flash LED: the torch is absent, and three tiles share the row (${w}px each)" [ "$w" -gt 100 ]
  else
    check S10 "a flash LED: four tiles share the row (${w}px each)" [ "$w" -lt 100 ]
  fi
  # Both halves read in one guest call. Read in two, a second apart, they once
  # disagreed -- no sink, and a slider drawn -- with the sink coming and going.
  local vv; vv=$(g volume_view)
  if [[ "$vv" == volume=absent* ]]; then
    check S14 "no sink: the volume slider is not drawn ($vv)" is "${vv#* }" none
  else
    check S14 "a sink: the volume slider is drawn ($vv)" [ "${vv#* }" != none ]
  fi

  read -r x y _ <<<"$(ipc shade target rotate)"; tap "$x" "$y"; sleep 1
  check S11 "Rotate turns the panel to one landscape" is "$(g transform)" 1
  g rotate_back; sleep 1
  check S11 "and portrait comes back" is "$(g transform)" 0

  ipc shade open >/dev/null; sleep 0.6
  read -r x y _ <<<"$(ipc shade target gear)"; tap "$x" "$y"; sleep 1
  check S2 "the gear puts the shade away and opens Settings, not the Omarchy menu" \
    is "$(ipc shade state) $(ipc settings state) $(g menu_mapped)" "closed open 0"
  ipc settings quit >/dev/null; sleep 0.6
  ipc shade open >/dev/null; sleep 0.6
  read -r x y _ <<<"$(ipc shade target power)"; tap "$x" "$y"; sleep 1
  check S3 "power opens Settings at its Power page" \
    is "$(ipc shade state) $(ipc settings page)" "closed system.power"
  ipc settings quit >/dev/null; sleep 0.6

  g set_dnd off
  # The bell's state by exact key, polled: the bar re-counts on a debounced
  # directory watch, behind the service's own file queue.
  bell_state() { ipc bar metrics | tr ' ' '\n' | sed -n 's/^bell=//p'; }
  for i in 1 2 3; do g notify "selftest $i" "Body of selftest notification $i"; sleep 0.2; done
  sleep 0.8
  # Counted with the shade still shut, which is when a toast would be up.
  local toasts; toasts=$(g toasts)
  check S26 "a notification puts the bell in the bar" wait_for bell_state shown
  ipc shade open >/dev/null; sleep 1.5
  local rows; rows=$(ipc shade notifications | grep -c 'selftest')
  check S24 "three notifications, no toast ($toasts omarchy-notifications layers), all three in the shade" \
    bash -c "[ '$toasts' = 0 ] && [ $rows -ge 3 ]"
  # The first of ITS OWN rows, not the first row: anything else that notifies
  # during the run is newer than all three and would lead the list.
  local first_own; first_own=$(ipc shade notifications | grep selftest | head -1)
  check S18 "notifications are listed, newest first ($rows; leading: ${first_own#* omarchy-action })" \
    bash -c "[ $rows -ge 3 ] && [[ '$first_own' == *'selftest 3'* ]]"
  local icon0 kinds nrows
  icon0=$(ipc shade target card0icon)
  kinds=$(ipc shade icons | awk 'NF == 2' | wc -l | tr -d ' ')
  nrows=$(ipc shade notifications | wc -l | tr -d ' ')
  check S25 "every card leads with an icon ($kinds of $nrows; the first from $(ipc shade icons | head -1 | cut -d' ' -f2))" \
    bash -c "[ '$icon0' != none ] && [ $kinds = $nrows ]"
  local cx cy
  read -r cx cy _ <<<"$(ipc shade target card0)"
  DX=-100 drag "$cx" "$cy" 0
  check H7a "a short sideways swipe dismisses nothing" \
    is "$(ipc shade notifications | grep -c selftest)" "$rows"
  DX=-230 drag "$cx" "$cy" 0
  check H7 "a sideways swipe dismisses that notification" \
    is "$(ipc shade notifications | grep -c selftest)" "$((rows - 1))"
  ipc shade close >/dev/null; sleep 0.5; ipc shade open >/dev/null; sleep 1.5
  check H7 "and it stays gone when the shade is reopened" \
    is "$(ipc shade notifications | grep -c selftest)" "$((rows - 1))"

  # One field by exact key: `max=` alone also matches `listmax=`, and the first
  # version of this check compared against both numbers at once.
  field() { tr ' ' '\n' <<<"$1" | sed -n "s/^$2=//p"; }
  local s; s=$(ipc shade sheet)
  local h wanted max
  h=$(field "$s" height)
  wanted=$(field "$s" wanted)
  max=$(field "$s" max)
  check S21 "the sheet is as tall as its content ($h of a $max cap)" \
    bash -c "[ $h = $wanted ] && [ $h -lt $max ]"

  for i in $(seq 4 12); do g notify "selftest $i" "Body $i"; done
  sleep 0.5; ipc shade close >/dev/null; sleep 0.5; ipc shade open >/dev/null; sleep 1.5
  s=$(ipc shade sheet)
  h=$(field "$s" height)
  # Within a pixel of the cap, not exactly on it: the list's y can land on a
  # half pixel and the sheet's height is an int, and one run read 629 of 630
  # with the list scrolling -- which is the criterion.
  check S22 "with more than fits, it stops at the cap and the list scrolls ($h of $max, $(grep -o 'scrolls=[01]' <<<"$s"))" \
    bash -c "[ $h -ge $((max - 1)) ] && [ $h -le $max ] && [[ '$s' == *scrolls=1* ]]"

  read -r cx cy _ <<<"$(ipc shade target card0)"
  drag "$cx" "$cy" -150 30 12
  check H5 "a vertical drag on a list that can scroll scrolls it, and the shade stays" \
    is "$(ipc shade state)" open

  read -r x y _ <<<"$(ipc shade target clearAll)"; tap "$x" "$y"; sleep 1
  check S19 "Clear all removes every notification" \
    is "$(ipc shade notifications | wc -l | tr -d ' ')" 0
  ipc shade close >/dev/null; sleep 0.8; ipc shade open >/dev/null; sleep 1.5
  check S19 "and they stay removed" is "$(ipc shade notifications | wc -l | tr -d ' ')" 0
  ipc shade close >/dev/null
  check S26 "and the bell goes with them" wait_for bell_state none

  g notify "selftest bell" "Body"
  wait_for bell_state shown
  g set_dnd on; sleep 0.5
  # One read, so the two halves cannot disagree about when they were taken.
  local silenced; silenced=$(ipc bar metrics)
  check S26 "with Silent on, Silent's glyph stands in for the bell" \
    bash -c "[[ '$silenced' == *dnd=on* ]] && [[ '$silenced' == *bell=none* ]]"
  ipc notifications clear >/dev/null
  g set_dnd off

  # S27. Real taps on card 0, which is always the notification just sent: the
  # list was emptied above, and each tap that runs something removes its card.
  local acts ran after left
  g notify "selftest inert" "Nothing to run"; sleep 1
  ipc shade open >/dev/null; sleep 1.5
  acts=$(ipc shade actions | head -1 | cut -d' ' -f2)
  read -r cx cy _ <<<"$(ipc shade target card0)"; tap "$cx" "$cy"; sleep 1
  check S27 "a tap on a card with nothing to run ($acts) leaves it, and the shade up" \
    is "$(ipc shade state) $(ipc shade notifications | grep -c 'selftest inert')" "open 1"
  ipc shade close >/dev/null; ipc notifications clear >/dev/null; sleep 0.8

  # The marker goes first, so a file an earlier run left cannot pass this.
  local marker=/tmp/omarchy-mobile-selftest-tapped
  g sh "rm -f $marker"
  g notify_exec "selftest tap" "Tap to run" touch "$marker"; sleep 1
  ipc shade open >/dev/null; sleep 1.5
  acts=$(ipc shade actions | head -1 | cut -d' ' -f2)
  read -r cx cy _ <<<"$(ipc shade target card0)"; tap "$cx" "$cy"; sleep 1
  ran=$(g sh "[ -e $marker ] && echo ran || echo not-run")
  after=$(ipc shade state)
  left=$(ipc shade notifications | grep -c 'selftest tap')
  check S27 "a tap on an --exec card ($acts) runs it, closes the shade and removes the card" \
    is "$ran $after $left" "ran closed 0"

  g open_app sel-t; g focus_ws empty; sleep 0.4
  g notify_as sel-t "selftest focus" "From sel-t"; sleep 1
  ipc shade open >/dev/null; sleep 1.5
  acts=$(ipc shade actions | head -1 | cut -d' ' -f2)
  read -r cx cy _ <<<"$(ipc shade target card0)"; tap "$cx" "$cy"; sleep 1
  check S27 "a tap on a card from an app with a window open ($acts) focuses it" \
    is "$(g active_class) $(ipc shade state)" "sel-t closed"

  ipc notifications clear >/dev/null
  g set_dnd "$dnd0"
}

section_K() {
  echo "-- K: screens that are windows"
  reset_session
  ipc wifi open >/dev/null; sleep 1.5
  local win; win=$(g titled "Wi-Fi")
  check K1 "the Wi-Fi screen maps as an ordinary window ($(jq -r .class <<<"$win"))" \
    bash -c "[ '$(jq .n <<<"$win")' = 1 ] && [ '$(jq -r .class <<<"$win")' = org.quickshell ]"
  check K1 "alone on its workspace, filling it" \
    is "$(jq -c .rect <<<"$win") $(g ws_windows)" "$(g usable) 1"
  check K5 "its card names the screen" \
    is "$(ipc recents list | grep -c '^mobile.wifi ')" 1

  ipc bluetooth open >/dev/null; sleep 1.5
  ipc wifi open >/dev/null; sleep 1
  check K12 "summoning a running screen focuses it and opens no second window" \
    bash -c "[[ '$(g active_title)' == Wi-Fi* ]] && [ '$(g titled Wi-Fi | jq .n)' = 1 ]"

  local ws; ws=$(g ws_id)
  DX=-150 drag $MID_X $STRIP_Y 0
  DX=150 drag $MID_X $STRIP_Y 0
  check K2 "swiping off a screen and back arrives back on it" \
    bash -c "[ '$(g ws_id)' = '$ws' ] && [[ '$(g active_title)' == Wi-Fi* ]]"

  drag $MID_X $STRIP_Y -200
  if [[ "$(ipc recents list | head -1)" == mobile.wifi* ]]; then
    local cx cy; read -r cx cy _ <<<"$(ipc recents cardTarget 0)"
    drag "$cx" "$cy" -200; sleep 1
    # What it saw goes in the message: this failed twice inside the suite and
    # passed every time on its own, and "FAIL" alone said nothing about why.
    local seen; seen="$(ipc wifi state) $(g titled Wi-Fi | jq .n)"
    check K6 "flicking its card closes the screen (saw: $seen; cards: $(ipc recents list | cut -d' ' -f1 | tr '\n' ' '))" \
      is "$seen" "closed 0"
  else
    check K6 "the Wi-Fi screen's card leads" false
    ipc recents close >/dev/null
  fi
  ipc wifi open >/dev/null; sleep 1.5
  check K6 "and it opens again afterwards" is "$(ipc wifi state) $(g titled Wi-Fi | jq .n)" "open 1"
  ipc wifi quit >/dev/null; sleep 0.6

  local x y
  ipc shade open >/dev/null; sleep 0.6
  read -r x y _ <<<"$(ipc shade target wifi)"; hold "$x" "$y"
  check S6 "holding the Wi-Fi tile opens the Wi-Fi screen and puts the shade away" \
    is "$(ipc wifi state) $(ipc shade state)" "open closed"
  # The back chevron, at its window-local centre (12 + 38/2, 8 + 44/2) plus
  # where the compositor put the window -- a client never knows that itself.
  local wx wy; read -r wx wy <<<"$(g win_at Wi-Fi)"
  tap $(( wx + 31 )) $(( wy + 30 )); sleep 0.8
  check S6b "its back chevron closes it and brings the shade back" \
    is "$(ipc wifi state) $(ipc shade state)" "closed open"

  read -r x y _ <<<"$(ipc shade target bluetooth)"; hold "$x" "$y"
  check S6c "holding the Bluetooth tile opens the Bluetooth screen" \
    is "$(ipc bluetooth state) $(ipc shade state)" "open closed"
  ipc bluetooth quit >/dev/null
}

# docs/spec/settings.md. Its ids reuse gestures.md's letters, so they print
# with an `s.` in front: s.A1 is Settings' A1, not the strip's.
#
# What it activates for real is harmless and put back: a reminder set and
# cancelled, the battery flag flipped and restored, the default terminal
# written as the one it already is, and one terminal opened on a prompt and
# closed. A row that would reboot, log out, install or reconfigure the VM is
# activated only once `dryRunState` has said dry run is on.
section_settings() {
  echo "-- settings: the Settings screen"
  reset_session
  st() { ipc settings "$@"; }
  has() { [[ "$1" == *"$2"* ]]; }
  matches() { [[ "$1" =~ $2 ]]; }
  count() { awk -F'\t' "$1" <<<"$2" | grep -c .; }
  local x y rows

  ipc shade open >/dev/null; sleep 0.6
  read -r x y _ <<<"$(ipc shade target gear)"; tap "$x" "$y"; sleep 1.2
  check s.A1 "the gear opens Settings at the root and puts the shade away" \
    is "$(st state) $(st page) $(ipc shade state)" "open root closed"
  local win; win=$(g titled Settings)
  # gestures.md K, applied to Settings, so no `s.`: settings.md's K is audio.
  check K1 "Settings maps as an ordinary window, alone on its workspace, filling it" \
    is "$(jq -r .class <<<"$win") $(jq -c .rect <<<"$win") $(g ws_windows)" \
       "org.quickshell $(g usable) 1"
  check K5 "its card names the screen" is "$(ipc recents list | grep -c '^mobile.settings')" 1

  # gestures.md I1a. One pixel of the screen's last row, left of the pill,
  # against the colour the shell says it painted there. At the output's own
  # scale: `grim -s 1` resamples, and on the screen's edge row its filter
  # blends in what lies beyond the edge -- the wallpaper read #2a2263 at y=715
  # and #261e59 at y=719. The last device pixel of the block is the true one.
  px() { g sh "grim -g '$1 1x1' -t ppm - | tail -c 3 | od -An -tx1 | tr -d ' \n'"; }
  # The screen's last row: STRIP_Y is the band's middle, 710 of 720.
  local last=$(( STRIP_Y + 9 )) geo fill sws
  geo=$(ipc gestures geometry); fill=$(grep -o 'fill=#[0-9a-f]*' <<<"$geo")
  check I1a "behind Settings the strip's band is the theme's background, not the wallpaper" \
    is "$(grep -o 'band=[01]' <<<"$geo") fill=#$(px 10,$last)" "band=1 $fill"
  sws=$(g ws_id); g focus_ws empty; sleep 0.8
  check I1a "on a home screen it is the wallpaper again" \
    bash -c "[ '$(ipc gestures geometry | grep -o 'band=[01]')' = band=0 ] && [ 'fill=#$(px 10,$last)' != '$fill' ]"
  g focus_ws "$sws"; sleep 0.8

  # A real tap on a row, aimed with `rowTarget` plus where Hyprland put the
  # window -- the path a finger takes, where every other check here takes IPC.
  local wx wy; read -r wx wy <<<"$(g win_at Settings)"
  read -r x y <<<"$(st rowTarget appearance)"
  tap $(( wx + x )) $(( wy + y )); sleep 1.2
  check s.B1 "tapping a nav row pushes exactly its page" \
    is "$(st page) $(st stack | grep -c .)" "appearance 2"
  # The chevron at its window-local centre (12 + 38/2, 8 + 44/2), as K's
  # Wi-Fi check aims it.
  tap $(( wx + 31 )) $(( wy + 30 )); sleep 1
  check s.B2 "and the header chevron pops it" is "$(st page)" root

  st quit >/dev/null; sleep 0.6
  ipc shade open >/dev/null; sleep 0.6
  read -r x y _ <<<"$(ipc shade target power)"; tap "$x" "$y"; sleep 1.2
  check s.A3 "the power glyph opens Settings at Power, not the Omarchy menu" \
    is "$(st page) $(g menu_mapped)" "system.power 0"
  check s.B2 "back walks up from a deep link and closes at the root" \
    is "$(st back) $(st back) $(st back)" "system root closed"
  sleep 0.6

  # A real tap on the drawer's tile, found by name as H4 finds Foot's. Exact,
  # so "Print Settings" is not it.
  ipc drawer open >/dev/null; sleep 0.5
  local i t target=""
  for i in $(seq 0 40); do
    t=$(ipc drawer cellTarget "$i")
    [ "$t" = none ] && break
    [ "${t#* * }" = Settings ] && { target=$t; break; }
  done
  if [ -n "$target" ]; then
    read -r x y _ <<<"$target"; tap "$x" "$y"
    wait_for "ipc settings state" open
  fi
  check s.A8 "the drawer has a Settings tile, and a tap on it opens Settings at the root" \
    is "$([ -n "$target" ] && echo tile || echo no-tile) $(st state) $(st page) $(ipc drawer state)" \
       "tile open root closed"
  st quit >/dev/null; sleep 0.6

  ipc drawer open >/dev/null; sleep 0.5
  st open >/dev/null; sleep 1
  check s.A2 "opening Settings puts the drawer away" \
    is "$(ipc drawer state) $(ipc shade state) $(ipc recents state)" "closed closed closed"
  check s.A4 "openAt goes to a page by id" is "$(st openAt appearance.bar) $(st page)" "ok appearance.bar"
  check s.A4 "and refuses an unknown one" is "$(st openAt nope)" "unknown page: nope"

  g open_app sel-a
  st open >/dev/null; sleep 1
  check s.A7 "summoned from another workspace it comes back on its page, as one window" \
    is "$(g active_title | cut -c1-8) $(st page) $(ipc recents list | grep -c '^mobile.settings')" \
       "Settings appearance.bar 1"
  local ws; ws=$(g ws_id)
  DX=-150 drag $MID_X $STRIP_Y 0
  DX=150 drag $MID_X $STRIP_Y 0
  check K2 "swiped off and back, it is still there on the same page" \
    is "$(g ws_id) $(g active_title | cut -c1-8) $(st page)" "$ws Settings appearance.bar"

  st quit >/dev/null; sleep 0.6; st open >/dev/null; sleep 1
  check s.A6 "closing and reopening lands on the root" is "$(st page)" root
  st goto appearance >/dev/null; st goto appearance >/dev/null
  check s.B6 "pushing the page already on top is a no-op" \
    is "$(st stack | tr '\n' ' ')" "root appearance "

  st openAt apps.default.browser >/dev/null; sleep 1.5
  check s.B8 "a row whose guard fails is not drawn: Chromium is, Firefox is not" \
    is "$(st rows | awk -F'\t' '$1 == "chromium" || $1 == "firefox" { print $1 "=" $4 }' | tr '\n' ' ')" \
       "chromium=1 firefox=0 "
  st openAt system.power >/dev/null; sleep 1.5
  local pw; pw=$(g sh 'passwd -S "$USER" | cut -d" " -f2')
  check s.B8 "Lock is offered only with a password to unlock it (passwd -S says $pw)" \
    is "$(st rows | awk -F'\t' '$1 == "lock" { print $4 }')" "$([ "$pw" = P ] && echo 1 || echo 0)"

  st openAt tools.reminders >/dev/null; sleep 1.5
  st quit >/dev/null; sleep 0.6
  st openAt appearance.font >/dev/null; sleep 2.5
  rows=$(st rows)
  check s.B9 "a provider page opened after another paints its own rows" \
    bash -c "! grep -q 'No reminders set' <<<\"\$1\"" _ "$rows"
  local want; want=$(g sh '{ omarchy-font-list; omarchy-font-current; } | awk NF | sort -u | grep -c .')
  check s.D6 "the font page is the provider's list ($want) with the font in use ticked" \
    is "$(grep -c . <<<"$rows") $(count '$5 == 1' "$rows")" "$want 1"

  st openAt net.dns >/dev/null; sleep 1.5
  local dns; dns=$(g sh omarchy-dns)
  check s.D1 "exactly one DNS row is ticked, the one omarchy-dns names ($dns)" \
    is "$(count '$5 == 1' "$(st rows)") $(st value net.dns)" "1 $dns"
  st back >/dev/null; sleep 1.5
  check s.D5 "the row that opens it shows the same value" \
    is "$(st rows | awk -F'\t' '$1 == "dns" { print $6 }')" "$dns"

  st openAt appearance.theme >/dev/null; sleep 2.5
  check s.D1 "one theme is ticked, the one omarchy-theme-current names" \
    is "$(st rows | awk -F'\t' '$5 == 1 { print $3 }')" "$(g sh omarchy-theme-current)"
  st openAt appearance.background >/dev/null; sleep 2.5
  check s.D7 "one wallpaper is ticked, and the reader is the path the rows carry" \
    is "$(count '$5 == 1' "$(st rows)") $(st value appearance.background)" \
       "1 $(g sh 'readlink -f "$HOME/.local/state/omarchy/current/background"')"

  st openAt apps.default.terminal >/dev/null; sleep 1.5
  if [ "$(g sh omarchy-default-terminal)" = foot ]; then
    st set foot x >/dev/null; sleep 2
    check s.D4 "a choice written through the page moves the tick to what the reader says" \
      is "$(st value apps.default.terminal) $(st rows | awk -F'\t' '$5 == 1 { print $1 }')" "foot foot"
  else
    skip s.D4 "the default terminal is not foot, and this suite does not change it"
  fi

  local pct0; pct0=$(g sh 'omarchy-toggle-enabled battery-percentage-off && echo off || echo on')
  st openAt appearance.bar >/dev/null; sleep 1.2
  g sh 'omarchy-toggle battery-percentage-off on' >/dev/null
  st refresh >/dev/null; sleep 1.5
  check s.C2 "a present negative-polarity flag reads as the switch off" is "$(st value battery)" off
  st set battery on >/dev/null; sleep 2
  check s.C3 "setting it re-reads it, and the flag file is gone" \
    is "$(st value battery) $(g sh 'omarchy-toggle-enabled battery-percentage-off && echo present || echo absent')" \
       "on absent"
  check s.C4 "and the bar hears of it ($(ipc bar metrics | grep -o 'pct=[a-z]*'))" has "$(ipc bar metrics)" "pct=on"
  st set battery off >/dev/null; sleep 2
  check s.C4 "both ways ($(ipc bar metrics | grep -o 'pct=[a-z]*'))" has "$(ipc bar metrics)" "pct=off"
  [ "$pct0" = on ] && { st set battery on >/dev/null; sleep 1.5; }

  st openAt display >/dev/null; sleep 1.5
  check s.C1 "Stay awake reads its reader" is "$(st value stayawake)" \
    "$([ "$(g sh 'omarchy-toggle-idle status | jq -r .enabled')" = true ] && echo on || echo off)"
  st openAt security >/dev/null; sleep 1.5
  check s.C8 "Remote access reads systemctl" is "$(st value ssh)" \
    "$(g sh 'systemctl is-enabled --quiet sshd && echo on || echo off')"
  check s.O15 "Authorize SSH keys says how many keys are authorized" \
    is "$(st rows | awk -F'\t' '$1 == "sshkeys" { print $6 }')" \
       "$(g sh 'echo "$(grep -c "^[a-z]" "$HOME/.ssh/authorized_keys" 2>/dev/null || echo 0) authorized"')"

  st dryRun 1 >/dev/null
  check s.E1 "dry run reads back as on before anything is activated under it" is "$(st dryRunState)" 1
  if [ "$(st dryRunState)" = 1 ]; then
    st openAt tools >/dev/null; sleep 1.2
    local n0; n0=$(g nwin)
    st activate emoji >/dev/null; sleep 0.6
    check s.E1 "a bridged row records upstream's command and runs nothing" \
      is "$(st lastLaunch) $(g nwin)" "omarchy-menu-emoji $n0"
    st activate screenshot >/dev/null
    check s.E1 "Screenshot takes the whole screen" is "$(st lastLaunch)" "omarchy-capture-screenshot fullscreen"
    st openAt system.power >/dev/null; sleep 1.2
    st activate reboot >/dev/null
    local asked; asked=$(st confirmText)
    st confirm >/dev/null
    check s.E1 "Restart asks first, and Continue runs upstream's reboot" \
      is "${asked:+asked} $(st lastLaunch)" "asked omarchy-system-reboot"
  fi
  st dryRun 0 >/dev/null

  st openAt apps.webapps >/dev/null; sleep 1.2
  local feet0 n1 p new=()
  feet0=" $(g pids foot) "; n1=$(g nwin)
  st activate add >/dev/null
  for _ in $(seq 1 25); do [ "$(g nwin)" -gt "$n1" ] && break; sleep 0.2; done
  check s.E6 "a bridged row opens its terminal, and Settings keeps running beside it" \
    is "$(( $(g nwin) - n1 )) $(st state) $(ipc recents list | grep -c '^mobile.settings')" "1 open 1"
  for p in $(g pids foot); do [[ "$feet0" == *" $p "* ]] || new+=("$p"); done
  [ ${#new[@]} -gt 0 ] && g kill_pids "${new[@]}"

  local r0; r0=$(g sh 'omarchy-mobile-reminders count')
  st openAt tools.reminders.new >/dev/null; sleep 1
  check s.J8 "Set reminder is inert until a duration is typed" \
    is "$(st rows | awk -F'\t' '$1 == "custom" { print $7 }') $(st activate custom)" "0 not ready"
  st set message 'selftest reminder' >/dev/null
  st set minutes 7 >/dev/null
  st activate custom >/dev/null; sleep 3
  rows=$(st rows)
  check s.J3 "a reminder set here is on the list the Set screen returns to" \
    is "$(st page) $(count '$3 == "selftest reminder"' "$rows")" "tools.reminders 1"
  local rid; rid=$(awk -F'\t' '$3 == "selftest reminder" { print $1; exit }' <<<"$rows")
  if [ -n "$rid" ]; then
    st activate "$rid" >/dev/null
    local q; q=$(st confirmText)
    check s.J4 "tapping it asks before cancelling it, and the timer is still there" \
      is "${q:+asked} $(g sh 'omarchy-mobile-reminders count')" "asked $(( r0 + 1 ))"
    st confirm >/dev/null; sleep 2.5
    check s.J4 "and Continue cancels it" is "$(g sh 'omarchy-mobile-reminders count')" "$r0"
  fi
  st goto tools.reminders.new >/dev/null; sleep 0.5
  check s.J12 "the Set screen starts empty when it is come back to" is "$(st value message)" ""

  st openAt sound.output >/dev/null; sleep 2
  rows=$(st rows)
  check s.K2 "one output row per sink, with the default ticked" \
    is "$(count '$2 == "choice"' "$rows") $(count '$5 == 1' "$rows")" \
       "$(g sh 'pactl list short sinks | grep -c .') 1"

  st openAt system.time.zone.Europe >/dev/null; sleep 2.5
  rows=$(st rows)
  local tz; tz=$(g sh 'timedatectl show -p Timezone --value')
  check s.L1 "a region lists as many cities as timedatectl has" \
    is "$(grep -c . <<<"$rows")" "$(g sh "timedatectl list-timezones | grep -c '^Europe/'")"
  check s.L2 "a city row is labelled by its city" is "$(count '$3 == "Berlin"' "$rows")" 1
  check s.L3 "the zone in use ($tz) is ticked only on its own region" \
    is "$(count '$5 == 1' "$rows")" "$([[ $tz == Europe/* ]] && echo 1 || echo 0)"
  st openAt system.time.zone >/dev/null; sleep 1.5
  check s.L4 "UTC is a choice row, not a region" \
    is "$(st rows | awk -F'\t' '$1 == "utc" { print $2 }')" choice

  st openAt shell.plugins >/dev/null; sleep 3
  rows=$(st rows)
  check s.M1 "one switch per plugin the shell can turn off" \
    is "$(count '$2 == "switch"' "$rows")" \
       "$(g sh "omarchy-shell shell listPlugins | jq '[.[] | select(.canDisable)] | length'")"
  check s.M2 "and none for the phone UI or the desktop bar" \
    is "$(count '$1 == "p-mobile.shell" || $1 == "p-omarchy.bar"' "$rows")" 0
  st back >/dev/null; sleep 1.5
  check s.M5 "the Plugins row says how many are on" \
    matches "$(st rows | awk -F'\t' '$1 == "plugins" { print $6 }')" '^[0-9]+ of [0-9]+ on$'

  st openAt about.omarchy >/dev/null; sleep 3
  rows=$(st rows)
  check s.N2 "every row on About Omarchy has a value" is "$(count '$6 == ""' "$rows")" 0
  check s.N3 "and it names both Omarchy and omarchy-mobile" \
    is "$(count '$3 == "Omarchy" || $3 == "omarchy-mobile"' "$rows")" 2

  # One guest call for the whole tree, not fifty-odd.
  local radios; radios=$(g sh 'for p in $(omarchy-shell settings pages); do omarchy-shell settings rowsOn "$p"; done' |
    awk -F'\t' '$2 == "switch" && tolower($3) ~ /^(wi-?fi|bluetooth|airplane|brightness|volume|silent|torch|rotate)/' | grep -c .)
  check s.H1 "no switch anywhere in Settings repeats a shade control" is "$radios" 0

  st openAt appearance >/dev/null; sleep 1
  drag $MID_X $STRIP_Y -200
  if [[ "$(ipc recents list | head -1)" == mobile.settings* ]]; then
    local cx cy; read -r cx cy _ <<<"$(ipc recents cardTarget 0)"
    drag "$cx" "$cy" -200; sleep 1
    check K6 "flicking its card closes Settings" is "$(st state) $(g titled Settings | jq .n)" "closed 0"
    st open >/dev/null; sleep 1
    check K6 "and it opens again at the root" is "$(st state) $(st page)" "open root"
  else
    check K6 "the Settings card leads the carousel" false
    ipc recents close >/dev/null
  fi
  st quit >/dev/null
}

SECTIONS=("$@")
[ ${#SECTIONS[@]} -gt 0 ] || SECTIONS=(W A B C D E H S K settings)
for s in "${SECTIONS[@]}"; do
  "section_$s"
done
reset_session

echo
summary="$PASSED passed"
[ "$SKIPPED" -gt 0 ] && summary="$summary, $SKIPPED skipped"
if [ ${#FAILED[@]} -eq 0 ]; then
  printf '\033[32m%s\033[0m\n' "$summary"
else
  printf '%s, \033[31m%d failed: %s\033[0m\n' "$summary" "${#FAILED[@]}" "${FAILED[*]}"
  exit 1
fi
