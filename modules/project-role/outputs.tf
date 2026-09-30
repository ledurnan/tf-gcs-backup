output "role_name" {
  description = "Full name of the custom role (projects/<project>/roles/<role_id>). Pass it to each backup-target module call."
  value       = google_project_iam_custom_role.writer.name
}

output "permissions" {
  description = "Permissions the role grants."
  value       = google_project_iam_custom_role.writer.permissions
}
