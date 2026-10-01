# Hand these to each host's Ansible variables.
output "config_host" {
  value = {
    bucket_name_prefix    = module.config_host.bucket_name_prefix
    buckets               = module.config_host.buckets
    service_account_email = module.config_host.service_account_email
    tiers                 = module.config_host.tiers
    lifecycle_slack_days  = module.config_host.lifecycle_slack_days
    key_issue_command     = module.config_host.key_issue_command
  }
}

output "database_host" {
  value = {
    bucket_name_prefix    = module.database_host.bucket_name_prefix
    buckets               = module.database_host.buckets
    service_account_email = module.database_host.service_account_email
    tiers                 = module.database_host.tiers
    lifecycle_slack_days  = module.database_host.lifecycle_slack_days
    key_issue_command     = module.database_host.key_issue_command
  }
}
