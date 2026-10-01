#!/usr/bin/env bats
#
# Tests for the sending side, against fake gcloud, age and curl.
# Run: bats tests/bats

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
BACKUP="$ROOT/ansible/roles/offsite_backup/files/offsite-backup"
REPORT="$ROOT/ansible/roles/offsite_backup/files/offsite-backup-report"
RESTORE="$ROOT/scripts/restore-test"

# 2026-06-01 is a Monday (weekday 1) and the first of the month.
MONDAY_FIRST=1780272000
# 2026-06-03 is a Wednesday.
WEDNESDAY=1780444800

setup() {
  export PATH="$BATS_TEST_DIRNAME/fakes:$PATH"
  T="$BATS_TEST_TMPDIR"
  export OFFSITE_BACKUP_CONF_DIR="$T/conf"
  export FAKE_GCS_DIR="$T/gcs"
  export FAKE_GCS_LOG="$T/gcloud.log"
  export FAKE_AGE_LOG="$T/age.log"
  export FAKE_CURL_LOG="$T/curl.log"
  export FAKE_BUCKETS_DIR="$T/buckets"
  mkdir -p "$OFFSITE_BACKUP_CONF_DIR" "$FAKE_GCS_DIR" "$FAKE_BUCKETS_DIR" "$T/data/app"
  echo "hello" >"$T/data/app/file.txt"

  cat >"$OFFSITE_BACKUP_CONF_DIR/backup.conf" <<EOF
BUCKET_PREFIX=example
PREFIX=host-a
LIFECYCLE_SLACK_DAYS=1
WORK_DIR=$T/work
STATE_DIR=$T/state
MAX_SIZE=1M
MAX_GROWTH_PERCENT=100
GROWTH_MIN_SIZE=0
EOF
  printf '%s\n' "daily 7 always" "weekly 35 weekday:1" "monthly 90 monthday:01" \
    >"$OFFSITE_BACKUP_CONF_DIR/tiers"
  echo "$T/data/app" >"$OFFSITE_BACKUP_CONF_DIR/paths"
  echo "age1exampleexampleexampleexampleexampleexampleexampleexampleex" \
    >"$OFFSITE_BACKUP_CONF_DIR/recipients"
  tier_buckets daily:7:8 weekly:35:36 monthly:90:91
}

