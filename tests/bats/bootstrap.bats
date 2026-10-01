#!/usr/bin/env bats
#
# scripts/bootstrap-project against a fake gcloud: what it changes, and
# which state bucket it will use.

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
BOOTSTRAP="$ROOT/scripts/bootstrap-project"

setup() {
  export PATH="$BATS_TEST_DIRNAME/fakes-bootstrap:$PATH"
  export FAKE_LOG="$BATS_TEST_TMPDIR/gcloud.log"
}

bootstrap() {
  run "$BOOTSTRAP" --project example-project --account owner@example.com \
    --location europe-west2 --state-bucket example-state "$@"
}

# Calls that change something, as opposed to reading what exists.
changes() {
  grep -E " (enable|create|update|add-iam-policy-binding) " "$FAKE_LOG" || true
}

@test "without --apply nothing is changed" {
  bootstrap
  [ "$status" -eq 0 ]
  [ -z "$(changes)" ]
}

@test "a new state bucket is created private, versioned and uniform" {
  bootstrap --apply
  [ "$status" -eq 0 ]
  grep -q "storage buckets create gs://example-state .*--uniform-bucket-level-access --public-access-prevention" "$FAKE_LOG"
  grep -q "storage buckets update gs://example-state .*--versioning" "$FAKE_LOG"
}

@test "a state bucket already in the project is kept and given the same settings" {
  FAKE_EXISTING="bucket" bootstrap --apply
  [ "$status" -eq 0 ]
  ! grep -q "storage buckets create" "$FAKE_LOG"
  grep -q "storage buckets update gs://example-state .*--versioning --uniform-bucket-level-access --public-access-prevention" "$FAKE_LOG"
  [[ "$output" == *"projectOwner:example"* ]]
}

@test "a bucket of that name in another project is refused, and nothing is granted on it" {
  FAKE_EXISTING="bucket" FAKE_BUCKET_PROJECT_NUMBER=999 bootstrap --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"exists in project number 999, not in example-project (111)"* ]]
  ! grep -q "storage buckets update" "$FAKE_LOG"
  ! grep -q "storage buckets add-iam-policy-binding" "$FAKE_LOG"
}

@test "a bucket that doesn't say which project it is in is refused" {
  FAKE_EXISTING="bucket" FAKE_BUCKET_PROJECT_NUMBER="" bootstrap --apply
  [ "$status" -eq 1 ]
}

@test "every call names the account" {
  bootstrap --apply
  [ "$status" -eq 0 ]
  ! grep -qv -- "--account=owner@example.com" "$FAKE_LOG"
}
