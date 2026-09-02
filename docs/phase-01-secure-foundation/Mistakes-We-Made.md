# Mistakes I made in Phase 1

Everything here actually happened. I have left in the parts that are embarrassing, because a document that only records the things that went well is not a record of building something, it is marketing.

Several of these cost me more time than the work they interrupted.

## 1. The PassRole condition that would have broken deployments silently

Checkov flagged `CKV_AWS_107` on `iam:PassRole` in the deploy policy. The check is right about the general danger: unconstrained `PassRole` lets whoever holds it hand any role to any service, which is a well-known privilege escalation path.

My first fix added an `iam:PassedToService` condition to the statement. Then two things happened.

The check did not clear. Checkov does not evaluate condition blocks at all, so the constraint was invisible to it. That was annoying and harmless.

The second thing was neither. The statement did not contain only `iam:PassRole`. It also contained `iam:CreateRole`, `iam:DeleteRole`, `iam:PutRolePolicy`, and the rest of the role lifecycle actions. An IAM condition applies to every action in the statement it sits in. `iam:CreateRole` has no `iam:PassedToService` key in its request context, so the condition can never evaluate true for it, so `CreateRole` would have been denied. Always.

Nothing about that failure is visible before deploy time. `terraform validate` passes. `terraform plan` passes. Checkov, having ignored the condition, said nothing about it. The first symptom would have been the Phase 4 pipeline failing to create the flow log role, in a CI job, with an `AccessDenied` on an action I had explicitly granted.

The fix was to split the statement in two. Role lifecycle actions in `FlowLogRoleManagement`, scoped by ARN prefix, no condition. `iam:PassRole` alone in `PassFlowLogRole`, same prefix, with the service condition. The condition now constrains only the action it applies to.

What I take from this: a condition is scoped to a statement, not to an action, and putting one action's constraint on five actions is a way of denying four of them. The fix looked correct, validated cleanly, and would have broken behaviour that only appears at runtime.

## 2. Checkov suppressions that did nothing

I wrote four `checkov:skip` comments immediately above `resource "aws_s3_bucket" "access_logs"`. Terraform was perfectly happy with them, because to Terraform they are comments. `terraform validate` passed. The Checkov run came back and I skimmed the failure list, which looked about right.

The summary line said `Skipped checks: 0`.

Checkov requires skip comments inside the resource block, not above it. Above the block they are attached to nothing. Moving all four inside took ten seconds; noticing was the hard part, because the failure list looked plausible either way and I had not been reading the summary.

Lesson: read the summary counts, not just the findings. The counts are how you tell whether the tool did what you asked. That single run moved from 116 passed, 10 failed, 0 skipped to 115 passed, 4 failed, 7 skipped without a byte of Terraform logic changing.

## 3. An unsaved editor buffer, twice

The first time cost me maybe twenty minutes. I edited a file, looked at it on screen, and it was clearly correct. Then `grep -c` for the string I had just added returned `0`. I spent several rounds convinced the file was corrupt or that I was grepping the wrong path. The file on disk did not contain my edit, because I had never saved the buffer.

The second time was worse, because it undid work rather than just failing to do it.

I had reverted a bad change with `sed`. A VS Code buffer had been open since before that revert, holding the pre-revert content. Saving that buffer wrote the old content back over the corrected file, silently, and reintroduced an orphaned code fragment that broke parsing.

The tell was `terraform fmt` printing nothing when it should have reformatted an obviously misindented file. Silence from `fmt` means no changes were needed. If the file on screen plainly needs reformatting and `fmt` says it does not, then the file `fmt` read is not the file I am looking at.

Three things came out of this. Unsaved buffers are invisible to every shell command, so the editor and the terminal can disagree indefinitely. When they disagree, trust the tool that parses the file over the window displaying it. And `grep` the file on disk before trusting any scan result, because a scanner reads disk too.

## 4. Provider attribute mismatch on `data.aws_region`

```
Error: Unsupported attribute
  on ../../modules/vpc/kms.tf line 30, in resource "aws_kms_key" "flow_logs":
  30:  Service = "logs.${data.aws_region.current.region}.amazonaws.com"
This object has no argument, nested block, or exported attribute named "region".
```

I had written `.region` because that is what current provider documentation shows. The `region` attribute was added to `data.aws_region` in a later provider version than the one pinned in `.terraform.lock.hcl`. The older attribute, `name`, works in both, so `data.aws_region.current.name` is what the module uses.

Code written against current documentation can be wrong against a pinned provider, and the error message tells you the attribute does not exist rather than that your provider is older than the docs you are reading. This is the argument for committing `.terraform.lock.hcl`: the failure is at least reproducible on every machine instead of appearing only on whichever one happened to resolve a different version.

## 5. KMS aliases are not accepted by GetKeyPolicy

```
An error occurred (InvalidArnException) when calling the GetKeyPolicy operation:
Key Aliases are not supported for this operation.
```

Most KMS operations take an alias wherever they take a key ID, which is why the habit of using aliases is a good one. `GetKeyPolicy` does not.

Rather than hardcode a key ID that changes on every rebuild, I resolve the alias at runtime:

```
KEY_ID=$(aws kms list-aliases \
  --query "Aliases[?AliasName=='alias/devsecops-sre-dev-flow-logs'].TargetKeyId" \
  --output text) && \
aws kms get-key-policy --key-id "$KEY_ID" --policy-name default \
  --query Policy --output text | python3 -m json.tool
```

"Use the alias" is a good rule with exceptions, and the exceptions announce themselves as an `InvalidArnException` rather than as anything helpful.

