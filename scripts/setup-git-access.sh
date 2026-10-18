#!/bin/bash
# setup-git-access.sh — make `git clone` of this repo work on a fresh machine.
#
#   bash setup-git-access.sh [GIT_HOST]
#
# The public GitHub copy clones over HTTPS with no setup. If you instead host
# this kit as a self-contained mirror on your own git server, a new machine
# needs two things, and each fails with a different (and easily-misread) error:
#
#   1. the host's SSH host key pinned, or git dies with
#          Host key verification failed
#   2. an SSH key authorized on that host, or git dies with
#          Permission denied (publickey)
#
# This script handles (1), creates a key for (2), and tells you exactly what to
# paste on the git host to finish (2).
#
set -uo pipefail

# --- defaults: your own git server (no internal values baked in) -----------
GIT_HOST="${1:?usage: $0 GIT_HOST [GIT_USER] [GIT_PATH]}"
GIT_USER="${2:-${GIT_USER:-git}}"
GIT_PATH="${3:-${GIT_PATH:-hermes-i386.git}}"

echo "hermes-i386 git access setup"
echo "  target: $GIT_USER@$GIT_HOST:$GIT_PATH"
echo

# --- 1. pin the host key ----------------------------------------------------
echo "=== host key ==="
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/known_hosts && chmod 600 ~/.ssh/known_hosts

if ssh-keygen -F "$GIT_HOST" >/dev/null 2>&1; then
    echo "  $GIT_HOST already pinned"
elif ssh-keyscan -H "$GIT_HOST" >> ~/.ssh/known_hosts 2>/dev/null \
     && ssh-keygen -F "$GIT_HOST" >/dev/null 2>&1; then
    echo "  pinned $GIT_HOST"
else
    echo "  WARNING: could not fetch the host key for $GIT_HOST"
    echo "           (is it reachable? otherwise copy its /etc/ssh/ssh_host_*_key.pub)"
fi

# --- 2. ensure a client key exists -----------------------------------------
echo
echo "=== client key ==="
KEY=""
for k in id_ed25519 id_rsa; do
    [ -f "$HOME/.ssh/$k" ] && KEY="$HOME/.ssh/$k" && break
done

if [ -z "$KEY" ]; then
    ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" \
        -C "hermes-i386@$(hostname 2>/dev/null || echo unknown)" >/dev/null 2>&1
    KEY="$HOME/.ssh/id_ed25519"
    echo "  generated $KEY"
else
    echo "  using existing $KEY"
fi

# --- 3. connectivity --------------------------------------------------------
echo
echo "=== connectivity ==="
if ssh -o BatchMode=yes -o ConnectTimeout=8 "$GIT_USER@$GIT_HOST" true 2>/dev/null; then
    echo "  authorized — clone with:"
    echo "    git clone $GIT_USER@$GIT_HOST:$GIT_PATH"
else
    echo "  not authorized yet. Append this public key to"
    echo "    $GIT_USER@$GIT_HOST:~/.ssh/authorized_keys"
    echo
    sed 's/^/    /' "${KEY}.pub"
    echo
    echo "  From a machine that already has access:"
    echo "    ssh $GIT_USER@$GIT_HOST \"echo '\$(cat ${KEY}.pub)' >> ~/.ssh/authorized_keys\""
    echo
    echo "  Then re-run this script, or go straight to:"
    echo "    git clone $GIT_USER@$GIT_HOST:$GIT_PATH"
fi
