# Troubleshooting

Errors I hit in Phase 1, in a form you can search by the message. The narrative version of most of these, with what I was thinking at the time, is in [Mistakes-We-Made.md](Mistakes-We-Made.md).

---

## `Unsupported attribute` on `data.aws_region.current.region`

```
Error: Unsupported attribute
  on ../../modules/vpc/kms.tf line 30, in resource "aws_kms_key" "flow_logs":
  30:  Service = "logs.${data.aws_region.current.region}.amazonaws.com"
This object has no argument, nested block, or exported attribute named "region".
```

**What it means.** The pinned AWS provider is older than the documentation the code was written against. `data.aws_region` gained a `region` attribute in a later provider release.

**Diagnosis.** Check the resolved provider version in `.terraform.lock.hcl` against the attribute's availability in the provider changelog. The error appears at plan time, before any AWS call.

**Fix.** Use `data.aws_region.current.name`, which exists in both. Alternatively raise the version constraint in `versions.tf` and run `terraform init -upgrade`, which is the right call only if something else needs the newer provider.

---

## `InvalidArnException` from `kms get-key-policy`

```
An error occurred (InvalidArnException) when calling the GetKeyPolicy operation:
Key Aliases are not supported for this operation.
```

**What it means.** `GetKeyPolicy` will not accept `alias/...` in `--key-id`, unlike most KMS operations.

**Fix.** Resolve the alias to a key ID first.

```
KEY_ID=$(aws kms list-aliases \
  --query "Aliases[?AliasName=='alias/devsecops-sre-dev-flow-logs'].TargetKeyId" \
  --output text)
aws kms get-key-policy --key-id "$KEY_ID" --policy-name default --query Policy --output text
```

---

## `Extra data: line 25 column 3 (char 713)` from `json.tool`

**What it means.** Something followed the closing brace of the JSON document. The document itself parsed fine up to that point.

**Diagnosis.** `aws kms get-key-policy ... --output text` prints the policy document and then a trailing metadata field on its own line. Piping the whole response into a JSON parser gives it two things to parse.

**Fix.** Extract only the policy with `--query Policy`.

```
aws kms get-key-policy --key-id "$KEY_ID" --policy-name default \
  --query Policy --output text | python3 -m json.tool
```

---

## Checkov reports `Skipped checks: 0` when suppressions are present

**What it means.** The `checkov:skip` comments are not where Checkov looks for them.

**Diagnosis.** Skip comments must be **inside** the resource block. Above the block, Terraform treats them as ordinary comments and Checkov attaches them to nothing. The failure list looks plausible in both cases, so the summary counts are the only reliable signal.

**Fix.**

```hcl
resource "aws_s3_bucket" "access_logs" {
  # checkov:skip=CKV_AWS_18:This bucket is itself the access-log destination.
  bucket = "..."
}
```

---

## A Checkov finding will not clear even though the code is constrained

**What it means.** Checkov does not evaluate IAM condition blocks. `CKV_AWS_107` on `iam:PassRole` and `CKV_AWS_356` on `Resource = "*"` both persist regardless of any condition you attach.

**Fix.** There is no code change that clears it. Suppress it with a written justification stating what the constraint is and why the check cannot see it. Before suppressing, confirm the constraint applies only to the actions it should, because a condition constrains every action in its statement.

---

## `AccessDenied` on an action that is explicitly granted

**What it means.** In almost every case, a condition in the granting statement cannot be satisfied by that action.

**Diagnosis.** Read the statement the action lives in and check every condition key against that action's request context. `iam:PassedToService` exists only in a `PassRole` request. `aws:RequestTag` exists only in a create request. `aws:ResourceTag` requires a resource that already carries the tag.

**Fix.** Split the statement so each condition sits with the actions it applies to.

This one did not fail in Phase 1 because nothing ran the pipeline yet. It would have failed on the first CI run in Phase 4. The full account is item 1 in [Mistakes-We-Made.md](Mistakes-We-Made.md).

---

## A file edit is visible in the editor but not to any command

**Symptoms.** `grep -c` returns 0 for a string plainly on screen. `terraform fmt` prints nothing for a file that is visibly misindented. A scanner reports a finding you have already fixed.

