variable "project" {
  description = "Your Google Cloud project ID."
  type        = string
}

variable "location" {
  description = "Where the backups live, for example europe-west2."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for bucket and service account names. Bucket names are global, so make it distinctive."
  type        = string
}

variable "role_id_prefix" {
  description = "Start of your role IDs: letters and digits, no hyphens. Unique to you within the project."
  type        = string
}
