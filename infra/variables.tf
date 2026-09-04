variable "account_id" {
  description = "AWS account that may receive personal cloud resources."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12 digit AWS account ID."
  }
}

variable "budget_email" {
  description = "Email address for gross monthly cost alerts."
  type        = string
  sensitive   = true
}

variable "instance_type" {
  description = "EC2 instance type for the development host."
  type        = string
  default     = "m7i.xlarge"
}

variable "data_volume_size" {
  description = "Persistent home volume size in GiB."
  type        = number
  default     = 300
}

variable "home_snapshot_id" {
  description = "Optional EBS snapshot used when creating a replacement home volume."
  type        = string
  default     = null

  validation {
    condition     = var.home_snapshot_id == null || can(regex("^snap-[0-9a-f]+$", var.home_snapshot_id))
    error_message = "home_snapshot_id must be null or an EBS snapshot ID."
  }
}
