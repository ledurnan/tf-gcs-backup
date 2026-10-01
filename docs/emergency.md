# Clearing an unlocked tier

When a tier holds something it shouldn't (junk from a compromised host,
a huge upload that slipped past the size guard, or data that must go
early) and the tier is **unlocked**. A locked tier can't be cleared by
anyone before its objects expire.

You need an identity with emergency access: one of the host's
`emergency_members` ([ADR 0008](adr/0008-emergency-access-to-unlocked-tiers.md)),
or the project owner.

## 1. Stop the source

If the host is compromised, stop it writing first: disable its writer
service account (`gcloud iam service-accounts disable <writer>`) or take
the host offline. Otherwise whatever you delete is written again.

## 2. See what's there

```bash
gcloud storage ls -l gs://<bucket name prefix>-<tier>/**
```

Decide exactly which objects go. Everything you delete is gone for good.

## 3. Remove the tier's retention policy

```bash
gcloud storage buckets update gs://<bucket name prefix>-<tier> --clear-retention-period
```

From now until step 5, nothing in this tier is protected, and the host's
backups fail their tier check (and alert). That's expected.

## 4. Delete

```bash
gcloud storage rm gs://<bucket name prefix>-<tier>/<object>
```

## 5. Put the policy back

```bash
terraform apply        # through scripts/tf-with-identity
```

The plan shows the tier's `retention_policy` being added back. Apply it.
The next backup run should pass its tier check again.

## 6. Afterwards

- Rotate or re-enable the host's writer key if you disabled it.
- If the junk came from a compromise, treat every object the host wrote
  since then as suspect, not only the ones you deleted.
