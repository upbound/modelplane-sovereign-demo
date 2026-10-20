#!/usr/bin/env bash
# Local control plane for the demo: a kind cluster running
# Crossplane and the Modelplane Configuration, as in Modelplane's install docs.
# The control plane runs no models and needs no GPU.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
name=${KIND_CLUSTER:-modelplane-demo}
ctx="kind-${name}"

# kind v0.31+ node images ship containerd 2.2.0, which breaks Modelplane, so
# pin the v0.30.0 default image the install docs use.
node_image="kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a"

# kind switches the current kube context to the new cluster; everything here
# uses --context, so put the user's current context back.
if ! kind get clusters 2>/dev/null | grep -qx "${name}"; then
  prev=$(kubectl config current-context 2>/dev/null || true)
  kind create cluster --name "${name}" --image "${node_image}"
  [[ -n "${prev}" ]] && kubectl config use-context "${prev}" >/dev/null
fi

helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null
helm repo update crossplane-stable >/dev/null
helm upgrade --install crossplane crossplane-stable/crossplane \
  --kube-context "${ctx}" \
  --namespace crossplane-system --create-namespace \
  --set "args={--enable-dependency-version-upgrades}" \
  --set-json 'provider.defaultActivations=[]' \
  --wait

kubectl --context "${ctx}" apply -f "${here}/control-plane/prerequisites.yaml"
kubectl --context "${ctx}" apply -f "${here}/control-plane/configuration.yaml"
kubectl --context "${ctx}" wait configuration/modelplane --for=condition=Healthy --timeout=15m

# modelplaneai/modelplane#517: from provider-nebius v1.1.0, the Nebius node
# groups' spec flip-flops in a loop and the provider pushes each flip to Nebius,
# which replaces the nodes and drops the model cache's filesystem from them.
# Modelplane v0.5 pins v1.2.0. v1.0.1, which v0.4 shipped, ignores the flip, so
# the node groups settle. With every dependency installed, stop resolving them
# (Crossplane would otherwise upgrade the provider back to the pin) and run
# v1.0.1. The Nebius CRDs are v1beta1 in both versions.
kubectl --context "${ctx}" patch configuration modelplane --type merge \
  -p '{"spec":{"skipDependencyResolution":true}}'
kubectl --context "${ctx}" patch providers.pkg.crossplane.io upbound-provider-nebius --type merge \
  -p '{"spec":{"package":"xpkg.upbound.io/upbound/provider-nebius:v1.0.1"}}'
