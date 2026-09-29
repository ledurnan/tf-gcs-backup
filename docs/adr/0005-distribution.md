# 0005: Distribution by tag, from one repository

- Status: Proposed

## Decision

Both halves are released together by tagging this repository
(`vX.Y.Z`), so a tag is a matched pair.

- **Terraform:**
  `source = "git::https://github.com/ledurnan/tf-gcs-backup.git//modules/<module>?ref=vX.Y.Z"`
- **Ansible:** the collection is built from the `ansible/` subdirectory:
  `ansible-galaxy collection install "git+https://github.com/ledurnan/tf-gcs-backup.git#/ansible/,vX.Y.Z"`,
  or in a `requirements.yml`:

  ```yaml
  collections:
    - name: https://github.com/ledurnan/tf-gcs-backup.git#/ansible/
      type: git
      version: vX.Y.Z
  ```

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
