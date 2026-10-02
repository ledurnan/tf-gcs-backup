#!/usr/bin/env bats
#
# issue-key against a fake gcloud (keys kept in a file) and the real
# ansible-vault, wrapped so a test can make one of its commands fail.
# Covers: the dry run, adding and rotating, every refusal, and the undo
# when a step after issuing the key fails.

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
ISSUE="$ROOT/scripts/issue-key"
SA="host-a-writer@proj-one.iam.gserviceaccount.com"

setup() {
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/work" "$T/repo"
  REAL_AV="$(command -v ansible-vault)"
  export REAL_AV FAKE_LOG="$T/gcloud.log" FAKE_KEYS="$T/keys" FAKE_ACCOUNTS="op@example.com"
  : >"$FAKE_KEYS"
  printf 'test-vault-password\n' >"$T/vault-pass"
  export ANSIBLE_VAULT_PASSWORD_FILE="$T/vault-pass"

  cat >"$T/bin/gcloud" <<'EOF'
#!/bin/bash
# Fake gcloud. Keys are ids, one per line, in $FAKE_KEYS.
echo "gcloud $*" >>"$FAKE_LOG"
case "$*" in
  "auth list"*) printf '%s\n' $FAKE_ACCOUNTS ;;
  *"service-accounts describe"*)
    [ -z "${FAKE_SA_MISSING:-}" ] || { echo "NOT_FOUND: no such account" >&2; exit 1; }
    echo "host-a-writer@proj-one.iam.gserviceaccount.com" ;;
  *"keys list"*) cat "$FAKE_KEYS" ;;
  *"keys create"*)
    [ -z "${FAKE_CREATE_FAIL:-}" ] || { echo "PERMISSION_DENIED: keys.create" >&2; exit 1; }
    # The last positional argument is the output file.
    out="$(printf '%s\n' "$@" | grep -v '^-' | tail -n 1)"
    id="k$(date +%s%N | tail -c 9)"
    echo "$id" >>"$FAKE_KEYS"
    begin="-----BEGIN"; kind="PRIV""ATE KEY"
    python3 - "$out" "$id" "${FAKE_KEY_EMAIL:-host-a-writer@proj-one.iam.gserviceaccount.com}" "$begin $kind-----" <<'PY'
import json, sys
out, key_id, email, pem = sys.argv[1:]
json.dump({"type": "service_account", "project_id": "proj-one", "private_key_id": key_id,
           "private_key": pem + "\nAAAA\n-----END " + pem[11:], "client_email": email,
           "token_uri": "https://oauth2.googleapis.com/token"}, open(out, "w"), indent=2)
PY
    [ -z "${FAKE_TOUCH_VAULT:-}" ] || echo "# someone else" >>"$FAKE_TOUCH_VAULT"
    [ -z "${FAKE_CREATE_SLEEP:-}" ] || { touch "$FAKE_KEYS.issued"; sleep "$FAKE_CREATE_SLEEP"; }
    ;;
  *"keys delete"*)
    [ -z "${FAKE_DELETE_FAIL:-}" ] || { echo "UNAVAILABLE" >&2; exit 1; }
    id="$(printf '%s\n' "$@" | grep -v '^-' | sed -n '5p')"
    grep -vxF "$id" "$FAKE_KEYS" >"$FAKE_KEYS.new" || true
    mv "$FAKE_KEYS.new" "$FAKE_KEYS" ;;
esac
EOF
  cat >"$T/bin/ansible-vault" <<'EOF'
#!/bin/bash
# The real ansible-vault, except the subcommand named in FAKE_AV_FAIL.
[ "${FAKE_AV_FAIL:-}" != "$1" ] || { echo "ERROR! simulated $1 failure" >&2; exit 1; }
exec "$REAL_AV" "$@"
EOF
  chmod +x "$T/bin/gcloud" "$T/bin/ansible-vault"
  export PATH="$T/bin:$PATH"

  VAULT="$T/repo/vault.yml"
  printf -- '---\n# database\nvault_db_password: s3cret\nvault_other: |\n  line one\n  line two\n' >"$T/plain"
  "$REAL_AV" encrypt --output "$VAULT" "$T/plain" >/dev/null 2>&1 </dev/null
  chmod 0640 "$VAULT"
}

issue() {
  run "$ISSUE" --service-account "$SA" --account op@example.com \
    --vault-file "$VAULT" --var vault_sa_key --work-dir "$T/work" --allow-disk-work-dir "$@"
}

