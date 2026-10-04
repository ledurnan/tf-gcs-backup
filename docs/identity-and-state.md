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

Use a project that holds nothing but backups, one per system, and put
any other cloud service in a different project
([ADR 0010](adr/0010-backup-only-project.md)). Most IAM roles are
granted per project, so a project shared with running services lets
their identities delete the backups. Project IDs can't be changed, so
name it for what it holds, for example `yourorg-app-backup`.

[`scripts/bootstrap-project`](../scripts/bootstrap-project), run by a
project owner **as themselves**:

```bash
scripts/bootstrap-project --project your-project --account you@example.com \
  --location europe-west2 --state-bucket your-project-tfstate          # prints the plan
scripts/bootstrap-project ... --apply                                  # runs it
```

It creates, if missing: the APIs impersonation needs; a custom role for
Terraform that can manage buckets, custom roles and service accounts but
**has no permission to delete any of them, to read or write objects in
backup buckets, or to create keys**; the Terraform service account; a
versioned state bucket, which that account can use; and permission for
the operator to impersonate it. Re-running is safe.

Because the role holds no delete permission, a `terraform destroy` or a
plan that replaces a bucket fails, and removing a backup target is a
deliberate manual step by a project owner, which is the point.

This guards against accidents. It is not a limit on the person running
Terraform: the role has to manage the writer role and its binding, so it
can change custom roles and bucket IAM in the project, and someone
holding it could grant themselves the permissions it lacks. Only give
impersonation of the Terraform service account to people you would trust
with the project's IAM.

Bucket names are shared by every Google Cloud project, so
`--state-bucket` may name a bucket that already exists somewhere else.
The script uses an existing bucket only if it is in this project, and
stops otherwise. A name with a suffix nobody could guess (for example
`your-project-tfstate-7f3a`) avoids the collision.

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
