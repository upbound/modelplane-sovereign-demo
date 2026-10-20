#!/usr/bin/env bash
# Writes a kubeconfig for each cluster Modelplane provisioned to
# .secrets/<cluster>.kubeconfig, for looking at engines, gateway usage records
# and collector logs on the workload cluster itself.
#
# AKS: the kubeconfig Modelplane keeps, as is. Nebius: Modelplane's kubeconfig
# carries no credentials (it authenticates with the service account key), so
# this adds a user that gets a token from the Nebius CLI as that same service
# account, through its own CLI config in .secrets/. No browser sign-in is
# involved, so a token never expires into an interactive prompt mid-demo.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
ctx=${CONTEXT:?set CONTEXT to the control plane kube context}
mkdir -p "${here}/.secrets"
umask 077

nebius_cli_config="${here}/.secrets/nebius-cli.yaml"
nebius_profile=modelplane-demo

# The Nebius CLI config with the service account profile, created once.
nebius_cli() {
  [[ -s "${nebius_cli_config}" ]] && return 0
  command -v nebius >/dev/null || { echo "the nebius CLI is needed for Nebius clusters" >&2; return 1; }
  local project=${NEBIUS_PROJECT_ID:-$(cat "${here}/.secrets/nebius-project-id" 2>/dev/null || true)}
  nebius --config "${nebius_cli_config}" profile create "${nebius_profile}" --endpoint api.nebius.cloud \
    --service-account-file-path "${here}/.secrets/nebius-credentials.json" \
    ${project:+--parent-id "${project}"} >/dev/null
}

kubectl --context "${ctx}" get inferencecluster -o json |
  jq -r '.items[] | "\(.metadata.name) \(.spec.cluster.source)"' |
  while read -r ic source; do
    secret=$(kubectl --context "${ctx}" -n modelplane-system get secret -o name |
      grep -E "^secret/${ic}-kubeconfig" | head -1 || true)
    if [[ -z "${secret}" ]]; then
      echo "${ic}: no kubeconfig Secret in modelplane-system yet" >&2
      continue
    fi
    out="${here}/.secrets/${ic}.kubeconfig"
    kubectl --context "${ctx}" -n modelplane-system get "${secret}" -o jsonpath='{.data.kubeconfig}' |
      base64 -d >"${out}"
    if [[ "${source}" == Nebius ]]; then
      nebius_cli
      NEBIUS="$(command -v nebius)" CFG="${nebius_cli_config}" PROFILE="${nebius_profile}" yq -i '
        .users[].user = {"exec": {
          "apiVersion": "client.authentication.k8s.io/v1beta1",
          "command": strenv(NEBIUS),
          "args": ["--config", strenv(CFG), "mk8s", "v1", "cluster", "get-token",
                   "--profile", strenv(PROFILE), "--format", "json"],
          "interactiveMode": "Never",
          "provideClusterInfo": false}}' "${out}"
    fi
    echo "${ic}: .secrets/${ic}.kubeconfig (from ${secret})"
  done
