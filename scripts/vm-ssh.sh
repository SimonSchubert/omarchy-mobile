#!/usr/bin/env bash
# ssh into the running VM, or run one command in it.
#
#   ./scripts/vm-ssh.sh                       # interactive shell
#   ./scripts/vm-ssh.sh hyprctl monitors      # one command
#   ./scripts/vm-ssh.sh --wait                # block until it answers
#
# The guest's host key changes every time the image is rebuilt, so this uses a
# known_hosts file of its own rather than poisoning ~/.ssh/known_hosts with an
# entry for 127.0.0.1 that will be wrong tomorrow.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"
. scripts/manifest.sh

USER_NAME=$(manifest_get guest user)  || exit 1
PORT=$(manifest_get vm ssh_port)      || exit 1
KNOWN="vm/out/known_hosts"
mkdir -p vm/out

SSH_OPTS=(
  -p "$PORT"
  -o UserKnownHostsFile="$KNOWN"
  -o StrictHostKeyChecking=no
  -o LogLevel=ERROR
  -o ConnectTimeout=5
)

if [ "${1:-}" = "--wait" ]; then
  shift
  printf 'waiting for sshd on 127.0.0.1:%s' "$PORT"
  for _ in $(seq 1 120); do
    if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$USER_NAME@127.0.0.1" true 2>/dev/null; then
      printf ' up\n'; break
    fi
    printf '.'; sleep 2
  done
  echo
fi

exec ssh "${SSH_OPTS[@]}" "$USER_NAME@127.0.0.1" ${1+"$@"}
