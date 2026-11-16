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

# Push integration branch with clean merge commit
git push -f origin "$INTEGRATION_BRANCH"

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
    gh pr edit "$EXISTING_PR" -R "$REPO_TARGET" --title "$PR_TITLE" --body "$PR_BODY"
    gh pr ready "$EXISTING_PR" -R "$REPO_TARGET" || true
  else
    echo "Creating validated PR for $TARGET_BRANCH..."
    gh pr create -R "$REPO_TARGET" --base "$TARGET_BRANCH" --head "$INTEGRATION_BRANCH" --title "$PR_TITLE" --body "$PR_BODY"
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
    echo "Updating existing PR #$EXISTING_PR..."
    gh pr edit "$EXISTING_PR" -R "$REPO_TARGET" --title "$PR_TITLE" --body "$PR_BODY"
  else
    echo "Creating draft PR for unverified integration..."
    gh pr create -R "$REPO_TARGET" --base "$TARGET_BRANCH" --head "$INTEGRATION_BRANCH" --title "$PR_TITLE" --body "$PR_BODY" --draft
  fi
fi
