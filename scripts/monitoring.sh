#!/usr/bin/env bash
# The fleet's metrics backend for the demo: a Prometheus on the AKS cluster
# that every inference cluster's collector remote-writes to, the
# TelemetryDestination on the control plane that points them at it, and
# Grafana on this laptop.
#
#   scripts/monitoring.sh up             Prometheus on AKS, then the TelemetryDestination
#   scripts/monitoring.sh grafana        Grafana on http://localhost:3000, with the fleet dashboard
#   scripts/monitoring.sh grafana-stop
#   scripts/monitoring.sh query PROMQL   an instant query against the fleet Prometheus, JSON on stdout
#   scripts/monitoring.sh url            the Prometheus address
#   scripts/monitoring.sh down           the TelemetryDestination, its Secret, Prometheus and Grafana
#
# Prometheus listens on a LoadBalancer, because the Nebius cluster's collector
# has to reach it too, with TLS from a CA generated here and basic auth for two
# users: collector (writes) and grafana (reads). Passwords, keys and
# certificates go to .secrets/monitoring/ and are never printed.
#
# Explicit contexts only: the control plane by CONTEXT, AKS by its kubeconfig.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
CONTEXT=${CONTEXT:-kind-modelplane-demo}
AKS_CLUSTER=${AKS_CLUSTER:-aks-swedencentral}
AKS_KUBECONFIG=${AKS_KUBECONFIG:-${here}/.secrets/${AKS_CLUSTER}.kubeconfig}

NS=monitoring
RELEASE=fleet-prometheus
SERVER=${RELEASE}-server
CHART_REPO=https://prometheus-community.github.io/helm-charts
CHART=prometheus-community/prometheus
CHART_VERSION=29.37.0
PORT=9090

# The TelemetryDestination names this Secret; Modelplane copies it to every
# cluster running a collector.
CP_SECRET=fleet-prometheus
DESTINATION=fleet-prometheus

GRAFANA_IMAGE=grafana/grafana:12.4.13
GRAFANA_NAME=modelplane-grafana
GRAFANA_PORT=3000
GRAFANA_DASHBOARD=modelplane-fleet

# Readable by others (0755) so Grafana's container can read the CA through
# Colima's mount; everything secret in it is 0600.
D="${here}/.secrets/monitoring"

aks() { kubectl --kubeconfig "${AKS_KUBECONFIG}" "$@"; }
cp_() { kubectl --context "${CONTEXT}" "$@"; }
log() { echo "monitoring: $*" >&2; }
die() { echo "monitoring: $*" >&2; exit 1; }

# A random password in .secrets/monitoring/<name>.password, created once, with
# no trailing newline: the collector reads it into an environment variable.
password() {
  local f="${D}/$1.password"
  [[ -s "${f}" ]] || (umask 077; openssl rand -hex 24 | tr -d '\n' >"${f}")
}

# A CA for the demo, created once.
ca() {
  [[ -s "${D}/ca.key" && -s "${D}/ca.crt" ]] && return 0
  local cnf="${D}/ca.cnf"
  printf '%s\n' '[req]' 'distinguished_name = dn' 'x509_extensions = v3_ca' 'prompt = no' \
    '[dn]' 'CN = modelplane-demo fleet Prometheus CA' \
    '[v3_ca]' 'basicConstraints = critical,CA:TRUE' 'keyUsage = critical,keyCertSign,cRLSign' \
    'subjectKeyIdentifier = hash' >"${cnf}"
  (umask 077; openssl req -x509 -new -newkey rsa:2048 -nodes -sha256 -days 90 \
    -config "${cnf}" -keyout "${D}/ca.key" -out "${D}/ca.crt" 2>/dev/null)
  chmod 0644 "${D}/ca.crt"
  log "generated a CA in .secrets/monitoring/"
}

# A server certificate for the subjectAltName in $1 (e.g. IP:20.1.2.3),
# reissued only when the name it was issued for changes.
server_cert() {
  local san="$1"
  if [[ -s "${D}/server.crt" && -s "${D}/server.key" && "$(cat "${D}/server.san" 2>/dev/null)" == "${san}" ]]; then
    return 0
  fi
  local ext="${D}/server.ext"
  printf '%s\n' 'basicConstraints = CA:FALSE' 'keyUsage = critical,digitalSignature,keyEncipherment' \
    'extendedKeyUsage = serverAuth' "subjectAltName = ${san}" >"${ext}"
  (umask 077
    openssl req -new -newkey rsa:2048 -nodes -subj "/CN=${RELEASE}" \
      -keyout "${D}/server.key" -out "${D}/server.csr" 2>/dev/null
    openssl x509 -req -sha256 -days 90 -in "${D}/server.csr" -CA "${D}/ca.crt" -CAkey "${D}/ca.key" \
      -CAcreateserial -CAserial "${D}/ca.srl" -extfile "${ext}" -out "${D}/server.crt" 2>/dev/null)
  printf '%s' "${san}" >"${D}/server.san"
  log "issued a server certificate for ${san}"
}

