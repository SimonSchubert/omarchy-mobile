#!/usr/bin/env bash
# Take turns at the VM: one session drives it at a time.
#
#   ./scripts/vm-lease.sh                 who holds the VM, for what, since when
#   ./scripts/vm-lease.sh take [what]     hold it across the commands to come
#   ./scripts/vm-lease.sh drop            hand it back
#   ./scripts/vm-lease.sh wait            block until it is free, then take it
#   ./scripts/vm-lease.sh take --force    take it from a holder that is still up
#
# There is one VM, with one pointer, one shell and one overlay, and two sessions
# sharing it test each other's work: one pushes its QML while the other's
# selftest is mid-drag, and the second reads a sheet the first left half open.
# So vm-push, vm-selftest, vm-drag and vm-screenshot take the lease themselves,
# and while somebody else holds it they refuse and say who. vm-ssh does not:
# looking is harmless, and a command that changes the guest through it should
# `take` first.
#
# The holder is a process, not a command -- the Claude Code session
# ($CLAUDE_PID) or the terminal's shell -- so what one command takes, the next
# one from the same place still holds. It lapses when that process exits, or
# after VM_LEASE_IDLE seconds (default 900) with no VM command, so a session
# parked on a question does not keep the VM from everybody else.
#
# Whoever takes the VM over is told when the guest's overlay came from another
# tree: until it pushes its own, it is testing somebody else's QML.
#
# macOS only, like the VM: lockf(1), and BSD date and ps.

_lease_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$_lease_root/scripts/manifest.sh"

# In /tmp and keyed on the port, not under the repo: a worktree is another
# checkout driving the same VM, and it has to find the same lease.
_lease_port=$(manifest_get vm ssh_port) || exit 1
LEASE_FILE=/tmp/omarchy-mobile-vm-$_lease_port.lease
LEASE_PUSHED=/tmp/omarchy-mobile-vm-$_lease_port.pushed
LEASE_IDLE=${VM_LEASE_IDLE:-900}

_lease_field() { [ -f "$1" ] || return 0; sed -n "s/^$2=//p" "$1" | head -n1; }

_lease_clock() {
  if [ "$(date -r "$1" +%F)" = "$(date +%F)" ]; then date -r "$1" +%H:%M
  else date -r "$1" '+%b %d %H:%M'; fi
}

# A process's start time, ps's padding squeezed out. The pid alone does not
# name the holder: pids are reused, and a lease whose session has exited must
# not pass to whatever got its number next.
_lease_started() { { ps -o lstart= -p "$1" 2>/dev/null || true; } | tr -s ' ' | sed 's/^ //; s/ $//'; }

