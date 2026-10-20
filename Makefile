# Modelplane walkthrough demo: from model to sovereign endpoint, on AKS and Nebius.
#
# End to end, with AZURE_SUBSCRIPTION_ID set and Nebius credentials in .secrets/:
#   make control-plane credentials nebius-credentials platform callers policy
#   make workloads oversight kubeconfig monitoring grafana wait smoke policy-test
#
# Between sessions: make aks-stop, then make aks-start.

KIND_CLUSTER ?= modelplane-demo
CONTEXT ?= kind-$(KIND_CLUSTER)
GATEWAY ?= eu
NAMESPACE ?= ml-team
AZURE_SP_NAME ?= modelplane-demo

KUBECTL := kubectl --context $(CONTEXT)
export CONTEXT KIND_CLUSTER AZURE_SUBSCRIPTION_ID AZURE_SP_NAME GATEWAY NAMESPACE NEBIUS_PROJECT_ID

.PHONY: help control-plane credentials nebius-credentials platform callers workloads policy \
	policy-test oversight wait smoke offline status kubeconfig monitoring grafana grafana-stop monitoring-down teardown aks-pause aks-unpause aks-stop aks-start destroy destroy-control-plane

help:
	@sed -n '1,7p' Makefile

control-plane: ## Local kind control plane with Crossplane and Modelplane (a main build with the AKS fix)
	scripts/control-plane.sh

credentials: ## Service principal (Contributor on AZURE_SUBSCRIPTION_ID, first run only) and the Azure ClusterProviderConfig
	scripts/azure-credentials.sh

nebius-credentials: ## Nebius service account key (.secrets/nebius-credentials.json) and the ClusterProviderConfig for NEBIUS_PROJECT_ID (or .secrets/nebius-project-id)
	scripts/nebius-credentials.sh

# Both clusters build in parallel (about 15 minutes each). Wait for both before
# the workloads: a cache staged while Nebius still replaces its first node can
# stay Pending (issue #494).
platform: ## Both GPU clusters (AKS and Nebius), gateway and telemetry
	$(KUBECTL) apply -k platform
	$(KUBECTL) wait --for=condition=Ready inferencecluster -l jurisdiction=eu --timeout=40m
	$(KUBECTL) wait --for=condition=Ready inferencegateway/$(GATEWAY) --timeout=10m

callers: ## API key Secret for the gateway's two callers, demo and chat-app
	scripts/callers.sh

workloads: ## Model cache, deployment and service
	$(KUBECTL) apply -k workloads

policy: ## EU-only admission policies for namespaces labelled jurisdiction=eu
	$(KUBECTL) apply -f policies/eu-only.yaml

# Retries for a few seconds because a namespace created moments earlier isn't
# visible to the policy's namespaceSelector straight away.
policy-test: ## Dry-run a deployment without the EU selector; it must be rejected
	@for i in 1 2 3 4 5 6; do \
		if ! $(KUBECTL) -n $(NAMESPACE) apply --dry-run=server -f policies/test/qwen-anywhere.yaml >/dev/null 2>&1; then \
			$(KUBECTL) -n $(NAMESPACE) apply --dry-run=server -f policies/test/qwen-anywhere.yaml 2>&1 | tail -1; \
			echo "PASS: deployment outside the EU was rejected"; exit 0; \
		fi; sleep 5; \
	done; echo "FAIL: deployment outside the EU was admitted"; exit 1

# After workloads: the bindings live in the team's namespace.
oversight: ## RBAC for human in the loop: the team views, only the GitOps pipeline edits
	$(KUBECTL) apply -f policies/oversight.yaml

wait: ## Wait for the model to be staged, deployed and routable
	$(KUBECTL) -n $(NAMESPACE) wait --for=condition=Ready modeldeployment/qwen-7b --timeout=40m
	$(KUBECTL) -n $(NAMESPACE) wait --for=condition=Ready modelservice/qwen-7b --timeout=10m

smoke: ## Call the model through the gateway with an API key
	scripts/smoke-test.sh

