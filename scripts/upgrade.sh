#!/usr/bin/env bash
#
# Rebuild this fork's patch branches on a new upstream release.
#
#   scripts/upgrade.sh v1.31.0 v1.32.0
#
# Creates each patch/* branch from OLD_TAG, cherry-picks the commits listed in
# TOPICS below, then rebases it onto NEW_TAG. Stops at the first conflict and
# names the branch and files; resolve, `git rebase --continue`, re-run.
#
# It does not touch the integration branch, tag anything, or push. Those are
# deliberate steps in UPGRADE.md.

set -euo pipefail

OLD_TAG="${1:-}"
NEW_TAG="${2:-}"

if [ -z "$OLD_TAG" ] || [ -z "$NEW_TAG" ]; then
  echo "usage: $0 OLD_TAG NEW_TAG   (e.g. $0 v1.31.0 v1.32.0)" >&2
  exit 2
fi

# One line per topic branch: branch name, then the commits it carries, oldest
# first. Update this when a patch is added or amended.
TOPICS="
patch/teams-host-attendee:197342f81
patch/ews-dup-guard:89c4cd485
patch/ews-fixes:d0e4f198c b40949f17 3b06096da
patch/itip:4274de503 721c9b888 39ca533fb
"

cd "$(git rev-parse --show-toplevel)"

git rev-parse --verify --quiet "$OLD_TAG^{commit}" >/dev/null ||
  { echo "no such tag: $OLD_TAG" >&2; exit 1; }
git rev-parse --verify --quiet "$NEW_TAG^{commit}" >/dev/null ||
  { echo "no such tag: $NEW_TAG" >&2; exit 1; }

git config rerere.enabled true

if [ -n "$(git status --porcelain)" ]; then
  echo "working tree is not clean; commit or stash first" >&2
  git status --short >&2
  exit 1
fi

ORIGINAL_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
trap 'git checkout -q "$ORIGINAL_BRANCH" 2>/dev/null || true' EXIT

echo "$TOPICS" | while IFS=: read -r branch commits; do
  [ -n "${branch:-}" ] || continue

  if git rev-parse --verify --quiet "$branch" >/dev/null &&
     git merge-base --is-ancestor "$NEW_TAG" "$branch"; then
    echo "== $branch already on $NEW_TAG, skipping"
    continue
  fi

  echo "== $branch"
  git checkout -q -B "$branch" "$OLD_TAG"

  # shellcheck disable=SC2086
  if ! git cherry-pick -x $commits; then
    echo "" >&2
    echo "CONFLICT on $branch while cherry-picking:" >&2
    git diff --name-only --diff-filter=U >&2
    echo "Resolve, 'git add' the files, 'git cherry-pick --continue', then re-run." >&2
    exit 1
  fi

  if ! git rebase --onto "$NEW_TAG" "$OLD_TAG" "$branch"; then
    echo "" >&2
    echo "CONFLICT on $branch while rebasing onto $NEW_TAG:" >&2
    git diff --name-only --diff-filter=U >&2
    echo "Resolve, 'git add' the files, 'git rebase --continue', then re-run." >&2
    exit 1
  fi

  echo "   $branch -> $(git rev-parse --short HEAD)"
done

echo ""
echo "Done. Next, by hand (see UPGRADE.md):"
echo "  git checkout -B custom/${NEW_TAG#v} $NEW_TAG"
echo "  for b in patch/teams-host-attendee patch/ews-dup-guard patch/ews-fixes patch/itip; do git merge --no-ff \"\$b\"; done"
