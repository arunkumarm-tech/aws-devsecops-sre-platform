variable "name_prefix" {
  description = "Prefix applied to all resource names in this module."
  type        = string
}

variable "github_org" {
  description = "GitHub organisation or username that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "Repository name allowed to assume the deploy role."
  type        = string
}

variable "github_branch" {
  description = "Branch allowed to assume the deploy role. Only this ref can deploy."
  type        = string
  default     = "main"
}

variable "tfstate_bucket" {
  description = "Name of the S3 bucket holding Terraform state."
  type        = string
}
