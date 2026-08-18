# Hugging Face to GitHub mirror

## Policy

The canonical model repository is
[`eyinlojuoluwa/distilbert-base-uncased-commit_labeller`](https://huggingface.co/eyinlojuoluwa/distilbert-base-uncased-commit_labeller)
on Hugging Face. GitHub is a **one-way, read-only mirror of the model history**.
Model files should be changed on Hugging Face, not independently on GitHub.
This avoids synchronization loops, ambiguous conflict resolution, and accidental
model history rewrites.

The GitHub repository has two branches:

- `huggingface-main` is the exact Hugging Face `main` commit. Matching commit
  IDs prove that the complete Git tree and its history match the source. Do not
  commit to this branch.
- `main` is GitHub's default integration branch. It contains every upstream
  commit unchanged, plus the synchronization implementation and merge commits
  made by it. Keeping GitHub-specific files outside the exact-source branch
  preserves the upstream commit IDs.

## Trigger and failure behavior

The selected operational trigger is a six-hour GitHub Actions schedule plus
`workflow_dispatch` for manual runs. Polling is intentionally used instead of a
webhook: the source is public, no Hugging Face or cross-service webhook
credential is needed, and a model repository does not require second-level
propagation. The expected maximum delay is roughly six hours, subject to
GitHub's scheduled-job queue.

The bootstrap credential could create and populate the repository, but it did
not have GitHub's separate `workflow` scope. GitHub therefore refused to install
a file under `.github/workflows/`. The reviewed workflow is committed as
[`automation/sync-from-huggingface.yml`](automation/sync-from-huggingface.yml),
but **the schedule is not active until a repository owner installs it**. Use the
GitHub web editor, or push the following change with a classic token that has
both `repo` and `workflow` scopes (equivalent fine-grained permissions also
work):

```bash
mkdir -p .github/workflows
cp automation/sync-from-huggingface.yml \
  .github/workflows/sync-from-huggingface.yml
git add .github/workflows/sync-from-huggingface.yml
git commit -m "Enable scheduled Hugging Face synchronization"
git push origin main
```

Until then, a maintainer can run the same guarded synchronization manually from
a current `main` checkout:

```bash
.github/scripts/sync-from-huggingface.sh
```

The sync job:

1. fetches Hugging Face `main` without downloading model data;
2. rejects a non-fast-forward source rewrite;
3. merges new source commits into GitHub `main` without changing their IDs;
4. fetches and validates all reachable Git LFS objects;
5. uploads LFS objects to GitHub; and
6. atomically advances both GitHub branches, then reads the remote refs back.

A merge conflict, missing/corrupt LFS object, source history rewrite, concurrent
push, failed upload, or an upstream change under `.github/workflows/` stops the
job. The last check prevents a non-GitHub source from silently installing
executable GitHub automation. The script never force-pushes and configures the
Hugging Face remote as fetch-only, so it cannot push in the reverse direction.
Once the workflow is installed, failed scheduled runs are visible in Actions
and use GitHub's normal workflow-failure notifications.

## Large model artifact

`.gitattributes` assigns `*.safetensors` to Git LFS. Consequently, Git stores a
small pointer while LFS stores the model payload. At bootstrap the artifact was:

| Path | LFS SHA-256 OID | Size |
| --- | --- | ---: |
| `model.safetensors` | `ec800033329b87581206965d697347fd5ba3d7c8500f0b76f85948d3f9d7f8ae` | 267,872,556 bytes |

The payload is too large for an ordinary GitHub Git blob, but is within GitHub
LFS's per-file limit. It consumes the GitHub account's LFS storage, and every
materialized clone consumes LFS bandwidth. The sync script performs no LFS
transfer when both remote branches are already synchronized.

## Verification

First compare the exact-source refs. They must print the same 40-character ID:

```bash
git ls-remote \
  https://huggingface.co/eyinlojuoluwa/distilbert-base-uncased-commit_labeller \
  refs/heads/main
git ls-remote \
  https://github.com/kesasta/distilbert-base-uncased-commit_labeller.git \
  refs/heads/huggingface-main
```

Matching IDs verify all normal Git files and source commits. To independently
verify that GitHub also serves the LFS payload, use a disposable clone:

```bash
tmp="$(mktemp -d)"
GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 \
  --branch huggingface-main \
  https://github.com/kesasta/distilbert-base-uncased-commit_labeller.git \
  "$tmp/model"
git -C "$tmp/model" lfs pull --include=model.safetensors
sha256sum "$tmp/model/model.safetensors"
stat -c '%s bytes' "$tmp/model/model.safetensors"
rm -rf "$tmp"
```

The hash and size should match the table above unless a later intentional model
update changes the pointer. `git lfs fsck` can be run in a materialized clone for
an additional local integrity check.

## Is a second copy necessary?

Hugging Face is the more useful canonical host for this repository: it supports
model discovery and model-aware downloads, while GitHub LFS adds storage and
bandwidth costs. Keep this mirror only if GitHub-native history browsing,
review, archival, or automation is a real requirement. If those are not needed,
a small GitHub repository linking to Hugging Face—or no GitHub repository at
all—is simpler.

If the mirror is retired, disable any installed scheduled workflow and archive
the GitHub repository. If GitHub later becomes canonical, remove this sync
before adding a single GitHub-to-Hugging-Face publisher; do not run both
directions.
