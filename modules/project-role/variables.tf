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

variable "emergency_role_id" {
  description = "ID of the emergency custom role (ADR 0008). Change it only to run two independent copies of this pattern in one project."
  type        = string
  default     = "offsiteBackupEmergency"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_.]{3,64}$", var.emergency_role_id))
    error_message = "emergency_role_id must be 3-64 characters of letters, digits, underscores or dots (a Google Cloud custom role ID)."
  }
}

variable "emergency_title" {
  description = "Human-readable title of the emergency custom role."
  type        = string
  default     = "Offsite backup emergency (unlocked tiers only)"
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
