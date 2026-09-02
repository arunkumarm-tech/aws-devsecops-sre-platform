# Flow logs and encryption

Flow logs record metadata about traffic in and out of network interfaces in the VPC. Not payloads. Source and destination address, ports, protocol, packet and byte counts, a time window, and whether security groups and NACLs permitted the traffic. They are the only visibility Phase 1 has into what is happening on the network.

## Configuration

```hcl
resource "aws_flow_log" "this" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  iam_role_arn             = aws_iam_role.flow_logs.arn
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  log_destination_type     = "cloud-watch-logs"
  max_aggregation_interval = 60
}
```

`traffic_type = "ALL"` captures accepted and rejected traffic. Capturing only rejects is cheaper and is a common default, and it hides the thing you usually want to know, which is what did get through.

`max_aggregation_interval = 60` is the shorter of the two permitted values, the other being 600. AWS aggregates records over the interval before publishing, so 60 seconds means a record shows up about a minute after the traffic rather than ten. In an incident that difference is the gap between watching something happen and reading about it afterwards.

Retention is 14 days, set through `var.flow_log_retention_days`. CloudWatch charges for ingestion and for storage, and the default is to keep logs forever. Fourteen days covers the window in which I would actually investigate something in a portfolio account. That number is a suppressed Checkov finding, and the justification is written into the source.

The log group is at `/aws/vpc-flow-logs/devsecops-sre-dev`, derived from the module's `name_prefix`.

## The delivery role, scoped to one log group

Flow logs are delivered by an AWS service, not by me, so the service needs a role to assume. The trust policy allows `vpc-flow-logs.amazonaws.com` and nothing else. The permission policy is the part worth looking at:

```hcl
statement {
  effect = "Allow"

  actions = [
    "logs:CreateLogStream",
    "logs:PutLogEvents",
    "logs:DescribeLogStreams",
  ]

  resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
}
```

Most examples of this role write `Resource = "*"`, which grants the ability to write into every log group in the account. Scoping it to the flow log group ARN with a `:*` suffix, which covers the log streams inside the group, means a compromised flow log role can write noise into one log group and nowhere else.

## The KMS key, and the condition that makes it worth having

CloudWatch Logs encrypts with an AWS-owned key by default and you cannot see or control that key. I created a customer-managed key for the flow log group instead. It costs $1 a month, which is the only standing charge in Phase 1 when nothing is deployed. I paid it because the key policy is the artefact I wanted to have written.

Rotation is enabled, and the deletion window is 7 days.

The policy has two statements.

```json
{
  "Sid": "AllowAccountAdministration",
  "Effect": "Allow",
  "Principal": { "AWS": "arn:aws:iam::123456789012:root" },
  "Action": "kms:*",
  "Resource": "*"
}
```

This one exists so the key remains manageable. KMS key policies are not like other resource policies: an identity policy granting `kms:*` does nothing unless the key policy also allows it. Create a key without a statement granting administration to the account, and you have created a key that nobody, including the account owner, can ever modify, disable, or delete. AWS support cannot fix it either. The key sits there until the account is closed.

```json
{
  "Sid": "AllowCloudWatchLogsEncryption",
  "Effect": "Allow",
  "Principal": { "Service": "logs.us-east-1.amazonaws.com" },
  "Action": [
    "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
    "kms:GenerateDataKey*", "kms:Describe*"
  ],
  "Resource": "*",
  "Condition": {
    "ArnEquals": {
      "kms:EncryptionContext:aws:logs:arn":
        "arn:aws:logs:us-east-1:123456789012:log-group:/aws/vpc-flow-logs/devsecops-sre-dev"
    }
  }
}
```

The condition is the interesting part. CloudWatch Logs passes the log group ARN as encryption context on every call it makes to KMS. Encryption context is additional authenticated data: it is bound into the ciphertext, and a decrypt call must supply the same context or it fails. Because the value arrives on every request, it can be matched in a key policy condition.

