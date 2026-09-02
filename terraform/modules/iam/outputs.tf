output "github_oidc_provider_arn" {
  description = "ARN of the GitHub OIDC identity provider."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "github_deploy_role_arn" {
  description = "ARN of the role GitHub Actions assumes. Used in workflow configuration."
  value       = aws_iam_role.github_deploy.arn
}

output "github_deploy_role_name" {
  description = "Name of the GitHub Actions deploy role."
  value       = aws_iam_role.github_deploy.name
}
