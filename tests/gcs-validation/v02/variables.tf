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

# This validation's own role names (ADR 0009): never another consumer's.
variable "role_id_prefix" {
  description = "Start of the validation's role IDs."
  type        = string
  default     = "tfgcsbValidation"
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
