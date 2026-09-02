# GitHub OIDC and least privilege

There are no AWS access keys in this project. Not in the repository, not in GitHub secrets, not on my machine for CI purposes. GitHub Actions authenticates to AWS by exchanging a short-lived OIDC token for temporary credentials, and the IAM module in `terraform/modules/iam/` builds both halves of that.

Nothing uses it yet. The pipeline arrives in Phase 4. I built the trust relationship first because getting it wrong is the kind of mistake that is hard to notice and expensive to have made.

## The identity provider

```hcl
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}
```

Registering this tells AWS to trust tokens signed by GitHub's OIDC issuer. Without it no GitHub workflow can assume any role in the account, regardless of what the role's trust policy says.

The thumbprint is a fingerprint of the issuer's TLS certificate chain. AWS now verifies GitHub's certificates against its own trust store and effectively ignores the value, but the API still requires the field to be populated, so it stays. It used to be a genuine operational hazard: certificates rotate, and a stale thumbprint broke every pipeline in the account at the moment of rotation with an error that pointed nowhere useful. If an interviewer asks about thumbprint rotation, that history is the answer, along with the fact that it no longer matters in practice.

## The trust policy, and the single most important word in it

```hcl
condition {
  test     = "StringEquals"
  variable = "token.actions.githubusercontent.com:aud"
  values   = ["sts.amazonaws.com"]
}

condition {
  test     = "StringEquals"
  variable = "token.actions.githubusercontent.com:sub"
  values   = ["repo:arunkumarm-tech/aws-devsecops-sre-platform:ref:refs/heads/main"]
}
```

The `aud` check confirms the token was minted for AWS STS rather than for some other service that also trusts GitHub tokens. A token issued for a different audience is not usable here.

The `sub` check is the control that actually matters. GitHub puts the repository, and what triggered the run, into the subject claim. A push to `main` in my repository produces exactly the string above. A pull request produces `repo:owner/repo:pull_request`. A tag produces `ref:refs/tags/...`. A different branch produces a different ref.

Both conditions are `StringEquals`. Not `StringLike`.

That distinction is the entire security of this arrangement. A wildcard in the `sub` condition is a documented privilege escalation path. Write `repo:arunkumarm-tech/*` and anybody who forks the repository can open a pull request whose workflow assumes the role, because a fork's pull request produces a subject that matches the pattern. The attacker controls the workflow file in their fork. They get my role. `StringEquals` on a full subject string cannot be satisfied by anything except a push to `main` in the exact repository.

The other failure mode is worse and more common: a trust policy with the `aud` condition and no `sub` condition at all. That trusts every GitHub Actions workflow on GitHub.

I verified this against the live API rather than trusting my own source:

```
aws iam get-role --role-name devsecops-sre-dev-github-deploy \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
```

Both conditions came back under `StringEquals`. Reading the Terraform tells me what I wrote. Reading the API tells me what AWS is enforcing, and those are only the same thing if the apply actually went through.

The role's `max_session_duration` is 3600 seconds. Long enough for a Terraform apply, short enough that a leaked credential expires within the hour.

## State access, and a real blast-radius boundary

Two statements:

```hcl
statement {
  sid       = "ListStateBucket"
  actions   = ["s3:ListBucket"]
  resources = ["arn:aws:s3:::devsecops-sre-tfstate-123456789012"]
}

statement {
  sid     = "ReadWriteStateObjects"
  actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
  resources = ["arn:aws:s3:::devsecops-sre-tfstate-123456789012/envs/*"]
}
```

`ListBucket` is a bucket-level action, so its resource is the bucket ARN with no key suffix. The object actions are scoped to the `envs/*` prefix.

The consequence is that the deploy role cannot read, write, or delete `bootstrap/terraform.tfstate`. Bootstrap state is what manages the state bucket itself, the log bucket, and their policies. CI can manage the dev environment and cannot manage the thing that holds CI's own state.

That is not a theoretical boundary. A compromised workflow, or a mistake in a Terraform configuration that CI runs, cannot destroy the bucket it needs to function. Recovery from a wrecked dev environment is `terraform apply`. Recovery from a deleted state bucket is manual reconstruction of every resource by hand.

## Permissions split by mutability

The `infrastructure` policy has five statements, grouped by what kind of thing the action does rather than by which service it belongs to.

**`NetworkingRead`.** `ec2:Describe*` and `ec2:Get*`, `Resource = "*"`, no condition.

This looks lazy and it is not. EC2 describe actions do not support resource-level permissions, and they do not support the `aws:ResourceTag` condition key. AWS only accepts `*` for them. If you write an ARN there, the policy is accepted and the action is denied, which is a confusing way to discover the limitation. This is the source of the `CKV_AWS_356` suppression.

**`NetworkingCreate`.** Explicit create actions: `CreateVpc`, `CreateSubnet`, `CreateRouteTable`, `CreateInternetGateway`, `CreateNatGateway`, `CreateSecurityGroup`, `CreateFlowLogs`, `CreateTags`, `AllocateAddress`. Conditioned on `aws:RequestTag/Project`.

`aws:RequestTag` is evaluated against the tags supplied in the API call itself. A create request that does not carry `Project = devsecops-sre` is denied. The provider block in `envs/dev` sets that tag through `default_tags`, so every resource Terraform creates carries it without the module having to.

**`NetworkingModify`.** Explicit modify and delete actions, conditioned on `aws:ResourceTag/Project`.

`aws:ResourceTag` is evaluated against the tags already on the target resource. So this role can only change or delete things that carry the project tag, which in practice means things it created. Somebody else's VPC in the same account is untouchable.

The split exists because the two condition keys answer different questions and neither one works for both cases. A create action has no resource to read tags from. A delete action has no request tags to check.

**`FlowLogDestination`.** CloudWatch Logs actions scoped to `arn:aws:logs:us-east-1:123456789012:log-group:/aws/vpc-flow-logs/*`.

**`FlowLogRoleManagement` and `PassFlowLogRole`.** Two statements, and the reason they are two is the best story in Phase 1. Role lifecycle actions in one, scoped by ARN prefix `role/devsecops-sre-dev-*`. `iam:PassRole` alone in the other, scoped by the same prefix and conditioned on `iam:PassedToService = vpc-flow-logs.amazonaws.com`.

Why `PassRole` needs constraining: creating a flow log means handing an existing IAM role to the flow logs service. `iam:PassRole` is the permission to do that handing. Unconstrained, it lets the holder give any role they can name to any service, which includes giving an administrator role to a service they control. It is one of the classic privilege escalation paths in AWS.

Why the two statements are separate is in [Mistakes-We-Made.md](Mistakes-We-Made.md). The short version is that my first attempt put them together, the condition then applied to `iam:CreateRole` as well, `CreateRole` cannot satisfy a `PassedToService` condition, and role creation would have been silently denied the first time CI ran in Phase 4. Everything validated. Nothing would have worked.

## Where this is still not least privilege

`NetworkingRead` is broad and AWS gives me no way to narrow it. That is a real limitation rather than a choice.

The create and modify statements list explicit actions rather than `ec2:*`, which is the meaningful part, but they still cover more of EC2 than this project strictly needs. Tightening further would mean editing the policy every time a module adds a resource type, and I would rather have a boundary that holds than one that is precisely fitted and always slightly out of date.

There is no permissions boundary on the deploy role, and no SCP above it. Both are the correct next layer, and neither exists yet.