view() { "$REAL_AV" view "$VAULT" 2>/dev/null </dev/null; }

key_in_vault() {
  view | python3 -c 'import json,sys,yaml; print(json.loads(yaml.safe_load(sys.stdin)["vault_sa_key"])[sys.argv[1]])' "$1"
}

work_is_empty() { [ -z "$(ls -A "$T/work")" ]; }

@test "issue-key: a dry run checks everything and changes nothing" {
  before="$(sha256sum <"$VAULT")"
  issue
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry run OK"* ]]
  ! grep -q "keys create" "$FAKE_LOG"
  [ "$(sha256sum <"$VAULT")" = "$before" ]
  work_is_empty
}

@test "issue-key: --apply adds the key and keeps everything else" {
  issue --apply
  [ "$status" -eq 0 ]
  [ "$(key_in_vault client_email)" = "$SA" ]
  [ "$(key_in_vault private_key_id)" = "$(cat "$FAKE_KEYS")" ]
  view | grep -qx 'vault_db_password: s3cret'
  view | grep -qx '# database'
  view | grep -qx '  line two'
  [ "$(stat -c %a "$VAULT")" = 640 ]
  head -n 1 "$VAULT" | grep -q '^\$ANSIBLE_VAULT;'
  work_is_empty
  [ -z "$(find "$T/repo" -name '.vault.yml.issue-key.*')" ]
}

@test "issue-key: the key never appears in its output" {
  issue --apply
  [ "$status" -eq 0 ]
  [[ "$output" != *"PRIV"*"ATE KEY"* ]]
  [[ "$output" == *"done: vault_sa_key"* ]]
}

@test "issue-key: refuses a variable that is already set, before issuing anything" {
  issue --apply
  [ "$status" -eq 0 ]
  : >"$FAKE_LOG"
  issue --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"already set"*"--rotate"* ]]
  ! grep -q "keys create" "$FAKE_LOG"
}

@test "issue-key: --rotate replaces the key and lists the old one to delete" {
  issue --apply
  old="$(cat "$FAKE_KEYS")"
  issue --apply --rotate
  [ "$status" -eq 0 ]
  new="$(tail -n 1 "$FAKE_KEYS")"
  [ "$new" != "$old" ]
  [ "$(key_in_vault private_key_id)" = "$new" ]
  [ "$(view | grep -c '^vault_sa_key:')" -eq 1 ]
  view | grep -qx 'vault_db_password: s3cret'
  [[ "$output" == *"keys delete $old "* ]]
}

@test "issue-key: --create-vault creates an encrypted vault, mode 0600" {
  VAULT="$T/repo/new/vault.yml"
  mkdir -p "$T/repo/new"
  issue --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"doesn't exist"*"--create-vault"* ]]
  issue --apply --create-vault
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$VAULT")" = 600 ]
  [ "$(key_in_vault client_email)" = "$SA" ]
}

@test "issue-key: a failed key issue leaves the vault untouched" {
  before="$(sha256sum <"$VAULT")"
  FAKE_CREATE_FAIL=1 issue --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not issue a key"*"PERMISSION_DENIED"* ]]
  [ "$(sha256sum <"$VAULT")" = "$before" ]
  work_is_empty
}

@test "issue-key: a key for the wrong account is deleted again" {
  before="$(sha256sum <"$VAULT")"
  FAKE_KEY_EMAIL=someone-else@proj-one.iam.gserviceaccount.com issue --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"isn't what was asked for"*"client_email"* ]]
  [[ "$output" == *"UNDO: deleted the new key"* ]]
  [ ! -s "$FAKE_KEYS" ]
  [ "$(sha256sum <"$VAULT")" = "$before" ]
  work_is_empty
}

@test "issue-key: a failed encrypt deletes the new key and leaves the vault" {
  before="$(sha256sum <"$VAULT")"
  FAKE_AV_FAIL=encrypt issue --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not encrypt"*"simulated encrypt failure"* ]]
  [[ "$output" == *"UNDO: deleted the new key"* ]]
  [ ! -s "$FAKE_KEYS" ]
  [ "$(sha256sum <"$VAULT")" = "$before" ]
  work_is_empty
}

