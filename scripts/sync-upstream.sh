#!/usr/bin/env bash
#
# sync-upstream.sh
#
# Sync fork's master with upstream/main, preserving and replaying local commits.
#
# Strategy (jj-native):
#   1. Fetch upstream + origin
#   2. Identify local-only commits on master not present in upstream/main
#   3. Rebase those commits on top of upstream/main
#   4. Update master bookmark to new tip
#   5. (Optional) push to origin with --allow-backwards under --force
#
# Requires: jj (Jujutsu) configured with both `upstream` and `origin` git remotes.
#
# Usage:
#   ./scripts/sync-upstream.sh         # safe: rebase + report, no push
#   ./scripts/sync-upstream.sh --force # rebase + push to origin/master (allow-backwards)
#
# Upstream is read-only. This script never mutates `upstream`.

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="main"
ORIGIN_REMOTE="origin"
LOCAL_BOOKMARK="master"

FORCE_PUSH=0
for arg in "$@"; do
    case "$arg" in
        --force|-f)
            FORCE_PUSH=1
            ;;
        --help|-h)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown arg: $arg" >&2
            echo "Usage: $0 [--force]" >&2
            exit 2
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_info()  { printf '\033[1;34m[sync]\033[0m %s\n' "$*"; }
_ok()    { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
_warn()  { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
_err()   { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; }

require() {
    if ! command -v "$1" >/dev/null 2>&1; then
        _err "missing required command: $1"
        exit 127
    fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

require jj

if [[ ! -d .jj ]]; then
    _err "not a jj repo (no .jj/ directory). cd to repo root."
    exit 1
fi

# Verify both remotes exist
if ! jj git remote list | grep -q "^${UPSTREAM_REMOTE} "; then
    _err "remote '${UPSTREAM_REMOTE}' not configured."
    _info "add via: jj git remote add ${UPSTREAM_REMOTE} <upstream-url>"
    exit 1
fi

if ! jj git remote list | grep -q "^${ORIGIN_REMOTE} "; then
    _err "remote '${ORIGIN_REMOTE}' not configured."
    exit 1
fi

# ---------------------------------------------------------------------------
# Fetch
# ---------------------------------------------------------------------------

_info "fetching ${UPSTREAM_REMOTE} + ${ORIGIN_REMOTE}..."
jj git fetch --remote "${UPSTREAM_REMOTE}"
jj git fetch --remote "${ORIGIN_REMOTE}"
_ok "fetch complete"

# ---------------------------------------------------------------------------
# Resolve revisions
# ---------------------------------------------------------------------------

UPSTREAM_REF="${UPSTREAM_BRANCH}@${UPSTREAM_REMOTE}"
LOCAL_REF="${LOCAL_BOOKMARK}@${ORIGIN_REMOTE}"

if ! jj log -r "${UPSTREAM_REF}" --no-graph -T 'commit_id' >/dev/null 2>&1; then
    _err "cannot resolve ${UPSTREAM_REF}. fetch may have failed."
    exit 1
fi

UPSTREAM_TIP=$(jj log -r "${UPSTREAM_REF}" --no-graph -T 'commit_id.short()' 2>/dev/null)
LOCAL_TIP=$(jj log -r "${LOCAL_REF}" --no-graph -T 'commit_id.short()' 2>/dev/null || echo "<none>")

_info "upstream tip: ${UPSTREAM_TIP}"
_info "local tip:    ${LOCAL_TIP}"

# ---------------------------------------------------------------------------
# Local-only commits
# ---------------------------------------------------------------------------
# Revset: commits reachable from local master but not from upstream main.

LOCAL_ONLY_REVSET="${LOCAL_REF}..${UPSTREAM_REF}"
LOCAL_ONLY_INVERSE="${UPSTREAM_REF}..${LOCAL_REF}"

LOCAL_ONLY_COUNT=$(jj log -r "${LOCAL_ONLY_INVERSE}" --no-graph -T 'commit_id ++ "\n"' 2>/dev/null | grep -c . || echo 0)

_info "local-only commits to replay: ${LOCAL_ONLY_COUNT}"

if [[ "${LOCAL_ONLY_COUNT}" -eq 0 ]]; then
    _info "fast-forward only — no local commits to rebase"
fi

# ---------------------------------------------------------------------------
# Rebase
# ---------------------------------------------------------------------------

if [[ "${LOCAL_ONLY_COUNT}" -gt 0 ]]; then
    _info "rebasing local commits onto ${UPSTREAM_REF}..."
    if ! jj rebase -s "roots(${LOCAL_ONLY_INVERSE})" -d "${UPSTREAM_REF}"; then
        _err "rebase failed — resolve conflicts, then re-run with --force to push"
        exit 1
    fi
    _ok "rebase applied"
else
    _info "moving ${LOCAL_BOOKMARK} bookmark to ${UPSTREAM_REF}..."
fi

# ---------------------------------------------------------------------------
# Move bookmark
# ---------------------------------------------------------------------------
# After rebase, the new tip is the descendant of UPSTREAM_REF that contains
# the replayed local commits. If no local commits, tip == UPSTREAM_REF.

if [[ "${LOCAL_ONLY_COUNT}" -gt 0 ]]; then
    NEW_TIP_REVSET="heads(${UPSTREAM_REF}::)"
    jj bookmark set "${LOCAL_BOOKMARK}" -r "${NEW_TIP_REVSET}" --allow-backwards
else
    jj bookmark set "${LOCAL_BOOKMARK}" -r "${UPSTREAM_REF}" --allow-backwards
fi

NEW_TIP=$(jj log -r "${LOCAL_BOOKMARK}" --no-graph -T 'commit_id.short()' 2>/dev/null)
_ok "bookmark ${LOCAL_BOOKMARK} -> ${NEW_TIP}"

# ---------------------------------------------------------------------------
# Push (optional)
# ---------------------------------------------------------------------------

if [[ "${FORCE_PUSH}" -eq 1 ]]; then
    _info "pushing ${LOCAL_BOOKMARK} to ${ORIGIN_REMOTE} (allow-backwards)..."
    jj git push --remote "${ORIGIN_REMOTE}" --bookmark "${LOCAL_BOOKMARK}" --allow-backwards
    _ok "push complete"
else
    _info "skip push (no --force). to publish:"
    echo "    jj git push --remote ${ORIGIN_REMOTE} --bookmark ${LOCAL_BOOKMARK} --allow-backwards"
fi

_ok "sync done"
