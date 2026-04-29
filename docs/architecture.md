# Kubernetes Architecture

A deep-dive reference for engineers who need more than surface-level knowledge.
This document covers how the control plane works, what runs on each node, the key
API objects you'll touch every day, and the full end-to-end journey a Pod takes
from `kubectl apply` to "Running".

---

## Table of Contents

1. [The Big Picture](#the-big-picture)
2. [Control Plane Components](#control-plane-components)
   - [API Server](#api-server)
   - [etcd](#etcd)
   - [Scheduler](#scheduler)
   - [Controller Manager](#controller-manager)
   - [Cloud Controller Manager](#cloud-controller-manager)
3. [Worker Node Components](#worker-node-components)
   - [kubelet](#kubelet)
   - [kube-proxy](#kube-proxy)
   - [Container Runtime](#container-runtime)
4. [Key API Objects](#key-api-objects)
5. [How a Pod Gets Scheduled — End-to-End](#how-a-pod-gets-scheduled--end-to-end)
6. [ASCII Architecture Diagram](#ascii-architecture-diagram)
7. [Further Reading](#further-reading)

---

## The Big Picture

Kubernetes is a **distributed system** that automates the deployment, scaling, and
lifecycle management of containerized workloads. Think of it as an operating system
for your data center: the control plane is the kernel, and the worker nodes are the
hardware.

Every interaction with Kubernetes goes through a single authoritative entry point —
the **API Server**. Nothing communicates directly with etcd or with another component
except through the API Server (with one exception: etcd itself communicates only
with the API Server). This strict fan-out pattern keeps the system auditable and
consistent.

---

## Control Plane Components

The control plane is the "brain" of the cluster. In production it runs on dedicated
nodes (often 3 or 5 for high availability) that are tainted so workloads cannot be
scheduled there.

### API Server

**Real-world analogy:** The API Server is the front-desk receptionist at a large
hospital. Every request — whether from a doctor (kubectl), a nurse (kubelet), or an
automated system (controller) — must go through the receptionist. The receptionist
checks your ID (authentication), verifies you have permission (authorization via
RBAC), validates the paperwork (admission controllers), and then files it in the
records room (etcd).

**What it does:**

- Exposes the Kubernetes REST API over HTTPS (default port 6443).
- Performs **Authentication** — Who are you? (certificates, bearer tokens, OIDC)
- Performs **Authorization** — Are you allowed? (RBAC, ABAC, Webhook)
- Runs **Admission Controllers** — Should this request be allowed/mutated?
  Examples: `LimitRanger`, `ResourceQuota`, `MutatingWebhookConfiguration`.
- Serializes state to etcd. It is the **only** component that reads/writes etcd.
- Implements **watch** semantics — clients subscribe to changes on any resource,
  allowing controllers to react without polling.

**Key insight:** The API Server is stateless. You can run multiple replicas behind a
load balancer for HA. All state lives in etcd.

---

### etcd

**Real-world analogy:** etcd is the hospital's medical records vault. It is the
single source of truth. The receptionist (API Server) is the only one with the key.
Records are replicated to multiple filing cabinets (etcd peers) using the Raft
consensus algorithm so no single cabinet failure loses data.

**What it does:**

- A distributed, strongly-consistent key-value store.
- Stores all cluster state: nodes, pods, secrets, configmaps, RBAC policies,
  custom resources — everything.
- Uses the **Raft consensus protocol** to elect a leader among peers and replicate
  writes. A write is committed only after a quorum (majority) of peers acknowledges
  it.
- Supports **watch** on keys/prefixes, which is how the API Server delivers
  change events to controllers.

**Production considerations:**

- Always run an odd number of etcd members (3 or 5) to maintain quorum during
  a member failure. With 3 members, you tolerate 1 failure. With 5, you tolerate 2.
- etcd is I/O sensitive — use SSDs with low write latency (< 10ms fsync).
- Back up etcd snapshots regularly (`etcdctl snapshot save`). This is your
  disaster-recovery lifeline.
- Encrypt etcd at rest using the `EncryptionConfiguration` API to protect Secrets
  stored in plaintext by default.

---

### Scheduler

**Real-world analogy:** The Scheduler is the hospital's bed manager. When a new
patient arrives (a Pod is created with no `nodeName`), the bed manager looks at all
available rooms (nodes), checks their occupancy and required equipment (resource
requests, node selectors, taints/tolerations, affinity rules), and assigns the
patient to the best available room. The bed manager does **not** move the patient —
it just writes the assignment down; the nurses (kubelets) on each floor handle the
actual admission.

**What it does:**

- Watches for Pods in `Pending` state with no `spec.nodeName`.
- Runs a two-phase algorithm:
  1. **Filtering** — eliminates nodes that cannot run the Pod (insufficient CPU/RAM,
     taint not tolerated, node affinity not satisfied, volume topology mismatch).
  2. **Scoring** — ranks remaining nodes using plugins (least-requested resources,
     image locality, inter-pod affinity spread, custom plugins).
- Writes the chosen `nodeName` back to the Pod spec via the API Server.
- The scheduler is **pluggable** — you can replace or extend it using the
  Scheduling Framework.

**Key scheduling concepts:**

| Concept | What it does |
|---|---|
| `nodeSelector` | Simple key=value match against node labels |
| `nodeAffinity` | Expressive rules (required vs. preferred) against node labels |
| `podAffinity` / `podAntiAffinity` | Schedule near / away from other Pods |
| `taints` + `tolerations` | Nodes repel Pods; Pods opt-in by tolerating |
| `topologySpreadConstraints` | Spread Pods evenly across zones/nodes |
| `priorityClass` | High-priority Pods can preempt lower-priority ones |

---

### Controller Manager

**Real-world analogy:** The Controller Manager is the hospital's department of
automated systems — the HVAC, fire suppression, elevator control, and supply
ordering systems all rolled into one binary. Each sub-system (controller) watches
a specific condition and continuously reconciles the actual state with the desired
state. They don't know about each other; each controller only watches what it cares
about.

**What it does:**

- Runs a collection of control loops (controllers), each responsible for one
  resource type.
- Each controller follows the **reconciliation loop** pattern:
  1. Watch the API Server for the desired state of its resource.
  2. Check the actual state (e.g., how many Pods exist).
  3. Take action to close the gap (create, delete, update).
  4. Repeat.

**Important controllers:**

| Controller | Responsibility |
|---|---|
| Deployment Controller | Creates/updates ReplicaSets to match Deployment spec |
| ReplicaSet Controller | Creates/deletes Pods to match `replicas` count |
| StatefulSet Controller | Manages ordered, stable-identity Pod sets |
| DaemonSet Controller | Ensures one Pod per node (or per matching node) |
| Job Controller | Runs Pods to completion, retries on failure |
| CronJob Controller | Creates Jobs on a cron schedule |
| Namespace Controller | Cleans up resources when a Namespace is deleted |
| Node Controller | Monitors node heartbeats, marks nodes `NotReady`, evicts Pods |
| Service Account Controller | Creates default ServiceAccounts in new Namespaces |
| Endpoints Controller | Populates Endpoints objects from Service + Pod selectors |

---

### Cloud Controller Manager

**Real-world analogy:** The Cloud Controller Manager is the hospital's liaison with
external vendors — the laundry service, food delivery, and security company. It
speaks the language of the outside world (AWS, GCP, Azure APIs) so that the internal
hospital staff (core controllers) don't have to.

**What it does:**

- Separates cloud-provider-specific logic from the core controller manager.
- Manages cloud infrastructure that Kubernetes needs to function:
  - **Node Controller** — Syncs node metadata from the cloud provider (instance ID,
    zone, instance type) and removes nodes from the cluster when cloud instances
    are terminated.
  - **Route Controller** — Programs cloud network routes so nodes can reach each
    other (GCP, older AWS setups).
  - **Service Controller** — Provisions cloud load balancers when a Service of
    type `LoadBalancer` is created.
- Each major cloud provider ships its own CCM binary (e.g., `cloud-provider-aws`,
  `cloud-provider-gcp`).

---

## Worker Node Components

Worker nodes run the actual application workloads. Each node runs three mandatory
components.

### kubelet

**Real-world analogy:** The kubelet is the charge nurse on a hospital floor. It
receives patient assignments (PodSpecs) from the bed manager (Scheduler), admits
the patient (pulls the container image, creates the container), monitors the
patient's vitals (liveness/readiness probes), reports status back to the receptionist
(API Server), and escalates if a patient deteriorates (restarts failed containers).

**What it does:**

- The primary node agent, running on every worker node.
- Watches the API Server for Pods assigned to its node.
- Calls the Container Runtime Interface (CRI) to pull images and start containers.
- Mounts volumes (PVs, ConfigMaps, Secrets, projected tokens) into the Pod.
- Executes **startup**, **liveness**, and **readiness** probes.
  - `startupProbe` — Prevents liveness/readiness checks until the app has started.
  - `livenessProbe` — Restarts a container that is stuck or deadlocked.
  - `readinessProbe` — Controls whether the Pod receives traffic via Services.
- Reports Pod status, node conditions, and resource usage (CPU, memory) to the
  API Server.
- Enforces resource limits via cgroups.
- Does **not** manage containers not created by Kubernetes (unlike Docker daemon).

---

### kube-proxy

**Real-world analogy:** kube-proxy is the hospital's telephone switchboard operator.
When someone calls the hospital's main number asking for "cardiology" (a Service),
the switchboard looks up which extension (Pod IP) to connect them to, applying
load balancing across all cardiologists currently on duty.

**What it does:**

- Runs on every node; implements the Service networking abstraction.
- Watches the API Server for Service and EndpointSlice changes.
- Programs the node's networking layer to forward traffic sent to a Service's
  ClusterIP:Port to a healthy backend Pod IP:Port.
- Supports three modes:
  - **iptables** (default on most clusters) — Installs iptables `DNAT` rules.
    Performant for most clusters; rules are programmed in O(n) with number of
    endpoints — can become slow at 10,000+ endpoints.
  - **ipvs** — Uses Linux IPVS (IP Virtual Server) for O(1) lookups and more
    sophisticated load-balancing algorithms (round-robin, least-connection, etc.).
    Preferred for large clusters.
  - **nftables** (Kubernetes 1.31+, beta) — Modern replacement for iptables.
  - **eBPF** — Used by CNI plugins like Cilium to bypass kube-proxy entirely,
    implementing Service routing at the kernel level for superior performance.

---

### Container Runtime

**Real-world analogy:** The container runtime is the hospital's operating room
equipment — the ventilators, monitors, and surgical tools that actually keep the
patient alive. kubelet tells it what to do; it does the low-level work.

**What it does:**

- The software that actually runs containers on the node.
- kubelet communicates with the runtime via the **CRI** (Container Runtime Interface),
  a gRPC API. This abstraction allows different runtimes to be swapped without
  changing kubelet.
- Responsibilities: pulling images, managing image layers, creating/deleting
  container namespaces (PID, network, mount, UTS, IPC), enforcing cgroup limits.

**Common runtimes:**

| Runtime | Notes |
|---|---|
| **containerd** | Most common; extracted from Docker; used by GKE, EKS, AKS |
| **CRI-O** | Lightweight; designed for Kubernetes; used by OpenShift |
| **Docker Engine** | Removed as a direct runtime in K8s 1.24 (dockershim removed) |
| **gVisor (runsc)** | Sandboxed runtime from Google; adds syscall interception layer |
| **Kata Containers** | VM-level isolation; each Pod runs in a lightweight VM |

---

## Key API Objects

| Object | What it represents |
|---|---|
| **Pod** | The smallest deployable unit. One or more containers sharing a network namespace and storage volumes. Pods are ephemeral — treat them as cattle, not pets. |
| **Deployment** | Declares the desired state of a set of identical Pods. Manages rollouts, rollbacks, and scaling via ReplicaSets. |
| **ReplicaSet** | Ensures N replicas of a Pod template are running. Rarely used directly — Deployments manage them. |
| **StatefulSet** | Like a Deployment, but Pods have stable names (pod-0, pod-1), stable network identities, and ordered, graceful scaling/updates. For databases, queues. |
| **DaemonSet** | Ensures one Pod runs on every (or every matching) node. For node-level agents: log collectors, monitoring exporters, CNI plugins. |
| **Job** | Runs one or more Pods to completion. For batch workloads. |
| **CronJob** | Creates Jobs on a cron schedule. |
| **Service** | A stable virtual IP (ClusterIP) + DNS name in front of a set of Pods. Decouples consumers from the ephemeral Pod IPs. Types: ClusterIP, NodePort, LoadBalancer, ExternalName. |
| **Ingress** | Layer-7 HTTP/HTTPS routing rules. Routes external traffic to Services based on hostname and path. Requires an Ingress Controller (nginx, Traefik, AWS ALB). |
| **ConfigMap** | Stores non-sensitive configuration as key-value pairs. Mounted as files or injected as environment variables. |
| **Secret** | Stores sensitive data (passwords, tokens, certs). Base64-encoded at rest by default — always enable encryption at rest and use an external secrets operator in production. |
| **Namespace** | A virtual cluster within the physical cluster. Provides scope for names, RBAC, resource quotas, and network policies. |
| **PersistentVolume (PV)** | A piece of storage provisioned by an admin or dynamically by a StorageClass. |
| **PersistentVolumeClaim (PVC)** | A user's request for storage. Kubernetes binds a PVC to a suitable PV. |
| **ServiceAccount** | An identity for processes running in a Pod. Used with RBAC to grant Pods permission to call the Kubernetes API. |
| **NetworkPolicy** | Firewall rules for Pods. Controls ingress/egress traffic between Pods and external endpoints. Requires a CNI plugin that enforces policies (Calico, Cilium). |
| **HorizontalPodAutoscaler** | Automatically scales Deployment/StatefulSet replicas based on CPU, memory, or custom metrics. |

---

## How a Pod Gets Scheduled — End-to-End

Below is the complete sequence of events from `kubectl apply` to the Pod reaching
`Running` state. Understanding this flow is essential for diagnosing scheduling
failures and optimizing startup time.

```
Step 1: kubectl apply -f pod.yaml
        └─> kubectl serializes the manifest to JSON
        └─> HTTPS POST to kube-apiserver:6443/api/v1/namespaces/default/pods

Step 2: API Server — Authentication
        └─> Validates the client certificate / bearer token / OIDC token
        └─> Determines the user identity (e.g., system:admin)

Step 3: API Server — Authorization (RBAC)
        └─> Checks: can this identity CREATE pods in this namespace?
        └─> Denied → 403 Forbidden

Step 4: API Server — Admission Controllers (in order)
        └─> MutatingAdmissionWebhook: may inject sidecars, set defaults
        └─> LimitRanger: applies default requests/limits if omitted
        └─> ResourceQuota: checks namespace quota isn't exceeded
        └─> ValidatingAdmissionWebhook: policy checks (OPA/Gatekeeper, Kyverno)
        └─> PodSecurity: enforces PodSecurity standards (restricted/baseline)

Step 5: API Server writes Pod to etcd
        └─> Pod is now in Pending state, spec.nodeName = ""
        └─> API Server sends watch event to all watchers

Step 6: Scheduler receives watch event (Pod with no nodeName)
        └─> Filtering phase: eliminates nodes that can't run this Pod
            ├─ Insufficient CPU or memory
            ├─ Taint not tolerated
            ├─ Node affinity not satisfied
            ├─ Pod affinity/anti-affinity not satisfied
            ├─ Volume topology mismatch
            └─ Node not Ready
        └─> Scoring phase: ranks remaining nodes (0-100 per plugin)
            ├─ LeastAllocated: prefers nodes with more free resources
            ├─ ImageLocality: prefers nodes that already have the image
            ├─ NodeAffinity: bonus for preferred affinity matches
            └─> NodeResourcesFit, InterPodAffinity, etc.
        └─> Scheduler writes spec.nodeName = "node-42" via API Server
        └─> Binding object created (another etcd write)

Step 7: kubelet on node-42 receives watch event
        └─> Sees a Pod assigned to it with phase=Pending

Step 8: kubelet — Image Pull
        └─> Calls CRI (containerd) to pull the image
        └─> containerd pulls layers from registry (if not cached)
        └─> imagePullPolicy: IfNotPresent skips pull if digest matches

Step 9: kubelet — Pod Setup
        └─> Creates the "pause" (infra) container to hold the network namespace
        └─> CNI plugin invoked: assigns Pod IP, programs routes
        └─> Creates volumes: mounts ConfigMaps, Secrets, PVCs, emptyDirs
        └─> Starts init containers in order (each must exit 0 before next starts)

Step 10: kubelet — Main Container Start
         └─> Calls CRI to create and start main containers
         └─> Applies cgroup limits (CPU, memory)
         └─> Injects environment variables (from ConfigMap/Secret refs)

Step 11: kubelet — startupProbe (if configured)
         └─> Probes repeatedly until success or failureThreshold exceeded
         └─> liveness and readiness probes are GATED until startup succeeds
         └─> Prevents premature restarts of slow-starting apps

Step 12: kubelet — readinessProbe
         └─> On success: kubelet marks the Pod condition Ready=True
         └─> Endpoints controller adds the Pod IP to the Service's EndpointSlice
         └─> kube-proxy/CNI programs traffic rules to include this Pod
         └─> Pod starts receiving traffic

Step 13: kubelet — livenessProbe (ongoing)
         └─> If probe fails consecutively (failureThreshold times):
             └─> kubelet sends SIGTERM to the container
             └─> preStop hook runs (e.g., sleep 5 for graceful drain)
             └─> terminationGracePeriodSeconds countdown starts
             └─> Container exits; kubelet restarts it (respecting restartPolicy)

Step 14: Pod is now Running and receiving traffic.
```

---

## ASCII Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                        CONTROL PLANE                                │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                     kube-apiserver                           │  │
│  │      (AuthN → AuthZ → Admission → etcd read/write)          │  │
│  └──────────────┬───────────────────────┬───────────────────────┘  │
│                 │                       │                           │
│         ┌───────┴──────┐       ┌────────┴────────┐                 │
│         │     etcd     │       │   kube-scheduler │                │
│         │  (cluster    │       │  (filter+score   │                │
│         │   state)     │       │   → bind)        │                │
│         └──────────────┘       └─────────────────┘                 │
│                                                                     │
│         ┌───────────────────┐  ┌─────────────────────────────┐     │
│         │  kube-controller  │  │  cloud-controller-manager   │     │
│         │  -manager         │  │  (node, route, service LB)  │     │
│         │  (reconcile loops)│  │                             │     │
│         └───────────────────┘  └─────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────────┘
                │  HTTPS (watch/list/update)
                │
┌───────────────▼───────────────────────────────────────────────────────┐
│                        WORKER NODE                                    │
│                                                                       │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │  kubelet                                                      │    │
│  │  ├─ Watches API Server for assigned Pods                      │    │
│  │  ├─ Calls CRI to pull images, start/stop containers          │    │
│  │  ├─ Mounts volumes (ConfigMap, Secret, PVC, emptyDir)        │    │
│  │  ├─ Runs startup/liveness/readiness probes                   │    │
│  │  └─ Reports node/pod status to API Server                    │    │
│  └──────────────────────────────────────────────────────────────┘    │
│                                                                       │
│  ┌─────────────────────┐    ┌────────────────────────────────────┐   │
│  │  kube-proxy         │    │  Container Runtime (containerd)    │   │
│  │  (iptables/ipvs     │    │  ├─ Pulls OCI images               │   │
│  │   rules for Service │    │  ├─ Manages container lifecycle     │   │
│  │   ClusterIP → Pod)  │    │  └─ CRI gRPC API                   │   │
│  └─────────────────────┘    └────────────────────────────────────┘   │
│                                                                       │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │  Pods (share node kernel, isolated via namespaces + cgroups)   │ │
│  │                                                                 │ │
│  │  ┌───────────────────────────────────────────────────────┐     │ │
│  │  │ Pod A                                                 │     │ │
│  │  │  ┌──────────────┐  ┌──────────────┐  shared:         │     │ │
│  │  │  │ init-ctr     │→ │ main-ctr     │  - network ns    │     │ │
│  │  │  │ (exits 0)    │  │ (nginx)      │  - volumes       │     │ │
│  │  │  └──────────────┘  └──────────────┘  - IPC ns        │     │ │
│  │  │                     ┌──────────────┐                  │     │ │
│  │  │                     │ sidecar-ctr  │                  │     │ │
│  │  │                     │ (log-fwd)    │                  │     │ │
│  │  │                     └──────────────┘                  │     │ │
│  │  └───────────────────────────────────────────────────────┘     │ │
│  └─────────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────────┘

Traffic flow for a Service request:
  Client → kube-proxy DNAT rule → Pod IP:containerPort
  (Service ClusterIP is a virtual IP; packets are rewritten at the node)
```

---

## Further Reading

**Official Kubernetes Documentation**
- [Kubernetes Components](https://kubernetes.io/docs/concepts/overview/components/)
- [The Kubernetes API](https://kubernetes.io/docs/concepts/overview/kubernetes-api/)
- [Scheduling, Preemption and Eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/)
- [Container Lifecycle Hooks](https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/)
- [Configure Liveness, Readiness and Startup Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)

**Deep Dives**
- [etcd FAQ](https://etcd.io/docs/latest/faq/)
- [Raft Consensus Visualized](https://raft.github.io/)
- [The Scheduler Framework](https://kubernetes.io/docs/concepts/scheduling-eviction/scheduling-framework/)
- [A Deep Dive into Kubernetes Controllers](https://engineering.bitnami.com/articles/a-deep-dive-into-kubernetes-controllers.html)
- [Life of a Packet (CNCF)](https://www.youtube.com/watch?v=0Omvgd7Hg1I)

**Security**
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Encrypting Secret Data at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
- [RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [NSA/CISA Kubernetes Hardening Guide](https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF)
