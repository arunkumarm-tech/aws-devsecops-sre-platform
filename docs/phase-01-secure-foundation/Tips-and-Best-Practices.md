# Tips and practices worth keeping

These are the parts of Phase 1 that transfer. Most of them cost me time before they became habits.

## Reference names and tags, never IDs

I built and destroyed this stack many times. Every rebuild produced a new VPC ID, new subnet IDs, new ENI IDs, a new NAT gateway ID, and a new KMS key ID. The only identifier that stayed constant was the CloudWatch log group name, `/aws/vpc-flow-logs/devsecops-sre-dev`, because it is derived from variables rather than allocated by AWS.

Anything that hardcodes a resource ID is correct until the next rebuild. That includes runbooks, dashboards, alarm definitions, and the verification commands in this repository. The KMS verification command resolves the key through `alias/devsecops-sre-dev-flow-logs` for exactly this reason, and it survives teardowns that would break a copied key ID.

Tags do the same job for resources with no name. The IAM policy conditions on `aws:ResourceTag/Project` work across rebuilds precisely because they do not care what anything is called this time.

## Push the feedback loop into the offline category

`terraform fmt`, `terraform validate`, and `checkov` need no credentials, no network, and no account. They run in seconds and they catch formatting, syntax, type errors, broken references, and most security misconfiguration.

`terraform plan` needs credentials and a round trip. `terraform apply` needs money.

Every error I can catch in the first category is one I catch faster, more cheaply, and reproducibly on any machine. The order I settled into was `fmt`, `validate`, `checkov`, then `plan`, and by the time I was running `plan` most of what could be wrong already was not.

## Prove the thing works, not that it was created

`terraform apply` reports that AWS accepted the API calls. That is a weaker statement than most people read it as.

The flow log is the clearest case. If the encryption context ARN in the KMS key policy were wrong by a character, `apply` would succeed, the flow log resource would exist, the log group would exist, and no record would ever be delivered. Nothing in Terraform's output would suggest a problem.

`DeliverLogsStatus: SUCCESS` is what proves it. For every control worth having, there is usually a read-only API call that shows it working rather than merely existing, and running that call is the difference between documentation that asserts and documentation that demonstrates.

## Destroy at the end of every session

`make destroy` against `terraform/envs/dev`, every time, without deciding case by case whether it is worth it.

The NAT gateway is the one component here billed by the hour. Left up for a month by accident it is roughly $32, which is not ruinous and is entirely avoidable. The one gateway that did get properly measured lived eleven minutes, from 12:03:29 to 12:14:02, and cost about half a cent.

Making it a rule rather than a judgement removes the failure mode where you decide once that you will be back in an hour and then are not.

## When a tool offers structured output, use it

I tried to extract Checkov findings from its human-readable output with `grep -A 3` and `grep -B 8`. The fixed context windows spliced check IDs onto neighbouring resource blocks and I drew several confident, wrong conclusions before noticing.

`--output json` and a few lines of python3 gave me each finding with its own resource, file, and line range. The text format was never a contract and it was never meant to be parsed. Scraping it is choosing to make errors.

## Read the summary counts, not just the findings

Four Checkov suppressions sat outside their resource block, where they did nothing at all. The failure list looked plausible either way. The only thing that revealed the problem was `Skipped checks: 0`.

Counts tell you whether the tool did what you asked. Findings tell you what it found. They answer different questions, and I had been reading only the second one.

## An IAM condition constrains its statement, not one action

The most expensive mistake in Phase 1 was putting `iam:PassRole` in the same statement as `iam:CreateRole` and attaching an `iam:PassedToService` condition. The condition applied to all of them, and `CreateRole` cannot satisfy it, so `CreateRole` would have been denied every time.

Before adding a condition, check every action in the statement against that condition key's availability. If some actions cannot satisfy it, split the statement. And if you are constraining a create action, `aws:RequestTag` is the key; for modify and delete, `aws:ResourceTag`, because a create request has no resource to read tags from.

## Trust the tool that parses the file, not the window showing it

An unsaved editor buffer is invisible to every shell command. `grep` reads disk. `terraform fmt` reads disk. Checkov reads disk. Your editor shows you memory.

When they disagree, the file on disk is the one that matters, and the fastest way to find out which you are looking at is to run something that parses it. Silence from `terraform fmt -check` on a visibly misindented file means your changes are not saved.

The worse variant is a stale buffer held open across a command-line edit. Saving it overwrites the edit and reverts work already done, silently.

## Commit the provider lock file

`.terraform.lock.hcl` is in the repository. Without it, two machines can resolve different provider versions from the same constraint, and an error like `This object has no argument, nested block, or exported attribute named "region"` appears on one and not the other.

With it committed, that failure is at least the same failure everywhere, and the fix is a decision rather than a mystery.

## Data sources never appear in plan counts

I predicted a plan of 7 resources and got 6, then predicted 2 changes and got 1. Both times the difference was a data source. `aws_caller_identity`, `aws_region`, `aws_availability_zones`, and every `aws_iam_policy_document` block is read rather than created, so none of them are changes.

Counting blocks in a file is not counting resources in a plan.

## Silence is a result

Empty ingress and egress arrays mean the default security group has no rules, which is the control passing. A quiet `terraform fmt -check` means the formatting is right. A quiet CLI delete means the delete worked. A quiet `git status` means nothing tracked has changed. And `git check-ignore -v` returning nothing rules out three ignore files in one command.

I kept reading absence of output as a failure to produce output. It is usually the answer.

## Suppress with a reason, in the source

Ten Checkov findings are suppressed in this repository, each with a `checkov:skip` comment inside the resource block stating what the constraint is and why the check cannot see it.

The reason lives next to the code it explains, so it is in front of anyone reviewing that resource and it moves when the resource moves. A justification in a separate document drifts out of date within a month and nobody notices.
