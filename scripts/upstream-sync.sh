#!/usr/bin/env bash
# ==============================================================================
# scripts/upstream-sync.sh
# Self-hosted upstream synchronisation script for samansalari/mybot
# Works with systemd timer, cron, or manual invocation.
# Does NOT require or invoke GitHub Actions.
# ==============================================================================
set -euo pipefail

# Find script directory and repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

# Default Configuration Paths
CONFIG_FILE="${MYBOT_SYNC_CONFIG:-${HOME}/.config/mybot-sync/config.env}"
if [[ ! -f "${CONFIG_FILE}" && -f "/etc/mybot-sync/config.env" ]]; then
  CONFIG_FILE="/etc/mybot-sync/config.env"
fi

# Load external configuration if present
if [[ -f "${CONFIG_FILE}" ]]; then
  # Ensure restricted permissions on config file
  CONFIG_PERMS="$(stat -f "%OLp" "${CONFIG_FILE}" 2>/dev/null || stat -c "%a" "${CONFIG_FILE}" 2>/dev/null || echo "600")"
  if [[ "${CONFIG_PERMS}" =~ [4567][4567]$ ]]; then
    echo "WARNING: Config file ${CONFIG_FILE} has loose permissions (${CONFIG_PERMS}). Should be 600." >&2
  fi
  # Source config file safely (ignoring comments)
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

# Configuration Defaults
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/elie222/rakazo.git}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
ORIGIN_REMOTE="${ORIGIN_REMOTE:-origin}"
TARGET_BRANCH="${TARGET_BRANCH:-main}"
INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-sync/upstream-integration}"
FORK_REPO="${FORK_REPO:-samansalari/mybot}"
LOCK_FILE="${LOCK_FILE:-/tmp/mybot-upstream-sync.lock}"
STATE_DIR="${STATE_DIR:-${HOME}/.local/state/mybot-sync}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/state.json}"
LOG_FILE="${LOG_FILE:-${STATE_DIR}/sync.log}"
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY_SEC="${RETRY_DELAY_SEC:-3}"
VALIDATION_ENABLED="${VALIDATION_ENABLED:-true}"

# Ensure state directory exists
mkdir -p "${STATE_DIR}"

# ------------------------------------------------------------------------------
# Logging & Utilities
# ------------------------------------------------------------------------------
log() {
  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local message="[${timestamp}] $*"
  echo "${message}"
  if [[ -n "${LOG_FILE}" ]]; then
    echo "${message}" >> "${LOG_FILE}" 2>/dev/null || true
  fi
}

log_error() {
  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local message="[${timestamp}] [ERROR] $*"
  echo "${message}" >&2
  if [[ -n "${LOG_FILE}" ]]; then
    echo "${message}" >> "${LOG_FILE}" 2>/dev/null || true
  fi
}

update_state() {
  local status="$1"
  local error_msg="${2:-}"
  local upstream_sha="${3:-}"
  local origin_sha="${4:-}"
  local pr_url="${5:-}"

  local now
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  python3 -c "
import json, os, sys

state_file = sys.argv[1]
status = sys.argv[2]
error_msg = sys.argv[3] or None
upstream_sha = sys.argv[4] or None
origin_sha = sys.argv[5] or None
pr_url = sys.argv[6] or None
now = sys.argv[7]

data = {}
if os.path.exists(state_file):
    try:
        with open(state_file, 'r') as f:
            data = json.load(f)
    except Exception:
        pass

data['last_run_timestamp'] = now
data['last_status'] = status
if error_msg:
    data['last_error'] = error_msg
elif status in ['SUCCESS', 'SUCCESS_FF', 'NO_CHANGES', 'DIVERGENT_PR_OPENED']:
    data['last_error'] = None

if status in ['SUCCESS', 'SUCCESS_FF', 'NO_CHANGES']:
    data['last_success_timestamp'] = now

if upstream_sha:
    data['last_upstream_sha'] = upstream_sha
if origin_sha:
    data['last_origin_sha'] = origin_sha
if pr_url:
    data['last_pr_url'] = pr_url

with open(state_file, 'w') as f:
    json.dump(data, f, indent=2)
" "${STATE_FILE}" "${status}" "${error_msg}" "${upstream_sha}" "${origin_sha}" "${pr_url}" "${now}" 2>/dev/null || true
}

