terraform {
  backend "s3" {
    bucket       = "devsecops-sre-tfstate-160827082645"
    key          = "envs/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
