module "vpc" {
  source = "../../modules/vpc"

  name_prefix        = "${var.project_name}-${var.environment}"
  vpc_cidr           = var.vpc_cidr
  az_count           = 2
  single_nat_gateway = var.single_nat_gateway
}

module "iam" {
  source = "../../modules/iam"

  name_prefix    = "${var.project_name}-${var.environment}"
  github_org     = "arunkumarm-tech"
  github_repo    = "aws-devsecops-sre-platform"
  github_branch  = "main"
  tfstate_bucket = "devsecops-sre-tfstate-160827082645"
  project_tag    = var.project_name
}