@test "issue-key: when the undo fails too, it exits 3 and says what to delete" {
  FAKE_AV_FAIL=encrypt FAKE_DELETE_FAIL=1 issue --apply
  [ "$status" -eq 3 ]
  [[ "$output" == *"UNDO FAILED: the new key"*"is still valid"* ]]
  [[ "$output" == *"gcloud iam service-accounts keys delete $(cat "$FAKE_KEYS") --iam-account=$SA"* ]]
  work_is_empty
}

@test "issue-key: a vault changed during the run is not overwritten" {
  FAKE_TOUCH_VAULT="$VAULT" issue --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"changed while this ran"* ]]
  [[ "$output" == *"UNDO: deleted the new key"* ]]
  tail -n 1 "$VAULT" | grep -qx '# someone else'
  [ ! -s "$FAKE_KEYS" ]
}

@test "issue-key: refuses a plaintext vault file" {
  printf 'vault_x: 1\n' >"$VAULT"
  issue --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"isn't encrypted with Ansible Vault"* ]]
  ! grep -q "keys create" "$FAKE_LOG"
}

@test "issue-key: a wrong vault password fails before issuing anything" {
  printf 'wrong\n' >"$T/vault-pass"
  issue --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"can't decrypt"* ]]
  ! grep -q "keys create" "$FAKE_LOG"
  work_is_empty
}

@test "issue-key: an account that isn't logged in is refused" {
  FAKE_ACCOUNTS="work@example.org" issue --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"op@example.com isn't logged in"* ]]
}

@test "issue-key: a missing service account is refused" {
  FAKE_SA_MISSING=1 issue --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"can't read service account"*"NOT_FOUND"* ]]
}

@test "issue-key: refuses at Google's limit of 10 keys" {
  seq -f 'old%g' 10 >"$FAKE_KEYS"
  issue --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"already has 10 keys"* ]]
}

@test "issue-key: refuses a variable set twice" {
  printf 'vault_sa_key: a\nvault_sa_key: b\n' >"$T/plain"
  "$REAL_AV" encrypt --output "$VAULT.new" "$T/plain" >/dev/null 2>&1 </dev/null && mv "$VAULT.new" "$VAULT"
  issue --apply --rotate
  [ "$status" -eq 1 ]
  [[ "$output" == *"set 2 times"* ]]
}

@test "issue-key: refuses a work directory on a disk unless allowed" {
  stat -f -c %T "$T/work" | grep -qvE '^(tmpfs|ramfs)$' || skip "the test directory is on tmpfs"
  run "$ISSUE" --service-account "$SA" --account op@example.com \
    --vault-file "$VAULT" --var vault_sa_key --work-dir "$T/work"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not tmpfs"*"--allow-disk-work-dir"* ]]
}

@test "issue-key: usage errors exit 2" {
  run "$ISSUE" --account op@example.com --vault-file "$VAULT" --var v
  [ "$status" -eq 2 ]
  [[ "$output" == *"--service-account is required"* ]]
  run "$ISSUE" --service-account "$SA" --project other-proj --account op@example.com --vault-file "$VAULT" --var v
  [ "$status" -eq 2 ]
  [[ "$output" == *"isn't the service account's project"* ]]
  run "$ISSUE" --service-account "$SA" --account op@example.com --vault-file "$VAULT" --var 'bad-name'
  [ "$status" -eq 2 ]
  run "$ISSUE" --service-account "$SA" --account op@example.com --vault-file "$VAULT" --var
  [ "$status" -eq 2 ]
  [[ "$output" == *"--var needs a value"* ]]
}

@test "issue-key: interrupted after issuing, it deletes the key and cleans up" {
  before="$(sha256sum <"$VAULT")"
  FAKE_CREATE_SLEEP=3 "$ISSUE" --service-account "$SA" --account op@example.com \
    --vault-file "$VAULT" --var vault_sa_key --work-dir "$T/work" --allow-disk-work-dir \
    --apply >"$T/out" 2>&1 &
  pid=$!
  for _ in $(seq 100); do [ -e "$FAKE_KEYS.issued" ] && break; sleep 0.1; done
  [ -e "$FAKE_KEYS.issued" ]
  kill -TERM "$pid"
  rc=0; wait "$pid" || rc=$?
  [ "$rc" -ne 0 ]
  grep -q "interrupted" "$T/out"
  grep -q "UNDO: deleted the new key" "$T/out"
  [ ! -s "$FAKE_KEYS" ]
  [ "$(sha256sum <"$VAULT")" = "$before" ]
  work_is_empty
}
