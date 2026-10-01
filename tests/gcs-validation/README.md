# Validating v0.2 against real Google Cloud Storage

The unit tests run against a mock provider and a fake `gcloud`. This
checks what they can't: how real GCS behaves with bucket retention
policies, and that a v0.1 host upgrades the way
[`docs/upgrading-to-v0.2.md`](../../docs/upgrading-to-v0.2.md) says.

It creates, in an existing project, and touches nothing else:

| What                             | Name                                                                 |
| -------------------------------- | -------------------------------------------------------------------- |
| Custom role                      | `tfgcsbValidationWriter` (never the default role ID)                 |
| A host as v0.1 left it, upgraded | bucket `<prefix>-upg`, then `<prefix>-upg-daily`, SA `tfgcsb-upg`    |
| A fresh v0.2 host                | buckets `<prefix>-val-daily`, `<prefix>-val-locked`, SA `tfgcsb-val` |

Every bucket is labelled `purpose=tf-gcs-backup-validation`. State is
local (`.state/`), never the project's state bucket. Real project IDs and
accounts live only in the git-ignored `validation.tfvars` and
`.tf-identity`.

**Two things can't be undone quickly:**

- Locking `<prefix>-val-locked` (step 7) is permanent. The bucket can't
  be deleted until its objects are past their 1-day retention.
- Locking may place a **lien** on the project that blocks deleting the
  project until the bucket is gone. Step 7 checks for one.

## A dedicated project (preferred)

A throwaway project keeps the test away from anything real, makes
cleanup one `gcloud projects delete`, and is the only way to see whether
a locked bucket blocks deleting a project.

```bash
gcloud projects create <id> --name="tf-gcs-backup validation" --account=<you>
gcloud billing projects link <id> --billing-account=<billing account> --account=<you>
../../scripts/bootstrap-project --project <id> --account <you> \
  --location europe-west2 --state-bucket <id>-tfstate            # read the plan
../../scripts/bootstrap-project ... --apply
```

- A billing account allows only a few linked projects (five, by
  default). If linking fails with `Cloud billing quota exceeded`,
  unlink an unused project for the duration, or ask Google for more.
- A budget alert needs the Budgets API enabled on a project and
  `--billing-project=<id>`. Otherwise gcloud charges the call to
  whatever quota project it defaults to.
- Impersonating the new Terraform account can be refused for a few
  minutes after bootstrap, until the grant takes effect.

Then skip step 1's clash check.

## Before you start

- You're a project owner, logged in to `gcloud` as that account
  (`gcloud auth list`).
- The project has the Terraform identity from
  [`scripts/bootstrap-project`](../../scripts/bootstrap-project).
- `terraform`, `gcloud` and `age` are installed. `gcloud alpha` is only
  needed for the lien check.

Commands run from this directory, except `tf`, which runs inside `v01/`
or `v02/`. `tf` below means:

```bash
tf() { TF_IDENTITY_FILE=../.tf-identity ../../../scripts/tf-with-identity "$@"; }
```

## 1. Configure

```bash
cp validation.tfvars.example validation.tfvars   # project, location, name_prefix
cp .tf-identity.example .tf-identity             # ACCOUNT, SERVICE_ACCOUNT
```

Check that nothing with these names exists yet. Each of these should
come back empty or "not found":

```bash
gcloud storage ls --project=<project> | grep tfgcsb
gcloud iam service-accounts list --project=<project> | grep tfgcsb
gcloud iam roles describe tfgcsbValidationWriter --project=<project>
```

## 2. Phase A: a host as v0.1 left it

```bash
cd v01
tf init
tf plan -var-file=../validation.tfvars     # expect 4 to add: role, bucket, SA, binding
tf apply -var-file=../validation.tfvars
cd ..
```

## 3. Phase B: the upgrade plan

```bash
cd v02
tf init
tf plan -var-file=../validation.tfvars -out=upgrade.tfplan
mkdir -p ../.logs
tf show -json upgrade.tfplan > ../.logs/upgrade-plan.json
../probe plan-check ../.logs/upgrade-plan.json
```

`plan-check` must pass before you apply. It checks that the old bucket is
**forgotten, not destroyed**, the old binding is removed, the new tier
bucket and binding are created, the service account is kept, and the
role loses `setRetention`. Then:

```bash
tf apply upgrade.tfplan
cd ..
```

## 4. Let your account act as the writers

```bash
./probe grant
```

Wait a minute for this to take effect.

## 5. The host side, for real

```bash
./probe host
```

This runs the real `offsite-backup` as the writer: the tier check against
the real buckets (which proves the parsing of `gcloud storage buckets
describe`), a backup to both tiers with read-back, and `restore-test` as
you. Then it checks that a mismatched tier is refused.

## 6. What the writer can't do

```bash
./probe writer
```

## 7. Lock a tier

```bash
./probe liens                                   # before
cd v02 && tf apply -var-file=../validation.tfvars -var=lock_locked_tier=true && cd ..
./probe liens                                   # after: a new lien?
./probe locked
```

## 8. Terraform can't unlock it

```bash
cd v02 && tf apply -var-file=../validation.tfvars -var=lock_locked_tier=false; cd ..
```

**This apply must fail.** Note the error.

## 9. The unlocked tier, as the operator

Run this on the same day as step 5, while the backup is still inside its
1-day retention:

```bash
./probe unlocked
cd v02 && tf apply -var-file=../validation.tfvars -var=lock_locked_tier=true && cd ..   # restores the policy
```

## 10. Results

Each step prints PASS, FAIL or UNEXPECTED and logs to `.logs/`. FAIL
means GCS doesn't behave the way the design assumes. UNEXPECTED means a
command failed for some other reason, such as a `gcloud` flag or a
missing object.

## 11. Clean up, at least a day after the last backup

```bash
./probe cleanup
rm -rf .state
```

It only deletes buckets carrying the validation label, and asks you to
type the project ID first. A bucket that still holds retained objects
can't be deleted yet: run it again later. Deleted custom role IDs can't
be reused for a few weeks.
