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

# Infrastructure permissions, split by mutability.
#
# Read-only actions cannot be tag-constrained, so they remain broad.
# Create actions are constrained by the tag Terraform applies at
# creation. Modify and delete actions are constrained by the tag
# already on the resource, so this role cannot touch infrastructure
# it did not create.
data "aws_iam_policy_document" "infrastructure" {
  statement {
    sid    = "NetworkingRead"
    effect = "Allow"

    actions = [
      "ec2:Describe*",
      "ec2:Get*",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "NetworkingCreate"
    effect = "Allow"

    actions = [
      "ec2:CreateVpc",
      "ec2:CreateSubnet",
      "ec2:CreateRouteTable",
      "ec2:CreateInternetGateway",
      "ec2:CreateNatGateway",
      "ec2:CreateSecurityGroup",
      "ec2:CreateFlowLogs",
      "ec2:CreateTags",
      "ec2:AllocateAddress",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = [var.project_tag]
    }
  }

  statement {
    sid    = "NetworkingModify"
    effect = "Allow"

    actions = [
      "ec2:DeleteVpc",
      "ec2:DeleteSubnet",
      "ec2:DeleteRouteTable",
      "ec2:DeleteInternetGateway",
      "ec2:DeleteNatGateway",
      "ec2:DeleteSecurityGroup",
      "ec2:DeleteFlowLogs",
      "ec2:DeleteTags",
      "ec2:ReleaseAddress",
      "ec2:AttachInternetGateway",
      "ec2:DetachInternetGateway",
      "ec2:AssociateRouteTable",
      "ec2:DisassociateRouteTable",
      "ec2:CreateRoute",
      "ec2:DeleteRoute",
      "ec2:ModifyVpcAttribute",
      "ec2:ModifySubnetAttribute",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project_tag]
    }
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
