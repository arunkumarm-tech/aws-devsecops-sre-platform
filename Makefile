.PHONY: fmt validate plan apply destroy check

ENV_DIR := terraform/envs/dev

fmt:
	terraform fmt -recursive

check:
	terraform fmt -check -recursive

validate:
	cd $(ENV_DIR) && terraform validate

plan:
	cd $(ENV_DIR) && terraform plan

apply:
	cd $(ENV_DIR) && terraform apply

destroy:
	cd $(ENV_DIR) && terraform destroy
