#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_tag_prefix="${TIP_TAG_PREFIX:-tip-}"
release_name_prefix="${TIP_RELEASE_NAME_PREFIX:-Tip}"

require_clean_worktree=true
if [[ "${1:-}" == "--allow-dirty" ]]; then
    require_clean_worktree=false
    shift
fi

if [[ $# -gt 0 ]]; then
    echo "usage: $0 [--allow-dirty]" >&2
    exit 1
fi

cd "${repo_root}"

if ! command -v gh >/dev/null 2>&1; then
    echo "gh is required" >&2
    exit 1
fi

if [[ "${require_clean_worktree}" == "true" ]] && [[ -n "$(git status --short)" ]]; then
    echo "worktree must be clean before publishing tip release" >&2
    exit 1
fi

current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "${current_branch}" != "dev" ]]; then
    echo "tip release must be published from the dev branch" >&2
    exit 1
fi

git fetch origin dev --tags

current_sha="$(git rev-parse HEAD)"
origin_dev_sha="$(git rev-parse origin/dev)"
if [[ "${current_sha}" != "${origin_dev_sha}" ]]; then
    echo "HEAD (${current_sha}) must match origin/dev (${origin_dev_sha}) before publishing tip release" >&2
    exit 1
fi

target="$(rustc -vV | awk '/^host:/ { print $2 }')"
if [[ -z "${target}" ]]; then
    echo "failed to determine Rust host target" >&2
    exit 1
fi

short_sha="${current_sha:0:12}"
release_tag="${release_tag_prefix}${current_sha}"
release_name="${release_name_prefix} ${short_sha}"
asset_name="codex-tip-${short_sha}-${target}.tar.gz"
output_dir="$(mktemp -d)"
trap 'rm -rf "${output_dir}"' EXIT

(
    cd codex-rs
    cargo build --release --bin codex --target "${target}"
)

stage_dir="${output_dir}/codex-tip-${target}"
mkdir -p "${stage_dir}"
cp "codex-rs/target/${target}/release/codex" "${stage_dir}/codex"
cat > "${stage_dir}/BUILD_INFO.txt" <<EOF
ref=dev
sha=${current_sha}
target=${target}
built_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

tar -C "${output_dir}" -czf "${output_dir}/${asset_name}" "codex-tip-${target}"

if gh release view tip >/dev/null 2>&1; then
    gh release delete tip --yes --cleanup-tag
elif git ls-remote --exit-code origin refs/tags/tip >/dev/null 2>&1; then
    git push origin :refs/tags/tip
fi

git tag -f "${release_tag}" "${current_sha}"
git push origin "refs/tags/${release_tag}"

release_notes="Dev tip build for ${current_sha} (${target})"
if gh release view "${release_tag}" >/dev/null 2>&1; then
    gh release edit "${release_tag}" \
        --title "${release_name}" \
        --notes "${release_notes}" \
        --prerelease
else
    gh release create "${release_tag}" \
        --title "${release_name}" \
        --notes "${release_notes}" \
        --prerelease
fi

gh release upload "${release_tag}" "${output_dir}/${asset_name}" --clobber

echo "Published ${asset_name} to release ${release_tag} for ${current_sha}"
