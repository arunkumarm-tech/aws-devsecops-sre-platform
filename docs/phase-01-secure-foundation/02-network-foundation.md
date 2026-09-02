# Network foundation

The VPC module in `terraform/modules/vpc/` builds a `10.0.0.0/16` network with public and private subnets across two availability zones. Nothing runs in it yet. Phase 1 was about getting the network right before there was anything in it to break.

## Subnet maths

I did not hardcode subnet ranges. The module calculates them:

```hcl
locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  public_subnet_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnet_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 10)]
}
```

`cidrsubnet(prefix, newbits, netnum)` borrows `newbits` bits from the host portion and returns the subnet at index `netnum`. Eight extra bits on a `/16` gives `/24`s, which is 251 usable addresses each after AWS reserves five. With `az_count = 2` that produces `10.0.0.0/24` and `10.0.1.0/24` for public, `10.0.10.0/24` and `10.0.11.0/24` for private.

The offset of ten on the private range is deliberate. It leaves indices 2 through 9 free, so a third or fourth AZ can be added later without renumbering anything that already exists. Renumbering a subnet means destroying and recreating it, and anything attached to it.

The availability zone list comes from `data.aws_availability_zones` rather than a hardcoded `["us-east-1a", "us-east-1b"]`. AZ names are per-account aliases onto physical zones, and hardcoding them makes the module fail the first time it runs in a region with different naming.

Two variables carry validation blocks:

```hcl
variable "vpc_cidr" {
  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "az_count" {
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be between 2 and 3."
  }
}
```

`can(cidrhost(...))` is the idiomatic way to test whether a string parses as a CIDR block. Both of these fail at plan time with a readable message instead of at apply time with an AWS API error.

## The NAT gateway decision, with the numbers

A NAT gateway lets instances in a private subnet reach the internet without being reachable from it. It costs roughly $32 a month before data processing charges, and it is the single most expensive thing in Phase 1 by a wide margin.

One NAT gateway serving both private subnets costs about $32 a month and is a single point of failure. If the availability zone holding it fails, every private subnet loses outbound connectivity, including the one in the healthy AZ. One NAT gateway per AZ removes that failure mode and costs about $64.

I did not pick one. The module takes a boolean:

```hcl
variable "single_nat_gateway" {
  description = <<-EOT
    When true, all private subnets route egress through one NAT Gateway.
    Cheaper (~$32/month vs ~$64), but loses egress if that AZ fails.
    Set false for production-grade per-AZ redundancy.
  EOT
  type    = bool
  default = true
}
```

Default is `true`, because this is a learning account and I destroy it at the end of every session. The honest engineering answer is that the right value depends on whether the workload can tolerate losing egress in one AZ, and that is a question about the workload rather than about the network. Parameterising it means the answer can change without editing the module.

## One route table per private subnet

The public subnets share a single route table with a default route to the internet gateway. That is correct, because they all want the same thing.

The private subnets get one route table each:

```hcl
resource "aws_route_table" "private" {
  count  = var.az_count
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
  }
}
```

With `single_nat_gateway = true` both tables point at the same gateway, and the extra table looks redundant. It is not. Flipping the boolean to `false` changes only which NAT gateway each table targets. If the private subnets shared one route table, enabling the HA path would mean restructuring the module rather than changing a variable, and the whole point of the parameter would be lost.

## Public subnets that do not hand out public IPs

`map_public_ip_on_launch = false` on the public subnets. The default is that anything launched into a public subnet gets a public IP automatically, which means a mistake in an instance definition produces an internet-facing host without anyone deciding that it should be.

Setting it false means assigning a public address is an explicit act. The subnet is still public in the sense that its route table reaches the internet gateway, so anything that genuinely needs an address can request one.

## The default security group, emptied

Every VPC ships with a default security group that allows all traffic between instances attached to it, and all outbound traffic. It cannot be deleted. AWS attaches it to anything launched without an explicit security group.

The module manages it as a resource with no rules declared:

```hcl
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-default-sg-locked"
  }
}
```

`aws_default_security_group` adopts the existing group rather than creating one, and declaring no `ingress` or `egress` blocks removes every rule. Anything that lands on it by accident can talk to nothing at all, which turns a silent misconfiguration into an obvious connectivity failure. This is a CIS benchmark control, and it is one of the few that is both easy and genuinely worth doing.

Verified after apply:

```
aws ec2 describe-security-groups --filters Name=group-name,Values=default \
  --query 'SecurityGroups[].[IpPermissions,IpPermissionsEgress]'
```

Both arrays came back empty.

## Tags for a phase that does not exist yet

The subnets carry Kubernetes ELB discovery tags:

```
public subnets:  "kubernetes.io/role/elb"          = "1"
private subnets: "kubernetes.io/role/internal-elb" = "1"
```

Nothing reads these today. The AWS load balancer controller uses them to decide which subnets to place a load balancer in, and that arrives in Phase 3. Adding them now costs nothing and means the network does not need editing when EKS lands. I mention it because someone reading the module will otherwise wonder what they are for.

## Deleting the default VPC

Every AWS region ships with a default VPC on `172.31.0.0/16`. I deleted the one in us-east-1, in dependency order: detach and delete the internet gateway, delete the six subnets, delete the VPC. The main route table, default security group, and default network ACL are deleted along with the VPC rather than separately.

Why bother. Every subnet in a default VPC is public, and the default security group is permissive. An instance launched with no thought at all is internet-facing. A purpose-built VPC inverts that, so exposure has to be chosen rather than inherited.

Two honest caveats. This was us-east-1 only, and there is a default VPC in every enabled region, so genuine hardening means repeating it everywhere or using an SCP. And it is reversible with `aws ec2 create-default-vpc`, which recreates the VPC and subnets, though not any resource that used to live in them.

There is a story attached. After a `make destroy` I opened the VPC console and saw a VPC still sitting there, and my first thought was that the teardown had failed. It had not. What I was looking at was the default VPC, which had been there since the account was created and which I had never noticed because I had never gone looking. The tells were all visible once I stopped panicking: the address range was `172.31.0.0/16` rather than `10.0.0.0/16`, there were six unnamed subnets rather than my four tagged ones, and the main route table had a default route to an internet gateway. Deleting it was the fix for both problems at once.

## Rebuilds change every ID

I built and destroyed this stack repeatedly. Every rebuild produces a new VPC ID, new subnet IDs, new ENI IDs, new NAT gateway ID. The only stable identifier is the CloudWatch log group name, `/aws/vpc-flow-logs/devsecops-sre-dev`, because it is derived from variables rather than allocated by AWS.

The operational lesson is worth more than the observation. A runbook, a dashboard, or an alarm that references a resource ID is correct exactly once. Reference names and tags.