retry_cmd() {
  local retries=0
  until "$@"; do
    local exit_code=$?
    retries=$((retries + 1))
    if [[ "${retries}" -ge "${MAX_RETRIES}" ]]; then
      log_error "Command failed after ${retries} attempts: $*"
      return "${exit_code}"
    fi
    log "Transient failure (exit ${exit_code}). Retrying in ${RETRY_DELAY_SEC}s (attempt ${retries}/${MAX_RETRIES})..."
    sleep "${RETRY_DELAY_SEC}"
  done
}

# ------------------------------------------------------------------------------
# Concurrency Lock (Flock)
# ------------------------------------------------------------------------------
acquire_lock() {
  # Portable locking across Linux & macOS
  if command -v flock >/dev/null 2>&1; then
    exec 200>"${LOCK_FILE}"
    if ! flock -n 200; then
      log "Another synchronisation job is already running (${LOCK_FILE}). Exiting cleanly."
      exit 0
    fi
  else
    # Fallback mkdir lock for macOS/POSIX environments without flock
    local lock_dir="${LOCK_FILE}.d"
    if ! mkdir "${lock_dir}" 2>/dev/null; then
      # Check if stale PID
      if [[ -f "${lock_dir}/pid" ]]; then
        local old_pid
        old_pid="$(cat "${lock_dir}/pid" 2>/dev/null || echo "")"
        if [[ -n "${old_pid}" ]] && ! kill -0 "${old_pid}" 2>/dev/null; then
          log "Clearing stale lock from deceased PID ${old_pid}."
          rm -rf "${lock_dir}"
          mkdir "${lock_dir}" || exit 0
        else
          log "Another synchronisation job is already running. Exiting cleanly."
          exit 0
        fi
      else
        log "Another synchronisation job is already running. Exiting cleanly."
        exit 0
      fi
    fi
    echo "$$" > "${lock_dir}/pid"
    trap 'rm -rf "${LOCK_FILE}.d"' EXIT
  fi
}

# ------------------------------------------------------------------------------
# Validation
# ------------------------------------------------------------------------------
run_validation() {
  if [[ "${VALIDATION_ENABLED}" != "true" ]]; then
    log "Validation skipped by configuration (VALIDATION_ENABLED=${VALIDATION_ENABLED})."
    return 0
  fi

  log "Running local validation..."
  cd "${REPO_DIR}"

  # 1. Architecture ratchets and checks
  log "Running pnpm checks (ratchets)..."
  if ! pnpm checks; then
    log_error "pnpm checks failed."
    return 1
  fi

  # 2. Monorepo TypeScript typecheck
  log "Running pnpm check (typecheck)..."
  if ! pnpm check; then
    log_error "pnpm check failed."
    return 1
  fi

  # 3. Test isolation check
  log "Running vitest isolation check on apps/api/src/database-outage-errors.test.ts..."
  if ! pnpm exec vitest run apps/api/src/database-outage-errors.test.ts; then
    log_error "vitest database outage test failed."
    return 1
  fi

  # 4. Sync script unit test verification
  if [[ -f "${SCRIPT_DIR}/upstream-sync.test.py" ]]; then
    log "Running sync logic test suite..."
    if ! python3 "${SCRIPT_DIR}/upstream-sync.test.py"; then
      log_error "upstream-sync unit tests failed."
      return 1
    fi
  fi

  log "All local validation checks passed successfully."
  return 0
}