# tier_buckets name:retain_days:expiry_age[:locked] ... writes each tier
# bucket's configuration, as `gcloud storage buckets describe` shows it.
# Any tier left out has no bucket.
tier_buckets() {
  rm -f "$FAKE_BUCKETS_DIR"/*.json
  local spec name days age locked
  for spec in "$@"; do
    IFS=: read -r name days age locked <<<"$spec"
    printf '{"name":"example-%s","retention_policy":{"isLocked":%s,"retentionPeriod":"%s"},"lifecycle_config":{"rule":[{"action":{"type":"Delete"},"condition":{"age":%s}}]}}\n' \
      "$name" "${locked:-false}" "$((days * 86400))" "$age" >"$FAKE_BUCKETS_DIR/example-$name.json"
  done
}

nothing_uploaded() {
  [ -z "$(ls -A "$FAKE_GCS_DIR")" ]
}

run_backup() {
  OFFSITE_BACKUP_NOW="$1" run "$BACKUP" "${@:2}"
}

@test "an ordinary day uploads only the tiers that are due" {
  run_backup "$WEDNESDAY"
  [ "$status" -eq 0 ]
  [ -f "$FAKE_GCS_DIR/example-daily/host-a/2026-06-03.tar.age" ]
  [ ! -d "$FAKE_GCS_DIR/example-weekly" ]
  [ ! -d "$FAKE_GCS_DIR/example-monthly" ]
}

@test "weekday and monthday tiers fire on their day, with their name formats" {
  run_backup "$MONDAY_FIRST"
  [ "$status" -eq 0 ]
  [ -f "$FAKE_GCS_DIR/example-daily/host-a/2026-06-01.tar.age" ]
  [ -f "$FAKE_GCS_DIR/example-weekly/host-a/2026-W23.tar.age" ]
  [ -f "$FAKE_GCS_DIR/example-monthly/host-a/2026-06.tar.age" ]
}

@test "uploads go to each tier's bucket and never set retention" {
  run_backup "$MONDAY_FIRST"
  [ "$status" -eq 0 ]
  grep -q "storage cp .* gs://example-daily/host-a/2026-06-01.tar.age$" "$FAKE_GCS_LOG"
  grep -q "storage cp .* gs://example-weekly/host-a/2026-W23.tar.age$" "$FAKE_GCS_LOG"
  ! grep -q -- "--retain-until\|--retention-mode" "$FAKE_GCS_LOG"
}

@test "a custom name format is used" {
  printf '%s\n' "hourly 2 always %Y%m%dT%H" >"$OFFSITE_BACKUP_CONF_DIR/tiers"
  tier_buckets hourly:2:3
  run_backup "$WEDNESDAY"
  [ "$status" -eq 0 ]
  [ -f "$FAKE_GCS_DIR/example-hourly/host-a/20260603T00.tar.age" ]
}

@test "the archive holds the configured paths" {
  run_backup "$WEDNESDAY"
  [ "$status" -eq 0 ]
  tar -tzf "$FAKE_GCS_DIR/example-daily/host-a/2026-06-03.tar.age" | grep -q "data/app/file.txt"
}

@test "the pre-backup hook's output is archived under offsite-backup-dump/" {
  cat >"$OFFSITE_BACKUP_CONF_DIR/pre-backup" <<'EOF'
#!/bin/bash
echo "dump contents" >"$DUMP_DIR/database.sql"
EOF
  chmod +x "$OFFSITE_BACKUP_CONF_DIR/pre-backup"
  run_backup "$WEDNESDAY"
  [ "$status" -eq 0 ]
  tar -tzf "$FAKE_GCS_DIR/example-daily/host-a/2026-06-03.tar.age" | grep -q "offsite-backup-dump/database.sql"
}

@test "a pre-backup hook alone is enough, with no paths" {
  : >"$OFFSITE_BACKUP_CONF_DIR/paths"
  printf '#!/bin/bash\necho x >"$DUMP_DIR/x"\n' >"$OFFSITE_BACKUP_CONF_DIR/pre-backup"
  chmod +x "$OFFSITE_BACKUP_CONF_DIR/pre-backup"
  run_backup "$WEDNESDAY"
  [ "$status" -eq 0 ]
}

@test "a failing pre-backup hook uploads nothing and says why" {
  printf '#!/bin/bash\nexit 3\n' >"$OFFSITE_BACKUP_CONF_DIR/pre-backup"
  chmod +x "$OFFSITE_BACKUP_CONF_DIR/pre-backup"
  run_backup "$WEDNESDAY"
  [ "$status" -ne 0 ]
  nothing_uploaded
  grep -q "pre-backup hook failed" "$T/state/last-error"
}

@test "nothing to back up is an error" {
  : >"$OFFSITE_BACKUP_CONF_DIR/paths"
  run_backup "$WEDNESDAY"
  [ "$status" -ne 0 ]
  grep -q "nothing to back up" "$T/state/last-error"
}

@test "a missing path fails the run" {
  echo "$T/does-not-exist" >>"$OFFSITE_BACKUP_CONF_DIR/paths"
  run_backup "$WEDNESDAY"
  [ "$status" -ne 0 ]
  grep -q "tar failed" "$T/state/last-error"
  nothing_uploaded
}

@test "a relative path is refused" {
  echo "relative/path" >"$OFFSITE_BACKUP_CONF_DIR/paths"
  run_backup "$WEDNESDAY"
  [ "$status" -ne 0 ]
  grep -q "not absolute" "$T/state/last-error"
}

@test "encryption failure uploads nothing" {
  FAKE_AGE_FAIL=1 OFFSITE_BACKUP_NOW="$WEDNESDAY" run "$BACKUP"
  [ "$status" -ne 0 ]
  grep -q "age encryption failed" "$T/state/last-error"
  nothing_uploaded
}

@test "the recipients file is passed to age" {
  run_backup "$WEDNESDAY"
  [ "$status" -eq 0 ]
  grep -q "recipients=$OFFSITE_BACKUP_CONF_DIR/recipients" "$FAKE_AGE_LOG"
}

@test "a read-back size mismatch fails the run" {
  FAKE_REMOTE_SIZE=1 OFFSITE_BACKUP_NOW="$WEDNESDAY" run "$BACKUP"
  [ "$status" -ne 0 ]
  grep -q "verify failed" "$T/state/last-error"
}

@test "contract: a tier with no bucket stops the run before any upload" {
  tier_buckets daily:7:8 weekly:35:36
  run_backup "$WEDNESDAY"
  [ "$status" -ne 0 ]
  grep -q "cannot read gs://example-monthly" "$T/state/last-error"
  nothing_uploaded
}

@test "contract: a different expiry age stops the run" {
  tier_buckets daily:7:8 weekly:35:91 monthly:90:91
  run_backup "$WEDNESDAY"
  [ "$status" -ne 0 ]
  grep -q "example-weekly expires objects after 91 days, this host expects 36" "$T/state/last-error"
  nothing_uploaded
}

@test "contract: a different retention period stops the run" {
  tier_buckets daily:7:8 weekly:30:36 monthly:90:91
  run_backup "$WEDNESDAY"
  [ "$status" -ne 0 ]
  grep -q "example-weekly keeps objects 30 days, this host expects 35" "$T/state/last-error"
  nothing_uploaded
}

@test "contract: every problem is reported, not just the first" {
  tier_buckets daily:6:8 weekly:35:36 monthly:90:99
  run_backup "$WEDNESDAY"
  [ "$status" -ne 0 ]
  grep -q "example-daily keeps objects 6 days" "$T/state/last-error"
  grep -q "example-monthly expires objects after 99 days" "$T/state/last-error"
}

@test "contract: a bucket with no retention policy stops the run" {
  echo '{"name":"example-daily","lifecycle_config":{"rule":[{"action":{"type":"Delete"},"condition":{"age":8}}]}}' \
    >"$FAKE_BUCKETS_DIR/example-daily.json"
  run_backup "$WEDNESDAY"
  [ "$status" -ne 0 ]
  grep -q "example-daily has no retention policy" "$T/state/last-error"
}

@test "contract: an expiry rule limited to a prefix doesn't count" {
  echo '{"name":"example-daily","retention_policy":{"retentionPeriod":"604800"},"lifecycle_config":{"rule":[{"action":{"type":"Delete"},"condition":{"age":8,"matchesPrefix":["host-a/"]}}]}}' \
    >"$FAKE_BUCKETS_DIR/example-daily.json"
  run_backup "$WEDNESDAY"
  [ "$status" -ne 0 ]
  grep -q "example-daily has no expiry rule covering every object" "$T/state/last-error"
}

@test "contract: a bucket whose configuration can't be read stops the run" {
  FAKE_BUCKET_DESCRIBE_FAIL=1 OFFSITE_BACKUP_NOW="$WEDNESDAY" run "$BACKUP"
  [ "$status" -ne 0 ]
  grep -q "cannot read gs://example-daily" "$T/state/last-error"
}

@test "contract: each tier's lock state is logged" {
  tier_buckets daily:7:8 weekly:35:36:true monthly:90:91:true
  run_backup "$WEDNESDAY" --check-contract
  [ "$status" -eq 0 ]
  [[ "$output" == *"daily:unlocked weekly:locked monthly:locked"* ]]
}

@test "contract: --check-contract checks and uploads nothing" {
  run_backup "$WEDNESDAY" --check-contract
  [ "$status" -eq 0 ]
  nothing_uploaded
}

@test "an invalid tier schedule is refused" {
  printf '%s\n' "daily 7 monthday:31" >"$OFFSITE_BACKUP_CONF_DIR/tiers"
  run_backup "$WEDNESDAY"
  [ "$status" -ne 0 ]
  grep -q "must be always, weekday" "$T/state/last-error"
}

@test "report: success posts ok" {
  REPORT_URL=https://heartbeat.example/abc SERVICE_RESULT=success \
    OFFSITE_BACKUP_STATE_DIR="$T/state" run "$REPORT"
  [ "$status" -eq 0 ]
  grep -q 'https://heartbeat.example/abc {"status":"ok"}' "$FAKE_CURL_LOG"
}

@test "report: success carries the archive size the backup recorded" {
  run_backup "$WEDNESDAY"
  [ "$status" -eq 0 ]
  size="$(cat "$T/state/last-size")"
  REPORT_URL=https://heartbeat.example/abc SERVICE_RESULT=success \
    OFFSITE_BACKUP_STATE_DIR="$T/state" run "$REPORT"
  [ "$status" -eq 0 ]
  grep -q "{\"status\":\"ok\",\"bytes\":${size}}" "$FAKE_CURL_LOG"
}

# --- size guard -----------------------------------------------------------

# big_file <bytes>: incompressible data, so the archive grows with it.
big_file() {
  head -c "$1" /dev/urandom >"$T/data/app/big.bin"
}

set_conf() {
  sed -i "s|^$1=.*|$1=$2|" "$OFFSITE_BACKUP_CONF_DIR/backup.conf"
}

@test "size guard: an archive over MAX_SIZE uploads nothing and says why" {
  big_file 2000000
  run_backup "$WEDNESDAY"
  [ "$status" -ne 0 ]
  nothing_uploaded
  grep -q "over MAX_SIZE 1.0MiB" "$T/state/last-error"
}

@test "size guard: accept-size never lifts MAX_SIZE" {
  big_file 2000000
  mkdir -p "$T/state" && touch "$T/state/accept-size"
  run_backup "$WEDNESDAY"
  [ "$status" -ne 0 ]
  nothing_uploaded
  [ -e "$T/state/accept-size" ]
}

@test "size guard: a successful run records its size" {
  run_backup "$WEDNESDAY"
  [ "$status" -eq 0 ]
  [ "$(cat "$T/state/last-size")" = "$(stat -c %s "$FAKE_GCS_DIR/example-daily/host-a/2026-06-03.tar.age")" ]
}

@test "size guard: growth beyond MAX_GROWTH_PERCENT uploads nothing" {
  big_file 100000
  run_backup "$WEDNESDAY"
  [ "$status" -eq 0 ]
  before="$(cat "$T/state/last-size")"
  big_file 300000
  OFFSITE_BACKUP_NOW=$((WEDNESDAY + 86400)) run "$BACKUP"
  [ "$status" -ne 0 ]
  [ ! -f "$FAKE_GCS_DIR/example-daily/host-a/2026-06-04.tar.age" ]
  grep -q "more than MAX_GROWTH_PERCENT 100%" "$T/state/last-error"
  grep -q "touch $T/state/accept-size" "$T/state/last-error"
  # A refused run leaves the baseline alone.
  [ "$(cat "$T/state/last-size")" = "$before" ]
}

@test "size guard: growth within MAX_GROWTH_PERCENT uploads" {
  big_file 100000
  run_backup "$WEDNESDAY"
  big_file 150000
  OFFSITE_BACKUP_NOW=$((WEDNESDAY + 86400)) run "$BACKUP"
  [ "$status" -eq 0 ]
  [ -f "$FAKE_GCS_DIR/example-daily/host-a/2026-06-04.tar.age" ]
}

@test "size guard: accept-size skips the growth check once, then is removed" {
  big_file 100000
  run_backup "$WEDNESDAY"
  big_file 300000
  touch "$T/state/accept-size"
  OFFSITE_BACKUP_NOW=$((WEDNESDAY + 86400)) run "$BACKUP"
  [ "$status" -eq 0 ]
  [ -f "$FAKE_GCS_DIR/example-daily/host-a/2026-06-04.tar.age" ]
  [ ! -e "$T/state/accept-size" ]
  [ "$(cat "$T/state/last-size")" -gt 300000 ]
}

@test "size guard: archives at or below GROWTH_MIN_SIZE skip the growth check" {
  set_conf GROWTH_MIN_SIZE 512K
  big_file 100000
  run_backup "$WEDNESDAY"
  big_file 300000
  OFFSITE_BACKUP_NOW=$((WEDNESDAY + 86400)) run "$BACKUP"
  [ "$status" -eq 0 ]
}

@test "size guard: MAX_GROWTH_PERCENT 0 turns the growth check off" {
  set_conf MAX_GROWTH_PERCENT 0
  big_file 100000
  run_backup "$WEDNESDAY"
  big_file 300000
  OFFSITE_BACKUP_NOW=$((WEDNESDAY + 86400)) run "$BACKUP"
  [ "$status" -eq 0 ]
}

@test "size guard: the first run has no baseline and isn't growth-checked" {
  big_file 300000
  run_backup "$WEDNESDAY"
  [ "$status" -eq 0 ]
}

@test "size guard: a malformed MAX_SIZE is refused" {
  set_conf MAX_SIZE 2GB
  run_backup "$WEDNESDAY"
  [ "$status" -ne 0 ]
  grep -q "MAX_SIZE '2GB' must be a whole number of bytes" "$T/state/last-error"
}

@test "report: failure posts the reason the backup script left" {
  mkdir -p "$T/state" && echo "tar failed with rc=2" >"$T/state/last-error"
  REPORT_URL=https://heartbeat.example/abc SERVICE_RESULT=exit-code EXIT_CODE=exited EXIT_STATUS=1 \
    OFFSITE_BACKUP_STATE_DIR="$T/state" run "$REPORT"
  [ "$status" -eq 0 ]
  grep -q '"status":"failed"' "$FAKE_CURL_LOG"
  grep -q 'tar failed with rc=2' "$FAKE_CURL_LOG"
}

@test "report: no URL, no report, no failure" {
  SERVICE_RESULT=success OFFSITE_BACKUP_STATE_DIR="$T/state" run "$REPORT"
  [ "$status" -eq 0 ]
  [ ! -f "$FAKE_CURL_LOG" ]
}

@test "restore test: finds the newest object, decrypts it and checks expected entries" {
  run_backup "$WEDNESDAY"
  OFFSITE_BACKUP_NOW=$((WEDNESDAY + 86400)) run "$BACKUP"
  run "$RESTORE" --bucket-prefix example --prefix host-a --tier daily \
    --identity /dev/null --expect "data/app/file.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-06-04.tar.age"* ]]
  [[ "$output" == *"PASS"* ]]
}

@test "restore test: a missing expected entry fails" {
  run_backup "$WEDNESDAY"
  run "$RESTORE" --bucket-prefix example --prefix host-a --tier daily \
    --identity /dev/null --expect "data/app/not-there.txt"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
}

@test "restore test: no objects fails" {
  run "$RESTORE" --bucket-prefix example --prefix host-a --tier daily --identity /dev/null
  [ "$status" -ne 0 ]
}

@test "restore test: --bucket still reads a v0.1 bucket holding every tier" {
  mkdir -p "$FAKE_GCS_DIR/old-bucket/daily/host-a"
  run_backup "$WEDNESDAY"
  cp "$FAKE_GCS_DIR/example-daily/host-a/2026-06-03.tar.age" "$FAKE_GCS_DIR/old-bucket/daily/host-a/"
  run "$RESTORE" --bucket old-bucket --prefix host-a --tier daily \
    --identity /dev/null --expect "data/app/file.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gs://old-bucket/daily/host-a/2026-06-03.tar.age"* ]]
}

@test "restore test: --bucket and --bucket-prefix together are refused" {
  run "$RESTORE" --bucket old --bucket-prefix example --prefix host-a --tier daily --identity /dev/null
  [ "$status" -eq 2 ]
}

