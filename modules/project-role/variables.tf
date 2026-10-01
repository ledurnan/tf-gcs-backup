variable "project" {
  description = "Google Cloud project that holds the backup buckets. Each consumer creates its own roles here, named by role_id_prefix, and shares them across its own backup targets."
  type        = string

  validation {
    condition     = length(var.project) > 0
    error_message = "project must not be empty."
  }
}

variable "role_id_prefix" {
  description = <<-EOT
    Start of both custom role IDs: <prefix>Writer and <prefix>Emergency,
    for example mailsvcBackup -> mailsvcBackupWriter. Required, and
    unique to each consumer: role IDs are unique within a project, so two
    consumers sharing a project with the same names would each keep
    rewriting the other's roles (ADR 0009).
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_.]{2,54}$", var.role_id_prefix))
    error_message = "role_id_prefix must be 3-55 letters, digits, underscores or dots, starting with a letter. Hyphens aren't allowed in role IDs: use mailsvcBackup, not mailsvc-backup."
  }
}

variable "title_prefix" {
  description = "Start of both roles' human-readable titles. Defaults to role_id_prefix."
  type        = string
  default     = null
}

variable "role_propagation_seconds" {
  description = "How long to wait after creating a role before anything binds it. Too short, and the first apply fails until re-run."
  type        = number
  default     = 60

  validation {
    condition     = var.role_propagation_seconds >= 0 && floor(var.role_propagation_seconds) == var.role_propagation_seconds
    error_message = "role_propagation_seconds must be a whole number of 0 or more."
  }
}
