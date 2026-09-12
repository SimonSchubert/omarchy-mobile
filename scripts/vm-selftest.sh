#!/usr/bin/env bash
# Check the mobile shell against its acceptance criteria, in the running VM.
#
#   ./scripts/vm-selftest.sh              every section
#   ./scripts/vm-selftest.sh A E S        only those (W A B C D G E H L S K settings keyboard splash apps agent)
#
# The whole suite is ~10 minutes on a windowed VM. Run the sections a change
# can reach, not all of them:
#
#   hypr/mobile.lua                                  W
#   EdgeGestures.qml                                 A B C D G, and S (S0, A8)
#   Carousel.qml                                     A E K
#   AppDrawer.qml                                    D H L splash, and A B
#                                                      (A5, A7, B3)
#   Splash.qml                                       splash
#   default/usr/local/bin/omarchy-mobile-app-remove  L
#   Shade.qml, Bar.qml                               S G, and splash (Bar's
#                                                      launchOsd opt-out)
#   WifiScreen.qml, BluetoothScreen.qml              K
#   MobileAppWindow.qml                              K settings
#   SettingsScreen.qml, SettingsRow.qml,
#     Pages.js, Guards.js                            settings
#   [pkg.moarchy-keep], [pkg.moarchy-store-git],
#     49-moarchy-store.rules, `drawer launch`        apps
#   default/usr/local/bin/omarchy-mobile-agent,
#     the agent icons, [pkg.mise-bin]                agent, and settings
#                                                      (D8, F8)
#   Shell.qml, Theme.js, patches/, this file's
#     plumbing (helper, drag, close_all)             every section
#
# Veil.qml is drawn and never read back: a screenshot checks it, not this.
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
# The VM's lease, for the whole run: another session's drag or push half-way
# through fails checks that have nothing to do with the change under test.
. scripts/vm-lease.sh
lease_take "vm-selftest.sh $*" || exit 1

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
  # The on-screen keyboard: `Visible` as busctl prints it ("b true"), or
  # nothing at all when no keyboard owns sm.puri.OSK0.
  osk_visible) busctl --user get-property sm.puri.OSK0 /sm/puri/OSK0 sm.puri.OSK0 Visible 2>/dev/null ;;
  osk_set) busctl --user call sm.puri.OSK0 /sm/puri/OSK0 sm.puri.OSK0 SetVisible b "$2" >/dev/null 2>&1 ;;
  # "x y w h" of the layer surface with this namespace, as the compositor
  # placed it -- the only account of a layer surface that is not its own.
  layer) hyprctl -j layers | jq -r --arg n "$2" \
           'first(.[].levels[][] | select(.namespace == $n) | "\(.x) \(.y) \(.w) \(.h)") // ""' ;;
  # What the exclusive surfaces on the bottom edge take off every window.
  reserved_bottom) hyprctl -j monitors | jq 'first(.[]).reserved[3]' ;;
  # A terminal that takes one raw keystroke into a file and then waits, so its
  # window stays up: what the on-screen keyboard types, byte for byte.
  open_typist)
    rm -f /tmp/omarchy-mobile-typed
    setsid -f foot -a "$2" -T "$2" sh -c \
      'stty raw -echo; dd bs=1 count=1 of=/tmp/omarchy-mobile-typed 2>/dev/null; sleep 900' \
      >/dev/null 2>&1
    for _ in $(seq 1 60); do
      hyprctl -j clients | jq -e --arg c "$2" 'any(.[]; .class == $c)' >/dev/null && { sleep 0.3; exit 0; }
      sleep 0.1
    done
    echo "!! $2 never mapped" >&2; exit 1 ;;
  typed) od -An -c /tmp/omarchy-mobile-typed 2>/dev/null | tr -d ' ' ;;
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
  # W7: bindings keyed on a pointer button, which on a desktop are the drag
  # that moves a window and the drag that resizes it. Counted rather than
  # matched by description -- upstream's wording is upstream's to change, and a
  # phone has no pointer button for any binding to be worth keeping.
  drag_binds) hyprctl -j binds | jq '[.[] | select(.key | startswith("mouse:"))] | length' ;;
  transform) hyprctl -j monitors | jq 'first(.[]).transform' ;;
  rotate_back)
    read -r name mode pos scale <<<"$(hyprctl -j monitors | jq -r 'first(.[]) |
      "\(.name) \(.width)x\(.height)@\(.refreshRate) \(.x)x\(.y) \(.scale)"')"
    hyprctl eval "hl.monitor({ output = \"$name\", mode = \"$mode\", position = \"$pos\", scale = $scale, transform = 0 })" >/dev/null ;;
  # The splash lives between a tap and the window it announces, and an ssh hop
  # each way is most of that -- so the launch and the reads that prove it
  # happened share one round trip (windows.md L1, L7). The layer is polled for,
  # because a surface is mapped a frame after the shell says it is up.
  splash_launch)
    omarchy-shell drawer launch "$2" >/dev/null
    echo "state=$(omarchy-shell splash state)"
    echo "drawn=$(omarchy-shell splash drawn)"
    l=""
    for _ in $(seq 1 10); do
      l=$(hyprctl -j layers | jq -r 'first(.[].levels[][] | select(.namespace == "omarchy-mobile-splash") | "\(.x) \(.y) \(.w) \(.h)") // ""')
      [ -n "$l" ] && break
      sleep 0.1
    done
    echo "layer=$l" ;;
  # And the reads that follow the drag, in one hop for the same reason: four
  # round trips after a launch is most of the fifteen seconds the splash has to
  # live, and a check that spends them is timing the ssh, not the splash.
  splash_crossed)
    echo "shade=$(omarchy-shell shade state)"
    echo "splash=$(omarchy-shell splash state)"
    echo "classes=$(hyprctl -j clients | jq -r '[.[].class] | sort | join(",")')" ;;
  classes) hyprctl -j clients | jq -r '[.[].class] | sort | join(",")' ;;
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
    # And the on-screen keyboard, for the reason the toasts are above it. A
    # section that put a finger in a text field -- Wi-Fi's passphrase, the
    # drawer's search, a reminder's duration -- leaves it up, and its panel is
    # the bottom 224px: it covers the strip every following section drags from,
    # and it is what I1a's pixel read at the screen's last row when settings ran
    # after K rather than alone. Nothing owns sm.puri.OSK0 on an image with no
    # keyboard, so this is allowed to fail.
    busctl --user call sm.puri.OSK0 /sm/puri/OSK0 sm.puri.OSK0 \
      SetVisible b false >/dev/null 2>&1 || true
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
# For the answers that carry somebody else's prose -- pacman's dependency line
# has single quotes in it, so it cannot be pasted into a `bash -c`.
contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
# `splash drawn` answers "icon <path>", "fallback", "nothing" or "down", and L7
# is the difference between the first two and the last two.
drew_something() { case "$1" in "icon "*|fallback) return 0 ;; *) return 1 ;; esac; }

