# State access is scoped to this project's bucket only.
# This part IS genuinely least privilege and worth doing properly.
data "aws_iam_policy_document" "tfstate_access" {
  statement {
    sid    = "ListStateBucket"
    effect = "Allow"

    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.tfstate_bucket}"]
  }

  statement {
    sid    = "ReadWriteStateObjects"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    # Scoped to the envs/ prefix. This role cannot touch
    # bootstrap/terraform.tfstate, which manages the bucket itself.
    resources = ["arn:aws:s3:::${var.tfstate_bucket}/envs/*"]
  }
}

resource "aws_iam_policy" "tfstate_access" {
  name        = "${var.name_prefix}-tfstate-access"
  description = "Read/write Terraform state under envs/ only."
  policy      = data.aws_iam_policy_document.tfstate_access.json
}

resource "aws_iam_role_policy_attachment" "tfstate_access" {
  role       = aws_iam_role.github_deploy.name
  policy_arn = aws_iam_policy.tfstate_access.arn
}

# Infrastructure permissions. Scoped by service, not by resource.
#
# TRADE-OFF, documented deliberately:
# Resource-level scoping is impractical here because Terraform creates
# resources whose ARNs do not exist until creation time. A policy that
# named specific VPC or subnet ARNs could never create the first one.
# Service-level scoping is the pragmatic boundary: this role can manage
# networking, but cannot touch IAM users, billing, or Organizations.
data "aws_iam_policy_document" "infrastructure" {
  statement {
    sid    = "NetworkingManagement"
    effect = "Allow"

    actions = [
      "ec2:*Vpc*",
      "ec2:*Subnet*",
      "ec2:*Route*",
      "ec2:*Gateway*",
      "ec2:*Address*",
      "ec2:*SecurityGroup*",
      "ec2:*NetworkAcl*",
      "ec2:*FlowLogs*",
      "ec2:*Tags*",
      "ec2:Describe*",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "FlowLogDestination"
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:DescribeLogGroups",
      "logs:PutRetentionPolicy",
      "logs:TagResource",
      "logs:ListTagsForResource",
    ]

    resources = ["arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/vpc-flow-logs/*"]
  }

  statement {
    sid    = "FlowLogServiceRole"
    effect = "Allow"

    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:PassRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
    ]

    # Only roles matching this project's naming convention.
    # This role cannot create or modify arbitrary IAM roles.
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.name_prefix}-*"]
  }
}

resource "aws_iam_policy" "infrastructure" {
  name        = "${var.name_prefix}-infrastructure"
  description = "Networking and flow-log permissions for the deploy role."
  policy      = data.aws_iam_policy_document.infrastructure.json
}

resource "aws_iam_role_policy_attachment" "infrastructure" {
  role       = aws_iam_role.github_deploy.name
  policy_arn = aws_iam_policy.infrastructure.arn
}