# Prometheus's web config: TLS, and a bcrypt hash per user. htpasswd reads the
# password from stdin, so it never appears in a process list.
web_config() {
  local user hashes=""
  for user in collector grafana; do
    hashes+="  ${user}: '$(htpasswd -niBC 10 "${user}" <"${D}/${user}.password" | cut -d: -f2- | tr -d '\n')'"$'\n'
  done
  (umask 077; {
    echo 'tls_server_config:'
    echo '  cert_file: /etc/prometheus-web/tls.crt'
    echo '  key_file: /etc/prometheus-web/tls.key'
    echo 'basic_auth_users:'
    printf '%s' "${hashes}"
  } >"${D}/web-config.yml")
}

address() {
  aks -n "${NS}" get service "${SERVER}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
}

wait_address() {
  local a i
  for i in $(seq 1 60); do
    a=$(address)
    [[ -n "${a}" ]] && { echo "${a}"; return 0; }
    sleep 5
  done
  die "service ${SERVER} has no LoadBalancer address after 5 minutes"
}

# curl a path on the fleet Prometheus as the grafana user: prom_curl PATH
# [curl args]. The credential goes through a config on a file descriptor, not
# the command line.
prom_curl() {
  local path="$1"; shift
  local ip; ip=$(cat "${D}/address" 2>/dev/null) || die "no address yet: run '$0 up' first"
  curl -sS --fail --max-time 15 --cacert "${D}/ca.crt" \
    -K <(printf 'user = "grafana:%s"\n' "$(cat "${D}/grafana.password")") \
    "$@" "https://${ip}:${PORT}${path}"
}

cmd_up() {
  [[ -s "${AKS_KUBECONFIG}" ]] || die "no kubeconfig at ${AKS_KUBECONFIG#"${here}"/}: run 'make kubeconfig' first"
  mkdir -p "${D}"; chmod 0755 "${D}"
  password collector
  password grafana
  ca

  if ! helm repo list 2>/dev/null | grep -q '^prometheus-community'; then
    helm repo add prometheus-community "${CHART_REPO}" >/dev/null
  fi
  helm repo update prometheus-community >/dev/null

  aks create namespace "${NS}" --dry-run=client -o yaml | aks apply -f - >/dev/null

  # Installed before its certificate exists: the certificate has to name the
  # LoadBalancer's address, which the Service only gets once it exists. The pod
  # waits for the prometheus-web Secret below, so no --wait here.
  log "installing ${CHART} ${CHART_VERSION} on ${AKS_CLUSTER} (namespace ${NS})"
  helm --kubeconfig "${AKS_KUBECONFIG}" upgrade --install "${RELEASE}" "${CHART}" \
    --version "${CHART_VERSION}" --namespace "${NS}" \
    -f "${here}/monitoring/prometheus-values.yaml" >/dev/null

  local ip; ip=$(wait_address)
  printf '%s' "${ip}" >"${D}/address"
  log "LoadBalancer address: ${ip}"

  server_cert "IP:${ip}"
  web_config
  # Server-side apply, so the Secret's data isn't copied into a
  # last-applied-configuration annotation. Prometheus re-reads the web config
  # and certificate on every request, so a reissued certificate needs no restart.
  aks -n "${NS}" create secret generic prometheus-web \
    --from-file=web-config.yml="${D}/web-config.yml" \
    --from-file=tls.crt="${D}/server.crt" \
    --from-file=tls.key="${D}/server.key" \
    --dry-run=client -o yaml |
    aks apply --server-side --force-conflicts --field-manager=modelplane-demo -f - >/dev/null

  aks -n "${NS}" rollout status "deployment/${SERVER}" --timeout=10m >&2
  # The load balancer can take a minute to pass traffic after the pod is ready.
  local i; for i in $(seq 1 24); do
    prom_curl /-/ready -o /dev/null 2>/dev/null && break
    sleep 5
  done
  prom_curl /-/ready -o /dev/null || die "https://${ip}:${PORT}/-/ready did not answer with TLS and basic auth"
  log "Prometheus is ready at https://${ip}:${PORT} (TLS, basic auth)"

  cmd_destination "${ip}"

  # For Grafana: an env file docker reads on this machine, so the password
  # never has to be readable inside Colima's VM.
  (umask 077; printf 'PROMETHEUS_URL=https://%s:%s\nGRAFANA_PROM_PASSWORD=%s\n' \
    "${ip}" "${PORT}" "$(cat "${D}/grafana.password")" >"${D}/grafana.env")
  log "done; 'make grafana' starts the dashboard"
}

