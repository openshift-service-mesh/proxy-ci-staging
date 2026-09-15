#!/bin/bash
#
# Sync staging branches with the upstream (production) repo.
#
# The staging repo is a copy of openshift-service-mesh/proxy with a few
# CI-specific modifications (disabled triggers, GCS path change, cleanup
# workflow, etc.). These modifications live as commits on top of the
# upstream history.
#
# This script rebases those staging-specific commits onto the latest
# upstream tip, so that after sync each branch looks like:
#
#   upstream history (identical to production) + staging patches on top
#
# Git identifies the staging commits automatically: they are the commits
# present in <branch> but not in upstream/<branch>. No hardcoded list.
#
# The script does NOT push. After running, review the result and push
# manually with --force-with-lease.

set -euo pipefail

ALL_BRANCHES=(master release-1.24 release-1.26 release-1.27 release-1.28 release-1.30 release-1.31)

usage() {
  cat <<'EOF'
Usage:
  sync-from-upstream.sh --branches=<branch>[,<branch>...]  [--dry-run]
  sync-from-upstream.sh --branches=all                     [--dry-run]
  sync-from-upstream.sh -h | --help

Required:
  --branches=<list>   Comma-separated list of branches to sync, or "all"
                      to sync all known branches.
                      Known branches: master, release-1.24, release-1.26,
                      release-1.27, release-1.28, release-1.30, release-1.31

Options:
  --dry-run           Show what would change without modifying anything.
  -h, --help          Show this help message and exit.

What it does:
  1. Fetches the latest state from the upstream remote.
  2. For each branch, rebases the staging-specific commits on top of the
     new upstream tip. If there are no new upstream commits, the branch
     is skipped.
  3. If a rebase conflict occurs, the script stops. Resolve the conflict
     manually (git rebase --continue) or abort (git rebase --abort).

After running:
  Review the result before pushing:
    git log upstream/<branch>..<branch>     # staging-only commits
    git diff upstream/<branch>..<branch>    # staging-only changes

  Push (per branch, after review):
    git push origin <branch> --force-with-lease

  --force-with-lease is needed because rebase rewrites the staging commits
  (new SHAs). It is safe because nobody else works on the staging repo,
  and --force-with-lease protects against accidental concurrent pushes.

Examples:
  # Preview what would happen on release-1.28
  ./.github/scripts/sync-from-upstream.sh --branches=release-1.28 --dry-run

  # Sync only release-1.28 and release-1.30
  ./.github/scripts/sync-from-upstream.sh --branches=release-1.28,release-1.30

  # Sync all branches (dry-run first, then for real)
  ./.github/scripts/sync-from-upstream.sh --branches=all --dry-run
  ./.github/scripts/sync-from-upstream.sh --branches=all
EOF
}

DRY_RUN=false
BRANCHES=()
BRANCHES_SET=false

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    --branches=*)
      BRANCHES_SET=true
      value="${arg#--branches=}"
      if [[ "$value" == "all" ]]; then
        BRANCHES=("${ALL_BRANCHES[@]}")
      else
        IFS=',' read -ra BRANCHES <<< "$value"
      fi
      ;;
    *)
      echo "Error: unknown argument '$arg'"
      echo ""
      usage
      exit 1
      ;;
  esac
done

if [[ "$BRANCHES_SET" == false ]]; then
  echo "Error: --branches is required."
  echo ""
  usage
  exit 1
fi

if [[ ${#BRANCHES[@]} -eq 0 ]]; then
  echo "Error: --branches value is empty."
  echo ""
  usage
  exit 1
fi

ORIGINAL_BRANCH=$(git branch --show-current)

echo "Fetching upstream..."
git fetch upstream

echo ""

for branch in "${BRANCHES[@]}"; do
  echo "============================================"
  echo "  $branch"
  echo "============================================"

  if ! git rev-parse --verify "$branch" &>/dev/null; then
    echo "  SKIP: local branch '$branch' does not exist"
    echo ""
    continue
  fi

  if ! git rev-parse --verify "upstream/$branch" &>/dev/null; then
    echo "  SKIP: upstream/$branch does not exist"
    echo ""
    continue
  fi

  STAGING_COMMITS=$(git log --oneline "upstream/$branch..$branch" 2>/dev/null)
  STAGING_COUNT=$(echo "$STAGING_COMMITS" | grep -c . 2>/dev/null || echo 0)

  BEHIND=$(git rev-list --count "$branch..upstream/$branch" 2>/dev/null || echo 0)

  echo "  Staging commits on top: $STAGING_COUNT"
  if [[ -n "$STAGING_COMMITS" ]]; then
    echo "$STAGING_COMMITS" | sed 's/^/    /'
  fi
  echo "  Commits behind upstream: $BEHIND"

  if [[ "$BEHIND" -eq 0 ]]; then
    echo "  Already up to date."
    echo ""
    continue
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo "  [dry-run] Would rebase $STAGING_COUNT staging commit(s) onto upstream/$branch"
    echo ""
    continue
  fi

  git checkout "$branch"

  if ! git rebase "upstream/$branch"; then
    echo ""
    echo "  CONFLICT during rebase of '$branch'."
    echo "  Resolve conflicts, then: git rebase --continue"
    echo "  Or abort with: git rebase --abort"
    echo ""
    echo "  Remaining branches were NOT synced."
    exit 1
  fi

  echo "  Synced. Staging commits after rebase:"
  git log --oneline "upstream/$branch..$branch" | sed 's/^/    /'
  echo ""
done

git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

echo "============================================"
echo "  Done."
echo "============================================"
echo ""
echo "Review:"
echo "  git log upstream/<branch>..<branch>     # staging-only commits"
echo "  git diff upstream/<branch>..<branch>    # staging-only changes"
echo ""
echo "Push (per branch, after review):"
echo "  git push origin <branch> --force-with-lease"
