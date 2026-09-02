# Architecture

Phase 1 builds three things that barely touch each other: somewhere for Terraform state to live, a network, and a way for CI to authenticate. They are separate on purpose. The state backend has to exist before anything else can be applied, and the deploy role deliberately cannot reach the state backend's own state.

## Diagram

```mermaid
graph TB
    subgraph GH["GitHub"]
        REPO["arunkumarm-tech/aws-devsecops-sre-platform<br/>branch: main"]
        OIDC_ISSUER["token.actions.githubusercontent.com"]
    end

    subgraph AWS["AWS account 123456789012 &mdash; us-east-1"]

        subgraph BOOT["Bootstrap &mdash; applied once, never destroyed"]
            STATE["S3: devsecops-sre-tfstate-123456789012<br/>versioned, SSE-S3, TLS-only, prevent_destroy<br/>native S3 locking via use_lockfile"]
            LOGS_B["S3: devsecops-sre-tfstate-logs-123456789012<br/>access-log destination, 90-day expiry"]
            STATE -- "server access logs<br/>best-effort, delayed" --> LOGS_B
        end

        subgraph IAMMOD["IAM module"]
            PROV["OIDC identity provider"]
            ROLE["Role: devsecops-sre-dev-github-deploy<br/>StringEquals on aud and sub<br/>max session 3600s"]
            P1["tfstate_access<br/>scoped to envs/* only"]
            P2["infrastructure<br/>split by mutability"]
            PROV --> ROLE
            ROLE --> P1
            ROLE --> P2
        end

        subgraph VPCMOD["VPC module &mdash; 10.0.0.0/16"]
            IGW["Internet gateway"]

            subgraph AZA["us-east-1a"]
                PUBA["public 10.0.0.0/24<br/>map_public_ip_on_launch = false"]
                PRIA["private 10.0.10.0/24"]
                NAT["NAT gateway<br/>single_nat_gateway = true"]
            end

            subgraph AZB["us-east-1b"]
                PUBB["public 10.0.1.0/24"]
                PRIB["private 10.0.11.0/24"]
            end

            DSG["Default security group<br/>managed empty, zero rules"]
        end

        subgraph OBS["Flow logs"]
            LG["CloudWatch log group<br/>/aws/vpc-flow-logs/devsecops-sre-dev<br/>traffic_type ALL, 60s aggregation, 14-day retention"]
            KMS["Customer-managed KMS key<br/>rotation on, 7-day deletion window<br/>scoped by kms:EncryptionContext:aws:logs:arn"]
            FLROLE["Flow log delivery role<br/>logs actions scoped to one group"]
            LG -- "encrypted with" --> KMS
            FLROLE -- "writes to" --> LG
        end

        GAP["No alarms. No dashboards.<br/>Deferred to Phase 5."]
    end

    REPO -- "requests token" --> OIDC_ISSUER
    OIDC_ISSUER -- "sts:AssumeRoleWithWebIdentity<br/>no stored credentials" --> PROV
    P1 -- "reads and writes<br/>envs/dev/terraform.tfstate" --> STATE

    PUBA --> IGW
    PUBB --> IGW
    NAT --> IGW
    PRIA -- "own route table" --> NAT
    PRIB -- "own route table" --> NAT
    VPCMOD -- "all traffic, both directions" --> FLROLE
    LG -.-> GAP

    classDef gap fill:#fff3cd,stroke:#856404,color:#856404
    class GAP gap
```

## Walkthrough

**Bootstrap.** `terraform/bootstrap/` creates the state bucket and its access-log bucket, and it is the only configuration applied against its own local state before migrating to S3. It is applied once. `prevent_destroy = true` on the state bucket means Terraform refuses to plan its deletion, so an accidental `terraform destroy` in that directory fails rather than removing the foundation of everything else.

State locking is native to S3 through `use_lockfile = true`, which writes a `.tflock` object beside the state file using S3 conditional writes. There is no DynamoDB table.

**The environment.** `terraform/envs/dev/` calls both modules and holds the backend configuration. It is the only place with a `providers.tf`, and its provider block sets `default_tags` for `Project`, `Environment`, and `ManagedBy`, which is what makes the IAM policy's tag conditions work without any module having to think about them.

The modules themselves contain no `providers.tf` and no `backend.tf`. A module that declares its own provider configuration cannot be reused anywhere else, because provider configuration belongs to the root that calls it. That is a Terraform convention with teeth rather than a style preference.

**The network.** One `/16` split into `/24`s by `cidrsubnet()`, two availability zones, public and private in each. Public subnets share a route table pointing at the internet gateway. Each private subnet gets its own route table pointing at a NAT gateway, so flipping `single_nat_gateway` to `false` is a variable change rather than a restructuring.

The default security group is managed as a resource with no rules, so anything that lands on it by accident can reach nothing.

**Observability, such as it is.** VPC flow logs capture all traffic to a CloudWatch log group encrypted with a customer-managed KMS key. The key policy grants CloudWatch Logs only what it needs, and constrains it to one log group through the encryption context that CloudWatch passes on every call. The delivery role can write to that one log group and nowhere else.

Nothing reads any of it automatically. There are no metric filters, no alarms, and no dashboards. Phase 5.

**CI authentication.** The OIDC provider registers GitHub as a trusted token issuer. The deploy role's trust policy requires an exact match on both the audience and the subject, so only a push to `main` in the named repository can assume it. The role can write state under `envs/*` and cannot touch `bootstrap/terraform.tfstate`, which means a compromised pipeline cannot destroy the bucket holding its own state.

No workflow uses this yet. Phase 4.

## What is not here

There is no compute, no container platform, no application, and no data store. There is no CloudTrail, no GuardDuty, and no AWS Config. There are no alarms or dashboards. Nothing spans a second region.

Phase 1 was the network and the trust relationships, verified, and nothing beyond that.
