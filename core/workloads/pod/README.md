# Pods

The Pod is the fundamental deployable unit in Kubernetes. Everything else —
Deployments, StatefulSets, DaemonSets, Jobs — is a controller that manages Pods.
Understanding Pods deeply is the prerequisite for understanding everything else.

---

## Table of Contents

1. [What is a Pod?](#what-is-a-pod)
2. [Pod Lifecycle](#pod-lifecycle)
3. [Init Containers](#init-containers)
4. [Sidecar Containers](#sidecar-containers)
5. [Multi-Container Patterns](#multi-container-patterns)
6. [Key Pod Spec Fields](#key-pod-spec-fields)
7. [Interview Prep](#interview-prep)
8. [Files in This Directory](#files-in-this-directory)

---

## What is a Pod?

A Pod is a **group of one or more containers** that:
- Share a **network namespace** — all containers in a Pod see the same IP address
  and port space. They communicate via `localhost`.
- Share **storage volumes** — volumes are defined at the Pod level and mounted
  individually into each container.
- Are **scheduled together** — all containers in a Pod always land on the same node.
- Have a **shared lifecycle** — when a Pod is deleted, all its containers are
  terminated together.

The containers in a Pod are like processes in a single OS process group. They are
not completely isolated from each other — they can communicate via localhost and
shared memory (if you mount an `emptyDir` with `medium: Memory`).

**Why not just use a single container per Pod?**
Most of the time you do. But the multi-container pattern exists for specific purposes:
init containers handle sequencing, and sidecars provide orthogonal concerns
(logging, proxying, certificate rotation) without modifying the main application.

**Pods are ephemeral.** Never design around a specific Pod's IP address or
hostname. Use Services for stable addressing. Pods die and are replaced; their IP
addresses change.

---

## Pod Lifecycle

A Pod transitions through a set of phases:

```
Pending → Running → Succeeded / Failed
              │
              └── (if container crashes) → CrashLoopBackOff (then back to Running on restart)
```

| Phase | Meaning |
|---|---|
| `Pending` | The Pod has been accepted by Kubernetes but one or more containers are not yet running. May be waiting for node assignment, image pull, or init containers. |
| `Running` | The Pod has been bound to a node; at least one container is running (or is starting/restarting). |
| `Succeeded` | All containers have terminated with exit code 0, and will not be restarted. Common for Jobs. |
| `Failed` | All containers have terminated, and at least one exited with non-zero or was killed. |
| `Unknown` | The state cannot be determined — usually because the node is unreachable. |

**Pod conditions** (more granular than phase):

| Condition | Meaning |
|---|---|
| `PodScheduled` | The Pod has been scheduled to a node. |
| `Initialized` | All init containers have completed successfully. |
| `ContainersReady` | All containers in the Pod are ready. |
| `Ready` | The Pod is ready to serve requests. This gates Service endpoint inclusion. |

**Container states:**

| State | Meaning |
|---|---|
| `Waiting` | Container is waiting to start (pulling image, waiting for init containers). |
| `Running` | Container is executing. |
| `Terminated` | Container has finished (exit code available). |

---

## Init Containers

Init containers run **before** the main application containers start. They run
**sequentially** (one at a time, each must exit 0 before the next starts), and
the main containers only start after **all** init containers have completed
successfully.

### Why Use Init Containers?

1. **Sequencing / dependency gating** — Wait for a database to be available before
   starting the app. Use `nslookup` or `curl` to check readiness.

2. **One-time setup** — Clone a Git repo, download configuration from S3, run
   database migrations, generate certificates.

3. **Security isolation** — Init containers can have different (often broader)
   permissions than the main container. E.g., an init container writes files as
   root; the main container runs as non-root and reads them.

4. **Bootstrapping** — Copy binary tools into shared volumes that the main container
   uses (e.g., copy a secrets-decryptor tool that the main container calls).

### Key Characteristics

- Init containers do NOT support `readinessProbe` (they must succeed, not just be
  ready).
- Init containers DO support `livenessProbe` and `startupProbe` (to avoid hanging
  forever).
- If an init container fails, kubelet restarts it according to the Pod's
  `restartPolicy`. The main containers do not start until all inits succeed.
- Init containers are listed under `spec.initContainers`, separate from
  `spec.containers`.

See: `init-container.yml` in this directory.

---

## Sidecar Containers

A sidecar is an **additional container in the same Pod** that provides a supporting
capability to the main container, running alongside it for the lifetime of the Pod.

### Common Sidecar Patterns

| Pattern | Example |
|---|---|
| **Log forwarder** | Tail the main app's log file and ship to a central log system (Fluentd, Vector, Filebeat) |
| **Reverse proxy** | Envoy proxy handling mTLS, circuit breaking, retries (service mesh data plane) |
| **Certificate rotation** | cert-manager's `cmctl` sidecar rotating TLS certs on disk |
| **Secrets sync** | Vault Agent sidecar writing secrets to a shared volume |
| **Metrics exporter** | Prometheus exporter running alongside a legacy app that doesn't expose /metrics natively |
| **Config reload** | Confd or Reloader watching ConfigMap changes and sending SIGHUP to the main process |

### Kubernetes 1.29+ Native Sidecar Containers

Before Kubernetes 1.29, sidecar containers were regular containers in `spec.containers`
— they had no formal ordering guarantee at startup or shutdown. Kubernetes 1.29
introduced **native sidecar support** via `initContainers` with `restartPolicy: Always`.
These:
- Start before main containers (like init containers).
- Run for the lifetime of the Pod (like regular sidecars).
- Are terminated **after** the main containers (proper shutdown ordering).
- Are visible in `kubectl get pod` output with `Init:` prefix.

This is critical for Jobs: the sidecar no longer prevents the Job's Pod from
completing, because native sidecars are terminated when the main container exits.

See: `sidecar-container.yml` in this directory.

---

## Multi-Container Patterns

Beyond the sidecar, there are two other recognized multi-container patterns:

### Ambassador Pattern

The main container talks to `localhost:port`. An ambassador container proxies that
traffic to the correct upstream (different in dev vs. prod). The main app is unaware
of the routing complexity.

```
Main App → localhost:5432 → Ambassador (envoy/nginx) → actual database endpoint
```

Use case: abstracting away service discovery, or routing to different databases in
different environments without changing application config.

### Adapter Pattern

The main container produces output in a proprietary or legacy format. An adapter
container transforms that output into a standard format (e.g., Prometheus metrics,
structured JSON logs) consumed by external systems.

```
Main App (writes legacy metrics format to file) → Adapter (reads file, exposes /metrics) → Prometheus
```

Use case: instrumenting legacy applications for modern observability without
modifying the application code.

---

## Key Pod Spec Fields

```yaml
spec:
  # Prevents automatic mounting of the service account token.
  # Best practice: disable and mount explicitly only when needed.
  automountServiceAccountToken: false

  # Grace period for SIGTERM before SIGKILL. Set higher for slow-shutdown apps.
  terminationGracePeriodSeconds: 60

  # Pod-level security context (applies to all containers)
  securityContext:
    runAsNonRoot: true          # Refuse to start if the image runs as root
    runAsUser: 1000             # UID for all containers unless overridden
    fsGroup: 2000               # GID applied to mounted volumes (for file permissions)
    seccompProfile:
      type: RuntimeDefault      # Apply the container runtime's default seccomp filter

  # Node selection
  nodeSelector:
    kubernetes.io/os: linux

  # Tolerations allow the Pod to be scheduled on tainted nodes
  tolerations:
  - key: "dedicated"
    operator: "Equal"
    value: "gpu"
    effect: "NoSchedule"

  # Affinity rules (more expressive than nodeSelector)
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app.kubernetes.io/name: myapp
        topologyKey: kubernetes.io/hostname  # No two replicas on the same node

  # Volumes available to all containers in the Pod
  volumes:
  - name: tmp
    emptyDir: {}

  containers:
  - name: app
    image: myapp:1.0.0
    ports:
    - containerPort: 8080
      protocol: TCP
      name: http

    # Container-level security context (overrides pod-level where applicable)
    securityContext:
      allowPrivilegeEscalation: false   # Cannot use setuid binaries
      readOnlyRootFilesystem: true      # Filesystem is immutable (security + predictability)
      capabilities:
        drop: ["ALL"]                   # Drop all Linux capabilities
        add: ["NET_BIND_SERVICE"]       # Re-add only what's needed (if port < 1024)

    resources:
      requests:
        memory: "128Mi"
        cpu: "100m"
      limits:
        memory: "128Mi"
        # No CPU limit to avoid throttling (cpu compressible resource)

    # Mount the volume
    volumeMounts:
    - name: tmp
      mountPath: /tmp

    # Drain time before SIGTERM — give load balancer time to remove the Pod
    lifecycle:
      preStop:
        exec:
          command: ["/bin/sh", "-c", "sleep 5"]

    # startupProbe: gates liveness/readiness until the app has started
    startupProbe:
      httpGet:
        path: /healthz
        port: 8080
      failureThreshold: 30
      periodSeconds: 2

    # readinessProbe: controls Service endpoint inclusion
    readinessProbe:
      httpGet:
        path: /ready
        port: 8080
      initialDelaySeconds: 5
      periodSeconds: 10
      failureThreshold: 3

    # livenessProbe: restarts the container if it becomes stuck
    livenessProbe:
      httpGet:
        path: /healthz
        port: 8080
      initialDelaySeconds: 15
      periodSeconds: 20
      failureThreshold: 3
```

---

## Interview Prep

> **"What is the difference between a Pod and a container?"**

A container is a single isolated process (or process group) with its own filesystem
namespace. A Pod is a Kubernetes abstraction that groups one or more containers that
share a network namespace (same IP), storage volumes, and lifecycle. The Pod is the
unit of scheduling in Kubernetes — the scheduler places Pods on nodes, not individual
containers.

> **"What happens when a Pod's liveness probe fails?"**

kubelet restarts the specific container that failed the probe. The restart respects
the Pod's `restartPolicy` (default is `Always` for Deployments). It does NOT delete
and recreate the Pod — it kills and restarts the container within the existing Pod.
The Pod's restart count increments. If restarts happen too frequently, the container
enters `CrashLoopBackOff` — kubelet backs off exponentially (10s, 20s, 40s, up to
5 minutes) to avoid thrashing.

> **"What is the difference between readinessProbe and livenessProbe?"**

- `readinessProbe`: Controls whether the Pod is included in Service Endpoints. A
  failing readiness probe removes the Pod from rotation — requests stop being sent
  to it — but the Pod is NOT restarted. Use for: "Am I ready to handle requests?"
  (e.g., cache warming, dependent service unavailable).
- `livenessProbe`: Controls whether the container is restarted. A failing liveness
  probe kills and restarts the container. Use for: "Am I still alive or stuck?"
  (e.g., deadlock detection, hung goroutine).

> **"What is an init container and when would you use one?"**

An init container runs before the main application container and must complete
successfully before the main container starts. Use cases: waiting for a database to
be ready (avoid crashing the app on startup), running schema migrations, pulling
secrets or config from external sources, or bootstrapping shared files in a volume.
Init containers run sequentially (one at a time), while main containers run in
parallel.

> **"How do containers in the same Pod communicate?"**

Via `localhost`. All containers in a Pod share the same network namespace — they
have the same IP address and can reach each other's ports via `127.0.0.1:port`.
They can also communicate via shared memory (using `emptyDir` with `medium: Memory`)
or via files on a shared `emptyDir` volume.

> **"Why should you set both requests and limits?"**

`requests` is what Kubernetes uses for scheduling — it reserves that amount of
resources on the node. `limits` is the hard cap enforced by cgroups. Without
`requests`, the scheduler doesn't know how much the container needs, leading to
overcommitment. Without `limits`, a misbehaving container can OOM-kill the entire
node. Best practice: set `memory request == memory limit` (to get `Guaranteed` QoS
class, which protects you from OOM eviction). CPU limits are controversial — omitting
them avoids throttling on bursting workloads, but risks noisy neighbors.

> **"What is the QoS class of a Pod and why does it matter?"**

Kubernetes assigns one of three Quality of Service classes, which determine eviction
priority during node memory pressure:
- **Guaranteed** — All containers have `requests == limits` for both CPU and memory.
  These Pods are evicted last.
- **Burstable** — At least one container has a resource request or limit set, but
  not all equal. Evicted second.
- **BestEffort** — No requests or limits set. Evicted first. Never use for
  production workloads.

---

## Files in This Directory

| File | Description |
|---|---|
| `README.md` | This file |
| `basic-pod.yml` | Minimal nginx Pod with all production security contexts |
| `init-container.yml` | Init container that waits for a service before starting nginx |
| `sidecar-container.yml` | Log-forwarding sidecar pattern with shared emptyDir volume |
