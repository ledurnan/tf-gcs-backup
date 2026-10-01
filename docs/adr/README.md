# Decisions

One file per decision. A decision is **Proposed** until the owner accepts
it; accepted decisions are changed only by a new one that supersedes
them.

| ADR                                              | Decision                                                                     | Status   |
| ------------------------------------------------ | ---------------------------------------------------------------------------- | -------- |
| [0001](0001-one-bucket-per-host.md)              | One bucket per backed-up host (per tier since 0007)                          | Proposed |
| [0002](0002-keys-out-of-band.md)                 | Service account keys are issued out of band, never through Terraform         | Proposed |
| [0003](0003-tier-contract.md)                    | The host checks the bucket's expiry rules before every run                   | Proposed |
| [0004](0004-terraform-and-provider-range.md)     | Terraform 1.7+, Google provider 7.x to 8.x; OpenTofu untested                | Proposed |
| [0005](0005-distribution.md)                     | Modules by git tag, the role as a collection from the same tag               | Proposed |
| [0006](0006-ownership.md)                        | Work projects depend on it like any external project                         | Accepted |
| [0007](0007-bucket-retention-policy-per-tier.md) | Retention is a bucket policy, one bucket per tier; the host never chooses it | Proposed |
