# Customer-managed key for VPC Flow Log encryption at rest.
#
# CloudWatch Logs encrypts with an AWS-owned key by default. A customer-managed
# key is used here so the key policy, rotation schedule, and deletion window are
# all visible in source and under our control.
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_kms_key" "flow_logs" {
  description             = "Encrypts VPC Flow Log data for ${var.name_prefix}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccountAdministration"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogsEncryption"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.name}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*"
        ]
        Resource = "*"
        Condition = {
          ArnEquals = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/vpc-flow-logs/${var.name_prefix}"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.name_prefix}-flow-logs-key"
  }
}

resource "aws_kms_alias" "flow_logs" {
  name          = "alias/${var.name_prefix}-flow-logs"
  target_key_id = aws_kms_key.flow_logs.key_id
}