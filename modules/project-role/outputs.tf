output "role_name" {
  description = "Full name of the custom role (projects/<project>/roles/<role_id>). Pass it to each backup-target module call."
  value       = time_sleep.roles_usable.triggers["writer"]
}

output "permissions" {
  description = "Permissions the role grants."
  value       = google_project_iam_custom_role.writer.permissions
}

output "emergency_role_name" {
  description = "Full name of the emergency custom role. Pass it to backup-target's emergency_role_name if you give anyone emergency access."
  value       = time_sleep.roles_usable.triggers["emergency"]
}
