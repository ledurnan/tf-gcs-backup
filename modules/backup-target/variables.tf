variable "project" {
  description = "Google Cloud project for the bucket and the service account."
  type        = string

  validation {
    condition     = length(var.project) > 0
    error_message = "project must not be empty."
  }
}

variable "bucket_name" {
  description = "Bucket name. The GCS namespace is global, so an 'already exists' error can mean someone else's project."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 characters: lowercase letters, digits, dots, hyphens and underscores, starting and ending with a letter or digit."
  }
}

variable "location" {
  description = "Bucket location, for example europe-west2. Required: where backups live can be a data-protection decision, so there is no default."
  type        = string

  validation {
    condition     = length(var.location) > 0
    error_message = "location must not be empty."
  }
}

variable "storage_class" {
  description = "Default storage class. Cold classes carry a minimum storage duration and bill early deletion, so every tier must retain at least that long (enforced at plan time)."
  type        = string
  default     = "STANDARD"

  validation {
    condition     = contains(["STANDARD", "NEARLINE", "COLDLINE", "ARCHIVE"], var.storage_class)
    error_message = "storage_class must be one of STANDARD, NEARLINE, COLDLINE or ARCHIVE."
  }
}

variable "tiers" {
  description = <<-EOT
    Retention tiers. Each object is written under "<name>/" and expires
    after retain_days (plus lifecycle_slack_days). The same list, with the
    same days, must be given to the sending side. Required: retention is a
    data-protection decision, and locked retention can't be shortened
    once an object is written.
  EOT
  type = list(object({
    name        = string
    retain_days = number
  }))

  validation {
    condition     = length(var.tiers) > 0
    error_message = "tiers must contain at least one tier."
  }

  validation {
    condition     = alltrue([for t in var.tiers : can(regex("^[a-z0-9][a-z0-9-]{0,30}$", t.name))])
    error_message = "Each tier name must be lowercase letters, digits and hyphens (1-31 characters), starting with a letter or digit. It becomes the object prefix."
  }

  validation {
    condition     = length(distinct([for t in var.tiers : t.name])) == length(var.tiers)
    error_message = "Tier names must be unique."
  }

  validation {
    condition     = alltrue([for t in var.tiers : t.retain_days >= 1 && floor(t.retain_days) == t.retain_days])
    error_message = "Each tier's retain_days must be a whole number of at least 1."
  }
}

variable "lifecycle_slack_days" {
  description = "Days added to each tier's retention before the lifecycle rule deletes the object, so expiry never races the retention clock. The sending side must use the same value."
  type        = number
  default     = 1

  validation {
    condition     = var.lifecycle_slack_days >= 0 && floor(var.lifecycle_slack_days) == var.lifecycle_slack_days
    error_message = "lifecycle_slack_days must be a whole number of 0 or more."
  }
}

variable "role_name" {
  description = "Full name of the write-only custom role, from the project-role module's role_name output."
  type        = string

  validation {
    condition     = can(regex("^projects/[^/]+/roles/[^/]+$", var.role_name))
    error_message = "role_name must be a full custom role name, projects/<project>/roles/<role_id>."
  }
}

variable "service_account_id" {
  description = "Account ID (the part before the @) of the service account the backed-up host uses. One per host."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.service_account_id))
    error_message = "service_account_id must be 6-30 characters of lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "service_account_display_name" {
  description = "Display name of the service account. Defaults to one naming the bucket."
  type        = string
  default     = null
}

variable "labels" {
  description = "Labels applied to the bucket."
  type        = map(string)
  default     = {}
}

variable "soft_delete_retention_seconds" {
  description = "Soft-delete retention for the bucket. null leaves the bucket's current setting unmanaged. Soft delete keeps expired objects (and bills for them) for this long after lifecycle deletion."
  type        = number
  default     = null
}
