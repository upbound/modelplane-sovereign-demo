#!/usr/bin/env bash
# Creates the gateway's caller Secret. Each key in it is one caller: the key's
# name is the identity the gateway stamps on usage records, its value the API
# key. Two callers: "demo", the presenter, and "chat-app", whose background
# traffic feeds the dashboard. Each key is generated once and kept in .secrets/.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
ctx=${CONTEXT:?set CONTEXT to the control plane kube context}

mkdir -p "${here}/.secrets"
args=()
for c in demo chat-app; do
  key_file="${here}/.secrets/api-key-${c}"
  if [[ ! -s "${key_file}" ]]; then
    (umask 077; printf 'sk-%s-%s' "${c}" "$(openssl rand -hex 16)" >"${key_file}")
  fi
  args+=(--from-file="${c}=${key_file}")
done

kubectl --context "${ctx}" -n modelplane-system create secret generic demo-callers \
  "${args[@]}" --dry-run=client -o yaml |
  kubectl --context "${ctx}" label --local -f - modelplane.ai/inference-keys=true -o yaml |
  kubectl --context "${ctx}" apply -f -
