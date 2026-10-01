#!/usr/bin/env bats
#
# bootstrap-project against a fake gcloud: a new service account that
# isn't visible yet is retried, and any other failure is not.

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
BOOTSTRAP="$ROOT/scripts/bootstrap-project"

setup() {
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin"
  export FAKE_LOG="$T/gcloud.log" FAKE_COUNT="$T/count"
  export BOOTSTRAP_RETRY_SECONDS=0 BOOTSTRAP_RETRIES=4
  echo 0 >"$FAKE_COUNT"
  # Nothing exists yet. Every add-iam-policy-binding fails FAKE_FAILURES
  # times with FAKE_ERROR, then succeeds.
  cat >"$T/bin/gcloud" <<'EOF'
#!/bin/bash
echo "gcloud $*" >>"$FAKE_LOG"
case "$*" in
  *" describe "*) exit 1 ;;
  *add-iam-policy-binding*)
    n=$(($(cat "$FAKE_COUNT") + 1)); echo "$n" >"$FAKE_COUNT"
    if [ "$n" -le "${FAKE_FAILURES:-0}" ]; then echo "${FAKE_ERROR:-boom}" >&2; exit 1; fi ;;
esac
exit 0
EOF
  chmod +x "$T/bin/gcloud"
  export PATH="$T/bin:$PATH"
}

bootstrap() {
  run "$BOOTSTRAP" --project p --account a@example.com --location europe-west2 \
    --state-bucket p-tfstate --apply
}

@test "bootstrap: a service account that isn't visible yet is retried" {
  FAKE_FAILURES=2 FAKE_ERROR="HTTPError 400: Service account x does not exist." bootstrap
  [ "$status" -eq 0 ]
  [ "$(grep -c 'add-iam-policy-binding' "$FAKE_LOG")" -eq 5 ]
  [[ "$output" == *"isn't visible yet; retrying (1/4)"* ]]
}

@test "bootstrap: it gives up after BOOTSTRAP_RETRIES" {
  FAKE_FAILURES=99 FAKE_ERROR="Service account x does not exist." bootstrap
  [ "$status" -ne 0 ]
  [ "$(grep -c 'add-iam-policy-binding' "$FAKE_LOG")" -eq 4 ]
}

@test "bootstrap: any other failure is not retried" {
  FAKE_FAILURES=1 FAKE_ERROR="PERMISSION_DENIED" bootstrap
  [ "$status" -ne 0 ]
  [ "$(grep -c 'add-iam-policy-binding' "$FAKE_LOG")" -eq 1 ]
  [[ "$output" == *"PERMISSION_DENIED"* ]]
}

@test "bootstrap: a dry run calls nothing that changes the project" {
  run "$BOOTSTRAP" --project p --account a@example.com --location europe-west2 --state-bucket p-tfstate
  [ "$status" -eq 0 ]
  ! grep -qE 'create|update|enable|add-iam-policy-binding' "$FAKE_LOG"
}
