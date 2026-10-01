output "bucket_name_prefix" {
  description = "Start of every tier bucket's name. The sending side's offsite_backup_bucket_name_prefix."
  value       = var.bucket_name_prefix
}

output "buckets" {
  description = "Each tier's bucket name, by tier."
  value       = { for k, b in google_storage_bucket.tier : k => b.name }
}

output "service_account_email" {
  description = "The writer service account. Issue its key out of band (see key_issue_command); keys never go through Terraform, so they never reach state."
  value       = google_service_account.writer.email
}

output "tiers" {
  description = "The tier contract: give the names and retain_days to the sending side unchanged. It refuses to upload if any tier's bucket disagrees."
  value       = [for t in var.tiers : local.tiers[t.name]]
}

output "lifecycle_slack_days" {
  description = "Slack added to each tier's expiry. The sending side must use the same value."
  value       = var.lifecycle_slack_days
}

output "key_issue_command" {
  description = "The one-off command that issues the host's key. Run it deliberately, put the key in your secret store, then delete the file."
  value       = "gcloud iam service-accounts keys create ./${var.service_account_id}.json --iam-account=${google_service_account.writer.email} --project=${var.project}"
}
