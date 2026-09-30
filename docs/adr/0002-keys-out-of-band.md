# 0002: Service account keys are issued out of band

- Status: Proposed

## Context

Each host authenticates with its service account. The Google provider can
create keys (`google_service_account_key`), but the private key is then
stored in Terraform state, which makes the state as sensitive as every
key in it, for as long as the state exists.

Keyless authentication (workload identity federation) avoids long-lived
keys, but needs an identity provider the host can prove itself to. Cloud
VMs have one built in; hosts on a home lab, a VPS provider or on-premises
generally don't, and running an OIDC issuer for them is its own project.

## Decision

Keys are never created by Terraform. The `backup-target` module outputs
`key_issue_command`, the one `gcloud` command that issues the key; an
operator runs it deliberately, stores the key in the consumer's secret
store, and deletes the file. The Ansible role validates the key's JSON
shape before using it.

## Consequences

- Terraform state holds no credentials.
- Key rotation is a manual step: issue a new key, update the secret,
  apply the role, then delete the old key in Google Cloud. Nothing tracks
  a key's age yet.
- Revisit keyless authentication for hosts that run on a platform with a
  usable identity provider.
