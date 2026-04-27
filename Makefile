# ==============================================================================
# kube-platform — Makefile
# ==============================================================================
# Usage:
#   make <target>
#
# Override defaults with env vars:
#   K8S_VERSION=1.31.0 CLUSTER_NAME=my-cluster make cluster-up
# ==============================================================================

# ---- Variables ---------------------------------------------------------------
K8S_VERSION    ?= 1.32.0
CLUSTER_NAME   ?= kube-platform
HELM_VERSION   ?= 3.17.0
KIND_CONFIG    ?= setup/local/kind/kind-config.yml
KUBECONFIG     ?= $(HOME)/.kube/config

# Derived
KIND_IMAGE     := kindest/node:v$(K8S_VERSION)

# Color codes
RESET  := \033[0m
BOLD   := \033[1m
GREEN  := \033[32m
YELLOW := \033[33m
CYAN   := \033[36m

# ---- Default target ----------------------------------------------------------
.DEFAULT_GOAL := help

# ==============================================================================
# HELP
# ==============================================================================

.PHONY: help
help: ## Show this help message
	@printf "\n$(BOLD)kube-platform Makefile$(RESET)\n\n"
	@printf "$(CYAN)Usage:$(RESET) make $(YELLOW)<target>$(RESET)\n\n"
	@printf "$(CYAN)Variables (override with env):$(RESET)\n"
	@printf "  K8S_VERSION    = $(K8S_VERSION)\n"
	@printf "  CLUSTER_NAME   = $(CLUSTER_NAME)\n"
	@printf "  HELM_VERSION   = $(HELM_VERSION)\n\n"
	@printf "$(CYAN)Targets:$(RESET)\n"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ { printf "  $(YELLOW)%-30s$(RESET) %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf "\n"

# ==============================================================================
# CLUSTER LIFECYCLE
# ==============================================================================

.PHONY: cluster-up
cluster-up: ## Create a local KIND cluster (1 control-plane + 2 workers)
	@printf "$(GREEN)Creating KIND cluster '$(CLUSTER_NAME)' with Kubernetes v$(K8S_VERSION)...$(RESET)\n"
	kind create cluster \
		--name $(CLUSTER_NAME) \
		--config $(KIND_CONFIG) \
		--image $(KIND_IMAGE) \
		--wait 120s
	@printf "$(GREEN)Cluster ready. Context: kind-$(CLUSTER_NAME)$(RESET)\n"
	kubectl cluster-info --context kind-$(CLUSTER_NAME)

.PHONY: cluster-down
cluster-down: ## Delete the local KIND cluster
	@printf "$(YELLOW)Deleting KIND cluster '$(CLUSTER_NAME)'...$(RESET)\n"
	kind delete cluster --name $(CLUSTER_NAME)
	@printf "$(GREEN)Cluster deleted.$(RESET)\n"

.PHONY: cluster-info
cluster-info: ## Show cluster info and node status
	@printf "$(CYAN)=== Cluster Info ===$(RESET)\n"
	kubectl cluster-info --context kind-$(CLUSTER_NAME)
	@printf "\n$(CYAN)=== Nodes ===$(RESET)\n"
	kubectl get nodes -o wide
	@printf "\n$(CYAN)=== System Pods ===$(RESET)\n"
	kubectl get pods -n kube-system

# ==============================================================================
# LINTING & VALIDATION
# ==============================================================================

.PHONY: lint
lint: ## Run yamllint on all YAML files (excluding vendor/)
	@printf "$(CYAN)Running yamllint...$(RESET)\n"
	@if command -v yamllint >/dev/null 2>&1; then \
		yamllint --strict -d '{extends: default, rules: {line-length: {max: 160}, truthy: {allowed-values: ["true", "false"]}}}' \
			$(shell find . -name '*.yml' -o -name '*.yaml' | grep -v vendor/ | grep -v '.git/'); \
		printf "$(GREEN)yamllint passed.$(RESET)\n"; \
	else \
		printf "$(YELLOW)yamllint not found. Install with: pip install yamllint$(RESET)\n"; \
		exit 1; \
	fi

.PHONY: validate
validate: ## Run kubeconform schema validation on all manifests
	@printf "$(CYAN)Running kubeconform...$(RESET)\n"
	@if command -v kubeconform >/dev/null 2>&1; then \
		find . -name '*.yaml' -o -name '*.yml' \
			| grep -v vendor/ | grep -v '.git/' \
			| grep -v 'kind-config' | grep -v 'setup/' \
			| xargs kubeconform \
				-kubernetes-version $(K8S_VERSION) \
				-strict \
				-ignore-missing-schemas \
				-summary; \
		printf "$(GREEN)kubeconform passed.$(RESET)\n"; \
	else \
		printf "$(YELLOW)kubeconform not found. Install with: brew install kubeconform$(RESET)\n"; \
		exit 1; \
	fi

.PHONY: helm-lint
helm-lint: ## Run helm lint --strict on all charts
	@printf "$(CYAN)Linting Helm charts...$(RESET)\n"
	@for chart in helm/apache helm/node-app; do \
		if [ -d "$$chart" ]; then \
			printf "  Linting $$chart...\n"; \
			helm lint --strict "$$chart" || exit 1; \
		fi; \
	done
	@printf "$(GREEN)helm lint passed.$(RESET)\n"

.PHONY: check
check: lint validate helm-lint ## Run all checks (lint + validate + helm-lint)
	@printf "\n$(GREEN)All checks passed.$(RESET)\n"

# ==============================================================================
# APPLY WORKLOADS
# ==============================================================================

.PHONY: apply-nginx
apply-nginx: ## Apply nginx Deployment + Service
	@printf "$(CYAN)Applying nginx workloads...$(RESET)\n"
	kubectl apply -f workloads/nginx/
	kubectl rollout status deployment/nginx -n nginx --timeout=120s

.PHONY: apply-mysql
apply-mysql: ## Apply MySQL Deployment + Service + ConfigMap + Secret
	@printf "$(CYAN)Applying MySQL workloads...$(RESET)\n"
	kubectl apply -f workloads/mysql/
	kubectl rollout status deployment/mysql -n mysql --timeout=120s

.PHONY: apply-rbac
apply-rbac: ## Apply RBAC example (ServiceAccount, Role, RoleBinding, ClusterRole, ClusterRoleBinding)
	@printf "$(CYAN)Applying RBAC objects...$(RESET)\n"
	kubectl apply -f security/rbac/

.PHONY: apply-network-policies
apply-network-policies: ## Apply NetworkPolicy examples
	@printf "$(CYAN)Applying NetworkPolicies...$(RESET)\n"
	kubectl apply -f networking/network-policies/

# ==============================================================================
# INSTALL PLATFORM TOOLS (via Helm)
# ==============================================================================

.PHONY: install-prometheus
install-prometheus: ## Install kube-prometheus-stack via Helm
	@printf "$(CYAN)Installing kube-prometheus-stack...$(RESET)\n"
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo update
	kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
		--namespace monitoring \
		--values observability/prometheus/values.yaml \
		--wait \
		--timeout 300s
	@printf "$(GREEN)Prometheus stack installed.$(RESET)\n"

.PHONY: install-argocd
install-argocd: ## Install Argo CD via Helm
	@printf "$(CYAN)Installing Argo CD...$(RESET)\n"
	helm repo add argo https://argoproj.github.io/argo-helm
	helm repo update
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install argocd argo/argo-cd \
		--namespace argocd \
		--wait \
		--timeout 300s
	@printf "$(GREEN)Argo CD installed. Run 'make port-forward-argocd' to access the UI.$(RESET)\n"

.PHONY: install-kyverno
install-kyverno: ## Install Kyverno policy engine via Helm
	@printf "$(CYAN)Installing Kyverno...$(RESET)\n"
	helm repo add kyverno https://kyverno.github.io/kyverno/
	helm repo update
	kubectl create namespace kyverno --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install kyverno kyverno/kyverno \
		--namespace kyverno \
		--wait \
		--timeout 300s
	@printf "$(GREEN)Kyverno installed.$(RESET)\n"

.PHONY: install-sealed-secrets
install-sealed-secrets: ## Install Bitnami Sealed Secrets controller via Helm
	@printf "$(CYAN)Installing Sealed Secrets...$(RESET)\n"
	helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
	helm repo update
	helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
		--namespace kube-system \
		--wait \
		--timeout 120s
	@printf "$(GREEN)Sealed Secrets installed.$(RESET)\n"

# ==============================================================================
# BOOTSTRAP & TEARDOWN
# ==============================================================================

.PHONY: bootstrap
bootstrap: cluster-up install-prometheus install-argocd install-kyverno install-sealed-secrets apply-nginx apply-mysql apply-rbac apply-network-policies ## Full bootstrap: cluster + all platform tools + example workloads
	@printf "\n$(GREEN)Bootstrap complete!$(RESET)\n"
	@printf "  Grafana:   make port-forward-grafana  (admin / prom-operator)\n"
	@printf "  Argo CD:   make port-forward-argocd\n"
	@printf "  Cluster:   kubectl get nodes\n"

.PHONY: teardown
teardown: cluster-down ## Destroy the cluster and clean local artifacts
	@printf "$(YELLOW)Teardown complete.$(RESET)\n"

# ==============================================================================
# PORT FORWARDS
# ==============================================================================

.PHONY: port-forward-grafana
port-forward-grafana: ## Port-forward Grafana to localhost:3000 (Ctrl+C to stop)
	@printf "$(CYAN)Forwarding Grafana to http://localhost:3000 (admin/prom-operator)$(RESET)\n"
	kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

.PHONY: port-forward-argocd
port-forward-argocd: ## Port-forward Argo CD server to localhost:8080 (Ctrl+C to stop)
	@printf "$(CYAN)Forwarding Argo CD to https://localhost:8080$(RESET)\n"
	@printf "$(YELLOW)Get the initial admin password with:$(RESET)\n"
	@printf "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d\n\n"
	kubectl port-forward -n argocd svc/argocd-server 8080:443

# ==============================================================================
# SEALED SECRETS HELPERS
# ==============================================================================

.PHONY: seal-secret
seal-secret: ## Seal a secret: NAME=mysecret NAMESPACE=default VALUE=s3cr3t make seal-secret
	@if [ -z "$(NAME)" ] || [ -z "$(NAMESPACE)" ] || [ -z "$(VALUE)" ]; then \
		printf "$(YELLOW)Usage: NAME=mysecret NAMESPACE=default VALUE=s3cr3t make seal-secret$(RESET)\n"; \
		exit 1; \
	fi
	@printf "$(CYAN)Sealing secret '$(NAME)' in namespace '$(NAMESPACE)'...$(RESET)\n"
	kubectl create secret generic $(NAME) \
		--from-literal=value=$(VALUE) \
		--namespace $(NAMESPACE) \
		--dry-run=client \
		-o yaml \
	| kubeseal \
		--controller-name sealed-secrets \
		--controller-namespace kube-system \
		--format yaml \
	> sealed-secrets/$(NAME)-sealed.yaml
	@printf "$(GREEN)Sealed secret written to sealed-secrets/$(NAME)-sealed.yaml$(RESET)\n"

# ==============================================================================
# CLEANUP
# ==============================================================================

.PHONY: clean
clean: ## Remove generated files (Chart.lock, *.tgz, values-override.yaml)
	@printf "$(CYAN)Cleaning generated files...$(RESET)\n"
	find . -name 'Chart.lock' -delete
	find . -name '*.tgz' -delete
	find . -name 'values-override.yaml' -delete
	@printf "$(GREEN)Clean complete.$(RESET)\n"
