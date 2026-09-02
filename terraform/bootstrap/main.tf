# Account ID is resolved at runtime, never hardcoded in source.
data "aws_caller_identity" "current" {}

locals {
  state_bucket_name = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "tfstate" {
  # checkov:skip=CKV_AWS_144:Cross-region replication is a production DR control. This is a single-region portfolio account and the state file is reproducible from source, so replication would double storage cost for no recovery benefit.
  # checkov:skip=CKV_AWS_145:SSE-S3 is used deliberately. A customer-managed KMS key would create a bootstrap dependency loop, since the key policy is managed by the same Terraform that needs the key to read its own state.
  # checkov:skip=CKV2_AWS_62:No consumer exists for S3 event notifications on this bucket. Adding a notification target with nothing listening would be configuration without purpose.
  bucket = local.state_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

# Versioning is mandatory: it is the recovery path for a corrupted
# state file, and native S3 locking depends on it.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# State files contain resource attributes in plaintext.
# This bucket must never be publicly reachable.
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Reject any unencrypted-in-transit request.
resource "aws_s3_bucket_policy" "tfstate_tls_only" {
  bucket = aws_s3_bucket.tfstate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.tfstate.arn,
          "${aws_s3_bucket.tfstate.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}

# Receives S3 server access logs from the state bucket.
resource "aws_s3_bucket" "access_logs" {
  # checkov:skip=CKV_AWS_18:This bucket is itself the access-log destination. Enabling access logging on it would create a recursive loop of logs about logs.
  # checkov:skip=CKV_AWS_144:Cross-region replication is a production DR control. Access logs are operational data with a 90-day life, not worth doubling storage cost here.
  # checkov:skip=CKV_AWS_145:SSE-S3 is used deliberately, matching the state bucket and avoiding a KMS dependency during bootstrap.
  # checkov:skip=CKV2_AWS_62:No consumer exists for S3 event notifications on this bucket.
  bucket = "${var.project_name}-tfstate-logs-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name    = "Terraform state access logs"
    Purpose = "S3 server access logging destination"
  }
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Delivers access logs for the state bucket into the log bucket.
# Best-effort and delayed by design; CloudTrail data events would be
# the authoritative record, at a per-event cost.
resource "aws_s3_bucket_logging" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "s3-access-logs/"
}

# Versioning keeps every state write forever without this rule.
# The current version is never expired; only superseded ones age out.
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}