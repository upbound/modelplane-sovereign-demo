# From model to sovereign endpoint: a Modelplane walkthrough

The live demo from the Sovereign Cloud Days 2026 workshop. One model,
Qwen2.5-7B AWQ on vLLM, on two GPU clusters from two providers, both in the EU:
an A100 on AKS in Sweden Central and an L40S on Nebius in Finland. Modelplane
v0.5 builds both clusters, stages the weights once per cluster, keeps the model
on EU clusters by policy, serves it through one API-key gateway, and sends every
cluster's metrics to a Prometheus you run.

The control plane is a kind cluster on your laptop. It needs no GPUs: it
schedules and composes.

## Replay the recorded demo

All ten beats were recorded from the real AKS and Nebius clusters on
20 October 2026, and the clusters were then torn down. Playing them back needs
only `bash`, `python3` and `jq`: no cluster, no cloud account, no network.

```bash
./demo.sh --replay --notes   # the guided talk, with the speaker lines on screen
./demo.sh --replay           # the same, without them
./demo.sh --replay scale     # one beat: dra fleet cache govern scale call resilience lifecycle oversight monitor
```

Press ENTER to advance, as in the live run. Use a terminal about 120 columns
wide. The addresses on screen belonged to the torn-down clusters.

## Layout

| Path | What it holds |
|---|---|
| `control-plane/` | Modelplane install (a main build with the AKS fix) and the Azure and Nebius provider configs |
| `platform/` | The platform team's objects: the A100 class and AKS cluster, and the EU gateway |
| `platform/nebius/` | The L40S class and the Nebius cluster |
| `workloads/` | The ML team's objects: `ml-team` namespace, ModelCache, ModelDeployment and ModelService |
| `policies/` | EU-only admission policies, a deployment they must reject, and the oversight RBAC |
| `examples/` | A rollout without downtime: a second deployment on a newer vLLM and a 90/10 weight split |
| `monitoring/` | Prometheus for the fleet's metrics on AKS, and Grafana with a dashboard for your laptop |
| `scripts/` | Control plane, credentials, caller keys, kubeconfigs, monitoring, smoke test, and `cast.py`, which records and replays the beats |
| `recordings/`, `recordings-notes/` | The recorded beats, without and with the speaker lines |
| `.secrets/` | Credentials, API keys and kubeconfigs (git-ignored) |

The workloads select hardware by label (`jurisdiction: eu`) and GPU memory
(at least 14 GiB), never by cluster, provider or GPU model. That is what lets the
same deployment run on the A100 and on the L40S.

## Setup

Needs `az` (logged in), `kubectl`, `helm`, `kind`, `jq`, `yq`, the `crossplane`
CLI, and Docker with 8 GB of memory.

- **Azure:** `AZURE_SUBSCRIPTION_ID` names the subscription the AKS cluster goes
  in. The first `make credentials` creates a service principal with Contributor
  on it; later runs reuse `.secrets/azure-sp.json`.
- **Nebius:** a service account key in `.secrets/nebius-credentials.json` (the
  format `nebius iam auth-public-key generate` writes, or
  `{"account_id","public_key_id","private_key"}`), and the project ID in
  `NEBIUS_PROJECT_ID` or `.secrets/nebius-project-id`. The project decides the
  region, so use one in eu-north1. The service account needs edit rights in it.

```bash
export AZURE_SUBSCRIPTION_ID=<subscription>
make control-plane        # kind cluster "modelplane-demo" with Crossplane and Modelplane
make credentials          # Azure service principal and ClusterProviderConfig
make nebius-credentials   # Nebius key and ClusterProviderConfig
make platform             # both GPU clusters in parallel (~15 min) and the gateway
make callers              # API keys for two callers: "demo" (you) and "chat-app"
make policy               # EU-only policies, before the workloads they govern
make workloads            # cache, deployment, service: ml-team/qwen-7b
make oversight            # the team views, only the GitOps pipeline edits
make kubeconfig           # each cluster's kubeconfig, into .secrets/
make monitoring           # Prometheus on AKS and the TelemetryDestination for every collector
make grafana              # Grafana on http://localhost:3000 with the fleet dashboard (Docker)
make wait smoke           # first start pulls the image and stages the weights
make policy-test          # a deployment without the EU selector is rejected
./demo.sh prewarm          # a replica on each cluster once, so no image pull on stage
```