# Who is asking. Exported, so the vm-drag.sh a selftest runs asks as the
# selftest's holder, not as a stranger whose parent is a script.
_lease_me() {
  [ -n "${VM_LEASE_STARTED:-}" ] && return 0
  VM_LEASE_PID=${VM_LEASE_PID:-${CLAUDE_PID:-$PPID}}
  VM_LEASE_STARTED=$(_lease_started "$VM_LEASE_PID")
  local sid=${CLAUDE_CODE_SESSION_ID:-} tty tree=$_lease_root branch
  if [ "$VM_LEASE_PID" = "${CLAUDE_PID:-}" ]; then
    if [ -n "$sid" ]; then VM_LEASE_WHO="Claude session ${sid:0:8}"
    else VM_LEASE_WHO="Claude Code (pid $VM_LEASE_PID)"; fi
  else
    tty=$({ ps -o tty= -p "$VM_LEASE_PID" 2>/dev/null || true; } | tr -d ' ')
    case $tty in
      ''|'??') VM_LEASE_WHO="pid $VM_LEASE_PID" ;;
      *)       VM_LEASE_WHO="the terminal on $tty" ;;
    esac
  fi
  case $tree in "$HOME"/*) tree="~${tree#"$HOME"}" ;; esac
  branch=$(git -C "$_lease_root" branch --show-current 2>/dev/null || true)
  VM_LEASE_TREE="$tree${branch:+ ($branch)}"
  export VM_LEASE_PID VM_LEASE_STARTED VM_LEASE_WHO VM_LEASE_TREE
}

# free or mine or theirs; or gone (its holder exited) or idle (it lapsed),
# which anybody may take.
_lease_state() {
  [ -f "$LEASE_FILE" ] || { echo free; return; }
  local pid started used
  pid=$(_lease_field "$LEASE_FILE" pid)
  started=$(_lease_field "$LEASE_FILE" started)
  used=$(_lease_field "$LEASE_FILE" used)
  if [ "$pid" = "$VM_LEASE_PID" ] && [ "$started" = "$VM_LEASE_STARTED" ]; then echo mine
  elif [ -z "$started" ] || [ "$(_lease_started "$pid")" != "$started" ]; then echo gone
  elif [ $(( $(date +%s) - ${used:-0} )) -ge "$LEASE_IDLE" ]; then echo idle
  else echo theirs
  fi
}

_lease_describe() {
  local used; used=$(_lease_field "$LEASE_FILE" used)
  echo "the VM is $(_lease_field "$LEASE_FILE" who)'s, in $(_lease_field "$LEASE_FILE" tree)," \
       "since $(_lease_clock "$(_lease_field "$LEASE_FILE" since)")"
  echo "   last ran $(_lease_field "$LEASE_FILE" what) at $(_lease_clock "$used");" \
       "it lapses at $(_lease_clock $(( used + LEASE_IDLE ))) unless it runs another"
}

_lease_write() {
  {
    echo "pid=$VM_LEASE_PID"
    echo "started=$VM_LEASE_STARTED"
    echo "who=$VM_LEASE_WHO"
    echo "tree=$VM_LEASE_TREE"
    echo "what=$1"
    echo "since=$2"
    echo "used=$(date +%s)"
  } >"$LEASE_FILE.new" && mv -f "$LEASE_FILE.new" "$LEASE_FILE"
}

# The read and the rewrite, under lockf(1), so two sessions cannot both find
# the lease free and both take it. Prints the state it found, then the previous
# holder; on a refusal, who holds it, and fails.
_lease_op() {
  local op=$1 force=$2 state since prev=""
  shift 2
  state=$(_lease_state)
  if [ "$state" = theirs ] && [ "$force" = 0 ]; then _lease_describe; return 1; fi
  case $state in gone|idle|theirs) prev=$(_lease_field "$LEASE_FILE" who) ;; esac
  case $op in
    take)
      since=$(date +%s)
      [ "$state" = mine ] && since=$(_lease_field "$LEASE_FILE" since)
      _lease_write "$*" "$since" ;;
    drop)
      rm -f "$LEASE_FILE" ;;
  esac
  echo "$state $prev"
}
# Through bash, not exec'd: lockf execs its command, and a checkout that lost
# the execute bit locked every VM script out with "Permission denied".
_lease_locked() {
  lockf -k -t 30 "$LEASE_FILE.lock" bash "$_lease_root/scripts/vm-lease.sh" _locked "$@"
}

# The guest keeps the last overlay pushed into it, whoever pushed it.
_lease_overlay_check() {
  local tree; tree=$(_lease_field "$LEASE_PUSHED" tree)
  if [ -n "$tree" ] && [ "$tree" != "$VM_LEASE_TREE" ]; then
    printf '\033[33m!! the guest runs what %s pushed from %s at %s, not this tree -- ./scripts/vm-push.sh before trusting a result\033[0m\n' \
      "$(_lease_field "$LEASE_PUSHED" who)" "$tree" "$(_lease_clock "$(_lease_field "$LEASE_PUSHED" at)")" >&2
  fi
  return 0
}

# lease_take [--force] [--pushing] <what> -- hold the VM for what runs next, or
# say who does and fail. VM_LEASE_WAIT=<seconds> waits that long for it first.
# --pushing is vm-push.sh, which needs no warning about the overlay it is about
# to replace.
lease_take() {
  local force=0 pushing=0
  while :; do
    case ${1:-} in
      --force)   force=1; shift ;;
      --pushing) pushing=1; shift ;;
      *) break ;;
    esac
  done
  _lease_me
  local out said=0 deadline=$(( $(date +%s) + ${VM_LEASE_WAIT:-0} ))
  until out=$(_lease_locked take "$force" "$*"); do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      printf '\033[31m!! %s\033[0m\n' "${out:-could not lock $LEASE_FILE.lock}" >&2
      echo "   ./scripts/vm-lease.sh wait   waits for it and takes it; from Claude Code, run it in the background" >&2
      return 1
    fi
    [ "$said" = 1 ] || { echo "waiting for the VM -- ${out%%$'\n'*}" >&2; said=1; }
    sleep 5
  done
  local state=${out%% *} prev=${out#* }
  case $state in
    gone)   echo "took the VM: $prev had it, and has exited" >&2 ;;
    idle)   echo "took the VM: $prev had it, and has not used it for $(( LEASE_IDLE / 60 )) minutes" >&2 ;;
    theirs) echo "took the VM from $prev, who still had it" >&2 ;;
  esac
  [ "$pushing" = 1 ] || [ "$state" = mine ] || _lease_overlay_check
  return 0
}

lease_drop() {
  local force=0 out
  [ "${1:-}" = --force ] && force=1
  _lease_me
  if ! out=$(_lease_locked drop "$force"); then
    printf '\033[31m!! %s\033[0m\n' "${out:-could not lock $LEASE_FILE.lock}" >&2
    return 1
  fi
  echo "the VM is free"
}

# Called by vm-push.sh: whose overlay the guest runs from now on.
lease_pushed() {
  { echo "tree=$VM_LEASE_TREE"; echo "who=$VM_LEASE_WHO"; echo "at=$(date +%s)"; } \
    >"$LEASE_PUSHED.new" && mv -f "$LEASE_PUSHED.new" "$LEASE_PUSHED"
}

lease_status() {
  _lease_me
  case $(_lease_state) in
    free)      echo "the VM is free" ;;
    gone|idle) echo "the VM is free: $(_lease_field "$LEASE_FILE" who)'s lease has lapsed" ;;
    mine)      echo "the VM is yours, since $(_lease_clock "$(_lease_field "$LEASE_FILE" since)")" \
                    "-- ./scripts/vm-lease.sh drop when you are done with it" ;;
    theirs)    _lease_describe ;;
  esac
  local at; at=$(_lease_field "$LEASE_PUSHED" at)
  if [ -n "$at" ]; then
    echo "the guest runs what $(_lease_field "$LEASE_PUSHED" who) pushed from" \
         "$(_lease_field "$LEASE_PUSHED" tree) at $(_lease_clock "$at")"
  fi
  return 0
}

# Sourced, this file is the functions above. Run, it is the command.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
set -euo pipefail

case ${1:-status} in
  status)  lease_status ;;
  take)    shift
           if [ "${1:-}" = --force ]; then shift; lease_take --force "${*:-vm-lease.sh take}"
           else lease_take "${*:-vm-lease.sh take}"; fi
           echo "the VM is yours" ;;
  drop)    shift; lease_drop "$@" ;;
  wait)    VM_LEASE_WAIT=${VM_LEASE_WAIT:-86400}
           lease_take "vm-lease.sh wait"
           echo "the VM is yours" ;;
  _locked) shift; _lease_op "$@" ;;
  -h|--help) sed -n '2,8p' "$0" ;;
  *) echo "usage: $0 [status | take [--force] [what] | drop [--force] | wait]" >&2; exit 2 ;;
esac
