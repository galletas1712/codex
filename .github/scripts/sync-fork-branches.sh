#!/usr/bin/env bash

set -euo pipefail

upstream_repo="${UPSTREAM_REPO:-openai/codex}"
upstream_branch="${UPSTREAM_BRANCH:-main}"
mirror_branch="${MIRROR_BRANCH:-main}"
patch_branch="${PATCH_BRANCH:-dev}"
patch_branch_test_command="${PATCH_BRANCH_TEST_COMMAND:-}"
dry_run="${DRY_RUN:-0}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "sync-fork-branches must run inside a git repository" >&2
    exit 1
fi

if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    git config user.name "${GIT_AUTHOR_NAME:-github-actions[bot]}"
    git config user.email "${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
fi

upstream_url="https://github.com/${upstream_repo}.git"
if git remote get-url upstream >/dev/null 2>&1; then
    git remote set-url upstream "${upstream_url}"
else
    git remote add upstream "${upstream_url}"
fi

git fetch --prune origin "${mirror_branch}" "${patch_branch}"
git fetch --prune upstream "${upstream_branch}"

origin_mirror_ref="origin/${mirror_branch}"
origin_patch_ref="origin/${patch_branch}"
upstream_ref="upstream/${upstream_branch}"

origin_mirror_sha="$(git rev-parse "${origin_mirror_ref}")"
origin_patch_sha="$(git rev-parse "${origin_patch_ref}")"
upstream_sha="$(git rev-parse "${upstream_ref}")"

echo "Syncing ${mirror_branch} from ${upstream_repo}@${upstream_branch}"
echo "  origin/${mirror_branch}: ${origin_mirror_sha}"
echo "  ${upstream_ref}: ${upstream_sha}"

git checkout -B "${mirror_branch}" "${origin_mirror_ref}"
git reset --hard "${upstream_ref}"

if [[ "${origin_mirror_sha}" != "${upstream_sha}" ]]; then
    if [[ "${dry_run}" == "1" ]]; then
        echo "[dry-run] git push --force-with-lease=refs/heads/${mirror_branch}:${origin_mirror_sha} origin ${mirror_branch}"
    else
        git push --force-with-lease="refs/heads/${mirror_branch}:${origin_mirror_sha}" origin "${mirror_branch}"
    fi
else
    echo "${mirror_branch} already matches ${upstream_ref}"
fi

echo "Rebasing ${patch_branch} onto ${mirror_branch}"
echo "  origin/${patch_branch}: ${origin_patch_sha}"

git checkout -B "${patch_branch}" "${origin_patch_ref}"
if ! git rebase "${mirror_branch}"; then
    conflicted_files="$(git diff --name-only --diff-filter=U || true)"
    git rebase --abort || true
    echo "::error::Failed to rebase ${patch_branch} onto ${mirror_branch}" >&2
    if [[ -n "${conflicted_files}" ]]; then
        printf 'Conflicted files:\n%s\n' "${conflicted_files}" >&2
    fi
    exit 1
fi

rebased_patch_sha="$(git rev-parse HEAD)"
echo "  rebased ${patch_branch}: ${rebased_patch_sha}"

if [[ "${rebased_patch_sha}" == "${origin_patch_sha}" ]]; then
    echo "${patch_branch} is already up to date"
    exit 0
fi

if [[ -n "${patch_branch_test_command}" ]]; then
    echo "Running validation: ${patch_branch_test_command}"
    bash -lc "${patch_branch_test_command}"
fi

if [[ "${dry_run}" == "1" ]]; then
    echo "[dry-run] git push --force-with-lease=refs/heads/${patch_branch}:${origin_patch_sha} origin ${patch_branch}"
else
    git push --force-with-lease="refs/heads/${patch_branch}:${origin_patch_sha}" origin "${patch_branch}"
fi
