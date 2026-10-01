#!/usr/bin/env bats
#
# When the role activates the service account key for gcloud. The backup
# uses only the key gcloud holds, so a rotated key that isn't activated
# is a key that is never used.

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
# client_email in tests/ansible/vars_valid.yml
ACCOUNT=$(sed -n 's/.*"client_email": *"\([^"]*\)".*/\1/p' "$ROOT/tests/ansible/vars_valid.yml")

setup() {
  export PATH="$BATS_TEST_DIRNAME/fakes:$PATH"
  export ANSIBLE_NOCOLOR=1 ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_INVENTORY_UNPARSED_WARNING=false
  export FAKE_GCS_LOG="$BATS_TEST_TMPDIR/gcloud.log"
  export FAKE_GCLOUD_ACCOUNTS="$BATS_TEST_TMPDIR/accounts"
  : >"$FAKE_GCLOUD_ACCOUNTS"
}

activate() {
  run ansible-playbook "$ROOT/tests/ansible/test_activate.yml" "$@"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

activated() {
  grep -q "auth activate-service-account --key-file=" "$FAKE_GCS_LOG"
}

@test "the fixture names an account" {
  [ -n "$ACCOUNT" ]
}

@test "an account gcloud doesn't have is activated" {
  activate
  activated
}

@test "an account gcloud already has, with an unchanged key, is left alone" {
  echo "$ACCOUNT" >"$FAKE_GCLOUD_ACCOUNTS"
  activate
  ! activated
}

@test "a rotated key for the same account is activated" {
  echo "$ACCOUNT" >"$FAKE_GCLOUD_ACCOUNTS"
  activate -e key_changed=true
  activated
}