Without that condition, the statement grants every log group in the account permission to use the key. With it, exactly one log group can, and the constraint is enforced by KMS rather than by convention. That is the answer to "how do you scope a KMS key to a single consumer", and it is a question a lot of people have not had to answer.

The service principal is regional. `logs.us-east-1.amazonaws.com`, not `logs.amazonaws.com`. In the module it is built from `data.aws_region.current.name`, which is what broke in the way described in the troubleshooting notes.

Two operational details I had to learn:

`kms_key_id` on `aws_cloudwatch_log_group` takes the key **ARN**, not the key ID, in spite of the attribute name. Passing the ID produces an error at apply time rather than at plan time, because Terraform has no way to know which format the API wants.

Deleting a KMS key is not immediate. Scheduling deletion starts a pending window of between 7 and 30 days, and 7 is the minimum. AWS enforces this because deletion is irreversible, and destroying a key destroys the ability to read everything encrypted under it. Seven days is the shortest window I can have in exchange for the shortest tail of cost after a teardown.

## Proving it works

`terraform apply` succeeding proves resources were created. It does not prove they function. If the encryption context ARN in that condition were wrong by one character, the flow log resource would exist, the log group would exist, and no log would ever be delivered, because CloudWatch Logs would be denied the key it needs. Nothing in the Terraform output would tell me.

```
aws ec2 describe-flow-logs \
  --query 'FlowLogs[].[FlowLogStatus,DeliverLogsStatus,DeliverLogsErrorMessage]' \
  --output table
```

```
-------------------------------
|      DescribeFlowLogs       |
+--------+-----------+--------+
|  ACTIVE|  SUCCESS  |  None  |
+--------+-----------+--------+
```

`ACTIVE` means the flow log resource is configured. `SUCCESS` in `DeliverLogsStatus` means records are actually landing, which is what proves the key policy is correct. `None` in the error field means there is nothing being suppressed.

The log group's own encryption was confirmed separately:

```
aws logs describe-log-groups --log-group-name-prefix /aws/vpc-flow-logs \
  --query 'logGroups[].[logGroupName,kmsKeyId,retentionInDays]' --output table
```

which returned the log group name, a KMS key ARN, and 14.

## Reading the records

Flow log records are positional. There are no field names in the line:

```
version | account-id | interface-id | srcaddr | dstaddr | srcport | dstport |
protocol | packets | bytes | start | end | action | log-status
```

Protocol is a number, not a name. 6 is TCP, 17 is UDP, 1 is ICMP, 47 is GRE. `log-status` should read `OK`; `SKIPDATA` means AWS dropped records for that window, and any analysis over that window is incomplete.

Because the format is positional, the CloudWatch console cannot highlight or filter on a field. The filter bar does substring matching, which is enough to find an address and useless for a question like "show me every rejected connection to a port under 1024". Real field queries need CloudWatch Logs Insights, which arrives in Phase 5.

## What the logs actually caught

Within roughly fifteen minutes of the NAT gateway being created, the flow logs had captured inbound traffic from five or more distinct source addresses. Every one of them was a single TCP SYN packet of 40 to 60 bytes, aimed at a random high port on the NAT gateway's interface.

That is internet-wide port scanning. Newly allocated public IPv4 addresses get probed almost immediately, because the entire IPv4 space is small enough to sweep continuously and scanners do exactly that. Nothing about it was targeted at me.

Three records stood out. One connection attempt to port 23, which is Telnet, and which is the signature of Mirai and its many descendants looking for devices with default credentials. One UDP record, protocol 17. And one GRE record, protocol 47, with source and destination ports of 0 and a 564-byte payload. GRE has no concept of ports, so zero is the correct value rather than a missing one.

Five of the records, exactly as captured:

