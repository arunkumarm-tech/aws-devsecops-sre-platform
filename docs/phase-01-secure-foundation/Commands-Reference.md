# Commands reference

Every command that mattered in Phase 1, grouped by what I was trying to find out. The *why* is the part worth reading. Most of these are obvious in what they do and non-obvious in when to reach for them.

## Three cost categories

Before the list, the distinction that shaped how I worked.

**Offline and free.** `terraform fmt`, `terraform validate`, `checkov`. No credentials, no network, no AWS calls, no charges. These answer "is this configuration coherent and sensible" and they answer it in seconds.

**Needs credentials, reads real state, still free.** `terraform plan`, and every `aws` CLI read. These answer "what does AWS currently think exists". They cost a round trip and nothing else.

**Costs money.** `terraform apply`. This is the only command in Phase 1 that creates a billable resource.

Most of a feedback loop should live in the first category. If I can catch something with `validate` and `checkov` before ever calling AWS, that is a loop measured in seconds rather than minutes, and the failure is reproducible on any machine with no account at all.

---

## Make targets

The `Makefile` at the repository root wraps the common operations against `terraform/envs/dev`, so I do not have to remember which directory to be in.

```
make fmt        # terraform fmt -recursive
make check      # terraform fmt -check -recursive
make validate   # cd terraform/envs/dev && terraform validate
make plan       # cd terraform/envs/dev && terraform plan
make apply      # cd terraform/envs/dev && terraform apply
make destroy    # cd terraform/envs/dev && terraform destroy
```

`make destroy` at the end of every session is the rule I held to. The NAT gateway is the only thing here costing real money by the hour, and leaving it up overnight by accident is the classic way to be surprised by a portfolio project.

`make check` is the CI-shaped version of `make fmt`. `fmt` rewrites files; `check` reports and exits non-zero without touching anything, which is what a gate needs.

---

## Terraform

```
terraform init
```
Downloads providers, initialises the backend, and writes `.terraform.lock.hcl`. Run it after changing a backend block, a module source, or a provider constraint.

```
terraform fmt -recursive
```
Canonical formatting. I ran it because I got the alignment wrong by hand twice, and the second time convinced me it belongs in CI rather than in my habits.

```
terraform fmt -check -recursive
```
Reports files that need formatting and changes nothing. Silence means everything is already correct. That silence is also a useful signal that the file on disk is not the file in your editor.

```
terraform validate
```
Syntax, type checking, and internal consistency of references. Offline. It will happily approve an insecure configuration, which is why Checkov exists.

```
terraform plan
```
The first command that needs credentials. It reads real state and real AWS resources and reports what would change. Data sources are read here, and they never appear in the change count.

```
terraform apply
```
The only command in Phase 1 that spends money.

```
terraform destroy
```
Run at the end of every session against `terraform/envs/dev`. Never against `terraform/bootstrap`, where `prevent_destroy = true` will refuse anyway.

---

## Checkov

```
checkov -d terraform/ --compact --quiet
```
Static analysis of the whole tree. Offline, no credentials. `--compact` drops the code blocks from the output, `--quiet` drops passed checks, which leaves the failures and the summary.

Read the summary line, not just the findings. Passed, failed, and skipped counts are how you tell whether your suppressions are actually registering.

```
checkov -d terraform/ --output json
```
Use this for anything that parses the results. Each finding carries its resource, file, and line range as structured fields. Scraping the human-readable output with `grep -A` and `grep -B` splices unrelated blocks together and produces confident wrong answers.

---

## Verifying what was actually built

`terraform apply` succeeding proves resources were created. It does not prove they work. These are the checks that close that gap.

```
aws ec2 describe-security-groups --filters Name=group-name,Values=default \
  --query 'SecurityGroups[].[IpPermissions,IpPermissionsEgress]'
```
Confirms the default security group has no rules. Two empty arrays is the control passing.

```
aws ec2 describe-flow-logs \
  --query 'FlowLogs[].[FlowLogStatus,DeliverLogsStatus,DeliverLogsErrorMessage]' \
  --output table
```
The most valuable check in Phase 1. `ACTIVE` means configured. `SUCCESS` in `DeliverLogsStatus` means records are landing, which is the only thing that proves the KMS key policy is correct. An encryption context ARN wrong by one character produces a flow log that exists and delivers nothing, and Terraform will not tell you.

