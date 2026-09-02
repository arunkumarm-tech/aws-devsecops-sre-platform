# Phase 1 — Secure foundation

Phase 1 builds the parts of an AWS account that everything later depends on, and nothing else. A Terraform state backend that cannot be accidentally destroyed. A network where exposure has to be chosen rather than inherited. A way for CI to authenticate without any stored credential. All of it scanned, and every scanner finding either fixed or answered in writing.

Nothing runs in it. There is no compute, no application, no pipeline. That is the point of a foundation phase, and I would rather say so than dress up an empty VPC as a platform.

Everything here was built on a MacBook Air against a real AWS account in us-east-1, built and torn down repeatedly, and verified against the live API rather than against my own Terraform source. The account ID has been replaced with `123456789012` throughout. Resource IDs are left as captured, because they are ephemeral and long since destroyed.

## What it produces

| | |
|---|---|
| Terraform state | S3 bucket, versioned, SSE-S3, TLS-only, `prevent_destroy`, native S3 locking |
| Access logging | Second S3 bucket, hardened identically, 90-day expiry |
| Network | `10.0.0.0/16`, public and private subnets across two AZs, one NAT gateway |
| Hardening | Default security group emptied, default VPC deleted, no auto-assigned public IPs |
| Observability | VPC flow logs to CloudWatch, encrypted with a customer-managed KMS key |
| CI identity | GitHub OIDC provider and a deploy role, no stored credentials |
| Scanning | Checkov 3.3.16 across the whole Terraform tree |

**Final Checkov result: 120 passed, 0 failed, 10 skipped.**

Zero failures does not mean there are no security issues. It means every finding was read and answered. Four were fixed with real changes. Ten are suppressed with justifications written into the resource blocks themselves, most of them because Checkov pattern-matches source and cannot evaluate IAM condition blocks. The progression from the first run to the last is in [05-security-scanning.md](05-security-scanning.md), and the middle of that table is more interesting than the end of it.

## Environment

| Component | Version |
|---|---|
| Terraform | 1.14.5 |
| AWS CLI | 2.33.19 |
| Checkov | 3.3.16 |
| Region | us-east-1 |
| Machine | MacBook Air, Apple Silicon, macOS |

There are no passwords or access keys anywhere in this project. GitHub Actions authenticates through OIDC, so there is no credential to leak, rotate, or forget about.

## How to read this

The numbered files are the build, in the order it happened. Read them in order if you want the whole thing.

| File | What it covers |
|---|---|
| [01-remote-state-backend.md](01-remote-state-backend.md) | The state bucket and every control on it, native S3 locking versus DynamoDB, why SSE-S3 rather than a customer-managed key, the one place an account ID is hardcoded and why Terraform leaves no choice |
| [02-network-foundation.md](02-network-foundation.md) | Subnet maths with `cidrsubnet()`, the NAT gateway trade-off with real numbers, one route table per private subnet, the emptied default security group, deleting the default VPC |
| [03-flow-logs-and-encryption.md](03-flow-logs-and-encryption.md) | Flow log configuration, the scoped delivery role, the KMS key policy and its encryption context condition, the port scanning the logs actually caught, why `ACCEPT` is not a breach, and the alerting gap |
| [04-github-oidc-and-least-privilege.md](04-github-oidc-and-least-privilege.md) | The OIDC provider, `StringEquals` versus `StringLike` in the trust policy, permissions split by mutability, and the state-prefix boundary that stops CI destroying its own backend |
| [05-security-scanning.md](05-security-scanning.md) | What Checkov can and cannot see, the scan progression, what was fixed against what was suppressed, and what a clean result actually claims |

The rest can be read in any order.

| File | What it is |
|---|---|
| [Architecture.md](Architecture.md) | Diagram and component walkthrough |
| [Commands-Reference.md](Commands-Reference.md) | Every command, grouped by purpose, each with why rather than what. Also which commands are free and offline, which need credentials, and which cost money |
| [Troubleshooting.md](Troubleshooting.md) | Real error messages, the diagnosis path, and the fix |
| [Mistakes-We-Made.md](Mistakes-We-Made.md) | Seventeen things that went wrong, written as narrative. The most useful file here |
| [Tips-and-Best-Practices.md](Tips-and-Best-Practices.md) | The lessons that transfer to any project |
| [Phase-01-Summary.md](Phase-01-Summary.md) | What exists at the end, what was deferred and to which phase, and the cost profile |

If you only read one, read [Mistakes-We-Made.md](Mistakes-We-Made.md). The best story in it is an IAM condition that looked correct, validated cleanly, passed every offline check, and would have silently denied role creation the first time the Phase 4 pipeline ran.
