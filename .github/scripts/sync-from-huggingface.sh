#!/usr/bin/env bash
# Import the public Hugging Face main branch without rewriting either history.
set -Eeuo pipefail

HF_REPOSITORY="${HF_REPOSITORY:-https://huggingface.co/eyinlojuoluwa/distilbert-base-uncased-commit_labeller}"
HF_BRANCH="${HF_BRANCH:-main}"
TARGET_BRANCH="${TARGET_BRANCH:-main}"
MIRROR_BRANCH="${MIRROR_BRANCH:-huggingface-main}"
HF_REMOTE="huggingface"

export GIT_LFS_SKIP_SMUDGE=1

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
  fi
}

[[ "$(git branch --show-current)" == "$TARGET_BRANCH" ]] ||
  die "this job must check out ${TARGET_BRANCH}"
git remote get-url origin >/dev/null 2>&1 || die "origin is not configured"
command -v git-lfs >/dev/null 2>&1 || die "Git LFS is not installed"
git lfs install --local

if git remote get-url "$HF_REMOTE" >/dev/null 2>&1; then
  git remote set-url "$HF_REMOTE" "$HF_REPOSITORY"
else
  git remote add "$HF_REMOTE" "$HF_REPOSITORY"
fi
# Make the chosen direction explicit even in a maintainer's local checkout.
git remote set-url --push "$HF_REMOTE" no_push

# Fetch only the branch being mirrored. LFS smudging is disabled; objects are
# transferred explicitly after the Git histories have passed the safety checks.
git fetch --no-tags --prune "$HF_REMOTE" \
  "+refs/heads/${HF_BRANCH}:refs/remotes/${HF_REMOTE}/${HF_BRANCH}"
upstream_ref="refs/remotes/${HF_REMOTE}/${HF_BRANCH}"
upstream_sha="$(git rev-parse --verify "${upstream_ref}^{commit}")"

old_sha=""
if git ls-remote --exit-code --heads origin \
  "refs/heads/${MIRROR_BRANCH}" >.git/huggingface-mirror-ref; then
  old_sha="$(awk 'NR == 1 { print $1 }' .git/huggingface-mirror-ref)"
  git fetch --no-tags origin \
    "+refs/heads/${MIRROR_BRANCH}:refs/remotes/origin/${MIRROR_BRANCH}"
fi
rm -f .git/huggingface-mirror-ref

remote_target_before="$(git ls-remote --heads origin \
  "refs/heads/${TARGET_BRANCH}" | awk 'NR == 1 { print $1 }')"
if [[ -n "$remote_target_before" ]]; then
  git fetch --no-tags origin \
    "+refs/heads/${TARGET_BRANCH}:refs/remotes/origin/${TARGET_BRANCH}"
  git merge-base --is-ancestor "$remote_target_before" HEAD ||
    die "remote ${TARGET_BRANCH} has commits that are not in this checkout; refusing to overwrite them"
fi

# Never silently absorb or propagate an upstream force-push. Rewriting model
# history should be reviewed and handled manually.
if [[ -n "$old_sha" ]] &&
   ! git merge-base --is-ancestor "$old_sha" "$upstream_sha"; then
  die "Hugging Face ${HF_BRANCH} was rewritten (${old_sha} -> ${upstream_sha}); refusing to force-push"
fi

# Do not let a non-GitHub source silently install executable GitHub Actions.
# Such a change needs explicit review and a workflow-authorized credential.
if [[ -n "$old_sha" ]]; then
  workflow_paths="$(git diff --name-only "${old_sha}..${upstream_sha}" -- \
    '.github/workflows' || true)"
else
  workflow_paths="$(git ls-tree -r --name-only "$upstream_sha" -- \
    '.github/workflows' || true)"
fi
[[ -z "$workflow_paths" ]] ||
  die "upstream changed .github/workflows; review and import that change manually"

already_integrated=false
if git merge-base --is-ancestor "$upstream_sha" HEAD; then
  already_integrated=true
fi

if [[ "$old_sha" == "$upstream_sha" &&
      "$already_integrated" == true &&
      "$remote_target_before" == "$(git rev-parse HEAD)" ]]; then
  printf 'Already synchronized at %s.\n' "$upstream_sha"
  summary "### Hugging Face synchronization"
  summary "No update was needed; \`${MIRROR_BRANCH}\` is at \`${upstream_sha}\`."
  exit 0
fi

if [[ -n "$old_sha" ]]; then
  imported_count="$(git rev-list --count "${old_sha}..${upstream_sha}")"
else
  imported_count="$(git rev-list --count "$upstream_sha")"
fi

if [[ "$already_integrated" == false ]]; then
  short_sha="$(git rev-parse --short=12 "$upstream_sha")"
  git -c user.name='github-actions[bot]' \
      -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
      merge --no-ff --no-edit "$upstream_sha" \
      -m "Merge Hugging Face main at ${short_sha}"
fi

# A Git commit stores only a 134-byte pointer for model.safetensors. Fetch every
# LFS object reachable from the imported history, validate it locally, and then
# upload it to GitHub before moving either remote branch.
git lfs fetch --all "$HF_REMOTE" "$upstream_sha"
git lfs fsck --objects "$upstream_sha"
git lfs fsck --pointers "$upstream_sha"
git lfs push --all origin HEAD "$upstream_sha"

# Update the integration branch and the exact-source branch together. A normal,
# atomic push makes races fail safely rather than overwriting somebody's work.
git push --atomic origin \
  "HEAD:refs/heads/${TARGET_BRANCH}" \
  "${upstream_sha}:refs/heads/${MIRROR_BRANCH}"

remote_target_sha="$(git ls-remote --exit-code --heads origin \
  "refs/heads/${TARGET_BRANCH}" | awk 'NR == 1 { print $1 }')"
remote_mirror_sha="$(git ls-remote --exit-code --heads origin \
  "refs/heads/${MIRROR_BRANCH}" | awk 'NR == 1 { print $1 }')"
[[ "$remote_target_sha" == "$(git rev-parse HEAD)" ]] ||
  die "remote ${TARGET_BRANCH} did not reach the expected commit"
[[ "$remote_mirror_sha" == "$upstream_sha" ]] ||
  die "remote ${MIRROR_BRANCH} does not match Hugging Face"

printf 'Imported %s commit(s); Hugging Face is now at %s.\n' \
  "$imported_count" "$upstream_sha"
summary "### Hugging Face synchronization"
summary "Imported **${imported_count}** commit(s)."
summary "Exact source revision: \`${upstream_sha}\`."
summary "Git LFS objects were validated and uploaded before the atomic ref update."