## 6. A malformed get-key-policy pipeline

```
Extra data: line 25 column 3 (char 713)
```

That is `python3 -m json.tool` complaining about content after the end of a JSON document. My first version of the command ran `--output text` on the whole `GetKeyPolicy` response, which prints the policy document followed by a trailing metadata field on its own line. The parser reached the closing brace, found more text, and stopped.

Adding `--query Policy` extracts just the policy document, which is the only part I wanted. The error message was accurate and I read it as "the policy is malformed" rather than "there is something after the policy".

## 7. terraform fmt reformatted hand-written files, twice

Once on `flow-logs.tf`, around `max_aggregation_interval = 60`. Once on `github-oidc.tf`, around `max_session_duration = 3600`. Both times I had lined up an assignment by eye and got the alignment wrong for the block it was in.

Making the same mistake twice is the argument for `terraform fmt -check` being a CI gate rather than a habit I intend to keep. `make check` runs it; Phase 4 will run it on every push.

## 8. Predicted the wrong resource count, twice, for the same reason

I expected a plan to show 7 resources and it showed 6. Later I expected 2 policy changes and got 1.

Both times the cause was the same. Data sources are read, not created. `data "aws_caller_identity"`, `data "aws_region"`, `data "aws_availability_zones"`, and every `data "aws_iam_policy_document"` block appear nowhere in a plan summary, because a plan summary counts changes to real infrastructure and reading a data source changes nothing.

Counting blocks in a file is not the same as counting resources in a plan, and I did it twice before it stuck.

## 9. Reading grep output that spliced unrelated lines together

Checkov's default output is formatted for humans. I tried to extract findings from it with `grep -A 3` and `grep -B 8`, and the fixed context windows repeatedly stitched a check ID onto the resource block below or above the one it belonged to. I reached several confident conclusions about which resource had which finding, and they were wrong.

The fix was to stop scraping:

```
checkov -d terraform/ --output json
```

and read the `failed_checks` key with python3, where each finding carries its own resource, file path, and line range as structured fields.

When a tool offers structured output and you scrape its human-readable output instead, you have chosen to make errors. The output format was never a contract; it just looked like one.

## 10. Silence means different things in different tools

This one is a pattern rather than a single incident, and I got caught by it more than once.

Empty `IpPermissions` and `IpPermissionsEgress` arrays from `describe-security-groups` mean the default security group has no rules, which is the control passing. A silent `terraform fmt -check` means every file is already correctly formatted. A silent CLI delete means the delete succeeded. A quiet `git status` means everything tracked is unchanged.

And `git check-ignore -v <path>` returning nothing at all is itself the answer. It rules out `.gitignore`, `.git/info/exclude`, and the global ignore file in one command, which is faster than reading three files and guessing.

Absence of output is a result. I kept treating it as a failure to produce one.

## 11. A leftover VPC that was never mine

After a successful `make destroy` I found a VPC still sitting in the console and assumed the teardown had failed. It was the AWS default VPC, on `172.31.0.0/16`, which had been in the account since it was created.

The tells were the address range, six unnamed subnets where mine were four and tagged, and a main route table with a default route straight to an internet gateway. I deleted it, which fixed the confusion and closed a real exposure at the same time. That story is in [02-network-foundation.md](02-network-foundation.md).

## 12. Deleted resources still visible in the console

After a destroy, the NAT gateway detail page still displayed the resource. `State: Deleted`, deletion timestamp 12:14:02 against a creation timestamp of 12:03:29.

Meanwhile the CLI check returned nothing, because it filtered on `Name=state,Values=available`.

Both were correct and they were answering different questions. The console shows deleted network resources for a period after deletion so you can still see what was there. The CLI filter asked for gateways in the `available` state, and there were none.

Billing stops at deletion, not at the point the console stops showing it. That gateway lived eleven minutes and cost roughly half a cent.

## 13. macOS pip installs land outside PATH

`pip3 install checkov` reported success. `checkov` was then not found.

On macOS, user-scope pip binaries go to `~/Library/Python/<version>/bin`, which is not on the default PATH. Adding that directory in `~/.zshrc` fixed it.

I deliberately did not move the binaries somewhere already on PATH. pip generates shim scripts with the interpreter path hardcoded on the first line, so moving them works until an upgrade rewrites them somewhere else. `pipx` is the better answer for future CLI tools, because it manages both the virtual environment and the PATH entry.

None of this affects the pipeline. CI installs Checkov fresh into a clean runner, so local layout is a local problem.

## 14. HCL pasted into the shell

```
parse error near '}'
```

I pasted a Terraform block into the terminal instead of into a file. Commands go in the shell, HCL goes in files, and bash tries to interpret whatever it is given.

## 15. git push failed with "Repository not found"

`git remote add` records a URL in `.git/config`. It does not create anything on GitHub, it does not check that the URL resolves, and it succeeds whether or not the repository exists. The repository has to be created on GitHub first.

## 16. A find command that hid the wrong directory

```
find . -type d -not -path './.git*'
```

I was excluding the `.git` directory from a listing and could not work out why `.github` had also vanished. The glob `./.git*` matches `./.github` too. Adding the trailing slash, `./.git/*`, or matching `./.git` exactly, fixes it.

The directory was there the whole time. The command was hiding it from me and reporting nothing unusual, which is the worst combination.

## 17. Heredoc redirection

`>` overwrites. `>>` appends. A single `>` at the start of a heredoc silently destroys whatever was in the target file, with no warning and no undo.

`EOF` is a marker word I choose, not a keyword. Any string works as long as the opening and closing markers match and the closing one sits alone at the start of a line.
