# 0005: Distribution by tag, from one repository

- Status: Proposed

## Decision

Both halves are released together by tagging this repository
(`vX.Y.Z`), so a tag is a matched pair.

- **Terraform:**
  `source = "git::https://github.com/ledurnan/tf-gcs-backup.git//modules/<module>?ref=vX.Y.Z"`
- **Ansible:** the collection is built from `ansible/` and attached to
  each GitHub release by CI (`ledurnan-gcs_backup-X.Y.Z.tar.gz`).
  Consumers install that file by URL:

  ```yaml
  collections:
    - name: https://github.com/ledurnan/tf-gcs-backup/releases/download/vX.Y.Z/ledurnan-gcs_backup-X.Y.Z.tar.gz
      type: url
  ```

  **Not from git.** `ansible-galaxy` can install straight from the
  `ansible/` subdirectory of a tag, but it does so by cloning, and inside
  a git hook the clone inherits `GIT_INDEX_FILE` and overwrites the
  committing repository's index with this repository's tree. An
  ansible-lint pre-commit hook installs `requirements.yml`, so this bit
  the first consumer (in a worktree, with nothing lost) the day v0.1.0
  was released. A URL install runs no git at all.

`ansible/galaxy.yml`'s `version` is bumped to match each tag.

## Visibility

The repository will be **public** once v0.1 is ready: it holds no
secrets, no state and no real project IDs, and being public removes the
need for deploy keys or tokens in every consuming organisation and CI.
Until then it stays private, and its history is kept free of AI
attribution (the commit-policy hook enforces this).

## Consequences

Renovate (or Dependabot) can propose tag bumps in consumers, as for any
other pinned dependency.
