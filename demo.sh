#!/usr/bin/env bash
#
# Modelplane walkthrough demo: "From model to sovereign endpoint".
#
# One model (Qwen2.5-7B AWQ on vLLM) on two GPU clusters from two providers, an
# A100 on AKS and an L40S on Nebius, both in the EU: staged on warm storage,
# held to EU clusters by an admission policy, served through one API-key
# gateway, and monitored in a Prometheus you run. Ten beats, in the order of the
# talk's deck. Beats that need two GPU clusters fall back to a single-cluster
# variant if only one is up.
#
# Usage:
#   ./demo.sh up            # control plane, both clusters, gateway, workloads (~40 min)
#   ./demo.sh               # guided talk: preflight, then 10 beats, ENTER between steps
#   ./demo.sh status        # preflight checklist only
#   ./demo.sh prewarm       # before the talk: the engine image onto every GPU node
#   ./demo.sh reset         # back to the start state: 1 replica, no drain taint
#   ./demo.sh <beat>        # dra | fleet | cache | govern | scale | call | resilience | lifecycle | oversight | monitor
#   ./demo.sh load [N]      # N streaming requests as the chat-app caller, 1 every 2s (default 30)
#   ./demo.sh rehearse [N]  # N unattended full runs with timings (default 1)
#   ./demo.sh down          # delete both GPU clusters and the control plane
#   ./demo.sh record [beat...]  # record the beats from the live setup, for --replay
#
# Flags:
#   --auto SECS             # don't wait for ENTER; sleep SECS instead (recording)
#   --notes                 # print speaker lines on screen
#   --replay                # play the recorded beats instead: no cluster, no network
#
# Environment (defaults below):
#   CONTEXT NAMESPACE GATEWAY GATEWAY_URL INSECURE API_KEY
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SECRETS="${DIR}/.secrets"
RUN="${DIR}/.run"
mkdir -p "${RUN}"

CONTEXT="${CONTEXT:-kind-modelplane-demo}"
NAMESPACE="${NAMESPACE:-ml-team}"
GATEWAY="${GATEWAY:-eu}"
# A gateway without TLS publishes its URL in status. One with TLS needs
# GATEWAY_URL, and INSECURE=1 while its certificate is self-signed.
GATEWAY_URL="${GATEWAY_URL:-}"
INSECURE="${INSECURE:-0}"
KEY_SECRET="demo-callers"; KEY_NAME="demo"
# The second caller: an app whose background traffic feeds the dashboard.
LOAD_KEY_NAME="chat-app"

MD="qwen-7b"                 # ModelDeployment, ModelCache and ModelService share the name
# The beats, in the deck's order.
BEATS=(dra fleet cache govern scale call resilience lifecycle oversight monitor)
DRAIN_KEY="modelplane.demo/drain"
# The lifecycle beat drains one cluster when there are two. DRAIN=0 skips it.
DRAIN="${DRAIN:-1}"
FIELD_MANAGER="modelplane-demo"

