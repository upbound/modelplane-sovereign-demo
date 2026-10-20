#!/usr/bin/env bash
# Gives the control plane's Nebius provider a service account key, and points
# the Nebius ClusterProviderConfig named default at your project.
#
# Needs two things, both kept out of git:
#   .secrets/nebius-credentials.json   the service account's authorized key
#   NEBIUS_PROJECT_ID, or .secrets/nebius-project-id   e.g. project-e00...
#
# The key file can be either what the Nebius CLI writes:
#   nebius iam auth-public-key generate --parent-id <project-id> \
#     --service-account-id <serviceaccount-id> --output .secrets/nebius-credentials.json
# which is {"subject-credentials": {"private-key", "kid", "sub", ...}}, or the
# flat form the Crossplane providers read:
#   {"account_id": "serviceaccount-...", "public_key_id": "publickey-...", "private_key": "-----BEGIN PRIVATE KEY-----..."}
# The script converts the first to the second. The service account needs
# edit rights in the project, for example as a member of the tenant's editors
# group.
#
# The project decides the region, so use one in eu-north1. Safe to run again:
# it replaces the Secret and the ClusterProviderConfig. It never prints the key.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
ctx=${CONTEXT:?set CONTEXT to the control plane kube context}
creds=${NEBIUS_CREDENTIALS:-"${here}/.secrets/nebius-credentials.json"}
project_file="${here}/.secrets/nebius-project-id"
crd=clusterproviderconfigs.nebius.m.upbound.io

project=${NEBIUS_PROJECT_ID:-}
if [[ -z "${project}" && -s "${project_file}" ]]; then
  project=$(tr -d '[:space:]' <"${project_file}")
fi
if [[ -z "${project}" ]]; then
  echo "Set NEBIUS_PROJECT_ID, or put the project ID in ${project_file}." >&2
  exit 1
fi
if [[ ! "${project}" =~ ^project-[a-z0-9]+$ ]]; then
  echo "NEBIUS_PROJECT_ID should look like project-e00...; got '${project}'." >&2
  exit 1
fi
if [[ ! -s "${creds}" ]]; then
  echo "Put the Nebius service account key in ${creds} (see the top of this script)." >&2
  exit 1
fi

umask 077
mkdir -p "${here}/.secrets"
flat=$(mktemp "${here}/.secrets/nebius-flat.XXXXXX")
trap 'rm -f "${flat}"' EXIT

# Normalise to the flat form and check every field is there, without printing
# any of them.
if ! jq -e '
    (if has("subject-credentials") then
       ."subject-credentials" | {account_id: .sub, public_key_id: .kid, private_key: ."private-key"}
     else
       {account_id, public_key_id, private_key}
     end)
    | if ([.account_id, .public_key_id, .private_key] | all(type == "string" and length > 0))
      then . else error("missing field") end
  ' "${creds}" >"${flat}" 2>/dev/null; then
  echo "${creds} isn't a Nebius service account key with an account ID, key ID and private key." >&2
  exit 1
fi

# provider-nebius comes with the Modelplane Configuration; its CRDs may take a
# minute to appear on a fresh control plane.
for _ in $(seq 1 60); do
  kubectl --context "${ctx}" get crd "${crd}" >/dev/null 2>&1 && break
  sleep 5
done
kubectl --context "${ctx}" wait --for=condition=Established "crd/${crd}" --timeout=2m >/dev/null

kubectl --context "${ctx}" -n crossplane-system create secret generic nebius-credentials \
  --from-file=credentials.json="${flat}" --dry-run=client -o yaml |
  kubectl --context "${ctx}" apply -f -

NEBIUS_PROJECT_ID="${project}" yq '.spec.projectID = strenv(NEBIUS_PROJECT_ID)' \
  "${here}/control-plane/clusterproviderconfig-nebius.yaml" |
  kubectl --context "${ctx}" apply -f -

echo "Nebius credentials applied for ${project}."
