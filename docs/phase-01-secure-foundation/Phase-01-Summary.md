# Phase 1 summary

## What exists at the end

A remote state backend in S3, applied once from `terraform/bootstrap/` and protected by `prevent_destroy`. Versioned, encrypted with SSE-S3, TLS-only by bucket policy, all four public access block settings on, ACLs disabled through `BucketOwnerEnforced`. Locking is native to S3 via `use_lockfile = true`, with no DynamoDB table.

A second bucket receiving the state bucket's server access logs, hardened the same way, with a 90-day object expiry and a 30-day non-current version expiry. Both buckets abort incomplete multipart uploads after 7 days.

A `10.0.0.0/16` VPC with public and private subnets in two availability zones, calculated with `cidrsubnet()`. An internet gateway, one NAT gateway, one route table per private subnet, and `map_public_ip_on_launch = false` on the public subnets. The default security group is managed as an empty resource with no rules. Kubernetes ELB discovery tags are on the subnets already, for Phase 3.

VPC flow logs capturing all traffic at a 60-second aggregation interval into a CloudWatch log group with 14-day retention, encrypted with a customer-managed KMS key whose policy scopes CloudWatch Logs to that one log group through the encryption context. The delivery role can write to that log group and nothing else.

A GitHub OIDC identity provider and a deploy role whose trust policy matches audience and subject with `StringEquals`, so only pushes to `main` in `arunkumarm-tech/aws-devsecops-sre-platform` can assume it. Its state permissions are scoped to the `envs/*` prefix, so it cannot touch bootstrap state. Its infrastructure permissions are split by mutability, with tag conditions on create and modify, and `iam:PassRole` isolated in its own statement.

The AWS default VPC in us-east-1 is deleted.

Checkov reports 120 passed, 0 failed, 10 skipped. Four findings were fixed with real changes; ten are suppressed with written justifications inside the resource blocks.

Nothing runs in any of this. There is no compute, no application, and no pipeline.

## Deliberately deferred

**GitHub Actions pipeline, to Phase 4.** The OIDC provider and the deploy role exist and are verified against the live API. No workflow uses them. `terraform fmt -check` becoming a gate rather than a habit belongs here too, since I made the same formatting mistake twice.

**Alarms, dashboards, and log queries, to Phase 5.** The CloudWatch overview for this account shows zero alarms and zero dashboards. Flow logs are collected and read by nobody unless I go looking, which is evidence collection rather than monitoring. CloudWatch Logs Insights, which is what makes the positional flow log format actually queryable by field, also lands in Phase 5.

**EKS and anything that consumes the network, to Phase 3.** The subnet tags are already in place.

**CloudTrail data events on the state bucket, with no phase attached.** These would be the authoritative record of who read or wrote state. S3 server access logging, which is what exists instead, is best-effort, delayed by up to hours, and admits to dropping records. Data events are billed per event and the state bucket is written on every plan and apply, so this is a cost decision rather than an oversight.

**A customer-managed KMS key on the state bucket, with no phase attached.** Blocked by a bootstrap dependency loop rather than by effort. Resolving it properly means creating the key from a configuration with a separate lifecycle, so that Terraform never needs the key in order to read the state that manages the key.

**Cross-region replication, permanently.** A single-region portfolio account with reproducible state has nothing to recover from that replication would help with.

**A permissions boundary on the deploy role, and an SCP above the account.** Both are the correct next layer of defence and neither exists.

**Default VPC deletion in every other region.** Done in us-east-1 only. Full hardening means every enabled region, which realistically means an SCP or a script rather than doing it by hand.

## Cost profile

**Standing cost when everything is destroyed: $1 a month.** That is the customer-managed KMS key. It is the only thing in Phase 1 that costs money while nothing is deployed, and I decided the key policy was an artefact worth paying a dollar a month to have written and verified.

**When the dev environment is up: roughly $32 a month for one NAT gateway,** before data processing charges. Doubling to about $64 buys one gateway per AZ and removes the single point of failure for outbound traffic. The module parameterises the choice rather than picking one, and defaults to the cheap side because this is a learning account.

**The rule that keeps that number theoretical: `make destroy` at the end of every session.** The one NAT gateway that got measured properly existed from 12:03:29 to 12:14:02, eleven minutes, and cost roughly half a cent. Billing stops at the deletion timestamp, not when the console stops displaying the resource.

**Everything else rounds to zero.** S3 holds about 5.7 KB across four buckets, which is $0.00 at any storage class. CloudWatch Logs ingestion is $0.50 per GB with storage at $0.03 per GB-month, and a dev VPC with nothing running in it produced single-digit megabytes over a 14-day retention window, so that is fractions of a cent too. The NAT gateway and the KMS key are the entire cost profile of Phase 1.

That is worth stating rather than leaving implied. The instinct when reading a bill is that many small line items add up, and here they do not. One hourly resource dominates everything else by three orders of magnitude, which is why the destroy habit matters more than any amount of tuning elsewhere.

## The account ID in the Terraform source

The documentation replaces the account ID with `123456789012` throughout. The Terraform source does not, and that is worth explaining rather than leaving as an apparent inconsistency.

The ID appears in exactly one kind of place: the `backend` block in `terraform/bootstrap/backend.tf` and `terraform/envs/dev/backend.tf`, as part of the state bucket name. Backend configuration is evaluated before Terraform has initialised providers or evaluated any expression, so it cannot use variables, locals, or interpolation. There is no version of this file that does not contain the literal string. `backend.tf` was committed on the first day, so the ID is in this repository's git history from the first commit and rewriting the working tree would not remove it.

Everywhere else the ID resolves at runtime. Bucket names in `bootstrap/main.tf`, role ARNs in the IAM module, the log group ARN in the KMS key policy, and the `root` principal in that policy all come from `data "aws_caller_identity" "current"`, so the same configuration applies cleanly in any account.

The reason I am comfortable with this is that an account ID is not a secret and it was never the control. The thing an exposed account ID is supposed to enable is role enumeration, guessing role names and attempting to assume them. What stops that here is the trust policy on the deploy role, which requires an exact `StringEquals` match on a subject naming one repository and one branch. There is no role in this account that can be assumed by anyone who merely knows the account number. Obscurity was never doing the work, so losing it costs nothing.

The redaction in the documentation is habit rather than defence: these files are what a reader sees first, and publishing an account ID in prose invites someone to try, which wastes their time and mine.

## What I would tell someone starting Phase 1 again

Build the state backend first and protect it before anything else exists to lose. Get the offline checks running before the first `apply`, because they catch most of what goes wrong and they cost nothing. Verify controls with a read-only API call rather than trusting that `apply` succeeding means the thing works. And destroy at the end of every session as a rule, not as a decision.
