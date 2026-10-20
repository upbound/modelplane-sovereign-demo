#!/usr/bin/env bash
# Calls the model through the gateway the way an application would, with an
# API key, over the OpenAI chat completions API.
#
# A gateway without TLS publishes its URL in status. One with TLS is reached on
# its own name or address: set GATEWAY_URL, and INSECURE=1 while it serves a
# self-signed certificate.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
ctx=${CONTEXT:?set CONTEXT to the control plane kube context}
gateway=${GATEWAY:-eu}
namespace=${NAMESPACE:-ml-team}
key=${API_KEY:-$(cat "${here}/.secrets/api-key-demo")}
curl_opts=(-sS --fail-with-body --max-time 120)
[[ "${INSECURE:-0}" == 1 ]] && curl_opts+=(-k)

url=${GATEWAY_URL:-$(kubectl --context "${ctx}" get inferencegateway "${gateway}" -o jsonpath='{.status.endpoints.openAI}')}
model=$(kubectl --context "${ctx}" -n "${namespace}" get modelservice qwen-7b -o jsonpath='{.status.model}')
if [[ -z "${url}" || -z "${model}" ]]; then
  echo "gateway URL or model not known yet (url='${url}', model='${model}')" >&2
  exit 1
fi

echo "POST ${url}/chat/completions model=${model}"
curl "${curl_opts[@]}" "${url}/chat/completions" \
  -H "Authorization: Bearer ${key}" \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"${model}\", \"max_tokens\": 64,
       \"messages\": [{\"role\": \"user\", \"content\": \"In one sentence, what is data locality?\"}]}" |
  jq '{model, answer: .choices[0].message.content, usage}'