# Issue #530: an engine that loads from a ModelCache still contacts Hugging Face
# at startup. This sets HF_HUB_OFFLINE=1 on the engine so it uses the cache
# only; it rolls the replicas. Test it in a rehearsal before relying on it.
offline: ## Run the engine without contacting Hugging Face (HF_HUB_OFFLINE=1)
	$(KUBECTL) -n $(NAMESPACE) patch modeldeployment qwen-7b --type=json --patch-file workloads/offline-patch.json

status:
	$(KUBECTL) get inferencecluster,inferencegateway,telemetrydestination
	$(KUBECTL) -n $(NAMESPACE) get modelcache,modeldeployment,modelreplica,modelservice

kubeconfig: ## Write each cluster's kubeconfig to .secrets/<cluster>.kubeconfig
	scripts/kubeconfig.sh

# After platform and kubeconfig: Prometheus runs on the AKS cluster.
# Prometheus on the AKS cluster (system pool) behind a LoadBalancer with TLS and
# basic auth, and the TelemetryDestination that points every cluster's collector
# at it. Credentials and certificates go to .secrets/monitoring/.
monitoring: ## Fleet metrics: Prometheus on AKS, and the TelemetryDestination for every collector
	scripts/monitoring.sh up

grafana: ## Grafana on http://localhost:3000 with the fleet dashboard (Docker)
	scripts/monitoring.sh grafana

grafana-stop: ## Stop the local Grafana
	scripts/monitoring.sh grafana-stop

monitoring-down: ## Remove the TelemetryDestination, its Secret, Prometheus and Grafana
	scripts/monitoring.sh down

# The workloads go before their namespace: the provider-kubernetes Objects they
# compose there can't finalize once the namespace is terminating, which hangs it.
teardown: ## Remove the demo's objects; keeps the AKS cluster and the control plane
	-$(KUBECTL) delete -f policies/eu-only.yaml --ignore-not-found
	-$(KUBECTL) -n $(NAMESPACE) delete modelservice/qwen-7b modeldeployment/qwen-7b modelcache/qwen-7b \
		--ignore-not-found --cascade=foreground --wait --timeout=20m
	-$(KUBECTL) delete -k workloads --ignore-not-found --wait
	-$(KUBECTL) -n modelplane-system delete secret demo-callers --ignore-not-found
	-$(KUBECTL) delete inferencegateway $(GATEWAY) --ignore-not-found --wait

# Crossplane won't delete a paused resource, so destroy unpauses first.
aks-pause:
	$(KUBECTL) -n modelplane-system annotate kubernetescluster.containerservice.azure.m.upbound.io,kubernetesclusternodepool.containerservice.azure.m.upbound.io --all crossplane.io/paused=true --overwrite

aks-unpause:
	$(KUBECTL) -n modelplane-system annotate kubernetescluster.containerservice.azure.m.upbound.io,kubernetesclusternodepool.containerservice.azure.m.upbound.io --all crossplane.io/paused-

# Stopping deallocates every node but keeps the clusters, the cache and the
# Crossplane state, so aks-start resumes where it left off. The AKS resources
# stay paused while stopped so Crossplane doesn't try to update a stopped cluster.
AKS_CLUSTERS = $(KUBECTL) -n modelplane-system get kubernetescluster.containerservice.azure.m.upbound.io \
	-o jsonpath='{range .items[*]}{.spec.forProvider.resourceGroupName}{" "}{.metadata.annotations.crossplane\.io/external-name}{"\n"}{end}'

aks-stop: aks-pause ## Stop the AKS clusters to save cost; aks-start resumes
	$(AKS_CLUSTERS) | while read -r rg name; do az aks stop -g "$$rg" -n "$$name"; done

aks-start: ## Start the stopped AKS clusters and resume Crossplane
	$(AKS_CLUSTERS) | while read -r rg name; do az aks start -g "$$rg" -n "$$name"; done
	$(MAKE) aks-unpause
	$(KUBECTL) wait --for=condition=Ready inferencecluster -l jurisdiction=eu --timeout=30m

destroy: teardown aks-unpause ## Also delete both GPU clusters (AKS and Nebius)
	-scripts/monitoring.sh down
	$(KUBECTL) delete -k platform --ignore-not-found --cascade=foreground --wait --timeout=40m

destroy-control-plane: ## Delete the local kind control plane (after destroy)
	kind delete cluster --name $(KIND_CLUSTER)
