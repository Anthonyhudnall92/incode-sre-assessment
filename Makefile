SHELL := /usr/bin/env bash
TF    := terraform -chdir=terraform
TFB   := terraform -chdir=bootstrap

# Every kubectl here uses the repo-local kubeconfig, never your current context.
export KUBECONFIG := $(CURDIR)/.kube/config

# The EKS API is private: kubectl and `make addons` go through `make tunnel`.
# DIRECT=1 talks to the public endpoint instead (break-glass, eks_public_access).
TUNNEL_PORT ?= 8443
API_URL     := $(if $(DIRECT),,https://127.0.0.1:$(TUNNEL_PORT))

.PHONY: help bootstrap backend-config init plan apply release up down status test lint fmt addons argocd argocd-password kubeconfig tunnel incident

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

release: ## Build, scan and push the app image, and pin its digest in the chart (then PR it)
	scripts/release.sh

addons: ## Install Argo CD and its apps (needs `make tunnel` running, or DIRECT=1)
	terraform -chdir=addons init -input=false -backend-config=../terraform/backend.hcl -backend-config=key=sre-demo/addons.tfstate
	terraform -chdir=addons apply $(if $(API_URL),-var api_server_url=$(API_URL))

tunnel: ## Open the private EKS API on 127.0.0.1:8443 through the SSM jump host (leave running)
	TUNNEL_PORT=$(TUNNEL_PORT) scripts/tunnel.sh

kubeconfig: ## Write .kube/config for this cluster (gitignored); points at the tunnel unless DIRECT=1
	aws eks update-kubeconfig --region "$$($(TF) output -raw region)" --name "$$($(TF) output -raw cluster_name)" --kubeconfig "$$KUBECONFIG" >/dev/null
	@if [ -n "$(API_URL)" ]; then \
	  host="$$($(TF) output -raw cluster_endpoint)"; \
	  kubectl config set-cluster "$$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')" \
	    --server=$(API_URL) --tls-server-name="$${host#https://}" >/dev/null; \
	  echo "kubeconfig -> $(API_URL) (via make tunnel)"; \
	else echo "kubeconfig -> public endpoint (break-glass)"; fi

argocd: kubeconfig ## Open the Argo CD UI on https://localhost:8080 (user admin; see argocd-password)
	kubectl -n argocd port-forward svc/argocd-server 8080:443

incident: kubeconfig ## Incident drill: make incident MODE=down|slow|ok (the demo service on the board)
	@case "$(MODE)" in ok|down|slow) ;; *) echo "usage: make incident MODE=down|slow|ok"; exit 1;; esac
	kubectl -n "$$($(TF) output -raw app_namespace)" exec deploy/"$$($(TF) output -raw app_name)" -- python -c \
	  "import urllib.request as u; r = u.Request('http://127.0.0.1:8080/internal/demo-mode', b'{\"mode\": \"$(MODE)\"}', {'Content-Type': 'application/json'}); print(u.urlopen(r).read().decode())"

argocd-password: ## Print the Argo CD admin password from Secrets Manager
	@aws secretsmanager get-secret-value --region "$$($(TF) output -raw region)" \
	  --secret-id "$$($(TF) output -raw cluster_name)/argocd-admin" --query SecretString --output text | jq -r .password

up: init plan apply ## Build the main stack; then `make tunnel` (leave running) and `make addons`
	@echo "Next: make tunnel (in another terminal), then make addons. Argo CD deploys the app."

down: ## Tear everything down (ALB first, then Terraform)
	scripts/destroy.sh

status: kubeconfig ## Quick health view
	kubectl -n argocd get applications
	kubectl -n "$$($(TF) output -raw app_namespace)" get deploy,pods,svc,ingress,networkpolicy -o wide
	@$(TF) output -raw dashboard_url; echo

test: ## App unit tests
	cd app && python3 -m unittest discover -s tests

fmt: ## Format Terraform
	terraform fmt -recursive

lint: ## Same checks as CI
	terraform fmt -check -recursive
	tflint --init && tflint --recursive
	checkov -d . --config-file .checkov.yaml
