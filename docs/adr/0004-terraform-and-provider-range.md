# 0004: Terraform 1.7+, Google provider 7.x to 8.x

- Status: Proposed

## Decision

- The modules require Terraform `>= 1.7`, the first version with mock
  providers in `terraform test`, which the module tests use. CI runs the
  current release.
- The Google provider range is `>= 7.0, < 9.0`. Every attribute used was
  checked against the 8.4 schema, including `enable_object_retention`
  and the bucket's `deletion_policy`.
- **OpenTofu** is untested. The modules use nothing Terraform-specific
  beyond `terraform test`, so they will likely work, but a consumer
  choosing OpenTofu should treat it as unverified until CI covers it.

## Consequences

Consumers pin the provider in their own configuration and commit their
own lock file; the modules don't commit one. A new major provider version
needs the range widened here, after the tests pass against it.
