output "state_bucket_name" {
  description = "S3 bucket holding Terraform remote state."
  value       = aws_s3_bucket.tfstate.id
}

output "aws_region" {
  description = "Region the state bucket was created in."
  value       = var.aws_region
}
