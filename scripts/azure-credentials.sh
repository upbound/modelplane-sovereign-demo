#!/usr/bin/env bash
# Gives the control plane's Azure provider a service principal.
#
# Creates one on first run, with Contributor on the subscription: Modelplane
# creates resource groups, networks and AKS clusters but no role assignments,
# so it needs no more than Contributor. The JSON stays in .secrets/, which git
# ignores. To use an existing principal, put its JSON there first:
#   {"clientId": "...", "clientSecret": "...", "tenantId": "...", "subscriptionId": "..."}
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
ctx=${CONTEXT:?set CONTEXT to the control plane kube context}
sp_name=${AZURE_SP_NAME:-modelplane-demo}
sp_json="${here}/.secrets/azure-sp.json"

if [[ ! -s "${sp_json}" ]]; then
  sub=${AZURE_SUBSCRIPTION_ID:?set AZURE_SUBSCRIPTION_ID to create the service principal}
  mkdir -p "${here}/.secrets"
  umask 077
  az ad sp create-for-rbac --name "${sp_name}" --role Contributor \
    --scopes "/subscriptions/${sub}" -o json |
    jq --arg sub "${sub}" \
      '{clientId: .appId, clientSecret: .password, tenantId: .tenant, subscriptionId: $sub}' \
      >"${sp_json}"
fi

kubectl --context "${ctx}" -n crossplane-system create secret generic azure-credentials \
  --from-file=credentials.json="${sp_json}" --dry-run=client -o yaml |
  kubectl --context "${ctx}" apply -f -
kubectl --context "${ctx}" apply -f "${here}/control-plane/clusterproviderconfig-azure.yaml"