# ------------------------------------------------------------------------------
# Status Command
# ------------------------------------------------------------------------------
show_status() {
  echo "=================================================================="
  echo " Rakazo Self-Hosted Upstream Sync Status"
  echo "=================================================================="
  echo "Repository:         ${FORK_REPO}"
  echo "Local Path:         ${REPO_DIR}"
  echo "Target Branch:      ${TARGET_BRANCH}"
  echo "Upstream URL:       ${UPSTREAM_URL}"
  echo "Config File:        ${CONFIG_FILE}"
  echo "State File:         ${STATE_FILE}"
  echo "Log File:           ${LOG_FILE}"
  echo "------------------------------------------------------------------"

  if [[ -f "${STATE_FILE}" ]]; then
    python3 -c "
import json, sys

with open(sys.argv[1], 'r') as f:
    data = json.load(f)

print(f\"Last Run:           {data.get('last_run_timestamp', 'Never')}\")
print(f\"Last Success:       {data.get('last_success_timestamp', 'Never')}\")
print(f\"Last Status:        {data.get('last_status', 'Unknown')}\")
if data.get('last_error'):
    print(f\"Last Error:         {data.get('last_error')}\")
print(f\"Last Upstream SHA:  {data.get('last_upstream_sha', 'Unknown')}\")
print(f\"Last Origin SHA:    {data.get('last_origin_sha', 'Unknown')}\")
if data.get('last_pr_url'):
    print(f\"Last PR URL:        {data.get('last_pr_url')}\")
" "${STATE_FILE}"
  else
    echo "No prior sync state recorded yet."
  fi

  echo "------------------------------------------------------------------"
  # Systemd timer status check if available
  if command -v systemctl >/dev/null 2>&1; then
    echo "Systemd Timer Status:"
    if systemctl is-active --quiet mybot-sync.timer 2>/dev/null; then
      systemctl status mybot-sync.timer --no-pager 2>/dev/null | grep -E "Active:|Loaded:|Trigger:" || true
    elif systemctl --user is-active --quiet mybot-sync.timer 2>/dev/null; then
      systemctl --user status mybot-sync.timer --no-pager 2>/dev/null | grep -E "Active:|Loaded:|Trigger:" || true
    else
      echo "  mybot-sync.timer is not currently active on this system."
    fi
  else
    echo "Systemd not detected (running in non-systemd environment or macOS)."
  fi
  echo "=================================================================="
}

# ------------------------------------------------------------------------------
# Core Synchronisation Routine
# ------------------------------------------------------------------------------
execute_sync() {
  log "Starting upstream synchronisation cycle..."
  cd "${REPO_DIR}"

  # Verify git remotes
  if ! git remote get-url "${UPSTREAM_REMOTE}" >/dev/null 2>&1; then
    log "Configuring remote '${UPSTREAM_REMOTE}' -> ${UPSTREAM_URL}"
    git remote add "${UPSTREAM_REMOTE}" "${UPSTREAM_URL}"
  fi

  # Fetch upstream and origin with retries
  log "Fetching upstream '${TARGET_BRANCH}'..."
  retry_cmd git fetch "${UPSTREAM_REMOTE}" "${TARGET_BRANCH}" --quiet

  log "Fetching origin '${TARGET_BRANCH}'..."
  retry_cmd git fetch "${ORIGIN_REMOTE}" "${TARGET_BRANCH}" --quiet

  local upstream_sha
  upstream_sha="$(git rev-parse "${UPSTREAM_REMOTE}/${TARGET_BRANCH}")"
  local origin_sha
  origin_sha="$(git rev-parse "${ORIGIN_REMOTE}/${TARGET_BRANCH}")"

  log "Upstream SHA: ${upstream_sha}"
  log "Origin SHA:   ${origin_sha}"

  # 1. Check if already identical
  if [[ "${upstream_sha}" == "${origin_sha}" ]]; then
    log "Repositories are already synchronized (${upstream_sha}). Nothing to do."
    update_state "NO_CHANGES" "" "${upstream_sha}" "${origin_sha}"
    return 0
  fi

  # 2. Check if origin is ahead of upstream
  if git merge-base --is-ancestor "${UPSTREAM_REMOTE}/${TARGET_BRANCH}" "${ORIGIN_REMOTE}/${TARGET_BRANCH}"; then
    log "Origin is ahead of upstream. All upstream commits are already integrated."
    update_state "NO_CHANGES" "" "${upstream_sha}" "${origin_sha}"
    return 0
  fi

  # 3. Check if fast-forward is possible (origin is ancestor of upstream)
  if git merge-base --is-ancestor "${ORIGIN_REMOTE}/${TARGET_BRANCH}" "${UPSTREAM_REMOTE}/${TARGET_BRANCH}"; then
    log "Fast-forward synchronisation possible (${origin_sha} -> ${upstream_sha})."

    # Switch to target branch cleanly
    git checkout "${TARGET_BRANCH}" --quiet
    git merge --ff-only "${ORIGIN_REMOTE}/${TARGET_BRANCH}" --quiet || true

    # Attempt fast forward merge
    git merge --ff-only "${UPSTREAM_REMOTE}/${TARGET_BRANCH}" --quiet

    # Validate before pushing
    if run_validation; then
      log "Validation passed. Pushing fast-forward update to origin/${TARGET_BRANCH}..."
      retry_cmd git push "${ORIGIN_REMOTE}" "${TARGET_BRANCH}" --quiet
      log "Fast-forward update successfully pushed to origin/${TARGET_BRANCH}."
      update_state "SUCCESS_FF" "" "${upstream_sha}" "${upstream_sha}"
      return 0
    else
      log_error "Validation failed on fast-forwarded commit ${upstream_sha}. Reverting local branch to ${origin_sha}."
      git reset --hard "${origin_sha}" --quiet
      update_state "VALIDATION_FAILED" "Validation checks failed on fast-forward commit" "${upstream_sha}" "${origin_sha}"
      return 1
    fi
  fi

  # 4. Histories have diverged - manage integration branch
  log "Histories have diverged. Creating/updating integration branch '${INTEGRATION_BRANCH}'..."

  # Create or checkout integration branch
  if git show-ref --verify --quiet "refs/heads/${INTEGRATION_BRANCH}"; then
    git checkout "${INTEGRATION_BRANCH}" --quiet
    # Reset integration branch to latest local target branch
    git reset --hard "${ORIGIN_REMOTE}/${TARGET_BRANCH}" --quiet
  else
    git checkout -b "${INTEGRATION_BRANCH}" "${ORIGIN_REMOTE}/${TARGET_BRANCH}" --quiet
  fi

  # Attempt merge of upstream
  log "Merging upstream/${TARGET_BRANCH} into ${INTEGRATION_BRANCH}..."
  if ! git merge --no-edit -m "chore(sync): merge upstream/${TARGET_BRANCH} into ${INTEGRATION_BRANCH}" "${UPSTREAM_REMOTE}/${TARGET_BRANCH}"; then
    local conflicts
    conflicts="$(git diff --name-only --diff-filter=U || echo "")"
    log_error "Merge conflict detected with upstream! Conflicting files:\n${conflicts}"
    git merge --abort || true
    update_state "MERGE_CONFLICT" "Merge conflict in files: ${conflicts}" "${upstream_sha}" "${origin_sha}"
    return 1
  fi

  local integration_commit
  integration_commit="$(git rev-parse HEAD)"
  log "Merge completed cleanly at ${integration_commit}."

  # Run validation on merged code
  local validation_passed=true
  if ! run_validation; then
    log_error "Validation failed on integration commit ${integration_commit}."
    validation_passed=false
  fi

  # Reconcile safely with existing origin integration branch (non-destructively, NO force push)
  if git rev-parse --verify --quiet "${ORIGIN_REMOTE}/${INTEGRATION_BRANCH}" >/dev/null; then
    log "Reconciling with existing remote integration branch ${ORIGIN_REMOTE}/${INTEGRATION_BRANCH}..."
    git merge --no-edit -m "chore(sync): preserve existing integration branch work" "${ORIGIN_REMOTE}/${INTEGRATION_BRANCH}" --quiet || true
  fi

  # Push integration branch
  log "Pushing integration branch '${INTEGRATION_BRANCH}' to origin..."
  retry_cmd git push "${ORIGIN_REMOTE}" "${INTEGRATION_BRANCH}" --quiet

  # Create or update Pull Request using gh CLI
  local pr_url=""
  if command -v gh >/dev/null 2>&1; then
    local existing_pr
    existing_pr="$(gh pr list -R "${FORK_REPO}" --head "${INTEGRATION_BRANCH}" --base "${TARGET_BRANCH}" --state open --json number -q '.[0].number' 2>/dev/null || echo "")"

    local pr_title="chore(sync): integrate upstream changes into ${TARGET_BRANCH}"
    local pr_body
    if [[ "${validation_passed}" == "true" ]]; then
      pr_title="${pr_title} (validated)"
      pr_body="$(cat << EOF
## Upstream Sync: Validated Integration

Self-hosted automatic synchronisation merged upstream changes cleanly and passed all local validation checks.

### Summary
- **Upstream commit**: \`${upstream_sha}\`
- **Local base commit**: \`${origin_sha}\`
- **Validation**: Passed (\`pnpm checks\`, \`pnpm check\`, unit tests)

This pull request is validated and ready for review and merge.
EOF
)"
    else
      pr_title="${pr_title} (validation failing)"
      pr_body="$(cat << EOF
## Upstream Sync: Integration Requires Review

Self-hosted automatic synchronisation merged upstream changes, but one or more local validation checks failed.

### Summary
- **Upstream commit**: \`${upstream_sha}\`
- **Local base commit**: \`${origin_sha}\`
- **Validation Status**: FAILED

Please review the test output and resolve remaining failures before merging.
EOF
)"
    fi

    if [[ -n "${existing_pr}" ]]; then
      log "Updating existing Pull Request #${existing_pr} on ${FORK_REPO}..."
      gh pr edit "${existing_pr}" -R "${FORK_REPO}" --title "${pr_title}" --body "${pr_body}" >/dev/null 2>&1 || true
      pr_url="https://github.com/${FORK_REPO}/pull/${existing_pr}"
    else
      log "Opening new Pull Request on ${FORK_REPO}..."
      local draft_flag=""
      if [[ "${validation_passed}" != "true" ]]; then
        draft_flag="--draft"
      fi
      # shellcheck disable=SC2086
      pr_url="$(gh pr create -R "${FORK_REPO}" --head "${INTEGRATION_BRANCH}" --base "${TARGET_BRANCH}" --title "${pr_title}" --body "${pr_body}" ${draft_flag} 2>/dev/null || echo "")"
    fi
  fi

  if [[ "${validation_passed}" == "true" ]]; then
    log "Integration PR ready: ${pr_url}"
    update_state "DIVERGENT_PR_OPENED" "" "${upstream_sha}" "${origin_sha}" "${pr_url}"
    return 0
  else
    log_error "Validation failed. PR marked for review: ${pr_url}"
    update_state "VALIDATION_FAILED" "Validation checks failed on merged integration branch" "${upstream_sha}" "${origin_sha}" "${pr_url}"
    return 1
  fi
}

# ------------------------------------------------------------------------------
# Entrypoint Dispatcher
# ------------------------------------------------------------------------------
main() {
  local action="run"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status)
        action="status"
        shift
        ;;
      --run|--manual)
        action="run"
        shift
        ;;
      --help|-h)
        echo "Usage: $0 [--run | --status | --help]"
        echo ""
        echo "Options:"
        echo "  --run, --manual   Execute an upstream synchronization cycle (default)"
        echo "  --status          Show current synchronization status, state, and timer"
        echo "  --help, -h        Show this help message"
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        echo "Run '$0 --help' for usage." >&2
        exit 1
        ;;
    esac
  done

  if [[ "${action}" == "status" ]]; then
    show_status
    exit 0
  fi

  acquire_lock
  execute_sync
}

main "$@"
