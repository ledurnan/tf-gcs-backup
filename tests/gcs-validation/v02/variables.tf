variable "project" {
  description = "Project to validate in."
  type        = string
}

variable "location" {
  description = "Bucket location."
  type        = string
}

variable "name_prefix" {
  description = "Start of every bucket name this validation creates."
  type        = string
}

variable "sa_prefix" {
  description = "Start of every service account ID this validation creates."
  type        = string
  default     = "tfgcsb"
}

# Never the default (offsiteBackupWriter): another configuration in the
# same project may own that role, and v0.2 changes its permissions.
variable "role_id" {
  description = "Custom role ID for the validation's writer role."
  type        = string
  default     = "tfgcsbValidationWriter"
}

variable "emergency_role_id" {
  description = "Custom role ID for the validation's emergency role."
  type        = string
  default     = "tfgcsbValidationEmergency"
}

variable "labels" {
  description = "Labels on every bucket, so validation buckets are easy to find."
  type        = map(string)
  default     = { purpose = "tf-gcs-backup-validation" }
}

variable "lock_locked_tier" {
  description = "Lock the validation's 'locked' tier. Irreversible."
  type        = bool
  default     = false
}
