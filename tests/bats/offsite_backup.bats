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
  export FAKE_BUCKET_JSON="$T/bucket.json"
  mkdir -p "$OFFSITE_BACKUP_CONF_DIR" "$FAKE_GCS_DIR" "$T/data/app"
  echo "hello" >"$T/data/app/file.txt"

  cat >"$OFFSITE_BACKUP_CONF_DIR/backup.conf" <<EOF
BUCKET=example-bucket
PREFIX=host-a
RETENTION_MODE=Unlocked
LIFECYCLE_SLACK_DAYS=1
WORK_DIR=$T/work
STATE_DIR=$T/state
EOF
  printf '%s\n' "daily 7 always" "weekly 35 weekday:1" "monthly 90 monthday:01" \
    >"$OFFSITE_BACKUP_CONF_DIR/tiers"
  echo "$T/data/app" >"$OFFSITE_BACKUP_CONF_DIR/paths"
  echo "age1exampleexampleexampleexampleexampleexampleexampleexampleex" \
    >"$OFFSITE_BACKUP_CONF_DIR/recipients"
  bucket_rules daily:8 weekly:36 monthly:91
}

# bucket_rules name:age ... writes the fake bucket's lifecycle config.
bucket_rules() {
  local rules="" sep=""
  for spec in "$@"; do
    rules+="$sep{\"action\":{\"type\":\"Delete\"},\"condition\":{\"age\":${spec#*:},\"matchesPrefix\":[\"${spec%%:*}/\"]}}"
    sep=","
  done
  echo "{\"name\":\"example-bucket\",\"lifecycle_config\":{\"rule\":[$rules]}}" >"$FAKE_BUCKET_JSON"
}

run_backup() {
  OFFSITE_BACKUP_NOW="$1" run "$BACKUP" "${@:2}"
}

@test "an ordinary day uploads only the tiers that are due" {
  run_backup "$WEDNESDAY"
  [ "$status" -eq 0 ]
  [ -f "$FAKE_GCS_DIR/example-bucket/daily/host-a/2026-06-03.tar.age" ]
  [ ! -d "$FAKE_GCS_DIR/example-bucket/weekly" ]
  [ ! -d "$FAKE_GCS_DIR/example-bucket/monthly" ]
}

@test "weekday and monthday tiers fire on their day, with their name formats" {
  run_backup "$MONDAY_FIRST"
  [ "$status" -eq 0 ]
  [ -f "$FAKE_GCS_DIR/example-bucket/daily/host-a/2026-06-01.tar.age" ]
  [ -f "$FAKE_GCS_DIR/example-bucket/weekly/host-a/2026-W23.tar.age" ]
  [ -f "$FAKE_GCS_DIR/example-bucket/monthly/host-a/2026-06.tar.age" ]
}

@test "each upload carries its tier's retain-until and the retention mode" {
  run_backup "$MONDAY_FIRST"
  [ "$status" -eq 0 ]
  grep -q "daily/host-a/2026-06-01.tar.age --retain-until=2026-06-08T00:00:00Z --retention-mode=Unlocked" "$FAKE_GCS_LOG"
  grep -q "weekly/host-a/2026-W23.tar.age --retain-until=2026-07-06T00:00:00Z --retention-mode=Unlocked" "$FAKE_GCS_LOG"
}

@test "a custom name format is used" {
  printf '%s\n' "hourly 2 always %Y%m%dT%H" >"$OFFSITE_BACKUP_CONF_DIR/tiers"
  bucket_rules hourly:3
  run_backup "$WEDNESDAY"
  [ "$status" -eq 0 ]
  [ -f "$FAKE_GCS_DIR/example-bucket/hourly/host-a/20260603T00.tar.age" ]
}

@test "the archive holds the configured paths" {
  run_backup "$WEDNESDAY"
  [ "$status" -eq 0 ]
  tar -tzf "$FAKE_GCS_DIR/example-bucket/daily/host-a/2026-06-03.tar.age" | grep -q "data/app/file.txt"
}

@test "the pre-backup hook's output is archived under offsite-backup-dump/" {
  cat >"$OFFSITE_BACKUP_CONF_DIR/pre-backup" <<'EOF'
#!/bin/bash
echo "dump contents" >"$DUMP_DIR/database.sql"
EOF
  chmod +x "$OFFSITE_BACKUP_CONF_DIR/pre-backup"
  run_backup "$WEDNESDAY"
  [ "$status" -eq 0 ]
  tar -tzf "$FAKE_GCS_DIR/example-bucket/daily/host-a/2026-06-03.tar.age" | grep -q "offsite-backup-dump/database.sql"
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
  [ ! -d "$FAKE_GCS_DIR/example-bucket" ]
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
  [ ! -d "$FAKE_GCS_DIR/example-bucket" ]
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
  [ ! -d "$FAKE_GCS_DIR/example-bucket" ]
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

@test "contract: a tier the bucket doesn't expire stops the run before any upload" {
  bucket_rules daily:8 weekly:36
  run_backup "$WEDNESDAY"
  [ "$status" -ne 0 ]
  grep -q "no expiry rule for monthly/" "$T/state/last-error"
  [ ! -d "$FAKE_GCS_DIR/example-bucket" ]
}

@test "contract: a different expiry age stops the run" {
  bucket_rules daily:8 weekly:91 monthly:91
  run_backup "$WEDNESDAY"
  [ "$status" -ne 0 ]
  grep -q "weekly/ expires after 91 days, this host expects 36" "$T/state/last-error"
}

@test "contract: a bucket whose configuration can't be read stops the run" {
  FAKE_BUCKET_DESCRIBE_FAIL=1 OFFSITE_BACKUP_NOW="$WEDNESDAY" run "$BACKUP"
  [ "$status" -ne 0 ]
  grep -q "cannot read gs://example-bucket" "$T/state/last-error"
}

@test "contract: --check-contract checks and uploads nothing" {
  run_backup "$WEDNESDAY" --check-contract
  [ "$status" -eq 0 ]
  [ ! -d "$FAKE_GCS_DIR/example-bucket" ]
}

@test "an invalid retention mode is refused" {
  sed -i 's/^RETENTION_MODE=.*/RETENTION_MODE=Forever/' "$OFFSITE_BACKUP_CONF_DIR/backup.conf"
  run_backup "$WEDNESDAY"
  [ "$status" -ne 0 ]
  grep -q "must be Locked or Unlocked" "$T/state/last-error"
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
  run "$RESTORE" --bucket example-bucket --prefix host-a --tier daily \
    --identity /dev/null --expect "data/app/file.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-06-04.tar.age"* ]]
  [[ "$output" == *"PASS"* ]]
}

@test "restore test: a missing expected entry fails" {
  run_backup "$WEDNESDAY"
  run "$RESTORE" --bucket example-bucket --prefix host-a --tier daily \
    --identity /dev/null --expect "data/app/not-there.txt"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
}

@test "restore test: no objects fails" {
  run "$RESTORE" --bucket example-bucket --prefix host-a --tier daily --identity /dev/null
  [ "$status" -ne 0 ]
}