`./demo.sh up` runs the same steps in one go. Every step skips what already
exists, so after a failure it can simply run again.

### Cost and teardown

The A100 costs about $5.65 an hour with its system nodes; check your Nebius
pricing for the L40S. Between sessions, `make aks-stop` deallocates the AKS
nodes and keeps the cluster and its warm cache (`make aks-start` resumes). There
is no Nebius equivalent here: delete the cluster between sessions or keep paying
for its nodes.

```bash
make destroy                 # demo objects, monitoring, then both GPU clusters (foreground)
make destroy-control-plane   # the kind cluster
```

### Monitoring

Modelplane ships no dashboards; it exports one `modelplane_*` vocabulary from
every cluster's collector to wherever a `TelemetryDestination` points. Here that
is a Prometheus with a remote-write receiver on the AKS system pool, behind a
LoadBalancer with TLS and basic auth, and Grafana in Docker on your laptop. The
credentials and certificates are generated into `.secrets/monitoring/` and never
printed. The guided run starts background traffic from the `chat-app` caller
at the oversight beat, so the panels show a few minutes of requests by the
monitor beat; to run that beat alone, start `./demo.sh load 30` in another
terminal a minute before. Who called is in the gateway's usage records, not in a
metric label ([#535](https://github.com/modelplaneai/modelplane/issues/535)).

## Demo script

`demo.sh` is the workshop's live demo: a preflight check, then ten beats with
ENTER between steps, in the order of the deck. `./demo.sh <beat>` runs one.

| Beat | Shows | With one GPU cluster |
|---|---|---|
| 1 · DRA (`dra`) | the GPU node's label, the driver's ResourceSlice, the engine pod's ResourceClaim and the InferenceClass it matched: the same CEL decides twice | same |
| 2 · Fleet | both InferenceClusters with region and jurisdiction; what one became (`crossplane resource trace`); the EU gateway | same |
| 3 · Warm cache (`cache`) | the cache on shared storage; scale to zero and back from the warm cache, timed | same |
| 4 · Govern | the deployment's EU selector, the policy's rule, a non-EU deployment rejected | same |
| 5 · Scale | one replica to two; the second lands on the other provider, and the gateway serves both | skipped |
| 6 · Call | the gateway and the model's name; 401 without a key, the model list with one, a streamed chat completion | same |
| 7 · Resilience | one replica's pod deleted while 20 requests run; the gateway retries on the other provider | the gateway's retry and ejection policy |
| 8 · Lifecycle | the ModelService's weights and a 90/10 rollout as a server-side dry run; the cluster spec; a drain with a NoExecute taint (`DRAIN=0` skips it); deleting an in-use cluster refused | same, without the drain |
| 9 · Oversight | who changed what (managed fields); the team can view, only the GitOps pipeline can edit | same |
| 10 · Monitor | the TelemetryDestination; usage records from two callers; both clusters' metrics in your Prometheus; the Grafana dashboard | same |

```bash
./demo.sh status           # preflight
./demo.sh prewarm          # the engine image onto every GPU node, then back to the start state
./demo.sh --notes          # guided run with the speaker lines on screen
./demo.sh scale            # one beat
./demo.sh reset            # back to 1 replica, no drain taint
./demo.sh load 30          # streaming load as the chat-app caller, for the dashboard
./demo.sh rehearse 3       # unattended runs, timings in .run/timings.log
./demo.sh record           # record every beat for --replay
./demo.sh --replay         # the guided talk from the recordings, offline
```

### Before the talk

About an hour before:

1. `./demo.sh status`. Fix every ✘; each `!` names its fix.
2. `./demo.sh prewarm` if the status says a cluster hasn't pulled the engine
   image. Otherwise the scale beat's new replica waits minutes for the pull
   ([#341](https://github.com/modelplaneai/modelplane/issues/341)).
3. `make grafana` if it isn't running, and open the dashboard once.
4. `./demo.sh reset`, then `./demo.sh status` again: all green.
5. A terminal font the back row can read, about 120 columns wide.

For a replay, `./demo.sh --replay status` is the whole check: every beat
recorded.

### Record and replay

`./demo.sh record` runs the ten beats unattended on the live setup, from the
start state and in the deck's order, and saves each one as an asciicast in
`recordings/`. `./demo.sh --replay` then runs the guided talk from those files
with no cluster and no network. The output and its timing are the recorded
ones, and it pauses where the live run pauses, with two exceptions:

- A gap of more than 1.5 s is shortened to 1.5 s.
- A wait's spinner plays ten frames a second, so a two-minute wait takes 12 s.
  The time the wait reports is the recorded one.

Each beat's banner says it's a recorded run, and when it was recorded.

```bash
./demo.sh record                  # all ten beats, then back to the start state
./demo.sh record scale            # re-record one beat, from the state it starts in
./demo.sh --replay                # the guided talk, from the recordings
./demo.sh --replay call           # one beat
CAST_SPEED=2 ./demo.sh --replay   # twice as fast
./demo.sh record --notes          # a second set with the speaker lines on screen
./demo.sh --replay --notes        # the guided talk from that set
```

The full recording runs the `chat-app` traffic from the oversight beat on, as
the live run does. Take the Grafana screenshot for the deck once it finishes,
while that traffic is still in the panels. The recordings show the gateway's and
Prometheus's addresses, so commit a new recording only once its clusters are
torn down.

The start state is one replica on `aks-swedencentral`. The scheduler breaks
ties by cluster name, so a replica scaled back from zero returns there, the
second one goes to `nebius-eu-north`, and scaling down removes the Nebius one
first.

The commands on screen are the ones the script runs, except that the API key is
masked; some output is trimmed or tabulated, and tables drop the COMPOSITION
column. Control plane commands assume the current kube context is the control
plane (`kind-modelplane-demo`); workload cluster commands name their kubeconfig.
The drain taint is added and removed by JSON patch, touching only the demo's own
entry (the removal tests its key first), so it never touches taints set by
anyone else.

## Known issues

- **AKS node pools rewritten in a loop on v0.5.0**
  ([#515](https://github.com/modelplaneai/modelplane/issues/515)): fixed on main
  by [#516](https://github.com/modelplaneai/modelplane/pull/516), and this setup
  runs a build of main. Move `control-plane/configuration.yaml` to the first
  release with the fix.
- **Nebius node groups rewritten in a loop on v0.5.0**
  ([#517](https://github.com/modelplaneai/modelplane/issues/517)): Modelplane
  v0.5 pins provider-nebius v1.2.0, which pushes a flip-flopping node group spec
  to Nebius, so the nodes are replaced again and again, without the model
  cache's filesystem. `make control-plane` runs provider-nebius v1.0.1 instead
  (v0.4's version, which ignores the flip) and turns off dependency resolution
  so Crossplane doesn't upgrade it back. Remove both once #517 is fixed.
- **A Nebius cache can stay Pending**
  ([#494](https://github.com/modelplaneai/modelplane/issues/494)) if Nebius
  replaces the node a cache volume was first assigned to while the cluster
  settles. `make platform` waits for both clusters before the workloads go on.
  To recover, against the Nebius cluster:
  `kubectl -n ml-team annotate pvc <cache-pvc> volume.kubernetes.io/selected-node-`.
- **Ready before the pods are**
  ([#497](https://github.com/modelplaneai/modelplane/issues/497)): a
  ModelDeployment can report Ready while its engine has no ready pods, so the
  beats wait for the engine's pods themselves.
- **The engine still contacts Hugging Face at startup**
  ([#530](https://github.com/modelplaneai/modelplane/issues/530)), even with a
  ModelCache. `make offline` sets `HF_HUB_OFFLINE=1` on the engine so it uses
  only the cache. It rolls the replicas; test it before relying on it.
- **`make destroy` can hang on AKS.** The serving stack's metrics adapter
  is uninstalled before its `custom.metrics.k8s.io` and
  `external.metrics.k8s.io` APIServices, so API discovery fails and the
  cluster's namespaces never finish deleting. Remove the two stale
  registrations and the teardown continues:
  `kubectl --kubeconfig .secrets/aks-swedencentral.kubeconfig delete apiservice v1beta1.custom.metrics.k8s.io v1beta1.external.metrics.k8s.io`.
- **Nebius serving stack objects can outlive the cluster on teardown.** Its
  Helm Releases and Objects then can't reach the cluster to uninstall and keep
  their finalizers. Once the cluster is gone at Nebius, remove their
  finalizers (and the Usages between them) on the control plane.
- **A fresh node pulls the engine image first**
  ([#341](https://github.com/modelplaneai/modelplane/issues/341)), so the first
  replica on a new node takes several minutes.
