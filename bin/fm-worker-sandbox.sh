#!/usr/bin/env bash
# fm-worker-sandbox.sh - EXP-MF-004 P1 worker sandbox (pavani06/firstmate).
#
# Replaces the pi binary for spawns whose home has config/worker-launch-wrapper
# (see fm-spawn.sh). The wrapper prepares a bubblewrap sandbox and execs the
# real pi binary (FFM_REAL_PI_BIN, passed by fm-spawn) with the original
# arguments inside it.
#
# Env policy inside the sandbox: SSH_AUTH_SOCK/SSH_AGENT_* removed; GH_TOKEN
# minted per dispatch from the GitHub App PEM (SOPS-encrypted; decrypted via
# process substitution, plaintext never on disk); git identity and URL rewrite
# point pushes at the App installation token; PI_CODING_AGENT_DIR points at a
# per-dispatch COPY of the operator's agent auth (the original is never
# mounted). Filesystem: host read-only except the explicit rw binds.
#
# Requires FM_TASK_ID: without it this is not a worker launch and the real
# binary runs unsandboxed (the primary is outside this mechanism by design,
# decision D2 of EXP-MF-004).
#
# Required config (gitignored, LOCAL): config/worker-sandbox.env holding
#   FFM_APP_ID=<github app id>
#   FFM_INSTALLATION_ID=<installation id covering the target repo>
#   FFM_PEM_ENC=<path to the sops-encrypted app pem>
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
FM_HOME=$(cd "$SCRIPT_DIR/.." && pwd)
REAL_BIN=${FFM_REAL_PI_BIN:-}
if [ -z "$REAL_BIN" ]; then
  echo "fm-worker-sandbox: FFM_REAL_PI_BIN not set; nothing to sandbox" >&2
  exit 1
fi
if [ -z "${FM_TASK_ID:-}" ]; then
  # Not a worker launch: run unsandboxed (primary/trusted zone, D2).
  exec "$REAL_BIN" "$@"
fi

fail() { echo "fm-worker-sandbox: $*" >&2; exit 1; }
command -v bwrap >/dev/null 2>&1 || fail "bwrap missing"
command -v gh >/dev/null 2>&1 || fail "gh missing"
command -v sops >/dev/null 2>&1 || fail "sops missing"
command -v age-keygen >/dev/null 2>&1 || fail "age-keygen missing"
ENV_FILE=$FM_HOME/config/worker-sandbox.env
[ -r "$ENV_FILE" ] || fail "missing $ENV_FILE"
# shellcheck disable=SC1090
. "$ENV_FILE"
: "${FFM_APP_ID:?}" "${FFM_INSTALLATION_ID:?}" "${FFM_PEM_ENC:?}"
[ -r "$FFM_PEM_ENC" ] || fail "unreadable $FFM_PEM_ENC"

WT=$PWD
STATE=$FM_HOME/state
DATA=$FM_HOME/data
mkdir -p "$STATE/worker-sessions"

# Per-dispatch agent-auth copy (D3/m3): refreshed from the operator's agent
# dir on every launch; provider token refreshes land on this copy, never on
# the original.
AGENT_SRC=$HOME/.pi/agent
AGENT_DIR=$HOME/.config/fm-worker-agent
rm -rf "$AGENT_DIR"
mkdir -p "$AGENT_DIR"
chmod 700 "$AGENT_DIR"
for f in auth.json models.json settings.json; do
  [ -e "$AGENT_SRC/$f" ] && cp "$AGENT_SRC/$f" "$AGENT_DIR/$f"