# The Secret the TelemetryDestination names, on the control plane, and the
# destination itself with the LoadBalancer's address filled in.
cmd_destination() {
  local ip="${1:-$(cat "${D}/address" 2>/dev/null)}"
  [[ -n "${ip}" ]] || die "no address yet: run '$0 up' first"
  cp_ -n modelplane-system create secret generic "${CP_SECRET}" \
    --from-file=PROMETHEUS_PASSWORD="${D}/collector.password" \
    --from-file=PROMETHEUS_CA="${D}/ca.crt" \
    --dry-run=client -o yaml |
    cp_ apply --server-side --force-conflicts --field-manager=modelplane-demo -f - >/dev/null
  sed "s/PROMETHEUS_ADDRESS/${ip}/" "${here}/monitoring/telemetry-destination.yaml" | cp_ apply -f - >&2
  log "every cluster's collector now remote-writes to https://${ip}:${PORT}/api/v1/write"
}

cmd_grafana() {
  [[ -s "${D}/grafana.env" && -s "${D}/ca.crt" ]] || die "run '$0 up' first"
  docker rm -f "${GRAFANA_NAME}" >/dev/null 2>&1 || true
  docker run -d --name "${GRAFANA_NAME}" --restart unless-stopped \
    -p "127.0.0.1:${GRAFANA_PORT}:3000" \
    --env-file "${D}/grafana.env" \
    -e GF_AUTH_ANONYMOUS_ENABLED=true \
    -e GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer \
    -e GF_AUTH_DISABLE_LOGIN_FORM=true \
    -e GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/${GRAFANA_DASHBOARD}.json \
    -e GF_NEWS_NEWS_FEED_ENABLED=false \
    -e GF_ANALYTICS_REPORTING_ENABLED=false \
    -e GF_ANALYTICS_CHECK_FOR_UPDATES=false \
    -v "${here}/monitoring/grafana/provisioning:/etc/grafana/provisioning:ro" \
    -v "${here}/monitoring/grafana/dashboards:/var/lib/grafana/dashboards:ro" \
    -v "${D}/ca.crt:/etc/grafana/secrets/ca.crt:ro" \
    "${GRAFANA_IMAGE}" >/dev/null
  local i; for i in $(seq 1 60); do
    curl -sf "http://127.0.0.1:${GRAFANA_PORT}/api/health" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -sf "http://127.0.0.1:${GRAFANA_PORT}/api/health" >/dev/null || die "Grafana didn't start: docker logs ${GRAFANA_NAME}"
  echo "http://localhost:${GRAFANA_PORT}/d/${GRAFANA_DASHBOARD}"
}

cmd_grafana_stop() { docker rm -f "${GRAFANA_NAME}" >/dev/null 2>&1 || true; }

cmd_query() {
  [[ $# -ge 1 ]] || die "usage: $0 query PROMQL"
  prom_curl /api/v1/query --data-urlencode "query=$1"
}

cmd_url() {
  local ip; ip=$(cat "${D}/address" 2>/dev/null) || die "no address yet: run '$0 up' first"
  echo "https://${ip}:${PORT}"
}

cmd_down() {
  cmd_grafana_stop
  cp_ delete telemetrydestination "${DESTINATION}" --ignore-not-found >&2 || true
  cp_ -n modelplane-system delete secret "${CP_SECRET}" --ignore-not-found >&2 || true
  if [[ -s "${AKS_KUBECONFIG}" ]]; then
    helm --kubeconfig "${AKS_KUBECONFIG}" -n "${NS}" uninstall "${RELEASE}" >&2 2>/dev/null || true
    aks delete namespace "${NS}" --ignore-not-found --wait=false >&2 || true
  fi
  rm -f "${D}/address" "${D}/grafana.env"
}

case "${1:-}" in
  up)           cmd_up ;;
  destination)  shift; cmd_destination "$@" ;;
  grafana)      cmd_grafana ;;
  grafana-stop) cmd_grafana_stop ;;
  query)        shift; cmd_query "$@" ;;
  url)          cmd_url ;;
  down)         cmd_down ;;
  *)            sed -n '7,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