```
aws logs describe-log-groups --log-group-name-prefix /aws/vpc-flow-logs \
  --query 'logGroups[].[logGroupName,kmsKeyId,retentionInDays]' --output table
```
Confirms the log group is encrypted with the customer-managed key and carries the retention I set. Returns the group name, a key ARN, and 14.

```
KEY_ID=$(aws kms list-aliases \
  --query "Aliases[?AliasName=='alias/devsecops-sre-dev-flow-logs'].TargetKeyId" \
  --output text) && \
aws kms get-key-policy --key-id "$KEY_ID" --policy-name default \
  --query Policy --output text | python3 -m json.tool
```
Reads the deployed key policy. Two details are load-bearing. Resolving through `list-aliases` means no hardcoded key ID, which matters because the key ID changes on every rebuild. And `--query Policy` extracts only the policy document, because `--output text` on the full response appends a metadata field that makes `json.tool` fail with `Extra data`.

`GetKeyPolicy` is one of the few KMS operations that will not accept an alias directly.

```
aws iam get-role --role-name devsecops-sre-dev-github-deploy \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
```
Reads the OIDC trust policy from the live API. Confirms `aud` and `sub` are both under `StringEquals` rather than `StringLike`. Reading the Terraform tells me what I wrote; reading the API tells me what AWS is enforcing.

---

## Default VPC removal

Deleted in dependency order in us-east-1. The order is not optional: an internet gateway cannot be deleted while attached, and a VPC cannot be deleted while it still has subnets.

```
aws ec2 detach-internet-gateway --internet-gateway-id igw-094a6fe5d7b9536a3 --vpc-id vpc-0abc5805df119faa8
aws ec2 delete-internet-gateway --internet-gateway-id igw-094a6fe5d7b9536a3

aws ec2 delete-subnet --subnet-id subnet-0256302a94d8d207e
aws ec2 delete-subnet --subnet-id subnet-0959afadba55e0702
aws ec2 delete-subnet --subnet-id subnet-0a73377c56e39b639
aws ec2 delete-subnet --subnet-id subnet-036aee2482c0b52f8
aws ec2 delete-subnet --subnet-id subnet-059e61a46bb664965
aws ec2 delete-subnet --subnet-id subnet-08a6a3d085e34b009

aws ec2 delete-vpc --vpc-id vpc-0abc5805df119faa8
```

Six subnets, one per availability zone in us-east-1. Every one of those commands printed nothing at all, which is the CLI reporting success.

The main route table, the default security group, and the default network ACL are deleted along with the VPC. There is no command for them, and attempting one fails, because they cannot exist independently of the VPC that owns them.

Confirming it is gone:

```
aws ec2 describe-vpcs --query 'Vpcs[].{Id:VpcId,CIDR:CidrBlock,Default:IsDefault}' --output table
```

Returned nothing. Not an empty table with headers, nothing at all, because there were no VPCs left in the region to describe. This was run after `make destroy` had already removed the project VPC, so an empty result is the correct one and it confirms both teardowns at once.

```
aws ec2 create-default-vpc
```
Recreates it, if it turns out you wanted it. That is what makes deleting it a reversible decision rather than a permanent one, and it is worth knowing before you delete it in an account somebody else uses.

---

## Diagnostics that saved time

```
git check-ignore -v path/to/file
```
Answers "why is git not tracking this" in one command. It reports the file, line number, and pattern that matched, across `.gitignore`, `.git/info/exclude`, and the global ignore file. Returning nothing at all is the answer: none of them match, so the reason is something else.

```
grep -n 'pattern' path/to/file.tf
```
Checks the file on disk rather than the file on screen. Worth doing before trusting any scanner result, because an unsaved editor buffer is invisible to every command.

```
find . -type d -not -path './.git/*'
```
Note the trailing slash. `'./.git*'` also matches `./.github`, which hides a directory you probably wanted to see.

```
pip3 install checkov
```
On macOS this installs to `~/Library/Python/<version>/bin`, which is not on the default PATH. Append it in `~/.zshrc`. Do not relocate the binaries, because pip shims hardcode the interpreter path.
