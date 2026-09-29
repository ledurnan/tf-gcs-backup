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

## Open: access to a private repository

The repository is private. Every consumer that fetches it needs read
access: a person's `gh`/git credentials locally, and in CI a deploy key or
a fine-grained token scoped to this repository, configured in each
consuming organisation. The alternative is making it public: it contains
no secrets. Not decided here.

## Consequences

Renovate (or Dependabot) can propose tag bumps in consumers, as for any
other pinned dependency.
