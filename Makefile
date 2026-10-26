SHELL := /usr/bin/env bash
TF    := terraform -chdir=terraform
TFB   := terraform -chdir=bootstrap

.PHONY: help bootstrap backend-config init plan apply deploy up down status test lint fmt

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-16s %s\n",$$1,$$2}'

bootstrap: ## One-time: create the encrypted, locked remote-state bucket
	$(TFB) init
	$(TFB) apply
	$(MAKE) backend-config

backend-config: ## Write terraform/backend.hcl from bootstrap outputs (gitignored)
	$(TFB) output -raw backend_hcl > terraform/backend.hcl
	@echo "wrote terraform/backend.hcl"

init: ## terraform init against the remote backend
	$(TF) init -backend-config=backend.hcl

plan: ## terraform plan
	$(TF) plan -out=tfplan

apply: ## terraform apply the saved plan
	$(TF) apply tfplan

deploy: ## Build, scan, push and deploy the app
	scripts/deploy.sh

up: init plan apply deploy ## Everything, from zero to a running app

down: ## Tear everything down (ALB first, then Terraform)
	scripts/destroy.sh

status: ## Quick health view
	kubectl -n demo get deploy,pods,svc,ingress,networkpolicy -o wide
	@$(TF) output -raw dashboard_url; echo

test: ## App unit tests
	cd app && python3 -m unittest discover -s tests

fmt: ## Format Terraform
	terraform fmt -recursive

lint: ## Same checks as CI
	terraform fmt -check -recursive
	tflint --init && tflint --recursive
	checkov -d . --config-file .checkov.yaml
