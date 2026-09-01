variable "aws_region" {
  description = "AWS region for all resources in this project."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short project identifier used in resource names and tags."
  type        = string
  default     = "devsecops-sre"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "dev"
}
