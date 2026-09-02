# Security scanning with Checkov

`terraform validate` answers whether a configuration is syntactically valid and internally consistent. It will happily approve a public S3 bucket with no encryption. Checkov asks a different question: given what this code says it will build, is that a sensible thing to build. It ships with roughly a thousand policies across the major cloud providers.

I ran it at version 3.3.16 against the whole `terraform/` tree, offline, with no credentials.

## What it cannot do

Checkov pattern-matches source code. It does not talk to AWS, it cannot see runtime state, and it does not evaluate IAM condition blocks.

That last one has consequences I ran into directly. A policy statement with `Resource = "*"` and a tight condition that makes it safe looks identical to Checkov as one with `Resource = "*"` and no condition at all. The finding stays. The code is fine. There is no way to make the check pass by improving the code, only by suppressing it with an explanation.

Which is why the number I care about is not the failure count. It is whether every finding has an answer attached.

## The progression

| Stage | Passed | Failed | Skipped |
|---|---|---|---|
| First run | 98 | 10 | 0 |
| After adding tag conditions to the IAM policy | 99 | 9 | 0 |
| After the S3 fixes, with suppressions misplaced | 116 | 10 | 0 |
| After moving the suppressions inside the resource blocks | 115 | 4 | 7 |
| Final, after the KMS fix and the IAM suppressions | 120 | 0 | 10 |

The third row is the one I would point at. Failures went from 9 back up to 10, and the passing count jumped by seventeen, because I had fixed `CKV_AWS_18` by building an access-log bucket and the new bucket got scanned exactly like every other resource. Fixing one finding by adding a resource can hand you more findings. That is not a flaw in the tool, it is what happens when the surface area grows, and it is worth knowing before you promise anyone a clean scan by the end of the afternoon.

The fourth row is the misplaced-suppression bug. Skipped went from 0 to 7 without me changing a single suppression, only their position. Details are in [Mistakes-We-Made.md](Mistakes-We-Made.md).

## Fixed, not suppressed

Four findings were genuine and got real changes.

`CKV_AWS_111` and `CKV_AWS_109`, both about write access without constraint, cleared once the IAM policy carried `aws:RequestTag/Project` on the create statement and `aws:ResourceTag/Project` on the modify statement. The tag conditions were the right thing to do anyway; the checks noticing was a bonus.

`CKV_AWS_18`, S3 access logging, cleared by building the second bucket and wiring `aws_s3_bucket_logging` on the state bucket.

`CKV2_AWS_61`, S3 lifecycle configuration, cleared by adding the lifecycle rules to both buckets.

`CKV_AWS_158`, CloudWatch log group encrypted with a customer-managed key, cleared by creating the KMS key and its policy.

## Suppressed, each with a written justification

| Check | Resource | Justification |
|---|---|---|
| `CKV_AWS_356` | infrastructure policy | `ec2:Describe*` does not support resource-level permissions or the `aws:ResourceTag` condition key. AWS only accepts `*` for these actions. |
| `CKV_AWS_107` | infrastructure policy | `iam:PassRole` sits in its own statement, scoped by role name prefix and constrained by `iam:PassedToService`. Checkov does not evaluate conditions, so the finding persists despite the constraint being present. |
| `CKV_AWS_338` | flow log group | 14-day retention is a deliberate cost decision. One year is a compliance control, and there is no compliance requirement behind it in this account. |
| `CKV_AWS_144` | both buckets | Cross-region replication is a production DR control. It doubles storage cost for no recovery benefit in a single-region account whose state is reproducible from source. |
| `CKV_AWS_145` | both buckets | SSE-S3 is used deliberately, because a customer-managed key on the state bucket creates a bootstrap dependency loop. |
| `CKV2_AWS_62` | both buckets | No consumer exists for S3 event notifications. A notification target with nothing listening is configuration without purpose. |
| `CKV_AWS_18` | log bucket | This bucket is itself the access-log destination. Enabling access logging on it recurses. |

`CKV_AWS_18` appears in both lists, which is not a contradiction. It was fixed on the state bucket by building somewhere for the logs to go, and suppressed on the log bucket, because the fix does not apply to the destination of its own logs.

Every one of these lives in the source as a `checkov:skip` comment inside the resource block, in the form `# checkov:skip=CHECK_ID:reason`. The reason is in the code, next to the thing it explains, rather than in a document that drifts away from it.

## What 120 passed and 0 failed means

It does not mean there are no security issues in this configuration. Checkov cannot see everything, and a check passing means only that a pattern matched.

What it means is that every finding was read and answered. Four were genuine and got fixed. Ten were policies that do not apply to this account for reasons I can state, and each carries that reason in the source where a reviewer will find it.

A clean scan on code nobody examined is a weaker claim than a scan with ten documented suppressions, because the second one proves somebody read the output. If I had gone the other way and left findings failing without comment, the CI gate in Phase 4 would either have to ignore them, which makes the gate meaningless, or block every run, which makes it something people learn to skip.

## Running it

```
checkov -d terraform/ --compact --quiet
```

Free, offline, no credentials. It runs before `terraform plan`, because there is no reason to spend a round trip to AWS on a configuration that will not pass its own review.

For anything that needs parsing, use the JSON output rather than scraping the text:

```
checkov -d terraform/ --output json
```

I learned that the hard way, which is also in the mistakes document.
