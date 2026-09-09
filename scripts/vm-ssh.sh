#!/usr/bin/env bash
# ssh into the running VM, or run one command in it.
#
#   ./scripts/vm-ssh.sh                       # interactive shell
#   ./scripts/vm-ssh.sh hyprctl monitors      # one command
#   ./scripts/vm-ssh.sh --wait                # block until it answers
#
# The guest's host key is regenerated on every image build, and the address is
# always 127.0.0.1 on a forwarded port -- so a known_hosts entry is guaranteed
# to be stale by the next build and warns about it in the loudest possible
# terms:
#
#   Offending ED25519 key in vm/out/known_hosts:1
#   Password authentication is disabled to avoid man-in-the-middle attacks.
#
# Host key checking is therefore off entirely and the file is /dev/null. There
# is nothing to protect: the port is bound to loopback by the QEMU we started,
# and the key belongs to an image this repo built ten minutes ago. What it does
# protect is ~/.ssh/known_hosts, which never gets an entry for a 127.0.0.1 that
# means something different tomorrow.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"
. scripts/manifest.sh

USER_NAME=$(manifest_get guest user)  || exit 1
PORT=$(manifest_get vm ssh_port)      || exit 1
SSH_OPTS=(
  -p "$PORT"
  -o UserKnownHostsFile=/dev/null
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