done
chmod 600 "$AGENT_DIR"/* 2>/dev/null || true

# Dispatch-scoped installation token (lives only in this process env).
GH_TOKEN=$(gh token generate --app-id "$FFM_APP_ID" --installation-id "$FFM_INSTALLATION_ID" \
  --key <(sops -d "$FFM_PEM_ENC") --token-only) || fail "token mint failed"
[ -n "$GH_TOKEN" ] || fail "empty token"
# Installation tokens cannot call GET /user (403). The App's bot identity is
# public: login = <app-slug>[bot], id via the unauthenticated users endpoint.
BOT_LOGIN=${FFM_BOT_LOGIN:-govevo-agents[bot]}
BOT_ID=$(gh api "users/${BOT_LOGIN}" --jq .id 2>/dev/null || true)
if [ -n "$BOT_ID" ]; then
  BOT_EMAIL="${BOT_ID}+${BOT_LOGIN}@users.noreply.github.com"
else
  BOT_EMAIL="${BOT_LOGIN}@users.noreply.github.com"
fi
export GH_TOKEN
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0="url.https://x-access-token:${GH_TOKEN}@github.com/.insteadOf"
export GIT_CONFIG_VALUE_0="git@github.com:"
export GIT_CONFIG_KEY_1="user.name"
export GIT_CONFIG_VALUE_1="${BOT_LOGIN} (firstmate worker)"
export GIT_CONFIG_KEY_2="user.email"
export GIT_CONFIG_VALUE_2="$BOT_EMAIL"

# --- sandbox binds (whitelist; everything else from the ro host bind) -------
bw=()
bw+=(--ro-bind / /)
bw+=(--tmpfs /home/futanbear)          # operator home gone (creds live there)
bw+=(--tmpfs /run/user)                # ssh-agent socket gone
bw+=(--ro-bind "$HOME/.npm-global" "$HOME/.npm-global")   # pi itself lives here
if [ -d "$HOME/.pi/agent/bin" ]; then
  bw+=(--ro-bind "$HOME/.pi/agent/bin" "$HOME/.pi/agent/bin")
fi
bw+=(--bind "$AGENT_DIR" "/home/futanbear/.pi-agent")   # rw: pi cria .lock e faz refresh na cópia por dispatch (original nunca montado)
bw+=(--bind "$WT" "$WT")
bw+=(--bind "$STATE/worker-sessions" "$STATE/worker-sessions")
for f in "$STATE/$FM_TASK_ID.status" "$STATE/$FM_TASK_ID.turn-ended" \
         "$STATE/$FM_TASK_ID.busy-state" "$STATE/$FM_TASK_ID.busy-gen" \
         "$STATE/$FM_TASK_ID.pi-ext.ts"; do
  [ -e "$f" ] && bw+=(--bind "$f" "$f")
done
[ -d "$STATE/$FM_TASK_ID.inbox" ] && bw+=(--bind "$STATE/$FM_TASK_ID.inbox" "$STATE/$FM_TASK_ID.inbox")
[ -d "$DATA/$FM_TASK_ID" ] && bw+=(--bind "$DATA/$FM_TASK_ID" "$DATA/$FM_TASK_ID")
if [ -n "${GOTMPDIR:-}" ]; then
  TASK_TMP=$(dirname "$GOTMPDIR")
  [ -d "$TASK_TMP" ] && bw+=(--bind "$TASK_TMP" "$TASK_TMP")
fi
bw+=(--proc /proc --dev /dev --tmpfs /tmp)
bw+=(--chdir "$WT")
bw+=(--die-with-parent --unshare-pid --unshare-ipc --unshare-uts)

# EXP-MF-004 rev-exec (option J): the pi-extension cannot write busy events
# from inside the sandbox (fm-busy-event needs to create its lock and do an
# atomic replace in state/, which per-file binds deny on purpose). The
# wrapper is the bwrap parent and owns the truth instead: when the sandboxed
# agent process exits — done, error or SIGKILL — it applies the idle/settled
# event from OUTSIDE, so busy-state never lies about a dead worker.
set +e
bwrap "${bw[@]}" \
  env -u SSH_AUTH_SOCK -u SSH_AGENT_LAUNCHER \
      PI_CODING_AGENT_DIR=/home/futanbear/.pi-agent \
      PI_CODING_AGENT_SESSION_DIR="$STATE/worker-sessions" \
      HOME=/home/futanbear \
  /bin/sh -c 'unset SSH_AUTH_SOCK SSH_AGENT_LAUNCHER; exec "$FFM_REAL_PI_BIN" "$@"' sh "$@"
RC=$?
set -euo pipefail
"$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$FM_TASK_ID" idle \
  --current-gen --source fm-worker-sandbox --event agent-settled \
  >/dev/null 2>&1 || true
exit "$RC"
