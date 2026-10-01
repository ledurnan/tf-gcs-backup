#!/usr/bin/env bats
#
# The role's validation: a valid configuration passes, and each invalid
# one is refused before anything changes on a host.

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

setup() {
  export ANSIBLE_ROLES_PATH="$ROOT/ansible/roles"
  export ANSIBLE_NOCOLOR=1 ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_INVENTORY_UNPARSED_WARNING=false
}

validate() {
  run ansible-playbook "$ROOT/tests/ansible/test_validate.yml" "$@"
}

refused() {
  validate -e "$1"
  [ "$status" -ne 0 ] || { echo "accepted: $1"; return 1; }
  # Refused by one of the role's asserts, not by some unrelated error.
  [[ "$output" == *"TASK [offsite_backup : Assert"* && "$output" =~ (fatal|failed):\ \[localhost\] ]] \
    || { echo "failed for another reason: $output"; return 1; }
}

@test "a valid configuration passes" {
  validate
  [ "$status" -eq 0 ]
}

@test "refused: no bucket name prefix" { refused '{"offsite_backup_bucket_name_prefix": ""}'; }
@test "refused: a bucket name prefix with capitals" { refused '{"offsite_backup_bucket_name_prefix": "Example-Host"}'; }
@test "refused: a tier bucket name over 63 characters" { refused '{"offsite_backup_bucket_name_prefix": "a-very-long-bucket-name-prefix-that-leaves-no-room-at-all"}'; }
@test "refused: a v0.1 retention mode" { refused '{"offsite_backup_retention_mode": "Locked"}'; }
@test "refused: a v0.1 bucket" { refused '{"offsite_backup_bucket": "example-host-backup"}'; }
@test "refused: no tiers" { refused '{"offsite_backup_tiers": []}'; }
@test "refused: no recipients" { refused '{"offsite_backup_age_recipients": []}'; }
@test "refused: a private key as a recipient" { refused '{"offsite_backup_age_recipients": ["AGE-SECRET-KEY-1EXAMPLE"]}'; }
@test "refused: nothing to back up" { refused '{"offsite_backup_paths": [], "offsite_backup_pre_command": ""}'; }
@test "refused: a relative path" { refused '{"offsite_backup_paths": ["etc/example"]}'; }
@test "refused: an unsafe prefix" { refused '{"offsite_backup_prefix": "../other-host"}'; }
@test "refused: a bad tier name" { refused '{"offsite_backup_tiers": [{"name": "Daily Tier", "retain_days": 7, "when": "always"}]}'; }
@test "refused: zero retention" { refused '{"offsite_backup_tiers": [{"name": "daily", "retain_days": 0, "when": "always"}]}'; }
@test "refused: a bad schedule" { refused '{"offsite_backup_tiers": [{"name": "daily", "retain_days": 7, "when": "monthday:31"}]}'; }
@test "refused: duplicate tiers" { refused '{"offsite_backup_tiers": [{"name": "daily", "retain_days": 7, "when": "always"}, {"name": "daily", "retain_days": 9, "when": "always"}]}'; }
@test "refused: a name format with a space" { refused '{"offsite_backup_tiers": [{"name": "daily", "retain_days": 7, "when": "always", "name_format": "%Y %m"}]}'; }
@test "refused: negative slack" { refused '{"offsite_backup_lifecycle_slack_days": -1}'; }
@test "refused: a key that isn't JSON" { refused '{"offsite_backup_sa_key": "not json"}'; }
@test "refused: a key of the wrong type" { refused '{"offsite_backup_sa_key": "{\"type\": \"user\", \"client_email\": \"x\", \"private_key\": \"y\"}"}'; }
@test "refused: a pre-backup command alone is fine, but no recipients is not" { refused '{"offsite_backup_paths": [], "offsite_backup_age_recipients": []}'; }
@test "refused: no maximum size" { refused '{"offsite_backup_max_size": ""}'; }
@test "refused: a zero maximum size" { refused '{"offsite_backup_max_size": "0"}'; }
@test "refused: a maximum size in decimal units" { refused '{"offsite_backup_max_size": "2GB"}'; }
@test "refused: a fractional growth percentage" { refused '{"offsite_backup_max_growth_percent": "50.5"}'; }
@test "accepted: a maximum size in plain bytes" {
  validate -e '{"offsite_backup_max_size": 1073741824}'
  [ "$status" -eq 0 ]
}