```
2 123456789012 eni-098c6aa80eb51c62e 162.216.149.10 10.0.0.219 50001 64963 6 1 44 1788302358 1788302359 ACCEPT OK
2 123456789012 eni-098c6aa80eb51c62e 147.185.132.244 10.0.0.219 50412 30007 6 1 44 1788302375 1788302375 ACCEPT OK
2 123456789012 eni-098c6aa80eb51c62e 45.79.145.233 10.0.0.219 40970 10134 6 1 52 1788302380 1788302381 ACCEPT OK
2 123456789012 eni-098c6aa80eb51c62e 85.217.140.53 10.0.0.219 58578 22014 6 1 52 1788302387 1788302387 ACCEPT OK
2 123456789012 eni-098c6aa80eb51c62e 162.216.150.123 10.0.0.219 52005 30695 6 1 44 1788302396 1788302396 ACCEPT OK
```

Taking the first one field by field against the positional format above:

| Position | Field | Value | What it tells me |
|---|---|---|---|
| 1 | `version` | `2` | Default flow log format |
| 2 | `account-id` | `123456789012` | Redacted here; the real ID in the capture |
| 3 | `interface-id` | `eni-098c6aa80eb51c62e` | The NAT gateway's network interface |
| 4 | `srcaddr` | `162.216.149.10` | Where it came from |
| 5 | `dstaddr` | `10.0.0.219` | The NAT gateway's own address inside the VPC |
| 6 | `srcport` | `50001` | An ephemeral source port |
| 7 | `dstport` | `64963` | A random high port, not a service anyone runs |
| 8 | `protocol` | `6` | TCP |
| 9 | `packets` | `1` | One packet |
| 10 | `bytes` | `44` | Small enough to be a header and nothing else |
| 11 | `start` | `1788302358` | Epoch seconds |
| 12 | `end` | `1788302359` | A one-second window |
| 13 | `action` | `ACCEPT` | Security groups and NACLs permitted it |
| 14 | `log-status` | `OK` | No records dropped for this window |

One packet, 44 bytes, protocol 6, a one-second window. That is a bare SYN with nothing following it, which means nothing answered. A completed handshake would show at least three packets and a byte count reflecting a payload. A conversation would also produce a matching record in the other direction, and there is none.

The other four say the same thing in slightly different numbers. Destination ports of 30007, 10134, 22014, and 30695 are not services anyone runs; they are what you get from a scanner walking a range. Byte counts of 44 and 52 are the difference between a SYN with no TCP options and one carrying a few. Every window is one second or less.

Two details in the set are worth noticing. The destination address is `10.0.0.219`, which is private, because flow logs on the NAT gateway's interface record the address on the VPC side of the translation rather than the public one the scanner aimed at. And `162.216.149.10` and `162.216.150.123` sit in the same `162.216.0.0/16`, so two of the five sources came from one network.

The five span from `1788302358` to `1788302396`, so all of this arrived inside thirty-eight seconds.

### Why ACCEPT is not a breach

Every one of those scan records has `ACCEPT` in the action field, and that reads alarmingly if you take the word at face value. It does not mean the connection succeeded.

The `action` field reports one thing: whether security groups and network ACLs permitted the packet. A NAT gateway has no security group. It is a managed AWS service, not an instance, and there is nothing to attach one to. The default network ACL permits all traffic in both directions. So the verdict recorded in the log is `ACCEPT`, correctly, because nothing at that layer rejected it.

What happened next is not in the log. The NAT gateway itself dropped every one of those packets, because a NAT gateway only forwards inbound traffic that matches a connection established from inside the VPC. An unsolicited SYN from the internet matches nothing in its translation table and goes nowhere. There was no instance behind it in any case.

`ACCEPT` describes a filtering decision. It says nothing about whether anything answered.

## The gap I am not going to pretend about

The CloudWatch overview for this account showed zero alarms and zero dashboards. Flow logs were being collected, encrypted, retained, and read by nobody unless I went looking.

That is evidence collection. It is not monitoring. If those scans had been something worth reacting to, the first I would have known about it is the next time I opened the console out of curiosity. Metric filters on the log group, an alarm on rejected traffic volume, and somewhere for that alarm to go are all Phase 5, and none of it exists yet.
