#!/usr/bin/env bash
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/elie222/rakazo.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
TARGET_BRANCH="${TARGET_BRANCH:-main}"
INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-sync/upstream-integration}"
REPO_TARGET="${GITHUB_REPOSITORY:-samansalari/mybot}"

echo "=========================================="
echo " Starting Upstream Synchronisation"
echo " Upstream:    $UPSTREAM_REPO ($UPSTREAM_BRANCH)"
echo " Target:      origin/$TARGET_BRANCH"
echo " Integration: $INTEGRATION_BRANCH"
echo " Repository:  $REPO_TARGET"
echo "=========================================="

# Ensure git credentials & identity
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

# Safe GitHub step output helper
set_output() {
  local name="$1"
  local value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "${name}=${value}" >> "$GITHUB_OUTPUT"
  fi
}

# Configure upstream remote
if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url upstream "$UPSTREAM_REPO"
else
  git remote add upstream "$UPSTREAM_REPO"
fi

echo "Fetching upstream/$UPSTREAM_BRANCH..."
git fetch upstream "$UPSTREAM_BRANCH" --no-tags

echo "Fetching origin/$TARGET_BRANCH..."
git fetch origin "$TARGET_BRANCH" --no-tags

LOCAL_SHA=$(git rev-parse "origin/$TARGET_BRANCH")
UPSTREAM_SHA=$(git rev-parse "upstream/$UPSTREAM_BRANCH")
MERGE_BASE=$(git merge-base "$LOCAL_SHA" "$UPSTREAM_SHA")

echo "Local SHA:    $LOCAL_SHA"
echo "Upstream SHA: $UPSTREAM_SHA"
echo "Merge Base:   $MERGE_BASE"

set_output "local_sha" "$LOCAL_SHA"
set_output "upstream_sha" "$UPSTREAM_SHA"
set_output "merge_base" "$MERGE_BASE"
set_output "need_validation" "false"
set_output "has_conflicts" "false"

# 1. Identical Check
if [[ "$LOCAL_SHA" == "$UPSTREAM_SHA" ]]; then
  echo "Repositories are already in sync at commit $UPSTREAM_SHA."
  echo "No changes to fetch or push. Exiting safely."
  set_output "sync_status" "identical"
  exit 0
fi

# 2. Local is ahead of upstream (no upstream changes)
if [[ "$UPSTREAM_SHA" == "$MERGE_BASE" ]]; then
  COMMITS_AHEAD=$(git rev-list --count "$UPSTREAM_SHA..$LOCAL_SHA")
  echo "Local $TARGET_BRANCH is ahead of upstream/$UPSTREAM_BRANCH by $COMMITS_AHEAD commit(s)."
  echo "No new upstream commits to synchronize. Exiting safely."
  set_output "sync_status" "ahead"
  exit 0
fi

# 3. Clean Fast-Forward
if [[ "$LOCAL_SHA" == "$MERGE_BASE" ]]; then
  COMMITS_BEHIND=$(git rev-list --count "$LOCAL_SHA..$UPSTREAM_SHA")
  echo "Fast-forward synchronisation possible ($COMMITS_BEHIND new upstream commit(s))."
  
  git checkout "$TARGET_BRANCH"
  git merge --ff-only "upstream/$UPSTREAM_BRANCH"
  
  echo "Pushing fast-forwarded $TARGET_BRANCH to origin..."
  git push origin "$TARGET_BRANCH"
  
  # Close obsolete integration PR if open
  if command -v gh >/dev/null 2>&1 && [[ -n "${GH_TOKEN:-}" ]]; then
    EXISTING_PR=$(gh pr list -R "$REPO_TARGET" --base "$TARGET_BRANCH" --head "$INTEGRATION_BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null || true)
    if [[ -n "$EXISTING_PR" ]]; then
      echo "Closing obsolete integration PR #$EXISTING_PR..."
      gh pr close "$EXISTING_PR" -R "$REPO_TARGET" --comment "Auto-closed: $TARGET_BRANCH was fast-forwarded directly to upstream commit $UPSTREAM_SHA." || true
    fi
  fi
  
  set_output "sync_status" "fast-forward"
  set_output "synced_sha" "$UPSTREAM_SHA"
  echo "Successfully fast-forwarded $TARGET_BRANCH to $UPSTREAM_SHA."
  exit 0
fi

# 4. Diverged - custom commits exist alongside upstream changes
echo "Histories have diverged. Creating safe integration branch..."
set_output "sync_status" "diverged"

# Prepare integration branch from current origin target branch
git checkout -B "$INTEGRATION_BRANCH" "origin/$TARGET_BRANCH"

echo "Attempting merge of upstream/$UPSTREAM_BRANCH into $INTEGRATION_BRANCH..."
set +e
git merge --no-ff "upstream/$UPSTREAM_BRANCH" -m "chore(sync): merge upstream/$UPSTREAM_BRANCH into $INTEGRATION_BRANCH"
MERGE_STATUS=$?
set -e

if [[ $MERGE_STATUS -ne 0 ]]; then
  echo "Merge conflict detected!"
  CONFLICT_FILES=$(git diff --name-only --diff-filter=U)
  echo "Conflicted files:"
  echo "$CONFLICT_FILES"
  
  git merge --abort
  
  # Checkout upstream commits onto the integration branch so PR compares upstream against local main
  git checkout -B "$INTEGRATION_BRANCH" "upstream/$UPSTREAM_BRANCH"
  git push -f origin "$INTEGRATION_BRANCH"
  
  set_output "has_conflicts" "true"
  set_output "need_validation" "false"
  
  if command -v gh >/dev/null 2>&1 && [[ -n "${GH_TOKEN:-}" ]]; then
    PR_TITLE="chore(sync): upstream integration requires manual conflict resolution"
    PR_BODY=$(cat <<EOF
## Upstream Sync: Merge Conflicts Detected

Automatic synchronization detected conflicting changes between upstream and local \`$TARGET_BRANCH\`.

### Status
- **Upstream commit:** \`$UPSTREAM_SHA\`
- **Local commit:** \`$LOCAL_SHA\`
- **Common ancestor:** \`$MERGE_BASE\`

### Conflicting Files
\`\`\`
$CONFLICT_FILES
\`\`\`

### Resolution Instructions
1. Check out a local resolution branch:
   \`\`\`bash
   git fetch origin
   git fetch upstream
   git checkout $TARGET_BRANCH
   git checkout -b sync/resolve-conflicts
   git merge upstream/$UPSTREAM_BRANCH
   \`\`\`
2. Resolve conflicts in the files listed above.
3. Validate changes:
   \`\`\`bash
   pnpm checks
   pnpm check
   pnpm test
   \`\`\`
4. Merge or fast-forward to \`$TARGET_BRANCH\` and push.
EOF
)
    EXISTING_PR=$(gh pr list -R "$REPO_TARGET" --base "$TARGET_BRANCH" --head "$INTEGRATION_BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null || true)
    if [[ -n "$EXISTING_PR" ]]; then
      echo "Updating existing PR #$EXISTING_PR with conflict details..."
      gh pr edit "$EXISTING_PR" -R "$REPO_TARGET" --title "$PR_TITLE" --body "$PR_BODY"
    else
      echo "Opening draft PR for conflict resolution..."
      gh pr create -R "$REPO_TARGET" --base "$TARGET_BRANCH" --head "$INTEGRATION_BRANCH" --title "$PR_TITLE" --body "$PR_BODY" --draft
    fi
  fi
  exit 0
fi

echo "Merge succeeded cleanly without conflicts."
set_output "has_conflicts" "false"
set_output "need_validation" "true"