AUTO_SLEEP=""
NOTES=0
REPLAY="${REPLAY:-0}"
# Set by `record` for the run it records: pauses become markers in the output.
DEMO_RECORDING="${DEMO_RECORDING:-0}"
POSITIONAL=()
while (( $# > 0 )); do
  case "$1" in
    --auto)   AUTO_SLEEP="$2"; shift 2 ;;
    --notes)  NOTES=1; shift ;;
    --replay) REPLAY=1; shift ;;
    -h|--help) awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"; exit 0 ;;
    *)        POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]:-}"

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
  CYAN=$'\033[36m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; MAGENTA=$'\033[35m'; RED=$'\033[31m'
else
  BOLD=""; DIM=""; RESET=""; CYAN=""; YELLOW=""; GREEN=""; MAGENTA=""; RED=""
fi

# The control plane, always by explicit context: never the current one.
k() { kubectl --context "${CONTEXT}" "$@"; }

# A workload cluster, by InferenceCluster name, through the kubeconfig
# `make kubeconfig` writes.
wk() { local ic="$1"; shift; kubectl --kubeconfig "${SECRETS}/${ic}.kubeconfig" "$@"; }

# The flag wk passes for a workload cluster, to show commands as they run.
wk_flag() { echo "--kubeconfig .secrets/$1.kubeconfig"; }

# Show a command over several lines, joined with shell continuations.
show_cmd() {
  local i line
  for (( i = 1; i <= $#; i++ )); do
    line="${!i}"
    if (( i == 1 )); then line="\$ ${line}"; else line="    ${line}"; fi
    (( i < $# )) && line+=" \\"
    echo "${BOLD}${CYAN}${line}${RESET}"
  done
}

now() { python3 -c 'import time; print(f"{time.time():.1f}")'; }
since() { python3 -c "print(f'{$(now) - $1:.1f}')"; }

# ---------------------------------------------------------------------------
# Presentation helpers
# ---------------------------------------------------------------------------

pause() {
  local prompt="${1:-ENTER}"
  if (( DEMO_RECORDING )); then
    # scripts/cast.py turns this into a marker; the replay pauses there.
    printf '\033]1337;DemoPause=%s\007' "${prompt}"
  elif [[ -n "${AUTO_SLEEP}" ]]; then
    sleep "${AUTO_SLEEP}"
  else
    flush_keys
    read -r -p "${DIM}↪ ${prompt}…${RESET}" _
  fi
}

# Drop keys pressed during the step before, so they can't skip the next pause.
# macOS's bash 3.2 has no fractional read timeout, so read the terminal
# non-blocking with stty instead.
flush_keys() {
  [[ -t 0 ]] || return 0
  local saved; saved=$(stty -g)
  stty -icanon -echo min 0 time 0
  while [[ -n "$(dd bs=256 count=1 2>/dev/null)" ]]; do :; done
  stty "${saved}"
}

banner() {
  clear
  echo
  echo "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
  echo "${BOLD}${CYAN}  $*${RESET}"
  echo "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
  (( DEMO_RECORDING )) && echo "${DIM}  recorded run · $(date '+%a %d %b %Y, %H:%M %Z')${RESET}"
  echo
}

beat()      { echo "${BOLD}${YELLOW}▸ $*${RESET}"; }
note()      { echo "${DIM}  $*${RESET}"; }
# A speaker line, with --notes: folded to fit a projector, continuation lines
# indented under the first.
say() {
  (( NOTES )) || return 0
  echo "$*" | fold -s -w 92 | awk -v c="${MAGENTA}" -v r="${RESET}" '{ printf "%s%s%s%s\n", c, (NR == 1 ? "🗣  " : "    "), $0, r }'
}
ok()        { echo "  ${GREEN}✔${RESET} $*"; }
bad()       { echo "  ${RED}✘${RESET} $*"; }
warn()      { echo "  ${YELLOW}!${RESET} $*"; }
echo_cmd()  { echo "${BOLD}${CYAN}\$ $*${RESET}"; }
punchline() { echo; echo "${BOLD}${GREEN}💡 $*${RESET}"; echo; }

# Show a kubectl command as the audience would type it, then run it.
kshow() { echo_cmd "kubectl $*"; k "$@" | no_composition; }

# Drop the COMPOSITION column from a kubectl table: every Modelplane kind prints
# it, it says the same on every row, and it costs about 30 columns.
no_composition() {
  # Each table's header is its first line, or the first after a blank one.
  awk '(NR == 1 || prev == "") { s = index($0, "COMPOSITION")
         if (s) e = match(substr($0, s), /^COMPOSITION +/) ? s + RLENGTH : length($0) + 1 }
       { print (s ? substr($0, 1, s - 1) substr($0, e) : $0); prev = $0 }'
}

# Color YAML keys.
yaml_view() { sed -E "s/^( *)(- )?([A-Za-z0-9._/-]+):( |\$)/\1\2${CYAN}\3${RESET}:\4/"; }

# wait_for SECS "label" check_fn: spinner with elapsed time; 0 on success.
wait_for() {
  local timeout="$1" label="$2" check="$3" i=0 start=$SECONDS
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  while (( SECONDS - start < timeout )); do
    if "${check}"; then
      printf "\r\033[K  ${GREEN}✔${RESET} %s ${DIM}(%ss)${RESET}\n" "${label}" "$(( SECONDS - start ))"
      return 0
    fi
    printf "\r\033[K  ${CYAN}%s${RESET} %s ${DIM}%ss${RESET}" "${frames[$(( i % 10 ))]}" "${label}" "$(( SECONDS - start ))"
    i=$(( i + 1 ))
    sleep 1
  done
  printf "\r\033[K  ${RED}✘${RESET} %s ${DIM}(timed out after %ss)${RESET}\n" "${label}" "${timeout}"
  return 1
}

die() { echo "${RED}error:${RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# State queries
# ---------------------------------------------------------------------------

cond() { k get "$1" "${@:3}" -o json 2>/dev/null | jq -r --arg t "$2" '.status.conditions[]? | select(.type==$t) | .status'; }
md_json() { k -n "${NAMESPACE}" get modeldeployment "${MD}" -o json 2>/dev/null; }
md_ready_replicas() { md_json | jq -r '.status.replicas.ready // 0'; }
md_replicas() { md_json | jq -r '.spec.replicas // 0'; }
replica_count() { k -n "${NAMESPACE}" get modelreplica -l "modelplane.ai/deployment=${MD}" --no-headers 2>/dev/null | wc -l | tr -d ' '; }
# The clusters this deployment's replicas run on, one per line.
replica_clusters() { k -n "${NAMESPACE}" get modelreplica -l "modelplane.ai/deployment=${MD}" -o jsonpath='{range .items[*]}{.spec.clusterName}{"\n"}{end}' 2>/dev/null; }
gateway_cluster() { k get inferencegateway "${GATEWAY}" -o jsonpath='{.spec.clusterName}'; }
eu_clusters() { k get inferencecluster -l jurisdiction=eu -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'; }
eu_cluster_count() { eu_clusters | grep -c . || true; }
model_name() { k -n "${NAMESPACE}" get modelservice "${MD}" -o jsonpath='{.status.model}' 2>/dev/null; }

gateway_url() {
  [[ -n "${GATEWAY_URL}" ]] && { echo "${GATEWAY_URL}"; return; }
  k get inferencegateway "${GATEWAY}" -o jsonpath='{.status.endpoints.openAI}'
}

# A caller's API key, by caller name. API_KEY overrides the demo caller's.
api_key_for() {
  [[ "$1" == "${KEY_NAME}" && -n "${API_KEY:-}" ]] && { echo "${API_KEY}"; return; }
  [[ -s "${SECRETS}/api-key-$1" ]] && { cat "${SECRETS}/api-key-$1"; return; }
  k -n modelplane-system get secret "${KEY_SECRET}" -o json | jq -r --arg n "$1" '.data[$n] // empty | @base64d'
}
api_key() { api_key_for "${KEY_NAME}"; }

CURL_OPTS=(-sS -m 120)
(( INSECURE )) && CURL_OPTS+=(-k)
gw() { curl "${CURL_OPTS[@]}" "$@"; }

md_ready()        { [[ "$(md_ready_replicas)" -ge "$(md_replicas)" && "$(md_replicas)" -ge 1 ]]; }
md_parked()       { [[ "$(replica_count)" == 0 ]]; }
md_two_ready()    { [[ "$(md_ready_replicas)" -ge 2 ]]; }
md_two_clusters() { [[ "$(replica_clusters | sort -u | grep -c .)" -ge 2 ]]; }
svc_ready()       { [[ "$(cond modelservice Ready "${MD}" -n "${NAMESPACE}")" == True ]]; }

# Engine pods Ready on workload cluster $1. The ModelDeployment can report Ready
# before its pods are (issue #497), so the beats check the pods themselves.
pods_ready_on() {
  wk "$1" get pods -A -l "modelplane.ai/deployment=${MD}" -o json 2>/dev/null |
    jq '[.items[] | select(.metadata.name | test("epp") | not)
         | select((.status.containerStatuses // []) | length > 0 and all(.ready))] | length'
}
# Every cluster with a replica has a Ready engine pod.
all_replicas_serving() {
  local c n=0
  for c in $(replica_clusters | sort -u); do
    [[ "$(pods_ready_on "${c}")" -ge 1 ]] || return 1
    n=$(( n + 1 ))
  done
  (( n >= 1 ))
}
two_serving() { md_two_clusters && all_replicas_serving; }
md_ready_and_serving() { [[ "$(replica_count)" == "$(md_replicas)" ]] && md_ready && all_replicas_serving; }
# Every ModelReplica of the deployment reports Ready.
replicas_all_ready() {
  k -n "${NAMESPACE}" get modelreplica -l "modelplane.ai/deployment=${MD}" -o json 2>/dev/null |
    jq -e '(.items | length) > 0 and all(.items[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))' >/dev/null
}
# A replica on every EU cluster.
replicas_everywhere() { [[ "$(replica_clusters | sort -u | grep -c .)" -ge "$(eu_cluster_count)" ]]; }
engine_image() { md_json | jq -r '.spec.template.spec.engines[0].members[0].template.spec.containers[0].image // empty'; }
# Whether a node of workload cluster $1 already holds image $2, so a replica
# placed there starts without pulling it first (issue #341).
image_on() {
  wk "$1" get nodes -o json 2>/dev/null |
    jq -e --arg i "$2" '[.items[].status.images[]?.names[]?] | any(. == $i or endswith("/" + $i))' >/dev/null
}
# A cluster with a replica that isn't the gateway's, else the first with one.
other_replica_cluster() {
  local g; g=$(gateway_cluster)
  { replica_clusters | grep -vx "${g}" || replica_clusters; } | head -1
}
all_eu_ready() {
  local total ready
  total=$(eu_cluster_count)
  ready=$(k get inferencecluster -l jurisdiction=eu -o json | jq '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length')
  (( total > 0 && ready == total ))
}
gw_answers() {
  local url; url=$(gateway_url 2>/dev/null || true)
  [[ -n "${url}" && "$(gw -o /dev/null -w '%{http_code}' "${url}/models" -H "Authorization: Bearer $(api_key)" 2>/dev/null)" == 200 ]]
}

# The JSON body of a chat completion: chat_body PROMPT MAX_TOKENS [stream].
# Built once and used both to show the request and to send it, so what's on
# screen is what's sent.
chat_body() {
  jq -cn --arg m "$(model_name)" --arg p "$1" --argjson n "$2" --arg s "${3:-}" \
    '{model: $m} + (if $s == "stream" then {stream: true} else {} end)
     + {max_tokens: $n, messages: [{role: "user", content: $p}]}'
}

# Show a request to the gateway as a curl command someone could type: one
# option per line, the API key masked, one body field per line.
# show_curl PATH [BODY] [nokey]
show_curl() {
  local path="$1" body="${2:-}" auth="${3:-key}" first="curl" lines=() i
  (( INSECURE )) && first+=" -k"
  [[ -n "${body}" && "$(jq -r '.stream // false' <<<"${body}")" == true ]] && first+=" -N"
  lines+=("${first} $(gateway_url)${path}")
  [[ "${auth}" == key ]] && lines+=("-H 'Authorization: Bearer sk-…'")
  if [[ -n "${body}" ]]; then
    lines+=("-H 'Content-Type: application/json'" "-d '{")
    while IFS= read -r i; do lines+=("  ${i}"); done < <(jq -r '
      def show: if type == "object" then "{" + (to_entries | map("\(.key | tojson): \(.value | show)") | join(", ")) + "}"
                elif type == "array" then "[" + (map(show) | join(", ")) + "]"
                else tojson end;
      to_entries | map("\(.key | tojson): \(.value | show)") | join(",\n")' <<<"${body}")
    lines+=("}'")
  fi
  # Shell continuations between options; the body's lines are inside quotes.
  local n=${#lines[@]} quoted=0 line
  for (( i = 0; i < n; i++ )); do
    line="${lines[i]}"
    (( i == 0 )) && line="\$ ${line}" || line="    ${line}"
    if (( ! quoted && i < n - 1 )) && [[ "${lines[i]}" != "-d '{" ]]; then line+=" \\"; fi
    [[ "${lines[i]}" == "-d '{" ]] && quoted=1
    echo "${BOLD}${CYAN}${line}${RESET}"
  done
}

# Stream a chat completion from a chat_body, printing tokens as they arrive. If
# the gateway answers with an error instead of a stream, show it and fail.
stream_chat() {
  local raw; raw=$(mktemp "${RUN}/stream.XXXXXX")
  { gw -N "$(gateway_url)/chat/completions" -w '\nHTTP %{http_code}\n' \
      -H "Authorization: Bearer $(api_key)" -H "Content-Type: application/json" -d "$1" || true; } |
    tee "${raw}" | sed -un 's/^data: //p' | { grep --line-buffered -v '^\[DONE\]' || true; } |
    jq --unbuffered -rj '.choices[0].delta.content // empty' | fold -s -w 64 | sed 's/^/    /'
  echo
  if ! grep -q '^data: ' "${raw}"; then
    bad "no stream: $(grep -o 'HTTP [0-9]*$' "${raw}" | tail -1) $(head -c 160 "${raw}" | tr '\n' ' ')"
    rm -f "${raw}"; return 1
  fi
  rm -f "${raw}"
}

# The short request the resilience and drain steps send.
ping_body() { chat_body "ping" 16; }

# One request, short: prints the HTTP status code.
one_request() {
  gw -o /dev/null -w '%{http_code}' "$(gateway_url)/chat/completions" \
    -H "Authorization: Bearer $(api_key)" -H "Content-Type: application/json" \
    -d "$(ping_body)" 2>/dev/null || echo 000
}

# A replica entering or leaving the gateway's routes makes it answer HTTP 500
# for a few seconds while its ext-proc reloads (issue #531). Before a step whose
# requests are the point, wait until three in a row succeed, and say on screen
# how many failed meanwhile.
SETTLE_FAILS=0
gw_settled() {
  local i
  for i in 1 2 3; do
    [[ "$(one_request)" == 200 ]] || { SETTLE_FAILS=$(( SETTLE_FAILS + 1 )); return 1; }
  done
}
settle_gateway() {
  SETTLE_FAILS=0
  wait_for 120 "gateway routes settled" gw_settled || return 1
  (( SETTLE_FAILS == 0 )) || note "${SETTLE_FAILS} request(s) failed while the routes changed (issue #531)"
}

# ---------------------------------------------------------------------------
# up / down / reset / status
# ---------------------------------------------------------------------------

cmd_up() {
  local t0; t0=$(now)
  for t in docker kubectl helm kind jq yq az crossplane; do
    command -v "$t" >/dev/null || die "'$t' not found in PATH"
  done
  beat "Control plane (kind), credentials, A100 on AKS and L40S on Nebius (~25 min)"
  make -C "${DIR}" control-plane credentials nebius-credentials
  k apply -k "${DIR}/platform"
  wait_for 2400 "both EU clusters Ready" all_eu_ready || die "clusters not up; make status"
  beat "Gateway caller, EU policy, workloads, oversight RBAC, monitoring"
  make -C "${DIR}" callers policy workloads oversight kubeconfig monitoring grafana
  wait_for 1800 "model Ready" md_ready || die "model not Ready; ./demo.sh status"
  wait_for 600 "service routable" svc_ready || die "service not routable"
  cmd_prewarm
  echo "${BOLD}${GREEN}✔ up in $(since "${t0}")s${RESET}"
}

# Run a replica on every EU cluster once, then return to the start state. Each
# GPU node then holds the engine image and each cluster's cache is staged, so
# the scale beat's new replica loads the model instead of pulling a multi-GB
# image on stage (issue #341).
cmd_prewarm() {
  local t0 n; t0=$(now); n=$(eu_cluster_count)
  beat "Prewarm: a replica on each of ${n} EU clusters, then back to one"
  k -n "${NAMESPACE}" scale modeldeployment "${MD}" --replicas="${n}" >/dev/null
  wait_for 600 "a replica on every cluster" replicas_everywhere || die "not placed everywhere: is a cluster tainted or full?"
  wait_for 1800 "every engine serving" all_replicas_serving || die "an engine didn't start; ./demo.sh status"
  ok "every GPU node has run the engine ${DIM}($(since "${t0}")s)${RESET}"
  cmd_reset
}

cmd_down() {
  read -r -p "${YELLOW}Delete both GPU clusters (AKS and Nebius) and the kind control plane? [y/N] ${RESET}" ans
  [[ "${ans}" == y || "${ans}" == Y ]] || exit 0
  cmd_undrain_all
  make -C "${DIR}" destroy destroy-control-plane
}

# Remove the demo's drain taint from every cluster.
cmd_undrain_all() {
  local c
  for c in $(eu_clusters); do remove_drain_taint "${c}"; done
}

# The drain taint goes on and off by JSON patch, touching only the demo's own
# entry: never server-side apply, which on a cluster created by a plain
# `kubectl apply` would take over every field it was created with.
DRAIN_TAINT="{\"key\": \"${DRAIN_KEY}\", \"effect\": \"NoExecute\"}"
add_drain_taint_patch() {
  if k get inferencecluster "$1" -o json | jq -e '.spec.taints' >/dev/null; then
    echo "[{\"op\": \"add\", \"path\": \"/spec/taints/-\", \"value\": ${DRAIN_TAINT}}]"
  else
    echo "[{\"op\": \"add\", \"path\": \"/spec/taints\", \"value\": [${DRAIN_TAINT}]}]"
  fi
}
add_drain_taint() {
  k patch inferencecluster "$1" --type json --field-manager="${FIELD_MANAGER}" -p "$(add_drain_taint_patch "$1")" >/dev/null
}
# The patch that removes the demo's taint from cluster $1, or nothing if it has
# none. It tests the entry's key first, so it can't remove anyone else's.
remove_drain_taint_patch() {
  local i
  i=$(k get inferencecluster "$1" -o json | jq --arg k "${DRAIN_KEY}" '[.spec.taints // [] | to_entries[] | select(.value.key == $k) | .key][0] // empty')
  [[ -n "${i}" ]] || return 0
  echo "[{\"op\": \"test\", \"path\": \"/spec/taints/${i}/key\", \"value\": \"${DRAIN_KEY}\"}, {\"op\": \"remove\", \"path\": \"/spec/taints/${i}\"}]"
}
remove_drain_taint() {
  local patch; patch=$(remove_drain_taint_patch "$1")
  [[ -n "${patch}" ]] || return 0
  k patch inferencecluster "$1" --type json --field-manager="${FIELD_MANAGER}" -p "${patch}" >/dev/null
}

cmd_reset() {
  local t0; t0=$(now)
  beat "Reset"
  cmd_undrain_all
  k -n "${NAMESPACE}" scale modeldeployment "${MD}" --replicas=1 >/dev/null
  one_replica() { [[ "$(replica_count)" == 1 ]]; }
  wait_for 300 "extra replicas removed" one_replica || die "still more than one replica"
  wait_for 900 "one replica Ready" md_ready || die "model not Ready"
  wait_for 900 "its engine serving" all_replicas_serving || die "engine pod not Ready"
  wait_for 300 "service routable" svc_ready || die "service not routable"
  ok "start state: ${MD} at 1 replica, no drain taint ${DIM}($(since "${t0}")s)${RESET}"
}

# Preflight checklist. Non-zero if anything critical is off; 2 if only the
# start state is off.
cmd_status() {
  local fail=0
  echo "  ${DIM}control plane ${CONTEXT} · namespace ${NAMESPACE}${RESET}"
  if k get --raw /readyz >/dev/null 2>&1; then ok "control plane reachable"; else bad "control plane ${CONTEXT} not reachable"; return 1; fi
  if [[ "$(cond configuration Healthy modelplane)" == True ]]; then
    ok "Modelplane $(k get configuration modelplane -o jsonpath='{.spec.package}' | sed 's/.*://') healthy"
  else bad "Modelplane Configuration not healthy"; fail=1; fi
  local ready total
  total=$(eu_cluster_count); ready=$(k get inferencecluster -l jurisdiction=eu -o json | jq '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length')
  if (( total > 0 && ready == total )); then ok "${ready} EU InferenceCluster(s) Ready"; else bad "${ready}/${total} EU InferenceClusters Ready"; fail=1; fi
  # A resource that isn't Synced shows up in the Fleet beat's trace. Usually
  # transient (Azure refuses an update while another is running), so warn only.
  local c stale
  for c in $(eu_clusters); do
    stale=$(crossplane resource trace "inferencecluster/${c}" --context "${CONTEXT}" -o json 2>/dev/null |
      jq -r '[.. | objects | select(has("object")) | .object
        | select(([.status.conditions[]? | select(.type=="Synced")][0].status // "True") == "False")
        | "\(.kind)/\(.metadata.name)"] | join(", ")')
    if [[ -z "${stale}" ]]; then ok "${c}: everything it composed is Synced"
    else warn "${c}: not Synced yet: ${stale} (the Fleet trace will show it)"; fi
  done
  if [[ "$(cond inferencegateway Ready "${GATEWAY}")" == True ]]; then ok "gateway ${GATEWAY} Ready"; else bad "gateway ${GATEWAY} not Ready"; fail=1; fi
  if [[ "$(cond modelcache Ready "${MD}" -n "${NAMESPACE}")" == True ]]; then ok "cache staged: $(k -n "${NAMESPACE}" get modelcache "${MD}" -o jsonpath='{.status.summary.ready}')"; else bad "cache ${MD} not staged"; fail=1; fi
  if md_ready; then ok "model ${NAMESPACE}/${MD}: $(md_ready_replicas)/$(md_replicas) ready"; else bad "model not ready"; fail=1; fi
  if k get validatingadmissionpolicy eu-only-model-deployments >/dev/null 2>&1; then ok "EU policy installed"; else bad "EU policy missing (make policy)"; fail=1; fi
  if k -n "${NAMESPACE}" get rolebinding gitops-edit >/dev/null 2>&1; then ok "oversight: the team views, the pipeline edits"; else bad "oversight RBAC missing (make oversight)"; fail=1; fi
  if [[ -n "$(api_key 2>/dev/null)" ]]; then ok "API key (${KEY_SECRET}/${KEY_NAME})"; else bad "no API key"; fail=1; fi
  if gw_answers; then ok "gateway answers at $(gateway_url)"; else bad "gateway not answering$(gateway_url 2>/dev/null | sed 's/^./ at &/' || true)"; fail=1; fi
  local img; img=$(engine_image || true)
  for c in $(eu_clusters); do
    if ! wk "${c}" get --raw /readyz >/dev/null 2>&1; then bad "workload cluster ${c} not reachable (make kubeconfig)"; continue; fi
    ok "workload cluster ${c} reachable"
    if [[ -n "${img}" ]] && ! image_on "${c}" "${img}"; then
      warn "${c}: ${img} not pulled yet, so a replica there takes minutes (./demo.sh prewarm)"
    fi
  done
  if (( total == 1 )); then
    warn "one EU cluster: the scale, resilience and drain steps fall back to single-cluster variants"
  fi
  # The last beat. Warnings, so a rehearsal without monitoring still runs.
  if k get telemetrydestination fleet-prometheus >/dev/null 2>&1; then
    local seen; seen=$(prom_rows 'count by (cluster) ({__name__=~"modelplane_.+"})' cluster | grep -c . || true)
    if (( seen >= total )); then ok "fleet Prometheus has metrics from ${seen} cluster(s)"
    else warn "fleet Prometheus has metrics from ${seen} of ${total} clusters"; fi
  else
    warn "no TelemetryDestination fleet-prometheus, so the monitor beat stops (make monitoring)"
  fi
  if curl -sf http://127.0.0.1:3000/api/health >/dev/null 2>&1; then ok "Grafana at ${GRAFANA_URL}"
  else warn "Grafana not running (make grafana)"; fi
  if (( fail == 0 )) && [[ "$(md_replicas)" != 1 || -n "$(k get inferencecluster -o json | jq -r --arg k "${DRAIN_KEY}" '.items[].spec.taints[]? | select(.key==$k) | .key')" ]]; then
    bad "not at start state (replicas=$(md_replicas), or a drain taint)"; fail=2
  fi
  return "${fail}"
}

# ---------------------------------------------------------------------------
# The ten beats, in the deck's order
# ---------------------------------------------------------------------------

# The cluster the DRA beat looks at: the gateway's if it runs a replica (in the
# start state it does), else the first one that does.
dra_cluster() {
  local g c; g=$(gateway_cluster)
  if replica_clusters | grep -qx "${g}"; then echo "${g}"; return; fi
  c=$(replica_clusters | head -1); echo "${c:-$(eu_clusters | head -1)}"
}

beat_dra() {
  banner "1 · DRA"
  say "Before DRA, a GPU is a node label and a count: you can ask for one GPU, not for one with at least 14 GiB."
  say "With DRA the driver publishes every device with typed attributes, and a pod claims one by what it is, in CEL."
  local c; c=$(dra_cluster)
  beat "Before DRA: the node carries a label, the pod asks for a count"
  show_cmd "kubectl $(wk_flag "${c}") get nodes" \
    "-l nvidia.com/gpu.present=true -L nvidia.com/gpu.product"
  wk "${c}" get nodes -l nvidia.com/gpu.present=true \
    -o custom-columns='NAME:.metadata.name,GPU.PRODUCT:.metadata.labels.nvidia\.com/gpu\.product' | sed 's/^/  /'
  echo
  pause
  beat "With DRA: the driver publishes each device"
  echo_cmd "kubectl $(wk_flag "${c}") get resourceslices -o yaml"
  note "the GPU driver's slice, abridged:"
  # resource.k8s.io/v1 puts attributes on the device; v1beta1 under .basic.
  wk "${c}" get resourceslices -o json | jq '[.items[] | select(.spec.driver == "gpu.nvidia.com")][0]
    | {spec: {driver: .spec.driver, nodeName: .spec.nodeName,
        devices: [.spec.devices[0] | {name,
          attributes: ((.attributes // .basic.attributes // {}) | with_entries(select(.key | test("productName|architecture|cudaComputeCapability")))),
          capacity: ((.capacity // .basic.capacity // {}) | with_entries(select(.key == "memory")))}]}}' |
    yq -P | yaml_view | sed 's/^/  /'
  echo
  pause
  beat "The engine pod claims a device by what it is"
  local claim; claim=$(wk "${c}" get resourceclaims -A -o json | jq -r '[.items[] | select(.status.allocation)][0] | "\(.metadata.namespace)/\(.metadata.name)"')
  show_cmd "kubectl $(wk_flag "${c}")" "-n ${claim%%/*} get resourceclaim" "${claim#*/} -o yaml"
  wk "${c}" -n "${claim%%/*}" get resourceclaim "${claim#*/}" -o json | jq '
    .spec.devices.requests[0] as $r | ($r.exactly // $r) as $x
    | {spec: {request: {deviceClassName: $x.deviceClassName, selectors: [$x.selectors[]?.cel.expression]}},
       status: {allocated: [.status.allocation.devices.results[]? | {driver, pool, device}]}}' |
    yq -P | yaml_view | sed 's/^/  /'
  echo
  pause
  beat "Modelplane checks the same CEL one level up, against each InferenceClass"
  local cls; cls=$(k get inferencecluster "${c}" -o jsonpath='{.spec.nodePools[0].className}')
  echo_cmd "kubectl get inferenceclass ${cls} -o yaml"
  k get inferenceclass "${cls}" -o json | jq '{spec: {devices: [.spec.devices[] | {name, claim, driver, attributes, capacity}]}}' |
    yq -P | yaml_view | sed 's/^/  /'
  note "The deployment's selector: $(md_json | jq -r '.spec.template.spec.engines[0].members[0].nodeSelector.devices[0].selectors[0].cel' | tr -d '\n')"
  punchline "The same CEL decides twice: Modelplane picks the cluster and pool, DRA binds the GPU."
}

beat_fleet() {
  banner "2 · Fleet"
  say "Every GPU cluster is one Kubernetes object on the control plane, labelled with where it is and which jurisdiction it belongs to."
  say "Modelplane built both: the AKS cluster in Sweden Central and the Nebius cluster in Finland, each with its GPU pool and serving stack."
  beat "The hardware on offer: one InferenceClass per kind of node pool"
  show_cmd "kubectl get inferenceclass" \
    "-o custom-columns=NAME:.metadata.name,DESCRIPTION:.spec.description,MEMORY:.spec.devices[0].capacity.memory.value"
  k get inferenceclass -o custom-columns='NAME:.metadata.name,DESCRIPTION:.spec.description,MEMORY:.spec.devices[0].capacity.memory.value' | sed 's/^/  /'
  echo
  beat "The clusters that offer it"
  kshow get inferencecluster -L modelplane.ai/region,jurisdiction
  note "GATEWAY is each cluster's own mTLS entry point: the front door reaches its replicas through it."
  echo
  pause
  local c; c=$(k get inferencecluster -o json | jq -r '[.items[] | select(.spec.cluster.source=="AKS")][0].metadata.name')
  beat "What one object became in Azure"
  echo_cmd "crossplane resource trace inferencecluster/${c}"
  # Piped: on a TTY the CLI queries the terminal's colors.
  crossplane resource trace "inferencecluster/${c}" --context "${CONTEXT}" 2>/dev/null |
    grep -v -E "^NAME|ManagedResourceActivationPolicy|ProviderConfig/" |
    sed -E 's/ \([a-z0-9-]+\)//; s/^(.*[^ ]) {2,}(True|False|-) {2,}(True|False|-) *(.*)$/\1\t\2\t\3\t\4/' |
    python3 -c '
import sys
fmt = "  %-66s %-7s %-6s %s"
r = o = 0; stack = False
print(fmt % ("NAME", "SYNCED", "READY", "STATUS"))
for line in sys.stdin:
    if "\t" not in line:  # the rest of a multi-line status message
        continue
    n, a, b, c = (line.rstrip("\n").split("\t") + ["", "", ""])[:4]
    if stack:
        r += "Release/" in n; o += "Object/" in n
        continue
    stack = "ServingStack/" in n
    print(fmt % (n if len(n) <= 65 else n[:64] + "…", a, b, c))
print("  │  └─ … %d Helm releases, %d objects: the serving stack" % (r, o))'
  if k -n modelplane-system get kubernetescluster.containerservice.azure.m.upbound.io -o json | jq -e '[.items[].metadata.annotations["crossplane.io/paused"]] | any(. == "true")' >/dev/null 2>&1; then
    note "(ReconcilePaused: the workaround for the AKS node pool update loop, README)"
  fi
  echo
  pause
  beat "The front door, on ${DIM}$(gateway_cluster)${RESET}${BOLD}${YELLOW}: one per place requests enter"
  kshow get inferencegateway
  note "It serves ModelServices labelled $(k get inferencegateway "${GATEWAY}" -o json | jq -r '.spec.serviceSelector.matchLabels // {} | to_entries | map("\(.key)=\(.value)") | join(",") | if . == "" then "(any)" else . end')."
  punchline "The platform team is done: capacity is published once, on two providers. ML teams self-serve from here."
}

beat_scale() {
  banner "5 · Scale"
  say "Replicas are the scaling axis, and each one is a whole serving instance, placed on its own."
  say "The scheduler spreads before it packs: a new replica goes to the eligible cluster with the fewest of this model's replicas."
  kshow -n "${NAMESPACE}" get modelreplica -l "modelplane.ai/deployment=${MD}"
  echo
  if (( $(eu_cluster_count) < 2 )); then
    note "One EU cluster up: the second replica has nowhere to spread to, so this step is skipped."
    return 0
  fi
  pause
  beat "Scale out: one more replica"
  local before; before=$(replica_clusters | sort -u)
  kshow -n "${NAMESPACE}" scale modeldeployment "${MD}" --replicas=2
  wait_for 300 "second replica placed" md_two_clusters || return 1
  kshow -n "${NAMESPACE}" get modelreplica -l "modelplane.ai/deployment=${MD}"
  local new; new=$(comm -13 <(echo "${before}") <(replica_clusters | sort -u) | head -1)
  new=${new:-$(other_replica_cluster)}
  # The engine's pod, not the deployment's Ready, says it can serve (issue #497).
  # A fresh node pulls the engine image first (issue #341), so allow minutes.
  serving_new() { [[ "$(pods_ready_on "${new}")" -ge 1 ]]; }
  wait_for 1200 "engine serving on ${new}" serving_new || return 1
  wait_for 300 "routable at the gateway" svc_ready || return 1
  settle_gateway || return 1
  show_curl /chat/completions "$(ping_body)"
  [[ "$(one_request)" == 200 ]] && ok "the gateway answers, with a replica on each cluster behind it" || bad "request failed"
  punchline "Scaling is one field. The new replica landed on the other provider."
}

beat_call() {
  banner "6 · Call"
  say "Callers see one endpoint that speaks the OpenAI and Anthropic APIs. They name a model, never a cluster."
  say "Every caller needs an API key; the gateway stamps who called on every request."
  kshow get inferencegateway "${GATEWAY}"
  kshow -n "${NAMESPACE}" get modelservice "${MD}"
  echo
  local url; url=$(gateway_url)
  beat "No key, no model"
  show_curl /models "" nokey
  echo "  ${RED}HTTP $(gw -o /dev/null -w '%{http_code}' "${url}/models")${RESET}"
  echo
  beat "With a key"
  show_curl /models
  gw "${url}/models" -H "Authorization: Bearer $(api_key)" | jq -r '.data[] | "  \(.id)"'
  echo
  pause
  beat "A chat completion, streamed"
  # The whole request is on screen, prompt included, so the answer reads as
  # the model's reply to it rather than as our description of the product.
  local body; body=$(chat_body "In two sentences, what does an inference gateway do?" 80 stream)
  show_curl /chat/completions "${body}"
  stream_chat "${body}" || return 1
  punchline "One OpenAI-compatible endpoint. Callers never see a cluster."
}

beat_cache() {
  banner "3 · Warm cache"
  say "The weights are staged once per EU cluster on shared storage, by a CPU job, not on a GPU."
  say "Scale the model to zero and the GPU is released; the weights stay. Scaling back skips the download."
  kshow -n "${NAMESPACE}" get modelcache "${MD}"
  echo
  local c; c=$(replica_clusters | head -1); c=${c:-$(eu_clusters | head -1)}
  beat "On ${c}: a ReadWriteMany volume the serving stack provides"
  show_cmd "kubectl $(wk_flag "${c}") get pvc -A"
  wk "${c}" get pvc -A -o json 2>/dev/null |
    jq -r '["NAMESPACE", "NAME", "STATUS", "SIZE", "ACCESS", "CLASS"],
      (.items[] | select(.metadata.name | test("modelcache"))
       | [.metadata.namespace, .metadata.name, .status.phase, .status.capacity.storage, .spec.accessModes[0], .spec.storageClassName]) | @tsv' |
    column -t -s $'\t' | sed 's/^/  /'
  echo
  pause
  beat "Park: scale to zero"
  kshow -n "${NAMESPACE}" scale modeldeployment "${MD}" --replicas=0
  wait_for 300 "replica gone, GPU released" md_parked || return 1
  kshow -n "${NAMESPACE}" get modelcache "${MD}"
  echo
  pause
  beat "Resume from the warm cache"
  local t; t=$(now)
  kshow -n "${NAMESPACE}" scale modeldeployment "${MD}" --replicas=1
  wait_for 900 "replica Ready" md_ready || return 1
  wait_for 900 "engine serving" all_replicas_serving || return 1
  wait_for 300 "routable at the gateway" svc_ready || return 1
  ok "back from zero in $(since "${t}")s, from the warm cache"
  note "The GPU node itself stays up: the cluster autoscaler can't yet scale a GPU pool up from zero for DRA pods."
  punchline "Scale to zero frees the GPU. The weights stay warm."
}

beat_resilience() {
  banner "7 · Resilience"
  say "Replicas spread across every eligible cluster. The gateway retries a failed request on another replica and ejects one that keeps failing."
  if (( $(eu_cluster_count) < 2 )); then
    say "Only one GPU cluster is up, so here's the policy rather than the failover itself."
    beat "One GPU cluster here: the failover policy the gateway runs"
    local gc btp; gc=$(gateway_cluster)
    btp=$(wk "${gc}" get backendtrafficpolicy -n modelplane-system -o json | jq -r '[.items[] | select(.spec.retry)][0].metadata.name')
    show_cmd "kubectl $(wk_flag "${gc}")" \
      "-n modelplane-system get backendtrafficpolicy ${btp} -o yaml"
    note "its spec's retry and passive health check:"
    wk "${gc}" get backendtrafficpolicy "${btp}" -n modelplane-system -o json |
      jq '{retry: .spec.retry, passiveHealthCheck: .spec.healthCheck.passive}' |
      yq -P | yaml_view | sed 's/^/  /'
    punchline "Retries and ejection are on by default. Add a second cluster and they span regions."
    return 0
  fi
  if (( $(md_replicas) < 2 )); then
    beat "Scale to two replicas"
    kshow -n "${NAMESPACE}" scale modeldeployment "${MD}" --replicas=2
  fi
  wait_for 1200 "a replica serving on each cluster" two_serving || return 1
  # Their Ready lags the pods, so the table below would contradict the line above.
  wait_for 180 "both replicas report Ready" replicas_all_ready || true
  settle_gateway || return 1
  kshow -n "${NAMESPACE}" get modelreplica -l "modelplane.ai/deployment=${MD}"
  echo
  pause
  beat "Fail over: stop one replica while requests run"
  note "20 of these, one a second:"
  show_curl /chat/completions "$(ping_body)"
  local victim_cluster victim ns
  victim_cluster=$(other_replica_cluster)
  ns=$(wk "${victim_cluster}" get pods -A -l "modelplane.ai/deployment=${MD}" -o jsonpath='{.items[0].metadata.namespace}')
  victim=$(wk "${victim_cluster}" get pods -n "${ns}" -l "modelplane.ai/deployment=${MD}" -o name | grep -v epp | head -1)
  local codes="" i
  for i in $(seq 1 20); do
    if (( i == 5 )); then
      echo; show_cmd "kubectl $(wk_flag "${victim_cluster}")" "-n ${ns} delete ${victim} --wait=false"
      wk "${victim_cluster}" -n "${ns}" delete "${victim}" --wait=false >/dev/null
    fi
    local code; code=$(one_request)
    codes+="${code} "
    [[ "${code}" == 200 ]] && printf "${GREEN}●${RESET}" || printf "${RED}●${RESET}"
    sleep 1
  done
  echo
  local fails=0 c; for c in ${codes}; do [[ "${c}" == 200 ]] || fails=$(( fails + 1 )); done
  (( fails == 0 )) && ok "20 requests, all 200" || bad "${fails} of 20 failed"
  note "The deleted pod comes back on its own; the next beat waits for it."
  punchline "Lose a replica, keep serving: the gateway retries on the other provider."
}

ROLLOUT_FILE="examples/rollout-qwen-7b-v2.yaml"

beat_lifecycle() {
  banner "8 · Lifecycle"
  say "Every event in the table is an edit to an object, so it goes through Git and the API like any other change."
  (( DRAIN )) && say "Maintenance is a field, not a runbook: a NoExecute taint moves the replicas off a cluster."
  say "Modelplane refuses to delete a cluster something still runs on, and says what."
  # The cluster to drain and retire: one with a replica that isn't the gateway's.
  local c; c=$(other_replica_cluster)
  beat "New weights, engine or config: a second deployment, then shift weight here"
  echo_cmd "kubectl -n ${NAMESPACE} get modelservice ${MD} -o yaml"
  k -n "${NAMESPACE}" get modelservice "${MD}" -o json |
    yq -P '{"spec": {"endpoints": [.spec.endpoints[] | {"name": .name, "weight": .weight, "selector": .selector}]}}' |
    yaml_view | sed 's/^/  /'
  echo
  beat "The rollout is one file: the new deployment and a second endpoint"
  echo "  ${DIM}from ${ROLLOUT_FILE}:${RESET}"
  echo "  ModelDeployment ${CYAN}qwen-7b-v2${RESET}: image $(yq 'select(.kind == "ModelDeployment") | .spec.template.spec.engines[0].members[0].template.spec.containers[0].image' "${DIR}/${ROLLOUT_FILE}") ${DIM}(qwen-7b runs $(md_json | jq -r '.spec.template.spec.engines[0].members[0].template.spec.containers[0].image | sub(".*:"; "")'))${RESET}"
  echo "  ModelService ${CYAN}qwen-7b${RESET}:"
  yq -o=json 'select(.kind == "ModelService")' "${DIR}/${ROLLOUT_FILE}" |
    jq -r '.spec.endpoints | (map(.weight) | add) as $t | "endpoints:",
      (.[] | "  - name: \(.name)\n    weight: \(.weight)    # \(.weight * 100 / $t | round)% of requests")' |
    yaml_view | sed "s/^/    /;s/#.*/${DIM}&${RESET}/"
  show_cmd "kubectl apply --dry-run=server" "-f ${ROLLOUT_FILE}"
  note "a server-side dry run: the API validates both and the EU policy admits qwen-7b-v2; nothing is created"
  k apply --dry-run=server -f "${DIR}/${ROLLOUT_FILE}" 2>&1 | sed 's/^/  /'
  [[ "${PIPESTATUS[0]}" == 0 ]] || { bad "the rollout was rejected"; return 1; }
  note "Shift the weights as v2 proves itself; callers keep calling ${NAMESPACE}/${MD} throughout."
  echo
  pause
  beat "Cluster upgrade: drain with a taint, change the version, remove the taint"
  echo_cmd "kubectl get inferencecluster ${c} -o yaml"
  k get inferencecluster "${c}" -o json |
    yq -P '{"spec": {"taints": (.spec.taints // []), "cluster": .spec.cluster}}' |
    yaml_view | sed 's/^/  /'
  echo
  pause
  if (( DRAIN )) && (( $(eu_cluster_count) >= 2 )); then
    wait_for 1200 "a replica serving on each cluster first" two_serving || return 1
    beat "Drain ${c}"
    show_cmd "kubectl patch inferencecluster ${c} --type json" "-p '$(add_drain_taint_patch "${c}")'"
    add_drain_taint "${c}"
    # Only off this cluster: with no free GPU elsewhere the replica isn't
    # recreated, and the deployment runs one short.
    drained() { ! replica_clusters | grep -qx "${c}"; }
    wait_for 900 "replica removed from ${c}" drained || return 1
    kshow -n "${NAMESPACE}" get modelreplica -l "modelplane.ai/deployment=${MD}"
    md_ready || note "(no other cluster has a free GPU: running one short until capacity frees up)"
    settle_gateway || return 1
    show_curl /chat/completions "$(ping_body)"
    [[ "$(one_request)" == 200 ]] && ok "the gateway still serves from the other replica" || bad "request failed during the drain"
    echo
    pause
    beat "End of maintenance: remove the taint"
    show_cmd "kubectl patch inferencecluster ${c} --type json" "-p '$(remove_drain_taint_patch "${c}")'"
    remove_drain_taint "${c}"
    ok "taint removed; a missing replica may land on ${c} again"
    echo
  fi
  beat "Retire a cluster that's still in use"
  echo_cmd "kubectl delete inferencecluster ${c} --dry-run=server"
  local why; why=$(k delete inferencecluster "${c}" --dry-run=server 2>&1 | grep -o 'with reason: "[^"]*"' | head -1 | sed 's/with reason: //;s/"//g' || true)
  if [[ -n "${why}" ]]; then
    echo "refused: ${why}" | fold -s -w 66 | sed "s/^/  ${RED}/;s/\$/${RESET}/"
  else
    bad "not refused: is anything running on ${c}?"; return 1
  fi
  punchline "Every lifecycle event is an edit to an object, and the destructive ones are guarded."
}

# The gateway's usage records on cluster $1: one JSON line per request that
# carried an API key.
usage_records() {
  wk "$1" -n envoy-gateway-system logs -l gateway.envoyproxy.io/owning-gateway-name=inference-gateway \
    --all-containers --since=30m --tail=-1 --prefix=false 2>/dev/null | { grep -h '"caller":"' || true; }
}

GRAFANA_URL="http://localhost:3000/d/modelplane-fleet"

# An instant query against the fleet Prometheus, through scripts/monitoring.sh
# (TLS and basic auth; the credential never reaches a command line). Prints one
# TSV row per series: the values of the labels named after the query, then the
# sample value.
prom_rows() {
  local q="$1"; shift
  "${DIR}/scripts/monitoring.sh" query "${q}" 2>/dev/null |
    jq -r '.data.result[] | . as $r | [($ARGS.positional[] | . as $l | ($r.metric[$l] // "-")), $r.value[1]] | @tsv' --args "$@"
}

beat_monitor() {
  banner "10 · Monitor"
  say "Modelplane ships no dashboards. Every cluster's collector exports one modelplane_* vocabulary to a backend you run."
  say "Here that's a Prometheus on the AKS cluster, and Grafana on this laptop."
  local gc; gc=$(gateway_cluster)

  beat "Where the fleet's metrics go ${DIM}(one object, on the control plane)${RESET}"
  echo_cmd "kubectl get telemetrydestination fleet-prometheus -o yaml"
  if ! k get telemetrydestination fleet-prometheus >/dev/null 2>&1; then
    bad "no TelemetryDestination fleet-prometheus: run 'make monitoring'"; return 1
  fi
  k get telemetrydestination fleet-prometheus -o json | yq -P '{"spec": (.spec | del(.crossplane))}' | yaml_view | sed 's/^/  /'
  note "Modelplane renders it into the collector on every cluster, and copies its Secret there."
  echo
  pause

  beat "Usage records from the gateway ${DIM}(one JSON line per request)${RESET}"
  local body; body=$(chat_body "Say hello in one short sentence." 20 stream)
  # Count this caller's records only: the chat-app's background traffic adds its own.
  local mine="\"caller\":\"${KEY_NAME}\""
  settle_gateway || return 1
  local n0; n0=$(usage_records "${gc}" | grep -c "${mine}" || true)
  show_curl /chat/completions "${body}"
  stream_chat "${body}" || return 1
  local sel="gateway.envoyproxy.io/owning-gateway-name=inference-gateway"
  show_cmd "kubectl $(wk_flag "${gc}") -n envoy-gateway-system" \
    "logs -l ${sel} --all-containers --since=30m --tail=-1" \
    "| grep '\"caller\":'"
  # Envoy writes its access log a few seconds after the request ends.
  local i; for i in $(seq 1 15); do
    (( $(usage_records "${gc}" | grep -c "${mine}" || true) > n0 )) && break
    sleep 1
  done
  note "the latest request from each caller, as a table:"
  printf "  ${DIM}%-14s %-18s %6s %6s %6s %8s${RESET}\n" CALLER MODEL IN OUT STATUS MS
  usage_records "${gc}" | jq -r -s 'group_by(.caller) | map(max_by(.start_time)) | sort_by(.start_time) | .[] | [.caller, .service, .input_tokens, .output_tokens, .status, .duration_ms] | @tsv' |
    while IFS=$'\t' read -r who svc in out st ms; do printf "  %-14s %-18s %6s %6s %6s %8s\n" "${who}" "${svc}" "${in}" "${out}" "${st}" "${ms}"; done
  note "Who called is a log, not a metric label: callers are unbounded (issue #535)."
  echo
  pause

  beat "Both clusters, one vocabulary, in your Prometheus"
  local prom; prom=$("${DIR}/scripts/monitoring.sh" url 2>/dev/null) || { bad "no fleet Prometheus: run 'make monitoring'"; return 1; }
  show_cmd "curl --cacert .secrets/monitoring/ca.crt -u grafana:… ${prom}/api/v1/query" \
    "--data-urlencode 'query=count by (cluster) ({__name__=~\"modelplane_.+\"})'"
  printf "  ${DIM}%-22s %s${RESET}\n" CLUSTER "MODELPLANE_* SERIES"
  prom_rows 'count by (cluster) ({__name__=~"modelplane_.+"})' cluster | sort |
    while IFS=$'\t' read -r c n; do printf "  %-22s %s\n" "${c}" "${n}"; done
  echo
  note "KV-cache use per replica, and GPU power, from the same store:"
  printf "  ${DIM}%-22s %-12s %-8s %s${RESET}\n" CLUSTER DEPLOYMENT REPLICA KV-CACHE
  prom_rows 'max by (cluster, deployment, replica) (modelplane_kv_cache_utilization_ratio)' cluster deployment replica | sort |
    while IFS=$'\t' read -r c d r v; do printf "  %-22s %-12s %-8s %s\n" "${c}" "${d}" "${r}" "$(awk -v v="${v}" 'BEGIN { printf "%.1f%%", v * 100 }')"; done
  printf "  ${DIM}%-22s %s${RESET}\n" CLUSTER "GPU POWER"
  prom_rows 'sum by (cluster) (modelplane_gpu_power_watts)' cluster | sort |
    while IFS=$'\t' read -r c v; do printf "  %-22s %s\n" "${c}" "$(awk -v v="${v}" 'BEGIN { printf "%.0f W", v }')"; done
  echo
  pause

  beat "The dashboard"
  if (( DEMO_RECORDING )); then
    note "The dashboard from this run is on the slide."
  elif curl -sf http://127.0.0.1:3000/api/health >/dev/null 2>&1; then
    ok "Grafana on this laptop: ${GRAFANA_URL}"
    { [[ -z "${AUTO_SLEEP}" ]] && command -v open >/dev/null && open "${GRAFANA_URL}"; } || true
  else
    note "Grafana isn't running: 'make grafana', then open ${GRAFANA_URL}"
  fi
  punchline "Every request leaves a record, in a backend you run."
}

# "One model, two writers": who owns which fields of the ModelDeployment.
show_writers() {
  echo_cmd "kubectl -n ${NAMESPACE} get modeldeployment ${MD} --show-managed-fields -o yaml"
  k -n "${NAMESPACE}" get modeldeployment "${MD}" --show-managed-fields -o json | jq -r '
    .metadata.managedFields[]
    | (.fieldsV1 // {}) as $f
    | ([$f | paths | select(length == 2 and .[0] == "f:spec" and .[1] != "." and .[1] != "f:crossplane") | "spec." + (.[1] | sub("^f:"; ""))]
       + (if .subresource == "status" and ($f | has("f:status")) then ["status"] else [] end)) as $fields
    | select($fields | length > 0)
    | (if (.manager | test("crossplane")) then "controller" else "person" end) as $who
    | [$who, .manager, ($fields | unique | join(", "))] | @tsv' |
  sort -u | while IFS=$'\t' read -r who mgr fields; do
    local c="${CYAN}"; [[ "${who}" == controller ]] && c="${GREEN}"
    printf "  %s%-11s%s %-38s %s\n" "${c}" "${who}" "${RESET}" "${mgr}" "${fields}"
  done
  note "With GitOps, the person's row becomes Argo CD or Flux: the pull request is the approval."
}

beat_govern() {
  banner "4 · Govern"
  say "Where a model may run is a label on the clusters and a selector on the deployment."
  say "Making it mandatory is an admission policy in the API: testable and auditable, not a wiki page."
  beat "Where this model may run"
  echo_cmd "kubectl -n ${NAMESPACE} get modeldeployment ${MD} -o yaml"
  md_json | yq -P '{"spec": {"template": {"spec": {"clusterSelector": .spec.template.spec.clusterSelector, "modelCacheRef": .spec.template.spec.modelCacheRef}}}}' | yaml_view | sed 's/^/  /'
  echo
  beat "The rule, in the API"
  echo_cmd "kubectl get validatingadmissionpolicy eu-only-model-deployments -o yaml"
  k get validatingadmissionpolicy eu-only-model-deployments -o json | jq -r '.spec.validations[0].expression | gsub(" && "; " &&\n")' |
    sed "s/^/  ${CYAN}/;s/\$/${RESET}/"
  echo
  pause
  beat "A team tries to deploy without the EU selector"
  show_cmd "kubectl -n ${NAMESPACE} apply --dry-run=server" "-f policies/test/qwen-anywhere.yaml"
  note "a server-side dry run: admission runs, nothing is stored"
  local out; out=$(k -n "${NAMESPACE}" apply --dry-run=server -f "${DIR}/policies/test/qwen-anywhere.yaml" 2>&1 || true)
  if echo "${out}" | grep -q denied; then
    echo "${RED}  denied by ValidatingAdmissionPolicy $(echo "${out}" | sed -n "s/.*ValidatingAdmissionPolicy '\([^']*\)'.*/\1/p"):${RESET}"
    echo "${out}" | sed 's/.*denied request: //' | fold -s -w 66 | sed "s/^/  ${RED}/;s/\$/${RESET}/"
    note "The policy binds to namespaces labelled jurisdiction=eu, such as ${NAMESPACE}."
  else
    bad "admitted: ${out}"; return 1
  fi
  punchline "Jurisdiction is a label. Enforcement is policy in the API."
}

# The pipeline's identity: Argo CD's application controller, which applies
# what a reviewed pull request merged.
PIPELINE="system:serviceaccount:argocd:argocd-application-controller"

beat_oversight() {
  banner "9 · Oversight"
  say "People propose a change in a pull request, a reviewer approves it, and the pipeline applies it."
  say "On the control plane that is plain RBAC: the team can read its models, only the pipeline can change them."
  beat "Who changed what ${DIM}(metadata.managedFields)${RESET}"
  show_writers
  echo
  pause
  beat "Who may do what in ${NAMESPACE}"
  kshow -n "${NAMESPACE}" get rolebinding ml-team-view gitops-edit -o wide
  echo
  beat "A team member tries to scale up by hand"
  show_cmd "kubectl --as=alice -n ${NAMESPACE} patch modeldeployment ${MD}" \
    "--type merge -p '{\"spec\":{\"replicas\":2}}' --dry-run=server"
  local out; out=$(k --as=alice -n "${NAMESPACE}" patch modeldeployment "${MD}" \
    --type merge -p '{"spec":{"replicas":2}}' --dry-run=server 2>&1 || true)
  if echo "${out}" | grep -q Forbidden; then
    echo "${out}" | sed 's/.*is forbidden: /forbidden: /' | fold -s -w 66 | sed "s/^/  ${RED}/;s/\$/${RESET}/"
  else
    bad "allowed: ${out}"; return 1
  fi
  note "alice can still see it:"
  kshow --as=alice -n "${NAMESPACE}" get modeldeployment
  echo
  pause
  beat "The pipeline can"
  show_cmd "kubectl auth can-i patch modeldeployments.modelplane.ai -n ${NAMESPACE}" "--as=${PIPELINE}"
  echo "  ${GREEN}$(k auth can-i patch modeldeployments.modelplane.ai -n "${NAMESPACE}" --as="${PIPELINE}" 2>&1 || true)${RESET}"
  note "The change is the pull request: Git holds who proposed it and who approved it."
  punchline "People propose in Git, a reviewer approves, the pipeline applies."
}

# ---------------------------------------------------------------------------
# Load and rehearsal
# ---------------------------------------------------------------------------

# N streaming requests as the chat-app caller: traffic for the dashboard, and a
# second caller in the usage records.
cmd_load() {
  local n="${1:-30}" i body url key
  body=$(chat_body "Tell me a short joke about GPUs" 120 stream)
  url=$(gateway_url)
  key=$(api_key_for "${LOAD_KEY_NAME}")
  [[ -n "${key}" ]] || die "no API key for ${LOAD_KEY_NAME}: make callers"
  beat "${n} streaming requests to $(model_name) as ${LOAD_KEY_NAME}, one every 2s"
  show_curl /chat/completions "${body}"
  for i in $(seq 1 "${n}"); do
    gw -N -o /dev/null -w "  ${i}/${n}  HTTP %{http_code}  %{time_total}s\n" "${url}/chat/completions" \
      -H "Authorization: Bearer ${key}" -H "Content-Type: application/json" -d "${body}" ||
      echo "  ${i}/${n}  failed"
    sleep 2
  done
}

# The guided run's background traffic, from the oversight beat on, so the
# monitor beat's panels show a few minutes of requests. Stopped on exit.
LOAD_PID=""
start_load() {
  stop_load
  ( cmd_load 300 ) >"${RUN}/load.log" 2>&1 &
  LOAD_PID=$!
}
stop_load() {
  [[ -n "${LOAD_PID}" ]] || return 0
  pkill -P "${LOAD_PID}" 2>/dev/null || true
  kill "${LOAD_PID}" 2>/dev/null || true
  LOAD_PID=""
}
trap stop_load EXIT

cmd_rehearse() {
  local n="${1:-1}" r
  AUTO_SLEEP=0
  for r in $(seq 1 "${n}"); do
    echo "${BOLD}── run ${r}/${n} ──${RESET}"
    local t0 line="" b t
    t0=$(now)
    cmd_reset
    for b in "${BEATS[@]}"; do
      t=$(now)
      "beat_${b}" >/dev/null 2>&1 || { bad "run ${r}: beat ${b} failed"; return 1; }
      line+="${b} $(since "${t}")s · "
    done
    cmd_reset >/dev/null
    echo "  ${line}total $(since "${t0}")s"
    echo "run=${r} ${line}total=$(since "${t0}")" >> "${RUN}/timings.log"
  done
}

# ---------------------------------------------------------------------------
# Recording and replay
# ---------------------------------------------------------------------------

# With --notes, a separate set with the speaker lines on screen.
REC_DIR="${DIR}/recordings"; (( NOTES )) && REC_DIR="${DIR}/recordings-notes"
REC_NAME="${REC_DIR##*/}"
NOTES_FLAG=""; (( NOTES )) && NOTES_FLAG="--notes"
CAST="${DIR}/scripts/cast.py"

# Record the beats from the live setup, one asciicast each, for --replay. With
# no beats named, it records all ten from the start state, unattended and in
# the deck's order, with the chat-app's traffic from the oversight beat on, and
# resets at the end. A named beat is recorded from whatever state it finds.
cmd_record() {
  local beats=() b
  if (( $# )); then beats=("$@"); else beats=("${BEATS[@]}"); cmd_reset; fi
  mkdir -p "${REC_DIR}"
  for b in "${beats[@]}"; do
    # A talk spends minutes on slides between beats; here, wait instead until
    # the replicas the last beat changed are serving and the routes settled.
    wait_for 1200 "replicas serving" md_ready_and_serving || die "replicas not serving before ${b}"
    settle_gateway || die "gateway not settling before ${b}"
    # The chat-app's traffic from the oversight beat on, or for the monitor beat alone.
    [[ "${b}" == oversight || ( "${b}" == monitor && -z "${LOAD_PID}" ) ]] && start_load
    beat "Recording ${b} to ${REC_NAME}/${b}.cast"
    DEMO_RECORDING=1 python3 "${CAST}" rec "${REC_DIR}/${b}.cast" -- \
      "${DIR}/demo.sh" --auto 0 ${NOTES_FLAG} "${b}" ||
      { stop_load; die "beat ${b} failed: fix it, then ./demo.sh record ${NOTES_FLAG:+${NOTES_FLAG} }${b}"; }
  done
  stop_load
  (( $# )) || cmd_reset
  ok "recorded ${#beats[@]} beat(s) in ${REC_NAME}/"
}

# Play a beat's recording: its output as it ran, pausing where the live run
# pauses. Nothing touches a cluster or the network.
replay_beat() {
  local f="${REC_DIR}/$1.cast"
  [[ -s "${f}" ]] || die "no recording of $1: ./demo.sh record ${NOTES_FLAG:+${NOTES_FLAG} }$1 on the live setup"
  CAST_AUTO="${AUTO_SLEEP}" python3 "${CAST}" play "${f}"
}

# The replay's preflight: every beat recorded, and when.
replay_status() {
  local b f fail=0
  echo "  ${DIM}replaying ${REC_NAME}/ · no cluster needed${RESET}"
  for b in "${BEATS[@]}"; do
    f="${REC_DIR}/${b}.cast"
    if [[ -s "${f}" ]]; then
      ok "${b}: recorded $(head -1 "${f}" | jq -r '.timestamp | strflocaltime("%a %d %b %H:%M")')"
    else
      bad "${b}: not recorded (./demo.sh record ${NOTES_FLAG:+${NOTES_FLAG} }${b})"; fail=1
    fi
  done
  return "${fail}"
}

# ---------------------------------------------------------------------------
# Guided flow
# ---------------------------------------------------------------------------

# One beat, live or from its recording.
run_one() { if (( REPLAY )); then replay_beat "$1"; else "beat_$1"; fi; }

# Run a beat; if it fails (a wait timed out), offer retry instead of dying mid-talk.
run_beat() {
  local b="$1" next="$2" ans
  until run_one "${b}"; do
    [[ -n "${AUTO_SLEEP}" ]] && return 1
    echo
    read -r -p "${YELLOW}↪ r = retry this beat · ENTER = continue anyway · q = quit ${RESET}" ans
    case "${ans}" in
      r|R) continue ;;
      q|Q) exit 1 ;;
      *)   break ;;
    esac
  done
  [[ -n "${next}" ]] && pause "next: ${next}"
  return 0
}

cmd_all() {
  banner "Preflight"
  if (( REPLAY )); then
    replay_status || die "record the missing beats first"
  else
    local rc=0; cmd_status || rc=$?
    if (( rc == 2 )); then
      echo; pause "not at start state: ENTER to reset (Ctrl-C to abort)"; cmd_reset
    elif (( rc != 0 )); then
      die "fix the items above first"
    fi
  fi
  echo; pause "ENTER to start: 1 · DRA"
  run_beat dra        "2 · Fleet"
  run_beat fleet      "3 · Warm cache"
  run_beat cache      "4 · Govern"
  run_beat govern     "5 · Scale"
  run_beat scale      "6 · Call"
  run_beat call       "7 · Resilience"
  run_beat resilience "8 · Lifecycle"
  run_beat lifecycle  "9 · Oversight"
  (( REPLAY )) || start_load
  run_beat oversight  "10 · Monitor"
  run_beat monitor    ""
  stop_load
  if (( REPLAY )); then
    echo "${BOLD}${GREEN}🎉 Demo complete.${RESET}"
  else
    echo "${BOLD}${GREEN}🎉 Demo complete.${RESET} ${DIM}(./demo.sh reset to run it again · ./demo.sh load for the dashboards)${RESET}"
  fi
}

CMD="${1:-all}"
if (( REPLAY )) && [[ " all status ${BEATS[*]} " != *" ${CMD} "* ]]; then
  die "--replay plays the recorded beats only: ./demo.sh --replay [status | <beat>]"
fi
case "${CMD}" in
  all)         cmd_all ;;
  up)          cmd_up ;;
  down)        cmd_down ;;
  reset)       cmd_reset ;;
  status)      if (( REPLAY )); then replay_status; else cmd_status; fi ;;
  prewarm)     cmd_prewarm ;;
  record)      shift; cmd_record "$@" ;;
  dra|fleet|cache|govern|scale|call|resilience|lifecycle|oversight|monitor) run_one "${CMD}" ;;
  load)        cmd_load "${2:-30}" ;;
  rehearse)    cmd_rehearse "${2:-1}" ;;
  *)           echo "unknown command: ${CMD} (see ./demo.sh --help)" >&2; exit 1 ;;
esac
