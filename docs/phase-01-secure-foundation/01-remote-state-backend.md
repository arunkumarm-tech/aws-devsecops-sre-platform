# Remote state backend

Terraform records every resource it manages in a state file. Lose that file and Terraform no longer knows the VPC in the console belongs to it. Run two applies against the same local copy and you get a corrupted map of reality. So the first thing I built was somewhere durable for it to live.

The bootstrap configuration sits in `terraform/bootstrap/`. I apply it once and never destroy it. When I run `make destroy` at the end of a session it targets `terraform/envs/dev`, which is where the running cost is. The bucket survives.

## The bucket and each control on it

The bucket is `devsecops-sre-tfstate-123456789012`. The account ID is in the name because S3 bucket names are globally unique across every AWS account on earth, and `devsecops-sre-tfstate` on its own would collide with somebody else's the first time anyone else tried it.

**Versioning, enabled.** This does two jobs. If a state write is interrupted and leaves a truncated file, the previous version is the recovery path. It is also a prerequisite for the locking mechanism described below, so it is not optional here even if I did not want it for recovery.

**SSE-S3 encryption with bucket keys.** Server-side encryption using S3-managed keys. Bucket keys reduce the number of encryption calls S3 makes per object. My reasoning for choosing this over a customer-managed KMS key is below, and it is one of the decisions I expect to be asked about.

**Public access block, all four settings true.** `block_public_acls`, `block_public_policy`, `ignore_public_acls`, `restrict_public_buckets`. A Terraform state file contains resource attributes in plaintext. Subnet IDs, role ARNs, and anything a provider chose to record. It should never be reachable from the internet, and the account-level setting is not something I want to rely on being unchanged.

**Ownership controls set to `BucketOwnerEnforced`.** This turns ACLs off entirely. Object ACLs are the legacy access mechanism and the source of most accidental public-bucket stories. With this set, the bucket policy and IAM are the only things that grant access, which means there is one place to look when answering "who can read this".

**A bucket policy denying any request where `aws:SecureTransport` is false.** Encryption at rest does nothing for a request travelling over plain HTTP. The deny is explicit and unconditional:

```hcl
{
  Sid       = "DenyInsecureTransport"
  Effect    = "Deny"
  Principal = "*"
  Action    = "s3:*"
  Resource  = [bucket_arn, "${bucket_arn}/*"]
  Condition = { Bool = { "aws:SecureTransport" = "false" } }
}
```

An explicit deny beats any allow in IAM evaluation, so this holds regardless of what identity policies exist now or later.

**`prevent_destroy = true` in the lifecycle block.** Terraform refuses to plan a destroy of this bucket. If I ever run `terraform destroy` in the bootstrap directory by accident, the plan fails rather than deleting the thing that holds the state of everything else.

## Locking without DynamoDB

State locking here uses S3 native locking, turned on with a single line in the backend block:

```hcl
terraform {
  backend "s3" {
    bucket       = "devsecops-sre-tfstate-123456789012"
    key          = "envs/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

Almost every tutorial still tells you to create a DynamoDB table with a `LockID` partition key and pass it as `dynamodb_table`. That approach is deprecated. S3 now supports conditional writes, which is all a lock ever needed, and `use_lockfile = true` makes Terraform write a `.tflock` object next to the state file instead. One less resource, one less thing to pay for, one less thing to forget to create in a new account.

I am calling this out because it is a cheap signal of currency. Anyone who copies a 2023 blog post ends up with the DynamoDB table.

## Why SSE-S3 and not a customer-managed KMS key

A customer-managed key would be the stronger control in isolation. I would get key rotation on my own schedule, a key policy I control, and an audit trail of key use. I chose not to, and the reason is a dependency loop.

The key policy would be managed by the same Terraform configuration that needs the key in order to read its own state. If the key policy is ever wrong, or the key is scheduled for deletion, Terraform cannot read the state file that would let it fix the key policy. There is no clean recovery from that except manual intervention in the console, which is exactly the situation infrastructure as code exists to avoid.

SSE-S3 has no such loop. AWS manages the key, it is always available, and the state file is still encrypted at rest.

This reasoning appears again in the Checkov section as the written justification for suppressing `CKV_AWS_145` on both buckets. I did not want a suppression that says "not needed here". I wanted one that says what would break.

## The one place the account ID is hardcoded

Everywhere else the account ID comes from a data source:

```hcl
data "aws_caller_identity" "current" {}

locals {
  state_bucket_name = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"
}
```

The exception is the `backend` block in `terraform/envs/dev/backend.tf`, where the bucket name is written out in full. Backend configuration is evaluated before Terraform has initialised providers or evaluated any expression, so it cannot use variables, locals, or interpolation of any kind. This is a documented Terraform limitation rather than something I overlooked. The escape hatch, if I needed one, is partial backend configuration passed with `-backend-config` at init time.

## S3 access logging, and what it is not

The state bucket sends server access logs to a second bucket, `devsecops-sre-tfstate-logs-123456789012`, via `aws_s3_bucket_logging` with the prefix `s3-access-logs/`. The log bucket is hardened identically: versioning, SSE-S3, all four public access block settings, `BucketOwnerEnforced`.

It does not have access logging enabled on itself. A bucket that logs its own access writes a log object, which is an access, which writes a log object. The recursion is the reason, and it is written into the source as a `checkov:skip` comment rather than left for a reader to work out.

The honest framing matters more than the control. S3 server access logging is best-effort. Delivery can be delayed by hours, and AWS states that records can be dropped. It is useful for noticing patterns and useless as an audit trail, because you cannot prove a negative from a log that admits to losing records.

The authoritative record of who read or wrote the state file would be CloudTrail data events. I did not enable them. They are billed per event, and a bucket that gets written on every plan and apply generates a lot of events for a portfolio account. That is a cost decision I can defend, and it is a different answer from "I did not think of it".

## Lifecycle rules, and the difference between the two buckets

Versioning without expiry means every state write is retained forever. A hundred applies leaves a hundred state files, all billed. The two buckets get deliberately different rules.

State bucket: only non-current versions expire, after 90 days. The current state file is never touched by a lifecycle rule, because the current state file is the thing the whole bucket exists to protect. Ninety days is long enough that I can still recover from a mistake I did not notice for a month.

Log bucket: objects expire outright at 90 days, and non-current versions at 30. These are operational records with a short useful life, and nothing depends on the current version of a log object staying around.

Both rules include `abort_incomplete_multipart_upload` after 7 days. A multipart upload that fails partway leaves its uploaded parts in the bucket. Those parts do not appear in the console object listing, they are not returned by `ListObjects`, and they are billed at standard storage rates until something removes them. It is the most common surprise line item on an S3 bill.

## What I would add for production

CloudTrail data events on the state bucket, accepting the per-event cost, because in a real environment the question "who changed state at 03:00" needs an answer that does not come with a disclaimer. Cross-region replication if the account had a disaster recovery requirement, which this one does not. A customer-managed key, once the key is created by a separate configuration with its own lifecycle, which removes the dependency loop rather than ignoring it.
