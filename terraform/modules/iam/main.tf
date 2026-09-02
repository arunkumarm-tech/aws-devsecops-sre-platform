data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# GitHub's OIDC identity provider. Registering this tells AWS to trust
# tokens signed by GitHub. Without it, no GitHub workflow can assume
# any role in this account.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}
