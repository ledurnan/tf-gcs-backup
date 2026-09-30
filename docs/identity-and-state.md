# Identity and state

Terraform for this pattern runs as a **dedicated service account per
Google Cloud project**, impersonated from a named operator account, with
state in a versioned bucket in the same project.

## Why not application-default credentials

`gcloud auth application-default login` writes one credentials file per
machine. On a workstation with several Google accounts (personal and
work), Terraform would use whichever logged in last, in every project.
Instead, each consuming configuration pins its identity in a
`.tf-identity` file:

```
ACCOUNT=you@example.com
SERVICE_ACCOUNT=tf-gcs-backup@your-project.iam.gserviceaccount.com
```

and runs Terraform through [`scripts/tf-with-identity`](../scripts/tf-with-identity).
The script mints a one-hour token for `SERVICE_ACCOUNT` from `ACCOUNT` by
impersonation, passes it as `GOOGLE_OAUTH_ACCESS_TOKEN` (read by both the
provider and the `gcs` backend), and refuses to fall back to anything
else. `.tf-identity` holds no secrets and is committed.

## Setting up a project, once

[`scripts/bootstrap-project`](../scripts/bootstrap-project), run by a
project owner **as themselves**:

```bash
scripts/bootstrap-project --project your-project --account you@example.com \
  --location europe-west2 --state-bucket your-project-tfstate          # prints the plan
scripts/bootstrap-project ... --apply                                  # runs it
```

It creates, if missing: the APIs impersonation needs; a custom role for
Terraform that can manage buckets, custom roles and service accounts but
**can't delete any of them, can't read or write objects in backup
buckets, and can't create keys**; the Terraform service account; a
versioned state bucket, which that account can use; and permission for
the operator to impersonate it. Re-running is safe.

Because Terraform can't delete buckets or service accounts, removing a
backup target is a deliberate manual step by a project owner, which is
the point.

## State

```hcl
terraform {
  backend "gcs" {
    bucket = "your-project-tfstate"
    prefix = "<consumer>/<name>"
  }
}
```

The state bucket is versioned: an older version of the state is the undo
for a bad apply. State holds resource IDs and settings, and no keys
(ADR 0002).
