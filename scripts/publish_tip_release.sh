#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_tag="${TIP_TAG:-tip}"
release_name="${TIP_RELEASE_NAME:-Tip}"

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

asset_name="codex-tip-${target}.tar.gz"
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

existing_tag_sha=""
if git rev-parse "refs/tags/${release_tag}^{commit}" >/dev/null 2>&1; then
    existing_tag_sha="$(git rev-parse "refs/tags/${release_tag}^{commit}")"
fi

if gh release view "${release_tag}" >/dev/null 2>&1; then
    if [[ -n "${existing_tag_sha}" ]] && [[ "${existing_tag_sha}" != "${current_sha}" ]]; then
        mapfile -t existing_assets < <(gh release view "${release_tag}" --json assets --jq '.assets[].name')
        for existing_asset in "${existing_assets[@]}"; do
            gh release delete-asset "${release_tag}" "${existing_asset}" --yes
        done
    fi
else
    existing_tag_sha=""
fi

git tag -f "${release_tag}" "${current_sha}"
git push origin "refs/tags/${release_tag}" --force

release_notes="Latest dev tip build for ${current_sha} (${target})"
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
