# AGENTS.md

Off-site backups to Google Cloud Storage that a compromised host can't erase.
Two halves, versioned together and released under one tag:

- `modules/`: Terraform receiving side (`project-role`, `backup-target`)
- `ansible/`: Ansible collection `ledurnan.gcs_backup` (sending side, role
  `offsite_backup`)
- `scripts/`: key issuing, restore test and bootstrap tools
- `examples/`: example configurations; `docs/`: user and design docs

The repository is public and holds no state, no secrets and no real project
IDs. Keep it that way.

## Build and test

`make help` lists the targets. `make test` runs everything CI runs except
tflint and gitleaks (Terraform validate and test with a mock provider,
shellcheck, ruff, pytest, bats, render, ansible-lint); `make tflint` runs
tflint.

## Architecture decisions (ADRs)

`docs/adr/` holds the decision records, one file per decision, indexed with
their status in `docs/adr/README.md`. They record why the design is the way
it is: bucket and tier layout, key handling, retention, distribution and
ownership. Read the relevant ADRs before changing anything they cover. An
accepted decision is changed only by a new ADR that supersedes it: when you
make a decision of that kind, add an ADR with the next number and list it in
the index.
