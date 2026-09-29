variable "project" {
  description = "Google Cloud project that holds the backup buckets. The role is created once per project and shared by every backup target in it."
  type        = string

  validation {
    condition     = length(var.project) > 0
    error_message = "project must not be empty."
  }
}

variable "role_id" {
  description = "ID of the custom role. Change it only to run two independent copies of this pattern in one project."
  type        = string
  default     = "offsiteBackupWriter"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_.]{3,64}$", var.role_id))
    error_message = "role_id must be 3-64 characters of letters, digits, underscores or dots (a Google Cloud custom role ID)."
  }
}

variable "title" {
  description = "Human-readable title of the custom role."
  type        = string
  default     = "Offsite backup writer (no delete)"
}
