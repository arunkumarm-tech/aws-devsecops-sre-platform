# aws-devsecops-sre-platform

A six-phase AWS DevSecOps and SRE build, done in a real account, torn down at the end of every session, and documented including the parts that went wrong.

Phase 1 is complete. Phases 2 through 6 have not been started, and nothing in this repository pretends otherwise.

I am Arun Kumar M. This exists to show what I can actually build and why I made each choice, rather than to list technologies I have read about.

## What Phase 1 built

A Terraform state backend in S3 that cannot be accidentally destroyed. A `10.0.0.0/16` VPC across two availability zones where nothing is internet-facing unless somebody decides it should be. VPC flow logs encrypted with a customer-managed KMS key scoped to a single log group. A GitHub Actions deploy role that authenticates by OIDC, with no stored AWS credentials anywhere in the project.

Checkov reports **120 passed, 0 failed, 10 skipped**. The zero is less interesting than the ten. Four findings were fixed with real code changes and ten are suppressed with written justifications inside the resource blocks, mostly because Checkov cannot evaluate IAM condition blocks and so cannot see the constraint that makes a broad-looking statement safe.

Nothing runs in any of it yet. No compute, no application, no pipeline. That is what a foundation phase is.

**→ [Phase 1 documentation](docs/phase-01-secure-foundation/README.md)**

If you have ninety seconds, read [Mistakes-We-Made.md](docs/phase-01-secure-foundation/Mistakes-We-Made.md). It has the IAM condition that validated cleanly, passed every offline check, and would have silently denied role creation on the first CI run.

## Architecture at a glance

```
GitHub push to main
   └── OIDC token, StringEquals on aud and sub, no stored credentials
         └── devsecops-sre-dev-github-deploy
               ├── S3 state, scoped to envs/* only (cannot touch bootstrap state)
               └── EC2 and Logs, split by mutability with tag conditions

AWS account 123456789012, us-east-1

  Bootstrap (applied once, never destroyed)
    devsecops-sre-tfstate-123456789012        versioned, SSE-S3, TLS-only,
                                              prevent_destroy, S3 native locking
    devsecops-sre-tfstate-logs-123456789012   access logs, 90-day expiry

  VPC 10.0.0.0/16
    public   10.0.0.0/24, 10.0.1.0/24    → internet gateway, no auto public IPs
    private  10.0.10.0/24, 10.0.11.0/24  → one route table each → NAT gateway
    default security group managed empty, zero rules
    default VPC (172.31.0.0/16) deleted

  Flow logs, all traffic, 60s aggregation, 14-day retention
    → CloudWatch /aws/vpc-flow-logs/devsecops-sre-dev
    → encrypted with a customer-managed KMS key, scoped by encryption context
    → no alarms, no dashboards (Phase 5)
```

A Mermaid version with more detail is in [Architecture.md](docs/phase-01-secure-foundation/Architecture.md).

## The six phases

| Phase | Status | |
|---|---|---|
| 1. Secure AWS foundation | **Complete** | State backend, VPC, flow logs and KMS, GitHub OIDC, Checkov |
| 2. Secure container supply chain | Not started | Image build, scanning, and provenance |
| 3. EKS platform | Not started | The subnets already carry `kubernetes.io/role/elb` and `kubernetes.io/role/internal-elb` tags in anticipation of this. |
| 4. Secure CI/CD | Not started | The GitHub Actions workflows that will use the OIDC role built in Phase 1. `terraform fmt -check` becomes a gate here. |
| 5. Observability and SRE | Not started | Alarms, dashboards, and CloudWatch Logs Insights. Phase 1 collects flow logs and nothing alerts on them; this is where that gap closes. |
| 6. Reliability and incident response | Not started | |

Phases 2 through 6 have no directories in this repository. Empty committed folders make a project look abandoned rather than planned.

## Tools and versions

| Component | Version |
|---|---|
| Terraform | 1.14.5 |
| AWS CLI | 2.33.19 |
| Checkov | 3.3.16 |
| Region | us-east-1 |
| Built on | MacBook Air, Apple Silicon, macOS |

## Repository layout

```
terraform/
├── bootstrap/          S3 remote state backend. Applied once, never destroyed.
├── modules/
│   ├── vpc/            Networking, flow logs, KMS key
│   └── iam/            GitHub OIDC provider, deploy role, scoped policies
└── envs/
    └── dev/            Calls both modules, holds the backend configuration

docs/phase-01-secure-foundation/    The Phase 1 write-up
Makefile                            fmt, check, validate, plan, apply, destroy
```

The modules contain no `providers.tf` and no `backend.tf`. A module inherits provider configuration from whatever calls it, and declaring it inside the module makes the module unusable anywhere else.

## Running it

Requires Terraform, the AWS CLI configured with credentials, and Checkov.

```
git clone https://github.com/arunkumarm-tech/aws-devsecops-sre-platform.git
cd aws-devsecops-sre-platform
```

The bootstrap directory creates the state bucket and is applied once. It writes bucket names containing your own account ID, which is read from `data "aws_caller_identity"` rather than hardcoded. The one place you will need to edit is the `bucket` value in `terraform/bootstrap/backend.tf` and `terraform/envs/dev/backend.tf`, because Terraform backend blocks cannot use variables or interpolation of any kind.

```
cd terraform/bootstrap
terraform init
terraform apply
```

Then the dev environment:

```
cd ../..
make fmt        # canonical formatting
make check      # formatting check, changes nothing, exits non-zero on drift
make validate   # syntax and reference checking, offline
checkov -d terraform/ --compact --quiet
make plan       # first command that needs credentials
make apply      # the only command that costs money
make destroy    # run this at the end of every session
```

The first four cost nothing and need no AWS account. Keeping the feedback loop in that category is most of why Phase 1 went as fast as it did.

## Cost

**$1 a month standing**, which is the customer-managed KMS key. It is the only thing that bills while everything else is destroyed. I decided a key policy with a real encryption context condition was worth a dollar a month to have written and verified.

**About $32 a month while the dev environment is up**, dominated by a single NAT gateway. One gateway per availability zone would be about $64 and would remove the single point of failure for outbound traffic. The module takes a `single_nat_gateway` boolean rather than picking one, and defaults to the cheap side because this is a learning account.

**`make destroy` at the end of every session** is the rule that keeps that number theoretical. The one NAT gateway I measured properly lived from 12:03:29 to 12:14:02, eleven minutes, and cost roughly half a cent.

## A note on redaction

The AWS account ID has been replaced with `123456789012` everywhere it appears. Resource IDs (VPC, ENI, KMS key, NAT gateway) are left as they were captured, because they were destroyed long ago and they make the command output what it is, which is real.

There are no passwords or access keys in this repository. That is a design decision rather than good housekeeping: GitHub Actions authenticates through OIDC, so there is no credential to store in the first place.
