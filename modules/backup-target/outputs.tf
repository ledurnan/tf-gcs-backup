output "bucket_name" {
  description = "The bucket's name."
  value       = google_storage_bucket.this.name
}

output "service_account_email" {
  description = "The writer service account. Issue its key out of band (see key_issue_command); keys never go through Terraform, so they never reach state."
  value       = google_service_account.writer.email
}

output "tiers" {
  description = "The tier contract: give this list to the sending side unchanged. It refuses to upload if the bucket's lifecycle rules disagree."
  value       = local.tiers
}

output "lifecycle_slack_days" {
  description = "Slack added to each tier's expiry. The sending side must use the same value."
  value       = var.lifecycle_slack_days
}

output "key_issue_command" {
  description = "The one-off command that issues the host's key. Run it deliberately, put the key in your secret store, then delete the file. The file name ends in -sa.json, which this repository's .gitignore covers; make sure yours does too."
  value       = "gcloud iam service-accounts keys create ./${var.service_account_id}-sa.json --iam-account=${google_service_account.writer.email} --project=${var.project}"
}
