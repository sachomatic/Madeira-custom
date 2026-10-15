#!/usr/bin/env bash
# Opens the Epic Cloud saves pull request against iediot/Madeira (the author of upstream PR #207),
# base branch epic-games. Run in WSL/Linux/macOS with git and the GitHub CLI (gh, or gh.exe from WSL).
# Used on 2026-10-15: https://github.com/iediot/Madeira/pull/1
#
#   one-time:   gh auth login          (you sign in; nothing here sees your password)
#   check only: bash open-epic-cloud-pr.sh --dry-run      builds the commit locally, pushes nothing
#   for real:   bash open-epic-cloud-pr.sh
#
# What it does: shallow, sparse clone of iediot/Madeira@epic-games (a few files, not the 180 MB repo),
# applies epic-cloud-saves.patch on a branch epic-cloud-saves, commits as you, pushes the branch to your
# fork and opens the pull request with PR-BODY.md.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
WORK="${WORK:-$HOME/pr-epic-cloud}"
UPSTREAM=iediot/Madeira
BASE=epic-games
EXPECT=e81e8128da      # the head this patch was tested against
CR=$'\r'

command -v git >/dev/null || { echo "git is needed"; exit 1; }
# The GitHub CLI: gh, or (inside WSL, with gh installed on Windows) gh.exe.
GH=gh; command -v gh >/dev/null 2>&1 || { command -v gh.exe >/dev/null 2>&1 && GH=gh.exe; }
ghx() { "$GH" "$@" | tr -d "$CR"; }
if [ "$DRY" = 0 ]; then
    command -v "$GH" >/dev/null 2>&1 || { echo "install the GitHub CLI (https://cli.github.com) and run: gh auth login"; exit 1; }
    "$GH" auth status >/dev/null 2>&1 || { echo "not signed in: run  gh auth login"; exit 1; }
fi
# Commit as you: your git identity, else your GitHub name and its no-reply address (no private email).
if [ -z "$(git config user.name || true)" ] || [ -z "$(git config user.email || true)" ]; then
    if [ "$DRY" = 1 ]; then
        export GIT_AUTHOR_NAME="Dry Run" GIT_AUTHOR_EMAIL=dry@example.invalid GIT_COMMITTER_NAME="Dry Run" GIT_COMMITTER_EMAIL=dry@example.invalid
    else
        login="$(ghx api user -q .login)"; uid="$(ghx api user -q .id)"; real="$(ghx api user -q .name)"
        export GIT_AUTHOR_NAME="${real:-$login}" GIT_AUTHOR_EMAIL="$uid+$login@users.noreply.github.com"
        export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
        echo "committing as $GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL> (set git config user.name / user.email to change)"
    fi
fi

rm -rf "$WORK"
git clone -q --depth 1 --filter=blob:none --no-checkout --branch "$BASE" "https://github.com/$UPSTREAM.git" "$WORK"
cd "$WORK"
head="$(git rev-parse --short=10 HEAD)"
if [ "$head" != "$EXPECT" ]; then
    echo "note: $UPSTREAM@$BASE is now $head, the patch was tested on $EXPECT; checking that it still applies"
fi
git sparse-checkout init --no-cone
git sparse-checkout set app/Madeira/Library.swift app/Madeira/Epic app/Madeira.xcodeproj/project.pbxproj docs/EPIC.md tests/host
git checkout -q "$BASE"
git checkout -q -b epic-cloud-saves
git apply --check "$HERE/epic-cloud-saves.patch" || { echo "the patch no longer applies to $UPSTREAM@$BASE; it needs a refresh"; exit 1; }
git apply "$HERE/epic-cloud-saves.patch"
git add -A
git commit -q -F - <<'EOF'
Epic: cloud saves

Sync the save files of installed Epic games with the account's Epic Cloud, in the format Legendary
reads and writes: downloads are verified before anything is written and back up what they replace,
uploads are new snapshots (nothing in the cloud is overwritten or deleted), and a save that changed on
both sides waits for the user's choice. Uploading newer saves is manual by default.

tests/host/check-epic-cloud.py checks the code against Legendary's own Manifest, Chunk and
SaveGameHelper in both directions.
EOF
git --no-pager log --stat --oneline -1 | tail -15
if [ "$DRY" = 1 ]; then
    echo; echo "dry run: the commit is in $WORK (branch epic-cloud-saves); nothing was pushed or opened"; exit 0
fi

me="$(ghx api user -q .login)"
# Your fork in this fork network. GitHub allows one per account, and its name may not be "Madeira"
# (it may even be a fork of the parent project rather than of iediot's: pull requests work between them).
out="$("$GH" repo fork "$UPSTREAM" --clone=false 2>&1 | tr -d "$CR" || true)"
echo "$out"
forkname="$(printf '%s\n' "$out" | grep -oE "$me/[A-Za-z0-9._-]+" | head -1 || true)"
forkname="${forkname:-$me/Madeira}"
for _ in 1 2 3 4 5 6; do ghx api "repos/$forkname" -q .full_name >/dev/null 2>&1 && break; sleep 5; done
ghx api "repos/$forkname" -q .full_name >/dev/null 2>&1 || { echo "the fork $forkname is not reachable"; exit 1; }
echo "fork: $forkname"

# A shallow clone cannot be pushed to another repository: fetch the commit history (no file contents).
git fetch -q --unshallow --filter=blob:none origin "$BASE"
git remote add fork "https://github.com/$forkname.git"
# Push with gh's token for this one command (never written to the repository's config).
token="$("$GH" auth token | tr -d "$CR\n")"
auth="$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $auth" push -u fork epic-cloud-saves

body="$(cat "$HERE/PR-BODY.md")"
ghx api "repos/$UPSTREAM/pulls" -f title="Epic Cloud saves" -f head="$me:epic-cloud-saves" -f base="$BASE" \
    -f body="$body" -F maintainer_can_modify=true -q .html_url
