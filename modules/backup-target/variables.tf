variable "project" {
  description = "Google Cloud project for the bucket and the service account."
  type        = string

  validation {
    condition     = length(var.project) > 0
    error_message = "project must not be empty."
  }
}

variable "bucket_name_prefix" {
  description = "Start of every bucket name: each tier gets <bucket_name_prefix>-<tier name>. The GCS namespace is global, so an 'already exists' error can mean someone else's project."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{0,60}[a-z0-9]$", var.bucket_name_prefix))
    error_message = "bucket_name_prefix must be 2-62 characters: lowercase letters, digits, dots, hyphens and underscores, starting and ending with a letter or digit."
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
    Retention tiers. Each tier gets its own bucket,
    <bucket_name_prefix>-<name>, whose retention policy keeps every object
    for retain_days and whose expiry rule deletes it retain_days +
    lifecycle_slack_days after upload. The same names and days must be
    given to the sending side. Required: retention is a data-protection
    decision.

    locked locks the bucket's retention policy: from then on nobody,
    including the project owner, can delete an object before it is
    retain_days old or shorten the period. It can't be undone. Leave it
    false until a restore test has passed.
  EOT
  type = list(object({
    name        = string
    retain_days = number
    locked      = optional(bool, false)
  }))

  validation {
    condition     = length(var.tiers) > 0
    error_message = "tiers must contain at least one tier."
  }

  validation {
    condition     = alltrue([for t in var.tiers : can(regex("^[a-z0-9][a-z0-9-]{0,30}$", t.name))])
    error_message = "Each tier name must be lowercase letters, digits and hyphens (1-31 characters), starting with a letter or digit. It ends the tier's bucket name."
  }

  validation {
    condition     = length(distinct([for t in var.tiers : t.name])) == length(var.tiers)
    error_message = "Tier names must be unique."
  }

  validation {
    condition     = alltrue([for t in var.tiers : t.retain_days >= 1 && t.retain_days <= 36500 && floor(t.retain_days) == t.retain_days])
    error_message = "Each tier's retain_days must be a whole number from 1 to 36500 (the 100-year limit of a bucket retention policy)."
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
  description = "Labels applied to every tier's bucket. Each also gets backup-tier = <tier name>."
  type        = map(string)
  default     = {}
}

variable "soft_delete_retention_seconds" {
  description = "Soft-delete retention for each tier's bucket. null leaves the bucket's current setting unmanaged. Soft delete keeps expired objects (and bills for them) for this long after lifecycle deletion."
  type        = number
  default     = null
}

variable "emergency_role_name" {
  description = "Full name of the emergency custom role, from the project-role module's emergency_role_name output. Needed only with emergency_members."
  type        = string
  default     = null

  validation {
    condition     = var.emergency_role_name == null || can(regex("^projects/[^/]+/roles/[^/]+$", var.emergency_role_name))
    error_message = "emergency_role_name must be a full custom role name, projects/<project>/roles/<role_id>."
  }
}

variable "emergency_members" {
  description = <<-EOT
    Principals given emergency access to this host's unlocked tiers
    (ADR 0008), by a name you choose: { oncall = "group:..." }. They can
    remove or shorten a tier's retention policy and then delete objects,
    for example to clear junk a compromised host wrote. Locked tiers are
    never included. Use an identity that is never on a backed-up host and
    isn't anyone's everyday account. Empty by default: the project owner
    can do the same in an emergency.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.emergency_members) : can(regex("^[a-z0-9][a-z0-9_-]{0,30}$", k))])
    error_message = "Each emergency member's name must be lowercase letters, digits, hyphens and underscores (1-31 characters)."
  }

  validation {
    condition     = alltrue([for m in values(var.emergency_members) : can(regex("^(user|group|serviceAccount):[^@\\s]+@[^@\\s]+$", m))])
    error_message = "Each emergency member must be user:, group: or serviceAccount: followed by an email address. Never allUsers, allAuthenticatedUsers or a whole domain."
  }
}