**Diagnosis.** The buffer has not been saved, so the shell and the editor are looking at different content.

**Fix.** Save, then verify against disk rather than against the window:

```
grep -n 'the string you added' path/to/file.tf
terraform fmt -check
```

Silence from `fmt -check` means the file on disk needs no reformatting, which for an obviously misindented file means your changes are not on disk.

**Related trap.** A stale buffer held open across a `sed` edit will overwrite that edit the next time it is saved, silently reverting work already done.

---

## `terraform apply` succeeds but flow logs deliver nothing

**What it means.** The resource exists and the delivery path does not work. Most likely the KMS key policy does not permit CloudWatch Logs to use the key, usually because the encryption context ARN or the regional service principal is wrong.

**Diagnosis.**

```
aws ec2 describe-flow-logs \
  --query 'FlowLogs[].[FlowLogStatus,DeliverLogsStatus,DeliverLogsErrorMessage]' \
  --output table
```

`FlowLogStatus: ACTIVE` alone proves nothing. `DeliverLogsStatus` must read `SUCCESS`, and `DeliverLogsErrorMessage` must be `None`.

**Fix.** Check that the service principal is regional (`logs.us-east-1.amazonaws.com`, not `logs.amazonaws.com`) and that the encryption context ARN in the key policy matches the log group ARN exactly.

---

## `kms_key_id` on a CloudWatch log group rejects the key ID

**What it means.** The attribute takes the key **ARN** despite being named `kms_key_id`.

**Fix.** Pass `aws_kms_key.flow_logs.arn`, not `.key_id` or `.id`.

---

## A KMS key will not delete immediately

**What it means.** This is not an error. Scheduling deletion starts a mandatory pending window of 7 to 30 days.

**Why.** Deleting a key permanently destroys the ability to decrypt anything encrypted under it, and the operation cannot be undone. The window is AWS refusing to let you do that in one keystroke. Seven days is the minimum, and it is what this key is configured with.

---

## A VPC is still in the console after a successful destroy

**Diagnosis.** Check the CIDR block. `172.31.0.0/16` with six unnamed subnets and a main route table routing to an internet gateway is the AWS default VPC, which was there before you and is unrelated to your Terraform.

**Fix.** Nothing is broken. If you want it gone, delete it in dependency order: detach and delete the internet gateway, delete the subnets, delete the VPC. Reversible with `aws ec2 create-default-vpc`.

---

## A deleted NAT gateway still appears in the console

**Diagnosis.** Look at the state field. `State: Deleted` with a deletion timestamp means it is gone; the console keeps deleted network resources visible for a period.

A CLI check filtered on `Name=state,Values=available` returning empty is consistent with this, not contradictory. The two are answering different questions.

Billing stops at the deletion timestamp.

---

## Plan shows fewer resources than expected

**Diagnosis.** Data sources are read, not created, and never appear in plan counts. `aws_caller_identity`, `aws_region`, `aws_availability_zones`, and every `aws_iam_policy_document` are invisible in a plan summary.

---

## `checkov: command not found` after a successful install on macOS

**Diagnosis.** User-scope pip binaries install to `~/Library/Python/<version>/bin`, which is not on the default PATH.

**Fix.** Append that directory to PATH in `~/.zshrc`. Do not move the binaries; pip shims hardcode the interpreter path. `pipx` avoids the problem entirely for future CLI tools.

---

## `parse error near '}'` in the shell

**Diagnosis.** HCL was pasted into the terminal. Bash is trying to interpret it.

---

## `git push` fails with "Repository not found"

**Diagnosis.** `git remote add` only writes a URL into `.git/config`. It does not create the repository, and it does not validate that the URL resolves.

**Fix.** Create the repository on GitHub, then push.

---

## `find` excludes a directory you wanted to keep

**Diagnosis.** `-not -path './.git*'` also matches `./.github`, because the glob has no boundary after `.git`.

**Fix.** Use `./.git/*` or match `./.git` exactly.

---

## A file was overwritten by a heredoc

**Diagnosis.** `>` truncates the target before writing. There is no confirmation and no undo.

**Fix.** Use `>>` to append. Check whether the file exists before redirecting into it. Recovery, if the file was committed, is `git checkout -- <path>`; if it was not, there is no recovery.
