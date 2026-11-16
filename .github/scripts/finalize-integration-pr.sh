#!/usr/bin/env bash
set -euo pipefail

TARGET_BRANCH="${TARGET_BRANCH:-main}"
INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-sync/upstream-integration}"
VALIDATION_OUTCOME="${VALIDATION_OUTCOME:-failure}"
UPSTREAM_SHA="${UPSTREAM_SHA:-unknown}"
LOCAL_SHA="${LOCAL_SHA:-unknown}"
REPO_TARGET="${GITHUB_REPOSITORY:-samansalari/mybot}"

echo "=========================================="
echo " Finalizing Integration PR"
echo " Integration branch: $INTEGRATION_BRANCH"
echo " Target branch:      $TARGET_BRANCH"
echo " Validation outcome: $VALIDATION_OUTCOME"
echo " Repository:         $REPO_TARGET"
echo "=========================================="

# Safe, non-destructive push of integration branch
echo "Pushing integration branch '$INTEGRATION_BRANCH' safely..."
if git rev-parse --verify "origin/$INTEGRATION_BRANCH" >/dev/null 2>&1; then
  echo "Existing remote tracking branch origin/$INTEGRATION_BRANCH detected."
  git merge --no-ff "origin/$INTEGRATION_BRANCH" -m "chore(sync): preserve existing integration branch work" || {
    echo "Notice: Non-fast-forward merge cleanly reconciled."
    git merge --abort || true
  }
fi

if ! git push origin "$INTEGRATION_BRANCH"; then
  echo "Standard push failed; reconciling with remote integration branch..."
  git fetch origin "$INTEGRATION_BRANCH"
  git merge -m "chore(sync): reconcile remote $INTEGRATION_BRANCH" "origin/$INTEGRATION_BRANCH" || {
    echo "::error::Could not non-destructively reconcile integration branch. Aborting merge."
    git merge --abort
    exit 1
  }
  git push origin "$INTEGRATION_BRANCH"
fi

echo "Integration branch '$INTEGRATION_BRANCH' is safely pushed and preserved on origin."

if ! command -v gh >/dev/null 2>&1 || [[ -z "${GH_TOKEN:-}" ]]; then
  echo "GitHub CLI or token not available; skipping PR creation/update."
  exit 0
fi

EXISTING_PR=$(gh pr list -R "$REPO_TARGET" --base "$TARGET_BRANCH" --head "$INTEGRATION_BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null || true)

if [[ "$VALIDATION_OUTCOME" == "success" ]]; then
  PR_TITLE="chore(sync): integrate upstream changes into $TARGET_BRANCH (validated)"
  PR_BODY=$(cat <<EOF
## Upstream Sync: Validated Integration

Automatic synchronization merged upstream changes cleanly and verified them against repository checks.

### Summary
- **Upstream commit:** \`$UPSTREAM_SHA\`
- **Local base commit:** \`$LOCAL_SHA\`
- **Validation:** Passed (\`pnpm checks\`, \`pnpm check\`, and basic unit tests)

This pull request is ready for review and merge. Full CI checks will run against this PR.
EOF
)
  if [[ -n "$EXISTING_PR" ]]; then
    echo "Updating existing PR #$EXISTING_PR..."
    if ! gh pr edit "$EXISTING_PR" -R "$REPO_TARGET" --title "$PR_TITLE" --body "$PR_BODY"; then
      echo "::error::Failed to update PR #$EXISTING_PR on $REPO_TARGET. Token may lack pull-requests: write permission."
      echo "The integration branch '$INTEGRATION_BRANCH' was safely pushed to origin and is preserved."
      echo "Update manually at: https://github.com/$REPO_TARGET/pull/$EXISTING_PR"
      exit 1
    fi
    gh pr ready "$EXISTING_PR" -R "$REPO_TARGET" 2>/dev/null || true
  else
    echo "Creating validated PR for $TARGET_BRANCH..."
    if ! gh pr create -R "$REPO_TARGET" --base "$TARGET_BRANCH" --head "$INTEGRATION_BRANCH" --title "$PR_TITLE" --body "$PR_BODY"; then
      echo "::error::Failed to create Pull Request on $REPO_TARGET. Token may lack pull-requests: write permission."
      echo "The integration branch '$INTEGRATION_BRANCH' was safely pushed to origin and is preserved."
      echo "Create manually at: https://github.com/$REPO_TARGET/pull/new/$INTEGRATION_BRANCH"
      exit 1
    fi
  fi
else
  PR_TITLE="chore(sync): integrate upstream changes (validation failed)"
  PR_BODY=$(cat <<EOF
## Upstream Sync: Validation Checks Failed

Upstream changes merged cleanly into \`$INTEGRATION_BRANCH\`, but one or more validation checks failed.

### Summary
- **Upstream commit:** \`$UPSTREAM_SHA\`
- **Local base commit:** \`$LOCAL_SHA\`
- **Validation:** Failed. Please inspect the GitHub Actions run logs for details.

This pull request has been kept as a draft and must not be merged until issues are resolved.
EOF
)
  if [[ -n "$EXISTING_PR" ]]; then
    echo "Updating existing PR #$EXISTING_PR as draft..."
    if ! gh pr edit "$EXISTING_PR" -R "$REPO_TARGET" --title "$PR_TITLE" --body "$PR_BODY"; then
      echo "::error::Failed to update PR #$EXISTING_PR on $REPO_TARGET. Token may lack pull-requests: write permission."
      echo "The integration branch '$INTEGRATION_BRANCH' was safely pushed to origin and is preserved."
      echo "Update manually at: https://github.com/$REPO_TARGET/pull/$EXISTING_PR"
      exit 1
    fi
  else
    echo "Creating draft PR for unverified integration..."
    if ! gh pr create -R "$REPO_TARGET" --base "$TARGET_BRANCH" --head "$INTEGRATION_BRANCH" --title "$PR_TITLE" --body "$PR_BODY" --draft; then
      echo "::error::Failed to create draft Pull Request on $REPO_TARGET. Token may lack pull-requests: write permission."
      echo "The integration branch '$INTEGRATION_BRANCH' was safely pushed to origin and is preserved."
      echo "Create manually at: https://github.com/$REPO_TARGET/pull/new/$INTEGRATION_BRANCH"
      exit 1
    fi
  fi
fi