# One key out of the drawer's long-press card (L). `detail` answers in the
# script's own key<TAB>value, with `info.` and `plan.` marking which fork said
# it, and every check below wants exactly one line of that.
detail_key() { ipc drawer detail | awk -F'\t' -v k="$1" '$1 == k { print $2 }'; }
drawer_apps() { ipc drawer status | sed 's/.*apps=\([0-9]*\).*/\1/'; }
l_entry_gone() {
  g sh 'test -e ~/.local/share/applications/selftest-l.desktop && echo here || echo gone'
}

# Poll until a command prints the wanted value, for up to ~3s -- for the checks
# whose outcome arrives through an animation and then a client's own close. The
# first argument is word-split on purpose: `wait_for "g nwin" 2`.
wait_for() { local i; for i in $(seq 1 15); do [ "$($1)" = "$2" ] && return 0; sleep 0.2; done; return 1; }

# A drag trace that went through the middle, rather than a sheet that appeared
# at a threshold (A1).
#
# Counting samples is the wrong measure here, and the count this used to want --
# eight -- is one this VM cannot be relied on to reach. A sample is a rendered
# frame: the carousel leaves 13 headless and 5-9 windowed on a loaded Mac, for
# the same gesture followed just as closely, and the window stays open on this
# machine by choice. Four identical drags measured 9, 5, 6, 9 -- the criterion
# straddled by the renderer, not by the shell.
#
# What separates following from snapping is not how many positions were drawn
# but whether any position between the ends was: a snap leaves "100", a follow
# leaves "14 15 69 70 100". So: three or more samples, all travelling the one
# way, and at least one strictly inside the travel.
#
# Either direction, because half these sheets open by growing and close by
# shrinking -- the shade's pull is 0 -> 100 and its dismissal 100 -> 0, and both
# of them follow the finger.
follows_finger() {
  local -a t; read -ra t <<<"$1"
  [ "${#t[@]}" -ge 3 ] || return 1
  local n=${#t[@]} first=${t[0]} last=${t[$(( ${#t[@]} - 1 ))]}
  local v prev mid=0 dir
  if   [ "$last" -gt "$first" ]; then dir=up
  elif [ "$last" -lt "$first" ]; then dir=down
  else return 1                      # it ended where it started: it went nowhere
  fi
  prev=$first
  for v in "${t[@]}"; do
    if [ "$dir" = up ]; then [ "$v" -ge "$prev" ] || return 1
    else                     [ "$v" -le "$prev" ] || return 1
    fi
    [ "$v" -gt 0 ] && [ "$v" -lt 100 ] && mid=1
    prev=$v
  done
  [ "$mid" = 1 ]
}
# Exported: the checks that pair it with a state read call it from `bash -c`,
# which is a child and would not otherwise have it.
export -f follows_finger
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
  check W7 "no pointer drag moves or resizes a window" is "$(g drag_binds)" 0
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
  local trace; trace=$(ipc recents dragTrace)
  check A1 "the carousel follows the finger ($trace)" follows_finger "$trace"
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
  check D1 "an up-drag on the wallpaper opens the drawer ($trace)" \
    bash -c "[ '$(ipc drawer state)' = open ] && follows_finger '$trace'"
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

section_G() {
  echo "-- G: the left edge, back"
  reset_session
  # One field of an IPC line of key=value pairs, as the keyboard section does.
  kv() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p"; }

  local geom band bw bh top inset strip screen width
  geom=$(ipc gestures geometry)
  band=$(kv back "$geom"); bw=${band%x*}; bh=${band#*x}
  top=$(kv backTop "$geom"); inset=$(kv backInset "$geom")
  strip=$(kv strip "$geom"); screen=$(kv screen "$geom")
  width=$(kv edge "$geom"); width=${width%x*}

  # G8, G10. The band is an input region and not a surface, so `gestures
  # geometry` is the only place it can be read from at all: from outside, a
  # band that failed to shrink and one that is fine both answer nothing, and a
  # tap below the cut and a tap on a dead edge look identical.
  check G8 "the band is ${bw}px wide -- a settable property, not a constant" \
    bash -c "[ $bw -gt 0 ] && [ $bw -le 40 ]"
  check G10 "it stops one strip plus one keyboard panel short of the bottom ($strip + 200 = $inset)" \
    is "$inset" "$(( strip + 200 ))"
  check G10 "and the bar's band short of the top, so it is $screen - $top - $inset = $bh tall" \
    is "$bh" "$(( screen - top - inset ))"

  # In from the left edge, far enough to commit (G6). BACK_Y is the middle of
  # the band, computed from what the shell just reported rather than written
  # down: below the bar, well above the keyboard's panel, and with room above
  # and below for a drag that is meant to travel vertically. The screen clamps
  # the pointer, so a swipe aimed off the top arrives with its dy cut short --
  # measured, a 120px rise from y=66 was delivered as 66 and read as the
  # sideways swipe it was not.
  local BACK_X=5 BACK_Y=$(( top + bh / 2 ))
  back_swipe() { DX=${1:-80} drag "$BACK_X" "${2:-$BACK_Y}" 0; }

  g open_app sel-a
  g osk_set false; wait_for "g osk_visible" "b false"
  local n; n=$(g nwin)

  back_swipe 20
  check G6 "a short drag in from the edge does nothing, so brushing it never closes an app" \
    is "$(g nwin)" "$n"
  DX=80 drag "$BACK_X" "$BACK_Y" -150
  check G6 "nor does a swipe that travels further up than in -- a scroll from the edge is not a back" \
    is "$(g nwin)" "$n"

  # G10's two cuts, from the outside. Both were dead corners before they were
  # cut: the bottom one swallowed the keyboard's leftmost key column, and the
  # top one is the shade's own handle.
  back_swipe 80 $(( screen - 10 ))
  check G10 "a swipe in the bottom ${inset}px is not a back -- that band is the strip's and the keyboard's" \
    is "$(g nwin) $(ipc recents state)" "$n closed"
  back_swipe 80 $(( top / 2 ))
  check G10 "nor is one in the bar's band, which stays the shade's handle" \
    is "$(g nwin) $(ipc shade state)" "$n closed"

  # G9. Android takes both edges; this takes one, which halves what it costs
  # apps. Nothing is listening on the right, so the mirror swipe does nothing.
  DX=-80 drag $(( width - 5 )) "$BACK_Y" 0
  check G9 "only the left edge is claimed -- the mirror swipe from the right does nothing" \
    is "$(g nwin) $(ipc drawer state)" "$n closed"

  # G1, G2. The keyboard is the first rung, and it is the whole of what that
  # swipe does: this is the gesture that puts the keyboard away, so it must not
  # also take the app with it.
  g osk_set true; wait_for "g osk_visible" "b true"
  back_swipe
  check G2 "with the keyboard up, back dismisses it and changes nothing else" \
    is "$(g osk_visible) $(g nwin)" "b false $n"

  # G1's order, on the two rungs that can be on screen at once.
  ipc drawer open >/dev/null; sleep 0.5
  g osk_set true; wait_for "g osk_visible" "b true"
  back_swipe
  check G1 "the keyboard goes before the sheet standing under it" \
    is "$(g osk_visible) $(ipc drawer state)" "b false open"
  back_swipe
  check G3 "and the next back closes that sheet, leaving the app underneath alone" \
    is "$(ipc drawer state) $(g nwin)" "closed $n"

  # G3 through the shade, which is the forwarding path: the shade is on Overlay
  # too and keeps its whole input region while up, so the press lands on it and
  # it hands the band back (A8 applied to this edge).
  ipc shade open >/dev/null; sleep 0.8
  back_swipe
  check G3 "the shade forwards the band it covers, so back still closes the shade" \
    is "$(ipc shade state) $(g nwin)" "closed $n"

  # G4, G7. A close *request*, which is why firing it from a swipe is
  # acceptable at all -- an editor with unsaved work prompts rather than dies.
  g osk_set false; wait_for "g osk_visible" "b false"
  g focus_class sel-a
  local before_close; before_close=$(g nwin)
  back_swipe
  check G4 "with nothing over it, back asks the focused app to close" \
    is "$(g nwin)" "$(( before_close - 1 ))"

  # G5. Nothing focused is a bare home screen, and that is where back stops --
  # including not reaching a window left running on another workspace.
  ipc gestures swipe home >/dev/null; sleep 1
  local ws total; ws=$(g ws_id); total=$(g nwin)
  back_swipe
  check G5 "on a bare home screen back does nothing at all" \
    is "$(g nwin) $(g ws_id) $(ipc drawer state) $(ipc recents state)" "$total $ws closed closed"

  # K7, settings.md B3. Printed here rather than in K or settings because this
  # is the gesture that reaches it: the page stack is walked by back and by
  # nothing else on screen. The ordering is the whole criterion -- back inside
  # Settings must never reach G4 and close the app beside it, and back on the
  # root must not be swallowed into doing nothing.
  ipc settings open >/dev/null; sleep 1.5
  ipc settings goto appearance >/dev/null; sleep 0.6
  g osk_set false; wait_for "g osk_visible" "b false"
  local before; before=$(g nwin)
  back_swipe
  check K7 "from depth 2, back walks Settings' page stack and closes no window" \
    is "$(ipc settings page) $(ipc settings state) $(g nwin)" "root open $before"
  back_swipe
  check K7 "from the root, the same gesture closes the window" \
    is "$(ipc settings state) $(g nwin)" "closed $(( before - 1 ))"
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
  local h1; h1=$(ipc drawer dragTrace)
  check H1 "a drag down on the sheet closes it ($h1)" \
    bash -c "[ '$(ipc drawer state)' = closed ] && follows_finger '$h1'"
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
    # Surface-local, so add where the compositor put the surface.
    read -r cx cy _ <<<"$target"
    tap "$cx" $(( cy + $(g layer omarchy-mobile-drawer | cut -d' ' -f2) ))
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
  local trace; trace=$(ipc shade dragTrace)
  check S0 "a pull down the status bar opens the shade, following the finger ($trace)" \
    bash -c "[ '$(ipc shade state)' = open ] && follows_finger '$trace'"

  drag $MID_X $STRIP_Y -120
  check A8 "with the shade down, an up-swipe from the strip puts it away and opens nothing" \
    is "$(ipc shade state) $(ipc recents state) $(ipc drawer state)" "closed closed closed"

  ipc shade open >/dev/null; sleep 0.6
  drag $MID_X 640 -300 125 12
  trace=$(ipc shade dragTrace)
  check H2 "an up-drag on the scrim closes it, following the finger ($trace)" \
    bash -c "[ '$(ipc shade state)' = closed ] && follows_finger '$trace'"

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
  # Home the phone's way, through goHome. Leaving Settings for an empty
  # workspace raises the keyboard -- a text input activates as the window loses
  # focus -- and goHome is what puts it back down (F3). A bare hyprctl jump
  # leaves it up, and the pixel then reads the keyboard's own background.
  sws=$(g ws_id); ipc gestures swipe home >/dev/null; sleep 0.8
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
    # Surface-local, so add where the compositor put the surface.
    read -r x y _ <<<"$target"
    tap "$x" $(( y + $(g layer omarchy-mobile-drawer | cut -d' ' -f2) ))
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
  check s.B8 "a row whose guard fails is not drawn: GNOME Web is, Chromium and Firefox are not" \
    is "$(st rows | awk -F'\t' '$1 == "epiphany" || $1 == "chromium" || $1 == "firefox" { print $1 "=" $4 }' | tr '\n' ' ')" \
       "epiphany=1 chromium=0 firefox=0 "
  # The image ships Epiphany and names it in default/etc/skel/.config/mimeapps.list,
  # so this is one check over both: the file landed, and D3's readValue matched a
  # reader that answers a raw desktop id because omarchy-default-browser has no
  # name for Epiphany to print.
  check s.D1 "the ticked browser is the one the image ships, read through readValue" \
    is "$(st value apps.default.browser) $(st rows | awk -F'\t' '$5 == 1 { print $1 }')" \
       "org.gnome.Epiphany.desktop epiphany"
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

# The on-screen keyboard, and everything that has to make way for it: F3, I1a's
# keyboard half, I5-I5e and I6 in gestures.md, and W5's typing in windows.md.
# Reached by AppDrawer.qml, EdgeGestures.qml, Shell.qml and hypr/mobile.lua.
#
# Every one needs moarchy-keyboard running and owning sm.puri.OSK0, and each
# is a SKIP rather than a FAIL without it. It leaves the keyboard down.
section_keyboard() {
  echo "-- keyboard: moarchy-keyboard"
  reset_session
  # One field of an IPC line of key=value pairs: `kv h "$geometry"`.
  kv() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p"; }

  local osk; osk=$(g osk_visible)
  check osk "an on-screen keyboard owns sm.puri.OSK0 (${osk:-nothing})" test -n "$osk"
  if [ -z "$osk" ]; then
    local id; for id in W5 I6 I5b I1a F3 I5 I5a I5c I5d I5e; do skip "$id" "no on-screen keyboard"; done
    return
  fi

  g osk_set false; sleep 0.5
  g sh omarchy-mobile-toggle-keyboard >/dev/null; sleep 0.5
  local toggled; toggled=$(g osk_visible)
  g sh omarchy-mobile-toggle-keyboard >/dev/null; sleep 0.5
  check osk "omarchy-mobile-toggle-keyboard puts it up and takes it down" \
    is "$toggled / $(g osk_visible)" "b true / b false"

  # W5. A text field raises the keyboard with nobody asking, and a real tap on
  # a key reaches the app. A terminal gets the terminal layout: five rows of
  # 40 under the keyboard's top edge, q to p the second of them.
  g open_typist sel-kbd
  wait_for "g osk_visible" "b true"
  check W5 "a focused terminal raises the keyboard by itself" is "$(g osk_visible)" "b true"

  # I6. The pill keeps the screen's edge and the keys sit on top of it. On
  # Hyprland that is the band surface's doing -- it reserves from Bottom, which
  # is arranged before the keyboard's Top -- and without it the strip landed
  # between the app and the keys.
  local strip_at kb_at edge=$(( STRIP_Y - 10 ))
  strip_at=$(g layer omarchy-mobile-strip); kb_at=$(g layer moarchy-keyboard)
  check I6 "with the keyboard up the pill keeps the screen edge (strip $strip_at, keyboard $kb_at)" \
    is "$(cut -d' ' -f2 <<<"$strip_at") $(( $(cut -d' ' -f2 <<<"$kb_at") + 200 ))" "$edge $edge"
  check I5b "the keyboard reserves its panel on top of the band ($(g reserved_bottom))" \
    is "$(g reserved_bottom)" $(( 720 - edge + 200 ))

  local ky; ky=$(g layer moarchy-keyboard | cut -d' ' -f2)
  tap 18 $(( ky + 60 )); sleep 0.5
  check W5 "a tap on the keyboard's q types q into the terminal" is "$(g typed)" q

  # I1a, the keyboard half: the band's fill goes while the keyboard is up, and
  # comes back behind the same window when it goes down.
  local up down
  up=$(ipc gestures geometry)
  g osk_set false; wait_for "g reserved_bottom" $(( 720 - edge ))
  down=$(ipc gestures geometry)
  check I1a "the keyboard takes the band's fill away and gives it back (up kbd=$(kv kbd "$up") band=$(kv band "$up"), down kbd=$(kv kbd "$down") band=$(kv band "$down"))" \
    is "$(kv kbd "$up")$(kv band "$up") $(kv kbd "$down")$(kv band "$down")" "10 01"

  # I6. And the strip still takes a gesture over it: an up-flick goes home.
  g osk_set true; wait_for "g reserved_bottom" $(( 720 - edge + 200 ))
  drag $MID_X $STRIP_Y -300
  check I6 "with the keyboard up an up-flick from the strip still goes home" is "$(g ws_windows)" 0

  # F3, through the IPC and not a swipe, as moarchy's check is: the fault was
  # in what going home does, not in reaching it. Sampled over 3s, because one
  # late reading cannot tell "never went down" from "went down and came back".
  g focus_class sel-kbd; sleep 0.5
  g osk_set true; wait_for "g osk_visible" "b true"
  ipc gestures swipe home >/dev/null
  local f3_up=0 i
  for i in 1 2 3 4 5 6; do sleep 0.5; [ "$(g osk_visible)" = "b true" ] && f3_up=$((f3_up + 1)); done
  check F3 "going home from a terminal puts the keyboard away and it stays away ($f3_up of 6 samples up)" is "$f3_up" 0

  # And from Settings, where Hyprland raises it after the switch: a text input
  # activates as the shell's own window loses focus, with the hide already sent.
  ipc settings open >/dev/null; sleep 1.5
  g osk_set false; sleep 0.5
  ipc gestures swipe home >/dev/null
  f3_up=0
  for i in 1 2 3 4 5 6; do sleep 0.5; [ "$(g osk_visible)" = "b true" ] && f3_up=$((f3_up + 1)); done
  check F3 "going home from Settings leaves the keyboard down ($f3_up of 6 samples up)" is "$f3_up" 0
  ipc settings quit >/dev/null; sleep 0.6

  # I5, I5a. The drawer reflows above the keyboard, and its inset under the
  # strip is dropped while the field has it up. A real tap on the field, at
  # the point the drawer names in its own surface plus where the compositor
  # put that surface.
  ipc drawer open >/dev/null; sleep 0.5
  local g_down g_up sx sy dy
  g_down=$(ipc drawer geometry)
  read -r sx sy _ <<<"$(ipc drawer searchTarget)"
  dy=$(g layer omarchy-mobile-drawer | cut -d' ' -f2)
  tap "$sx" $(( dy + sy ))
  wait_for "g osk_visible" "b true"
  g_up=$(ipc drawer geometry)
  if [ "$(g osk_visible)" != "b true" ]; then
    skip I5 "the keyboard did not come up for a tap on the search field ($(ipc drawer searchTarget))"
  else
    # The grid is as tall as its apps rather than the sheet, so its end does not
    # move when the surface's bottom does, and moarchy's "gap unchanged" cannot
    # hold here. What the criterion is for can: the grid ends clear of the
    # keyboard, at least a strip above the surface's new bottom.
    check I5 "the drawer reflows above the keyboard (h $(kv h "$g_down") -> $(kv h "$g_up"), the grid ending $(kv gap "$g_up") above it)" \
      bash -c "[ $(kv h "$g_up") -lt $(kv h "$g_down") ] && [ $(kv gap "$g_up") -ge $(kv strip "$g_up") ]"
    check I5a "the inset is -strip with the keyboard down and 0 with the field up ($(kv margin "$g_down") / $(kv margin "$g_up"))" \
      is "$(kv margin "$g_down") $(kv margin "$g_up")" "-$(kv strip "$g_down") 0"
  fi

  # I5c. Closing lets go of the field, so the next open starts with the inset.
  ipc drawer close >/dev/null; sleep 0.5
  ipc drawer open >/dev/null; sleep 0.5
  local st; st=$(ipc drawer searchTarget)
  check I5c "the drawer reopens with the field let go ($(kv focused "$st"), margin $(kv margin "$(ipc drawer geometry)"))" \
    is "$(kv focused "$st") $(kv margin "$(ipc drawer geometry)")" "false -$(kv strip "$g_down")"

  # I5e. Forced up with the field untouched: the inset follows the keyboard.
  g osk_set false; wait_for "g reserved_bottom" $(( 720 - edge ))
  g osk_set true; wait_for "g reserved_bottom" $(( 720 - edge + 200 ))
  local g_e; g_e=$(ipc drawer geometry); st=$(ipc drawer searchTarget)
  check I5e "the inset follows the keyboard, not the field (focused=$(kv focused "$st") margin=$(kv margin "$g_e") kbd=$(kv kbd "$g_e"))" \
    is "$(kv focused "$st") $(kv margin "$g_e") $(kv kbd "$g_e")" "false 0 1"
  g osk_set false; ipc drawer close >/dev/null; sleep 0.5

  # I5d. Closing the drawer never raises the keyboard. The drawer over an app
  # whose terminal wants one, and a tap on the sheet so the drawer holds the
  # seat's keyboard: the close hands it back to the terminal, whose text input
  # re-enters. Read off the compositor's reservation, sampled over 3s.
  g focus_class sel-kbd; sleep 0.5
  g osk_set false; wait_for "g reserved_bottom" $(( 720 - edge ))
  ipc drawer open >/dev/null; sleep 0.5
  tap $MID_X $(( dy + 13 )); sleep 0.5
  ipc drawer close >/dev/null
  local d_up=0
  for i in 1 2 3 4 5 6; do
    sleep 0.5; [ "$(g reserved_bottom)" != $(( 720 - edge )) ] && d_up=$((d_up + 1))
  done
  check I5d "closing the drawer over a terminal leaves the keyboard down ($d_up of 6 samples up)" is "$d_up" 0

  g osk_set false
}

section_L() {
  echo "-- L: long-press on an app"
  reset_session

  # The two halves the card is made of outside this repo's QML. Checked first
  # and by name, because a guest that has neither fails every check below for
  # one reason and none of them says which.
  check L "the card's script is installed" \
    g sh 'command -v omarchy-mobile-app-remove >/dev/null'
  check L12 "and the session tier it asks is in the guest" \
    g sh 'test -s /etc/omarchy-mobile/session-packages'

  ipc drawer open >/dev/null; sleep 0.4
  # Surface-local, so every gesture below adds where the compositor put the sheet.
  local top; top=$(g layer omarchy-mobile-drawer | cut -d' ' -f2)

  # Foot's cell, found the way H4 finds it: the grid's order is the library's,
  # and neither is this file's to assume. Foot is also L12's own case, so the
  # gesture checks and the rule they lead to hold the same icon -- and it is
  # the one app here whose stray window this suite already knows how to close.
  local i t target=""
  for i in $(seq 0 40); do
    t=$(ipc drawer cellTarget "$i")
    [ "$t" = none ] && break
    [ "${t#* * }" = Foot ] && { target=$t; break; }
  done
  if [ -z "$target" ]; then
    skip L1 "Foot is not in the grid, so there is no cell to hold"
    ipc drawer close >/dev/null
    return
  fi
  local cx cy; read -r cx cy _ <<<"$target"
  cy=$(( cy + top ))

  # --- L1, L2: the gesture -------------------------------------------------
  local before pids_before; before=$(g nwin); pids_before=$(g pids foot)
  hold "$cx" "$cy"
  check L1 "a 900ms press on Foot's cell opens its card" \
    is "$(detail_key info.name)" Foot
  check L2 "and the click Qt delivers after it launches nothing" \
    is "$(g nwin) $(ipc drawer state)" "$before open"
  # --- L6: what the card says it is ----------------------------------------
  #
  # One snapshot in one round trip, rather than a `detail_key` per key. Each of
  # those is an ssh call, and a card read across five of them is a card that
  # anything driving this VM in between can close halfway through -- which is
  # what one run of this section saw.
  #
  # The id carries no `.desktop`: that is what this library's entries hold,
  # which is also why `drawer launch` strips the suffix off what it is given.
  local id kind pkg version size
  read -r id kind pkg version size <<<"$(ipc drawer detail | awk -F'\t' '
      $1 == "id" { id = $2 }
      $1 == "info.kind" { kind = $2 }
      $1 == "info.package" { pkg = $2 }
      $1 == "info.version" { version = $2 }
      $1 == "info.size" { size = $2 }
      END { print id, kind, pkg, version, size }')"
  check L6 "the card names the entry, its kind and its package" \
    is "$id $kind $pkg" "foot package foot"
  check L6 "and the version and size pacman already knows ($version, $size)" \
    bash -c "[ -n '$version' ] && [ -n '$size' ]"

  # Belt to L2's braces: a launch it caught is still a window, and this suite
  # closes only what it opened.
  local p new=()
  for p in $(g pids foot); do [[ " $pids_before " == *" $p "* ]] || new+=("$p"); done
  [ ${#new[@]} -gt 0 ] && g kill_pids "${new[@]}"

  # --- L5: back walks out one level at a time ------------------------------
  check L5 "back leaves the card and the drawer stays open" \
    is "$(ipc drawer back) $(ipc drawer state)" "grid open"
  check L5 "back again leaves the drawer" \
    is "$(ipc drawer back) $(ipc drawer state)" "closed closed"

  # --- L3: travel cancels the hold -----------------------------------------
  ipc drawer open >/dev/null; sleep 0.4
  # 1.2s downward from the same cell: longer than the 500ms hold, and every
  # pixel of it past the slop.
  drag "$cx" "$cy" 400 100 12
  check L3 "a 1.2s drag down from a cell closes the sheet and opens no card" \
    bash -c "[ '$(ipc drawer state)' = closed ] && [ -z '$(ipc drawer detail)' ] &&
             follows_finger '$(ipc drawer dragTrace)'"

  # --- L7, L8, L11, L12: what a plan may say -------------------------------
  #
  # Four cards, one per rule, every one of them read and none of them
  # confirmed. A plan is `pacman -Rs --print`: it changes nothing, which is
  # what makes it safe to ask it about the phone's own terminal.
  ipc drawer open >/dev/null; sleep 0.4

  # L7, the shape of an answer: a package nothing else needs, planned.
  check L7 "Uninstall on Clocks plans it rather than removing it" \
    is "$(ipc drawer hold org.gnome.clocks) $(ipc drawer uninstall)" "ok ok"
  wait_for "ipc drawer canRemove" yes
  local count psize
  count=$(detail_key plan.count); psize=$(detail_key plan.size)
  check L7 "and the plan says how many packages and how much ($count, $psize)" \
    bash -c "[ '$(ipc drawer canRemove)' = yes ] && [ -n '$count' ] && [ -n '$psize' ]"
  ipc drawer detailClose >/dev/null

  # L8. Files is Nautilus, and nautilus-python declares it: pacman refuses, the
  # card says so in pacman's own words, and no Remove button is drawn.
  ipc drawer hold org.gnome.Nautilus >/dev/null
  ipc drawer uninstall >/dev/null
  wait_for "ipc drawer canRemove" no
  local blocked; blocked=$(detail_key plan.blocked)
  check L8 "a package another one needs is refused, naming what refused it" \
    is "$(ipc drawer canRemove)" no
  check L8 "and the reason is pacman's line: $blocked" \
    contains nautilus-python "$blocked"
  ipc drawer detailClose >/dev/null

  # L12. Foot is in the session tier and nothing in pacman's db says so -- the
  # phone's own terminal is the case this project's half of L12 exists for.
  ipc drawer hold foot >/dev/null
  wait_for "ipc drawer canRemove" no
  check L12 "the session's own packages are refused, and refused as protected" \
    is "$(ipc drawer uninstall) $(detail_key info.protected)" "protected 1"
  ipc drawer detailClose >/dev/null

  # L11. The shell will not uninstall itself.
  ipc drawer hold org.moarchy.Keep >/dev/null
  wait_for "ipc drawer canRemove" no
  check L11 "and neither is one of this project's own packages" \
    is "$(ipc drawer uninstall) $(detail_key info.protected)" "protected 1"
  ipc drawer detailClose >/dev/null

  # --- L9, L10: the one removal this suite runs ----------------------------
  #
  # Against a launcher it wrote two seconds earlier, and never against a
  # package. `kind user` is the branch that deletes one file, so what this
  # exercises is the whole path -- hold, plan, confirm, and the grid noticing
  # -- without uninstalling anything from somebody's phone.
  g sh 'printf "[Desktop Entry]\nType=Application\nName=Selftest L\nExec=true\nIcon=utilities-terminal\n" >~/.local/share/applications/selftest-l.desktop'
  if wait_for "ipc drawer hold selftest-l" ok; then
    local apps_before; apps_before=$(drawer_apps)
    check L9 "a hold on a personal entry says what it is" \
      is "$(detail_key info.kind)" user
    ipc drawer uninstall >/dev/null
    wait_for "ipc drawer canRemove" yes
    check L7 "Uninstall says what it takes: $(detail_key plan.note)" \
      is "$(ipc drawer canRemove)" yes
    check L9 "Remove takes the launcher and closes the card" \
      bash -c "[ '$(ipc drawer removeConfirm)' = ok ] && sleep 1 &&
               [ '$(l_entry_gone)' = gone ] && [ -z '$(ipc drawer detail)' ]"
    check L10 "and the grid drops it without being reopened" \
      is "$(ipc drawer state) $(drawer_apps)" "open $(( apps_before - 1 ))"
  else
    skip L9 "the launcher this section wrote never reached the grid"
  fi
  # Whatever the checks made of it: a file left behind is an app this suite put
  # in somebody's drawer.
  g sh 'rm -f ~/.local/share/applications/selftest-l.desktop'
  ipc drawer close >/dev/null
}

# windows.md's L ids, not gestures.md's: this section prints them with a `w.`
# in front, the way the Settings checks print an `s.`, because the two specs
# reuse the same letter for the long-press card and for the launch splash.
section_splash() {
  echo "-- splash: the launching app's own icon (windows.md L)"
  reset_session

  local geom; geom=$(ipc splash geometry)
  check w.L2a "the splash is an Overlay surface, not Top ($geom)" \
    contains "layer=overlay" "$geom"
  # The screen is 360 wide; this surface is 130, with a 96px icon in it.
  local w; w=$(sed 's/.*w=\([0-9]*\).*/\1/' <<<"$geom")
  check w.L2 "sized to its icon rather than to the screen (w=$w)" \
    bash -c "[ ${w:-0} -gt 0 ] && [ ${w:-0} -lt 180 ]"
  check w.L "nothing is on the wallpaper with no launch in flight" \
    is "$(ipc splash state)" closed

  # Foot, which is the app this suite opens everywhere else and the one whose
  # windows it knows how to close again.
  local pids_before; pids_before=$(g pids foot)
  local probe; probe=$(g splash_launch foot)
  local state drawn layer
  state=$(sed -n 's/^state=//p' <<<"$probe")
  drawn=$(sed -n 's/^drawn=//p' <<<"$probe")
  layer=$(sed -n 's/^layer=//p' <<<"$probe")
  check w.L1 "a launch puts it up at once, not two seconds later" is "$state" open
  check w.L7 "and something is drawn on it ($drawn)" drew_something "$drawn"
  check w.L2 "and the compositor maps it that size, centred (${layer:-unmapped})" \
    bash -c "[ -n '$layer' ] && [ \$(cut -d' ' -f3 <<<'$layer') -lt 180 ]"

  local i
  for i in $(seq 1 50); do [ "$(g pids foot)" != "$pids_before" ] && break; sleep 0.2; done
  check w.L4 "it goes once the window has mapped" wait_for "ipc splash state" closed
  local p new=()
  for p in $(g pids foot); do [[ " $pids_before " == *" $p "* ]] || new+=("$p"); done
  [ ${#new[@]} -gt 0 ] && g kill_pids "${new[@]}"

  # L5. Settings' entry summons this shell rather than starting a process, so
  # no toplevel need appear at all -- and if its window is already up and
  # focused, none does. The screen opening is what ends the launch.
  probe=$(g splash_launch omarchy-mobile-settings)
  check w.L5 "a .desktop entry that summons a screen puts a splash up too" \
    is "$(sed -n 's/^state=//p' <<<"$probe")" open
  check w.L5 "and the screen opening takes it down, with no window to wait for" \
    wait_for "ipc splash state" closed
  ipc settings quit >/dev/null

  # L3, L6, L7 all off one launch: an id no entry answers to. The drawer asks
  # the library anyway, gtk-launch fails, and nothing ever maps -- so the
  # splash is up for the full fifteen seconds, which is both the case the
  # timeout is for and the only window long enough to drag a finger through.
  probe=$(g splash_launch selftest-nothing-at-all)
  check w.L7 "an id with no entry still gets a splash, as the outline" \
    is "$(sed -n 's/^drawn=//p' <<<"$probe")" fallback

  # The shade's drag starts at the status bar and ends past the middle of the
  # screen, which is where the splash is. On this compositor the pointer is not
  # grabbed across a layer surface's edge, so a splash with an input region
  # would take the rest of this gesture and the shade would stop where the icon
  # starts.
  #
  # "Still up afterwards" is how the drag is known to have crossed a splash
  # rather than an empty screen, so both windows lists are printed: a window
  # mapping mid-drag ends the launch for the right reason (L4) and makes this
  # check say the wrong thing, and the difference between the two lists is what
  # says which happened.
  #
  # "Was it up while the finger went through it" is asserted at the START of the
  # drag, not the end, because one drag costs longer than a splash lives: the
  # uinput device is scp'd in, created, waited on for udev and torn down again,
  # which is ~16s on this VM against the splash's 15s (L6). Read afterwards, the
  # splash is always down -- by its own timeout, on a launch nothing ever
  # answered -- and the check reported the drag as having dismissed it. It never
  # had; instrumenting finish() showed the timeout firing every time.
  #
  # So: up when the drag begins, and nothing mapped while it ran. The pointer
  # crosses the icon in the first fraction of the gesture, seconds inside the
  # fifteen, and with no window appearing there is nothing but that timeout that
  # could have taken it down -- so the finger did go through a splash that was
  # there, which is what L3 needs and all it needs.
  local wins_before; wins_before=$(g classes)
  local before; before=$(g splash_launch selftest-nothing-at-all)
  check w.L3 "the splash is up as the drag starts, so there is one to cross" \
    is "$(sed -n 's/^state=//p' <<<"$before")" open
  drag $MID_X 13 400 125 12
  local crossed; crossed=$(g splash_crossed)
  local wins_after; wins_after=$(sed -n 's/^classes=//p' <<<"$crossed")
  check w.L3 "a drag straight through the splash still reaches the shade" \
    is "$(sed -n 's/^shade=//p' <<<"$crossed")" open
  check w.L3 "and no window mapped while it ran, so nothing but its own timeout took the splash down (windows: [$wins_before] -> [$wins_after])" \
    is "$wins_after" "$wins_before"
  ipc shade close >/dev/null

  sleep 16
  check w.L6 "15 seconds with nothing mapped and it gives up, rather than sitting there" \
    is "$(ipc splash state)" closed
}

section_apps() {
  echo "-- apps: moarchy-keep and moarchy-store"
  reset_session

  local pkg
  for pkg in moarchy-keep moarchy-store-git; do
    check apps "$pkg is installed" g sh "pacman -Q $pkg >/dev/null"
  done

  # L9a. Each opens the way the store's Open opens what it installs: by bare
  # desktop id, through the drawer, which must find its own entry for it and
  # then map the app's window. Only a window this call opened is closed after
  # -- one already up is somebody's notes, and the check skips rather than
  # touch it.
  local id i
  for id in org.moarchy.Keep org.moarchy.Store; do
    if [ -n "$(g pids "$id")" ]; then
      skip L9a "$id is already open, and not this suite's to close"; continue
    fi
    check L9a "drawer launch $id finds the drawer's entry for the bare id" \
      is "$(ipc drawer launch "$id")" ok
    for i in $(seq 1 50); do [ -n "$(g pids "$id")" ] && break; sleep 0.2; done
    check apps "$id maps a window from that launch" test -n "$(g pids "$id")"
    g kill_pids $(g pids "$id")
    wait_for "g pids $id" ""
  done

  # L9, the half that is not the splash (section `splash` has that one): the
  # installed store hands Open to the shell rather than starting it through Gio.
  check L9 "the installed store's launcher.py calls 'omarchy-shell drawer launch'" \
    g sh 'grep -qF "\"drawer\", \"launch\"" "$(pacman -Qlq moarchy-store-git | grep "/launcher\.py$")"'

  # The store installs through pkexec, which cannot authenticate an account the
  # image locks. pkcheck asks polkit what pkexec will, as this user and from a
  # session with no seat, which the rule is written not to care about.
  check store "polkit grants the store's install action with no password" \
    g sh 'pkcheck --action-id org.moarchy.store.manage --process $$ >/dev/null 2>&1'
  # And what it installs has to verify: archlinuxarm-keyring, populated.
  check store "pacman in the guest trusts ALARM's build key" \
    g sh 'sudo pacman-key --list-keys builder@archlinuxarm.org 2>/dev/null | grep -q "\[ *full *\]"'
}

section_agent() {
  echo "-- agent: the coding agent tile (settings.md P)"

  # P is about two files that record somebody's choice -- the default agent and
  # the tile naming it -- and this VM is shared. Both are moved aside here and
  # put back at the end, whatever the checks do to them in between. So is
  # ~/.local/bin/claude, which P7 deliberately puts a decoy at.
  local ENTRY='~/.local/share/applications/omarchy-mobile-agent.desktop'
  g sh 'for f in ~/.config/omarchy/defaults/agent \
                 ~/.local/share/applications/omarchy-mobile-agent.desktop \
                 ~/.local/bin/claude; do
          [ -e "$f" ] && mv -f "$f" "$f.selftest-saved"
        done; true'

  local has_mise=no a
  g sh 'command -v mise >/dev/null' && has_mise=yes

  # What was in ~/.local/bin before any of this ran. The seed below writes
  # eleven wrappers, and on a shared VM they must not be left behind -- but nor
  # may a wrapper the user already had be deleted, so the two are told apart by
  # this list rather than by name.
  local bin_before
  bin_before=$(g sh 'ls ~/.local/bin 2>/dev/null | tr "\n" " "')

  # One key out of the tile. Every P below reads the file this way, and a key
  # that is not there answers empty rather than the line before it.
  entry_key() { g sh "sed -n 's/^$1=//p' $ENTRY"; }

  # --- P5: one list, checked against upstream rather than against itself -----
  # Four copies of the same thirteen names: this script's, upstream's own
  # `omarchy:args=` line, the choice rows on the page, and the icons that ship.
  # All four are compared to upstream's, so an agent upstream adds fails here
  # instead of quietly arriving with no icon.
  local ours upstream icons rows
  ours=$(g sh 'omarchy-mobile-agent list | sort | tr "\n" " "')
  upstream=$(g sh "sed -n 's/.*omarchy:args=\[\(.*\)\].*/\1/p' /usr/bin/omarchy-default-agent \
                   | tr '|' '\n' | sort | tr '\n' ' '")
  icons=$(g sh 'ls ~/.local/share/icons/hicolor/scalable/apps/omarchy-mobile-agent-*.svg 2>/dev/null \
                | sed "s|.*/omarchy-mobile-agent-||; s|\.svg$||" | sort | tr "\n" " "')
  rows=$(ipc settings rowsOn apps.default.agent | awk -F'\t' '$2 == "choice" { print $1 }' | sort | tr '\n' ' ')

  check P5 "omarchy-mobile-agent list is upstream's own agent list" is "$ours" "$upstream"
  check P5 "the choice rows on apps.default.agent are that same list" is "$rows" "$upstream"
  check P5 "one icon ships per agent, and no icon without an agent" is "$icons" "$upstream"
  # Set aside from the list above because it is the one file there that is not
  # an agent, which is exactly how it could go missing unnoticed.
  check P5 "the setup tile's own icon ships" \
    g sh 'test -f ~/.local/share/icons/hicolor/scalable/apps/omarchy-mobile-agent.svg'

  # --- P3, P10, P11: the tile before anything is picked ---------------------
  # Twice: with no defaults file at all, and with a word in it that is not an
  # agent. A tile named after whatever ended up in that file is worse than one
  # that offers the picker.
  local junk
  for junk in "" "not-an-agent"; do
    if [ -z "$junk" ]; then
      g sh 'rm -f ~/.config/omarchy/defaults/agent'
    else
      g sh 'mkdir -p ~/.config/omarchy/defaults; echo not-an-agent >~/.config/omarchy/defaults/agent'
    fi
    g sh 'omarchy-mobile-agent entry'
    check P3 "with ${junk:-no} defaults/agent the tile is the setup tile" \
      is "$(entry_key Name)" "AI Agent"
    check P3 "and it says so in X-Omarchy-Mobile-Agent" \
      is "$(entry_key X-Omarchy-Mobile-Agent)" none
  done

  # P10. The Exec is the IPC the plugin entries already use to raise a shell
  # surface, and it is checked by running it rather than by reading it: the
  # string being right and the page existing are two different claims.
  check P10 "the setup tile opens the picker rather than installing anything" \
    is "$(entry_key Exec)" "omarchy-shell settings openAt apps.default.agent"
  check P10 "running that Exec answers ok" is "$(ipc settings openAt apps.default.agent)" ok
  check P10 "and leaves Settings on the page that lists the thirteen" \
    is "$(ipc settings page)" apps.default.agent
  check P10 "with all thirteen choice rows drawn" \
    is "$(ipc settings rows | awk -F'\t' '$2 == "choice" && $4 == "1"' | wc -l | tr -d ' ')" 13
  ipc settings close >/dev/null

  # P11, and the whole reason this section exists. Searching the drawer for
  # "agent" answered nothing at all before the tile: no entry matched, and the
  # settings row that would have matched is guarded on mise, which the drawer
  # honours (O7). Both halves are checked -- the word for the category, and the
  # name of an agent nobody has installed.
  # Read once and compared here rather than looped over in the guest: every
  # command `g` sends crosses three parsers (printf %q, the login shell ssh
  # hands it to, and the helper's own `bash -lc`), and a loop with a `$a` and a
  # quoted pattern in it is where that silently starts testing something else.
  local keywords missing="" q
  keywords=$(entry_key Keywords)
  for q in $(g sh 'omarchy-mobile-agent list'); do
    case ";$keywords" in *";$q;"*) ;; *) missing="$missing $q" ;; esac
  done
  check P11 "the setup tile carries every agent name as a keyword" is "$missing" ""
  # `drawer entries` prints desktop IDS, one per line, not file names -- so the
  # match is the id exactly, `grep -x`, and not a substring of "...desktop".
  # Written the wrong way first, and all three of these failed against a drawer
  # that was in fact answering correctly.
  for q in agent claude opencode; do
    ipc drawer type "$q" >/dev/null
    check P11 "drawer type $q finds the agent tile in the grid" \
      is "$(ipc drawer entries | grep -cx omarchy-mobile-agent)" 1
  done
  ipc drawer type "" >/dev/null

  # --- P1, P2, P4: the tile once an agent is picked --------------------------
  # `entry <name>` rather than `open <name>`: open's last act is to exec
  # omarchy-default-agent, which installs an agent over the network and opens a
  # terminal on it. The tile is written by write_entry either way, and that is
  # the half P1, P2 and P4 are about.
  g sh 'omarchy-mobile-agent entry claude; omarchy-mobile-agent entry opencode'
  check P1 "two agents opened, one tile in the grid" \
    is "$(g sh 'ls ~/.local/share/applications/omarchy-mobile-agent*.desktop | xargs -n1 basename | tr "\n" " "')" \
       "omarchy-mobile-agent.desktop "
  check P2 "the tile names whichever agent was picked last" is "$(entry_key Name)" OpenCode
  check P2 "its Exec comes back through this script, not upstream's" \
    is "$(entry_key Exec)" "omarchy-mobile-agent open opencode"
  check P2 "and X-Omarchy-Mobile-Agent agrees with both" \
    is "$(entry_key X-Omarchy-Mobile-Agent)" opencode
  # P4. A themed name, which is where this port reverses moarchy -- and the
  # claim is not that the string is right but that it resolves, so the file it
  # names is what gets checked.
  check P4 "the icon is a themed name under this project's own prefix" \
    is "$(entry_key Icon)" omarchy-mobile-agent-opencode
  check P4 "and that name resolves to a file that ships" \
    g sh "test -f ~/.local/share/icons/hicolor/scalable/apps/$(entry_key Icon).svg"

  # --- P9: the default set behind this script's back -------------------------
  # The write is the one omarchy-default-agent makes -- `printf '%s\n' codex`
  # into that file -- rather than a run of it, which would install Codex. What
  # P9 is about is the repair, and the repair reads the file.
  g sh 'mkdir -p ~/.config/omarchy/defaults; echo codex >~/.config/omarchy/defaults/agent'
  check P9 "a default set behind the script's back leaves the tile stale" \
    is "$(entry_key X-Omarchy-Mobile-Agent)" opencode
  g sh 'omarchy-mobile-agent entry'
  check P9 "and entry with no argument repairs it from the file" \
    is "$(entry_key X-Omarchy-Mobile-Agent)" codex

  # --- P6, P7, P8: the wrappers ---------------------------------------------
  if [ "$has_mise" = no ]; then
    # Not a failure: the wrapper's whole body is a mise call, so writing one on
    # an image without mise puts names on PATH that cannot run and makes
    # omarchy-cmd-present lie. The tile is still written, and that is the half
    # that matters most on an image with no installer.
    skip P6 "no mise in this image, so no wrapper is written -- by design"
    skip P7 "needs mise: without it write_shim returns before it reads the file"
    skip P8 "needs mise: nothing is written for any agent, Hermes included"
    g sh 'omarchy-mobile-agent seed' >/dev/null
    check P6 "seed still writes the tile on an image with no mise" \
      g sh "test -f $ENTRY"
    # `ls` of the one directory, intersected here: same reason as P11 above.
    local present="" onpath
    onpath=$(g sh 'ls ~/.local/bin 2>/dev/null')
    for a in $(g sh 'omarchy-mobile-agent list'); do
      case " $onpath " in *" $a "*) present="$present $a" ;; esac
    done
    check P6 "and writes no wrapper for any agent" is "$present" ""
  else
    # P7's decoy goes in before the seed, since the seed is what must not take
    # it. Written to look nothing like a mise wrapper, which is the only thing
    # write_shim looks at.
    g sh 'mkdir -p ~/.local/bin; printf "#!/bin/sh\necho a real claude\n" >~/.local/bin/claude; chmod +x ~/.local/bin/claude'
    g sh 'omarchy-mobile-agent seed' >/dev/null

    check P7 "a hand-placed binary in ~/.local/bin survives the seed" \
      is "$(g sh 'cat ~/.local/bin/claude')" "$(printf '#!/bin/sh\necho a real claude')"
    # P8. Neither is shimmed, and the reason is upstream's: each has an
    # installer that owns that path and treats anything foreign as the user's.
    for a in hermes openclaw; do
      check P8 "$a is left to its own installer, not shimmed" \
        g sh "test ! -e ~/.local/bin/$a"
    done
    # P6. Everything else, less the decoy at claude, resolves and says mise.
    # One `grep -l mise` over the directory, and the comparison here. The
    # decoy at claude is excluded because P7 is the check that it survived;
    # hermes and openclaw because P8 is the check that they were skipped.
    local wrapped expected="" a2
    # The save at the top of this section lands in the very directory this
    # greps: on a guest that has seeded once, ~/.local/bin/claude is a mise
    # wrapper, and moving it aside leaves claude.selftest-saved beside the
    # eleven for the glob to find. Excluded here rather than saved elsewhere,
    # so the three files this section moves aside still move the same way.
    wrapped=$(g sh 'grep -l mise ~/.local/bin/* 2>/dev/null | grep -v "\.selftest-saved$" | xargs -n1 basename | sort | tr "\n" " "')
    for a2 in $(g sh 'omarchy-mobile-agent list | sort'); do
      case $a2 in hermes|openclaw|claude) continue ;; esac
      expected="$expected$a2 "
    done
    check P6 "every other agent name is on PATH and resolves to a mise wrapper" \
      is "$wrapped" "$expected"
  fi

  # The wrappers the seed wrote, and only those: any agent name that is in
  # ~/.local/bin now and was not there when this section started.
  local stale=""
  for a in $(g sh 'omarchy-mobile-agent list'); do
    case " $bin_before " in *" $a "*) continue ;; esac
    stale="$stale ~/.local/bin/$a"
  done
  [ -n "$stale" ] && g sh "rm -f$stale"

  # Everything back the way it was found, including the tile, which is rewritten
  # from whatever default was there before this ran rather than left on codex.
  g sh 'for f in ~/.config/omarchy/defaults/agent \
                 ~/.local/share/applications/omarchy-mobile-agent.desktop \
                 ~/.local/bin/claude; do
          rm -f "$f"
          [ -e "$f.selftest-saved" ] && mv -f "$f.selftest-saved" "$f"
        done; true'
  unset -f entry_key
}

SECTIONS=("$@")
[ ${#SECTIONS[@]} -gt 0 ] || SECTIONS=(W A B C D G E H L S K settings keyboard splash apps agent)
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
