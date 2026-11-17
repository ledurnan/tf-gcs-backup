#!/usr/bin/env bats
#
# The DR-testing runbook template (docs/dr-testing.md) and restore.md tell
# people how to run restore-test. These keep what they say true: every
# option they pass exists, and the key handover the template prescribes
# (read -rs, then --identity <(printf ...)) decrypts with each recipient
# and with no other key. Real age; a fake gcloud stands in for GCS.
# Run: bats tests/bats

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
RESTORE="$ROOT/scripts/restore-test"

# The options restore-test accepts, from its argument parser: those that
# take a value (shift). --report-url is parsed only to refuse it.
accepted_options() {
  sed -n '/^while \[ \$# -gt 0 \]/,/^done/p' "$RESTORE" \
    | grep -E '^ +--[a-z-]+\).*shift' | grep -oE -- '--[a-z-]+'
}

# Every --option given to restore-test in a doc's code blocks, with
# continuation lines joined.
documented_options() {
  awk '/^```/ { inblock = !inblock; next } inblock' "$1" \
    | sed -e ':a' -e '/\\$/N; s/\\\n//; ta' \
    | grep 'restore-test' \
    | awk '{ print substr($0, index($0, "restore-test") + 12) }' \
    | grep -oE '(^|[[:space:]])--[a-z-]+' | tr -d ' \t' | sort -u
}

@test "docs: every restore-test option in the runbook template and restore.md exists" {
  local accepted doc opt found=0
  accepted="$(accepted_options)"
  [ -n "$accepted" ]
  for doc in docs/dr-testing.md docs/restore.md; do
    while read -r opt; do
      [ -n "$opt" ] || continue
      found=$((found + 1))
      grep -qxF -- "$opt" <<<"$accepted" \
        || { echo "$doc passes $opt, which restore-test doesn't accept" >&2; return 1; }
    done < <(documented_options "$ROOT/$doc")
  done
  [ "$found" -gt 0 ]
}

@test "docs: the runbook template's key handover decrypts with each recipient, and no other key" {
  command -v age >/dev/null && command -v age-keygen >/dev/null \
    || skip "age is not installed"
  local T="$BATS_TEST_TMPDIR" name
  mkdir -p "$T/bin" "$T/gcs/yourorg-backup-host-a-daily/host-a" "$T/data/etc/yourapp"
  ln -s "$BATS_TEST_DIRNAME/fakes/gcloud" "$T/bin/gcloud"
  export PATH="$T/bin:$PATH" FAKE_GCS_DIR="$T/gcs" FAKE_GCS_LOG="$T/gcloud.log"

  # Keys exist only for the test; the doc's flow keeps them off disk.
  for name in operator recovery stranger; do
    age-keygen 2>/dev/null >"$T/$name.key"
  done
  echo conf >"$T/data/etc/yourapp/app.conf"
  tar -czf - -C "$T/data" etc \
    | age -r "$(age-keygen -y "$T/operator.key")" -r "$(age-keygen -y "$T/recovery.key")" \
      >"$T/gcs/yourorg-backup-host-a-daily/host-a/2026-06-03.tar.age"

  # As the template has it: the key in an unexported variable, handed over
  # through a pipe.
  for name in operator recovery; do
    run bash -c '
      AGE_ID="$(grep "^AGE-SECRET-KEY-" "$1")"
      age-keygen -y <(printf "%s\n" "$AGE_ID") >/dev/null || exit 9
      "$2" --bucket-prefix yourorg-backup-host-a --tier daily --prefix host-a \
        --identity <(printf "%s\n" "$AGE_ID") --expect etc/yourapp/' _ "$T/$name.key" "$RESTORE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS: gs://yourorg-backup-host-a-daily/host-a/2026-06-03.tar.age"* ]]
  done

  run bash -c '
    AGE_ID="$(grep "^AGE-SECRET-KEY-" "$1")"
    "$2" --bucket-prefix yourorg-backup-host-a --tier daily --prefix host-a \
      --identity <(printf "%s\n" "$AGE_ID")' _ "$T/stranger.key" "$RESTORE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL: could not decrypt"* ]]
}
