# Kubernetes Interview Preparation Guide

50+ questions and detailed answers organized by difficulty level. Includes scenario-based questions that mirror real production troubleshooting discussions.

---

## Table of Contents

1. [Beginner Questions](#1-beginner-questions)
2. [Intermediate Questions](#2-intermediate-questions)
3. [Advanced Questions](#3-advanced-questions)
4. [Scenario-Based Questions](#4-scenario-based-questions)

---

## 1. Beginner Questions

---

**Q1. What is Kubernetes and why is it used?**

Kubernetes (K8s) is an open-source container orchestration platform that automates deployment, scaling, and management of containerized applications. It abstracts away the underlying infrastructure, allowing you to declare the desired state of your application (what containers to run, how many replicas, what resources they need) and letting Kubernetes continuously reconcile the actual state toward that desired state.

Key capabilities: self-healing (restarts failed containers), horizontal scaling, service discovery and load balancing, rolling deployments, secret and configuration management.

---

**Q2. What is the difference between a Pod and a Container?**

A container is a single process runtime unit managed by a container runtime (containerd, CRI-O). A Pod is the smallest deployable unit in Kubernetes and wraps one or more containers that share the same network namespace (same IP address, same `localhost`), IPC namespace, and optionally storage volumes. Containers within a Pod communicate via `localhost`. Pods are scheduled together on the same node and start and stop together.

The typical pattern is one container per Pod; sidecar containers (logging agents, service mesh proxies, secret injectors) are legitimate reasons for multi-container Pods.

---

**Q3. What is the difference between a Deployment and a StatefulSet?**

| Aspect | Deployment | StatefulSet |
|--------|-----------|-------------|
| Pod identity | Pods are interchangeable; random hash suffix | Each Pod has a stable ordinal name: `<name>-0`, `<name>-1` |
| Network identity | Dynamic IPs; no stable hostname | Stable DNS hostname via headless service: `<pod>.<svc>.<ns>.svc.cluster.local` |
| Storage | Shared or no persistent storage | Each Pod gets its own PVC from `volumeClaimTemplate` |
| Scaling order | Simultaneous | Sequential by default (0→1→2 up, 2→1→0 down) |
| Rolling update | All at once by default | One Pod at a time, in reverse ordinal order |
| Use cases | Stateless apps (web servers, APIs) | Databases, distributed systems with leader election (Zookeeper, Kafka, Cassandra) |

---

**Q4. What is a Namespace and why do you use them?**

A Namespace is a virtual cluster inside a physical Kubernetes cluster. It provides a scope for names (resource names must be unique within a namespace but can repeat across namespaces), and is the boundary for:
- RBAC policies
- ResourceQuotas
- LimitRanges
- NetworkPolicies

Common patterns: separate namespaces per team, per environment (dev/staging/prod in the same cluster), or per application. Cluster-scoped resources (Nodes, PersistentVolumes, ClusterRoles) are not namespaced.

---

**Q5. What are the types of Kubernetes Services?**

- **ClusterIP** (default): Internal-only virtual IP. Pods within the cluster reach the service; nothing external can.
- **NodePort**: Exposes a static port on every node's IP. External clients hit `<nodeIP>:<nodePort>`.
- **LoadBalancer**: Provisions a cloud load balancer (or MetalLB on bare-metal) in front of the service.
- **ExternalName**: CNAME alias for an external DNS name. No proxying.
- **Headless** (ClusterIP: None): Returns pod IPs directly via DNS instead of a single virtual IP. Used with StatefulSets.

---

**Q6. What is a ConfigMap and when would you use it over a Secret?**

A ConfigMap stores non-sensitive configuration data as key-value pairs. Use ConfigMaps for: environment-specific configuration (database hostnames, feature flags, log levels). Use Secrets for: credentials, API keys, TLS certificates, tokens.

The practical difference: Secrets are base64-encoded and (when etcd encryption is enabled) encrypted at rest. ConfigMaps are plaintext. Both can be consumed as environment variables or volume-mounted files.

---

**Q7. What is kubectl apply vs kubectl create?**

`kubectl create` is imperative — it creates a resource; fails if the resource already exists.

`kubectl apply` is declarative — it creates or updates a resource based on the provided YAML. It uses server-side or client-side apply to compute and apply a three-way merge (last applied config, live config, desired config). This is the recommended approach for GitOps and production use because it is idempotent.

---

**Q8. What is a ReplicaSet?**

A ReplicaSet ensures a specified number of pod replicas are running at all times. It uses a label selector to identify the pods it owns. If a pod dies, the ReplicaSet controller creates a replacement. If there are too many pods, it deletes the excess.

In practice, you rarely create ReplicaSets directly — Deployments manage them. A Deployment creates a new ReplicaSet for each new version and manages the rollout by scaling up the new ReplicaSet while scaling down the old one.

---

**Q9. How do liveness, readiness, and startup probes differ?**

- **LivenessProbe**: Is the container alive? If it fails, the kubelet kills and restarts the container. Use for detecting deadlocks.
- **ReadinessProbe**: Is the container ready to receive traffic? If it fails, the pod is removed from Service endpoints. Use for slow initialization or temporary unavailability.
- **StartupProbe**: Has the container started successfully? Disables liveness and readiness probes until it passes. Use for slow-starting applications to avoid premature liveness kills.

Liveness and readiness probes run continuously. The startup probe runs only during initial startup.

---

**Q10. What is a DaemonSet?**

A DaemonSet ensures exactly one copy of a pod runs on each node (or a subset of nodes matching a node selector). When nodes are added, the DaemonSet controller schedules a pod on them automatically. When nodes are removed, the pod is garbage-collected.

Use cases: log collectors (Fluentd, Filebeat), metrics agents (node-exporter, Datadog agent), CNI plugins, storage drivers, Falco runtime security.

---

**Q11. What is the difference between a Job and a CronJob?**

A **Job** runs a pod to completion — it creates one or more pods and retries until the specified number of completions succeed. Use for one-off or batch tasks.

A **CronJob** is a Job scheduled on a cron schedule. It creates Job objects at the configured time. Use for periodic tasks: database backups, report generation, cleanup scripts. CronJobs inherit Job failure handling (`backoffLimit`, `activeDeadlineSeconds`).

---

**Q12. What is a resource request vs a resource limit?**

A **request** is the amount of CPU or memory that Kubernetes guarantees is available to the container. It is used by the scheduler to decide which node can accommodate the pod. The node's allocatable capacity is decremented by the sum of all pod requests on that node.

A **limit** is the maximum amount of CPU or memory a container can use. If a container exceeds its memory limit, it is OOMKilled. If it exceeds its CPU limit, it is throttled by the CFS scheduler (not killed).

---

## 2. Intermediate Questions

---

**Q13. How does a Service find its pods?**

A Service uses a **label selector** defined in `spec.selector`. The Endpoints controller (or EndpointSlice controller in newer clusters) continuously watches for pods with matching labels that are Running and Ready. It populates an Endpoints/EndpointSlice object with those pod IPs and ports.

Kube-proxy on each node watches the EndpointSlice API and programs iptables (or IPVS) rules that map the Service ClusterIP:port to one of the backing pod IPs:port using NAT (DNAT in iptables mode). Traffic is load-balanced across all ready endpoints using a round-robin or random algorithm.

---

**Q14. What happens when you run `kubectl apply -f deployment.yaml`?**

1. **Client-side validation**: `kubectl` checks the YAML against the OpenAPI schema locally and rejects obviously malformed resources.
2. **API server authentication**: The request is authenticated (client certificate, bearer token, or OIDC).
3. **Authorization (RBAC)**: The API server checks whether the authenticated user/ServiceAccount has permission to create or update the resource.
4. **Admission controllers**: Mutating webhooks run first (they can modify the object — e.g., inject sidecars). Then validating webhooks run (they can reject the object — e.g., Kyverno policy checks). Built-in admission controllers (LimitRanger, ResourceQuota) also run here.
5. **Persistence**: The final object is written to etcd.
6. **Controller reconciliation**: The Deployment controller detects the new/changed Deployment via a watch. It creates or updates ReplicaSets. The ReplicaSet controller creates pods. The scheduler assigns pods to nodes. The kubelet starts containers on the assigned nodes.

---

**Q15. What is RBAC in Kubernetes? Explain subjects, verbs, resources, and binding scope.**

RBAC (Role-Based Access Control) governs what API operations are permitted.

**Subjects**: Who is making the request. Types: `User` (human identity from an OIDC provider or certificate), `Group` (collection of users), `ServiceAccount` (machine identity for pods).

**Verbs**: What operation. Common verbs: `get`, `list`, `watch`, `create`, `update`, `patch`, `delete`, `deletecollection`, plus subresource verbs like `exec`, `portforward`, `log`.

**Resources**: What Kubernetes resource type. Examples: `pods`, `services`, `deployments`, `secrets`. Resources can have subresources: `pods/log`, `pods/exec`.

**Role vs ClusterRole**: A `Role` grants permissions in a specific namespace. A `ClusterRole` grants permissions cluster-wide (for cluster-scoped resources like Nodes, or namespaced resources across all namespaces).

**Binding scope**: A `RoleBinding` grants a Role or ClusterRole to a subject within one namespace. A `ClusterRoleBinding` grants a ClusterRole to a subject cluster-wide.

---

**Q16. How do you do a zero-downtime deployment?**

Four components work together:

1. **RollingUpdate strategy** (`strategy.type: RollingUpdate`): Update pods incrementally with `maxSurge` and `maxUnavailable` controls instead of recreating all at once.

2. **ReadinessProbe**: New pod replicas are only added to Service endpoints after their readiness probe passes. Traffic is not sent to unready pods, preventing 502s during startup.

3. **PodDisruptionBudget (PDB)**: Ensures a minimum number of pods remain available during voluntary disruptions (drains, rolling updates). Without a PDB, Kubernetes might evict too many pods simultaneously.

4. **HPA (Horizontal Pod Autoscaler)**: Ensures enough replicas are running to absorb traffic during the update. If you have 2 replicas and `maxUnavailable: 1`, you have 1 pod handling all traffic during each step — this may be insufficient under load.

Additional settings:
- `minReadySeconds`: How long a newly ready pod must be ready before it is considered stable (prevents immediately failing pods from being counted as available)
- `progressDeadlineSeconds`: Maximum time to wait for a rollout to make progress before marking it as failed

---

**Q17. What is a PodDisruptionBudget?**

A PDB limits the number of pods of a replicated application that are simultaneously disrupted during **voluntary** disruptions — node drains, rolling deployments, cluster upgrades. It specifies either `minAvailable` (minimum number of pods that must be up) or `maxUnavailable` (maximum pods that can be unavailable at once).

PDBs are enforced by the eviction API. If draining a node would violate a PDB, the drain operation blocks until it can be satisfied (or the operator forces it). PDBs do not protect against involuntary disruptions (hardware failures, OOMKills).

---

**Q18. Explain the Kubernetes control plane components.**

| Component | Role |
|-----------|------|
| `kube-apiserver` | Single entry point for all API calls; authentication, authorization, admission |
| `etcd` | Distributed key-value store; source of truth for all cluster state |
| `kube-controller-manager` | Runs all built-in controllers (Deployment, ReplicaSet, Job, Node, etc.) |
| `kube-scheduler` | Assigns unscheduled pods to nodes based on resource availability, affinity, taints |
| `cloud-controller-manager` | Interfaces with cloud provider APIs (load balancers, node lifecycle, routes) |

---

**Q19. What is the difference between `kubectl exec` and running a Job?**

`kubectl exec` opens an interactive or one-shot command in a **running container's** existing process namespace. It is good for debugging but does not create a new process in a controlled way — it bypasses scheduling, resource management, and audit trails.

A **Job** creates a new pod with its own resource requests/limits, ServiceAccount, restart policy, and backoff limit. It is auditable, reproducible, and can be tracked. Use Jobs for production tasks (migrations, batch processing). Use `kubectl exec` only for ad-hoc debugging.

---

**Q20. What is Helm and what problems does it solve?**

Helm is a package manager for Kubernetes. It addresses:

1. **Templating**: Kubernetes YAML has no native templating. Helm uses Go templates + a `values.yaml` file to generate environment-specific manifests from a single set of templates.
2. **Release management**: Helm tracks deployed releases (stored as Secrets in the target namespace) and supports atomic upgrades, rollbacks, and uninstalls.
3. **Dependency management**: Charts can declare dependencies on other charts (`Chart.yaml` dependencies).
4. **Distribution**: Charts are packaged and shared via OCI registries or Helm repositories.

Alternatives: Kustomize (no templating, overlay-based), CUE, jsonnet.

---

**Q21. What is the difference between Kustomize and Helm?**

| Aspect | Helm | Kustomize |
|--------|------|-----------|
| Approach | Templating (Go templates + values.yaml) | Overlay patching (no templating) |
| CLI | Separate `helm` binary | Built into `kubectl apply -k` |
| Output | Rendered Kubernetes manifests | Kubernetes manifests |
| Release tracking | Yes (stored in cluster as Secrets) | No |
| Complexity | Higher learning curve; powerful | Simple; opinionated |
| GitOps compatibility | Good (with ArgoCD Helm support) | Excellent (plain YAML output) |

They are often used together: Helm charts for third-party applications, Kustomize overlays for internal applications.

---

**Q22. What is a NetworkPolicy and how does it work?**

A NetworkPolicy is a Kubernetes resource that controls traffic flow to and from pods using label selectors at the IP/port level. It is implemented by the CNI plugin — not all CNI plugins support NetworkPolicy (the default kubenet does not).

NetworkPolicy rules are additive (no explicit deny overrides). A pod with no NetworkPolicy applied to it allows all traffic. A pod with any NetworkPolicy applied to it defaults to deny for the policy types covered (Ingress, Egress) and only allows what the policy explicitly permits.

Common pattern:
1. Apply a default-deny-all policy to a namespace
2. Apply targeted allow policies for each required communication path

---

**Q23. How does Horizontal Pod Autoscaling work?**

HPA runs a control loop (default: every 15 seconds) that:
1. Queries the Metrics API (`metrics.k8s.io` for CPU/memory via Metrics Server, or `custom.metrics.k8s.io` via Prometheus Adapter)
2. Computes the desired replica count: `desiredReplicas = ceil(currentReplicas × (currentMetricValue / desiredMetricValue))`
3. Updates the `spec.replicas` on the target Deployment/StatefulSet

Scale-up is immediate when the threshold is crossed. Scale-down has a configurable stabilization window (default: 300s) to prevent flapping. See `platform/autoscaling/hpa/`.

---

**Q24. What is a ServiceAccount and how is it used?**

A ServiceAccount provides an identity for processes running in pods. Every pod runs under a ServiceAccount (default: `default`). When a pod is created, Kubernetes automatically mounts a projected ServiceAccount token into the pod at `/var/run/secrets/kubernetes.io/serviceaccount/token`.

This token is a short-lived JWT signed by the API server. Pods use it to authenticate API calls to the Kubernetes API server. RBAC permissions are granted to ServiceAccounts via RoleBindings.

Best practice: create dedicated ServiceAccounts per workload; set `automountServiceAccountToken: false` for workloads that do not call the Kubernetes API.

---

## 3. Advanced Questions

---

**Q25. Walk me through how a pod gets scheduled.**

1. A Deployment controller creates a pod object in the API server with `spec.nodeName` unset (unscheduled).
2. The scheduler's informer detects the new unscheduled pod and adds it to the scheduling queue.
3. **Filtering** (predicates): The scheduler filters the full node list down to feasible nodes. Filters include: `NodeUnschedulable`, `PodFitsResources` (CPU/memory), `PodMatchNodeSelector`, `PodToleratesNodeTaints`, `VolumeZonePredicate`, `InterPodAntiAffinity`.
4. **Scoring** (priorities): The scheduler scores feasible nodes using weightedfunctions: `LeastAllocated` (prefer nodes with more free resources), `ImageLocality` (prefer nodes with the image already pulled), `InterPodAffinity` (prefer nodes where preferred pods run).
5. The scheduler selects the highest-scoring node and writes `spec.nodeName` to the pod object via the API server (a "binding" API call).
6. The kubelet on the selected node detects the pod (via watch) and starts the containers.

---

**Q26. What happens when the API server goes down?**

- **Running workloads continue unaffected**: The kubelet maintains pod state independently. Running pods keep running.
- **No new pods can be scheduled**: The scheduler and controllers can't make changes without API server access.
- **kubectl doesn't work**: All API operations fail.
- **Controllers stop reconciling**: If a pod dies while the API server is down, the controller can't create a replacement.
- **etcd is unaffected**: etcd continues running; cluster state is preserved.

This is why control-plane HA (multiple API server replicas behind a load balancer) is critical for production. With etcd running, recovering the API server restores full cluster function.

---

**Q27. Explain the difference between CPU requests, CPU limits, and CPU throttling.**

**CPU request**: The scheduler's input. The node must have this much allocatable CPU for the pod to be placed there. The Linux CFS scheduler also uses requests to determine CPU share priority between competing pods (via `cpu.shares` cgroup parameter).

**CPU limit**: Enforced via CFS bandwidth quota. Each pod is given a quota of CPU time per 100 ms period. If a container consumes its entire quota, it is throttled (cannot run) for the remainder of the period. This adds latency without causing an OOMKill.

**When to omit CPU limits**: For latency-sensitive workloads (web servers, databases), CPU limits can cause significant p99 latency spikes from throttling even when the node has spare capacity. Many SRE teams set only CPU requests (for scheduling) without limits (for burst performance). This requires careful node overcommit management.

**Memory behaves differently**: Memory limits result in OOMKill (SIGKILL), not throttling. Always set memory limits.

---

**Q28. How does etcd achieve consistency?**

etcd uses the **Raft consensus algorithm**. In Raft:
- One node is elected as leader. All writes go through the leader.
- The leader appends the write to its log and sends it to follower nodes.
- Once a **quorum** (majority: ⌊n/2⌋ + 1) of nodes acknowledges the write, it is committed.
- Committed entries are applied to the state machine.

This means etcd requires quorum for writes. A 3-node cluster can tolerate 1 node failure; a 5-node cluster can tolerate 2. You can read from followers but reads may be stale unless you use `linearizable` read mode.

---

**Q29. What is the difference between server-side apply and client-side apply in `kubectl apply`?**

**Client-side apply**: `kubectl` stores the "last applied configuration" as an annotation (`kubectl.kubernetes.io/last-applied-configuration`) on the resource. On subsequent applies, it computes a three-way merge between the last applied config, the live config, and the new config. Fields not present in the last applied config are assumed to be managed by other actors and are not removed.

**Server-side apply** (`kubectl apply --server-side`): The merge logic runs on the API server rather than the client. The API server tracks **field managers** — each controller or actor owns specific fields. Conflicts (where two actors try to manage the same field) are reported as errors rather than silently overwritten. This is more robust for GitOps scenarios with multiple managers.

---

**Q30. How does Kubernetes handle secret rotation with ESO?**

External Secrets Operator (ESO) periodically reconciles `ExternalSecret` resources by polling the external provider (AWS Secrets Manager, Vault, etc.) at a configurable `refreshInterval`. When the secret value changes in the provider, ESO detects the change and updates the Kubernetes Secret object.

For running pods to pick up the new secret value:
- **Environment variables**: Pods must be restarted (rolling restart) because env vars are set at pod start time
- **Volume-mounted secrets**: The kubelet periodically syncs mounted secret volumes (default sync period: 60s). The file on disk is updated automatically without pod restart — applications must handle file content changes (e.g., reload on SIGHUP or watch the file)

---

**Q31. What is the Operator pattern and when should you use it?**

An Operator is a combination of a Custom Resource Definition (CRD) and a controller that encodes operational domain knowledge. The controller watches instances of the CRD and reconciles the actual state toward the desired state.

Use an Operator when:
- The application has complex lifecycle operations (backups, failover, upgrades) that require domain knowledge beyond what Kubernetes primitives provide
- You need to manage external resources in response to Kubernetes events
- The application is a stateful system with non-trivial scaling semantics

Examples: PostgreSQL Operator (CNPG), Kafka Operator (Strimzi), cert-manager, External Secrets Operator.

---

**Q32. Explain the scheduling framework and extension points.**

The Kubernetes scheduling framework defines a plugin-based architecture with well-defined extension points:

- **PreFilter / Filter**: Eliminate infeasible nodes (e.g., resource insufficiency, taints, affinity)
- **PreScore / Score**: Rank feasible nodes (e.g., balanced resource usage, image locality)
- **Reserve**: Mark resources as reserved before binding to prevent race conditions
- **Permit**: Allow plugins to delay or conditionally approve binding (used by gang scheduling: wait until all pods in a group can be co-scheduled)
- **PreBind / Bind / PostBind**: Perform binding and post-binding actions (e.g., provision a CSI volume before binding)

Custom scheduler plugins implement these interfaces and register with the scheduler framework. The default scheduler includes ~30 built-in plugins.

---

**Q33. What is a VolumeSnapshot and how does it interact with StatefulSets?**

A VolumeSnapshot is a point-in-time copy of a PVC, backed by the CSI driver's snapshot capability. The VolumeSnapshot API has three objects:
- `VolumeSnapshotClass`: Defines the CSI driver and snapshot parameters
- `VolumeSnapshot`: The actual snapshot request
- `VolumeSnapshotContent`: The underlying snapshot resource (like PV for PVC)

For StatefulSets, snapshots are typically taken per-PVC using a script or Kubernetes Job that iterates over the StatefulSet's PVCs. There is no built-in StatefulSet-level snapshot primitive. Restore is done by creating a new PVC from the snapshot using `spec.dataSource`.

---

## 4. Scenario-Based Questions

---

**Q34. A production pod is OOMKilled — walk me through diagnosing and fixing it.**

**Step 1 — Confirm OOMKill:**
```bash
kubectl describe pod <pod-name> -n <namespace>
# Look for: Last State: Terminated  Reason: OOMKilled  Exit Code: 137
```

**Step 2 — Understand current memory usage:**
```bash
kubectl top pod <pod-name> -n <namespace> --containers
# Check if current usage approaches the limit
```

**Step 3 — Check historical usage in Prometheus/Grafana:**
Look at `container_memory_working_set_bytes` for the container. Is usage gradually growing (memory leak) or spiking suddenly (request spike, large batch)?

**Step 4 — Immediate mitigation:**
```bash
# Increase the memory limit temporarily
kubectl set resources deployment/<name> -n <namespace> \
  --limits=memory=2Gi --requests=memory=1Gi
```

**Step 5 — Root cause analysis:**
- **Memory leak**: Profile the application (heap dump, Go pprof, Java heap analysis). Fix the leak in code.
- **Correct limit too low**: Use VPA recommendation mode (`platform/autoscaling/vpa/vpa-auto.yml`) to find the right sizing. Increase limit permanently.
- **Traffic spike**: Scale horizontally (HPA) so each pod handles less load.
- **Large dataset in memory**: Optimize the algorithm, add pagination, or use streaming instead of loading all data at once.

**Step 6 — Prevent recurrence:**
- Set memory requests == limits (Guaranteed QoS — pod is not evicted under memory pressure)
- Configure VPA auto mode for non-latency-sensitive workloads
- Add Prometheus alerting: `container_memory_working_set_bytes / container_spec_memory_limit_bytes > 0.8`

---

**Q35. Ingress is returning 502 — what's your debugging process?**

502 Bad Gateway means the ingress controller received an invalid response from the upstream (backend service), or could not connect at all.

**Step 1 — Confirm and scope:**
```bash
curl -v https://my-app.example.com/api/health
# Capture headers: look for X-Request-ID, server headers indicating ingress vs backend
kubectl get ingress -n <namespace>
kubectl describe ingress <ingress-name> -n <namespace>
```

**Step 2 — Check ingress controller logs:**
```bash
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=50
# Look for: "error obtaining endpoints" or "connect: connection refused"
```

**Step 3 — Check backend Service endpoints:**
```bash
kubectl get endpoints <backend-svc> -n <namespace>
# If empty: pods are not ready or selector doesn't match
```

**Step 4 — Check pod readiness:**
```bash
kubectl get pods -n <namespace> -l app=<backend>
# If not Running/Ready: check pod logs and describe
kubectl logs <backend-pod> -n <namespace>
kubectl describe pod <backend-pod> -n <namespace>
```

**Step 5 — Direct connectivity test:**
```bash
# Port-forward directly to bypass ingress
kubectl port-forward svc/<backend-svc> 8080:80 -n <namespace>
curl http://localhost:8080/api/health
# If this works, the problem is in ingress → service routing
# If this fails, the problem is in the application
```

**Step 6 — Common causes and fixes:**

| Cause | Symptom | Fix |
|-------|---------|-----|
| No ready pods | Empty endpoints | Fix CrashLoopBackOff, readiness probe |
| Wrong targetPort | Endpoints populated but connection refused | Align targetPort with container port |
| TLS mismatch | SSL handshake errors in ingress logs | Check backend TLS settings (`nginx.ingress.kubernetes.io/backend-protocol: HTTPS`) |
| Application error | 502 with valid connection | Fix application bug (check app logs) |
| NetworkPolicy blocking | Connection refused from ingress controller | Add NetworkPolicy allowing ingress-nginx namespace |

---

**Q36. Your deployment has been running for weeks. A config change is needed but you can't take any downtime. How do you proceed?**

1. **Update the ConfigMap** (if the config is in a ConfigMap): `kubectl apply -f new-configmap.yaml`

2. **Trigger a rolling restart** to pick up new config:
```bash
kubectl rollout restart deployment/<name> -n <namespace>
```

3. **Monitor the rollout**:
```bash
kubectl rollout status deployment/<name> -n <namespace>
kubectl get pods -n <namespace> -w
```

4. **Verify the PDB is in place** before starting:
```bash
kubectl get pdb -n <namespace>
```
If not, create one: `kubectl apply -f - <<EOF ... EOF`

5. **Watch readiness probes**: Only proceed with the rollout if pods are becoming Ready. The rolling update will pause if the readiness probe fails (the failed pod is not considered Available).

6. **If something goes wrong**:
```bash
kubectl rollout undo deployment/<name> -n <namespace>
```

7. **Post-verification**: Check application metrics, error rates, and latency in Grafana before closing the change.

---

**Q37. A developer says "my pod can't connect to the database." How do you debug it?**

**Step 1 — Reproduce from inside the pod:**
```bash
kubectl exec -it <app-pod> -n <namespace> -- /bin/sh
# Test DNS
nslookup mysql.production.svc.cluster.local
# Test TCP connectivity
nc -zv mysql.production.svc.cluster.local 3306
```

**Step 2 — Check Service and Endpoints:**
```bash
kubectl get svc mysql -n <namespace>
kubectl get endpoints mysql -n <namespace>
```

**Step 3 — Check NetworkPolicy:**
```bash
kubectl get networkpolicy -n <namespace>
kubectl get networkpolicy -n production   # database namespace
```
Check if there's a default-deny in the database namespace and whether the app pod's namespace is explicitly allowed.

**Step 4 — Check credentials:**
```bash
# Verify the Secret exists and the keys are correct
kubectl get secret db-credentials -n <namespace>
kubectl get secret db-credentials -n <namespace> \
  -o jsonpath='{.data.password}' | base64 -d
```

**Step 5 — Check database pod health:**
```bash
kubectl get pods -n production -l app=mysql
kubectl logs -n production <mysql-pod>
```

**Step 6 — Cross-namespace networking:**
If app is in namespace `app` and DB is in namespace `production`, ensure there's a NetworkPolicy in `production` allowing ingress from namespace `app`.

---

**Q38. How would you migrate a StatefulSet from one StorageClass to another with zero data loss?**

This is a complex operation with no native Kubernetes migration primitive. The process:

1. **Scale down the StatefulSet** to 0 replicas (quiesce writes)
2. **Create VolumeSnapshots** of all PVCs
3. **Create new PVCs** from the snapshots using the new StorageClass:
```yaml
spec:
  storageClassName: new-storage-class
  dataSource:
    name: my-snapshot
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
```
4. **Update the StatefulSet's `volumeClaimTemplate`** — note: this field is immutable on existing StatefulSets. You must delete the StatefulSet with `--cascade=orphan` (keeps pods and PVCs alive), update the spec, and recreate it.
5. **Patch existing pods** to mount the new PVCs (or delete and recreate them).
6. **Scale back up** and verify data integrity.

This operation should be done during a maintenance window with backups verified.

---

**Q39. How do you handle secret rotation for a running application with zero downtime?**

1. **Update the secret in the external provider** (AWS Secrets Manager, Vault).
2. **ESO picks up the change** within the `refreshInterval` and updates the Kubernetes Secret.
3. **If mounted as a volume**: The kubelet syncs the mounted file within 60s (configurable). Applications must either watch the file for changes or reload on SIGHUP.
4. **If injected as env var**: Pod must be restarted. Use `kubectl rollout restart deployment/<name>` to trigger a zero-downtime rolling restart.
5. **Old credential validity**: Keep the old credential valid for a grace period (2× the pod rollout time) so in-flight requests using old credentials don't fail.
6. **Verify**: After rollout, test that the application successfully connects using the new credential.

---

**Q40. How would you set up multi-tenancy in a Kubernetes cluster?**

Multi-tenancy in Kubernetes is layered:

**Namespace isolation**:
- One namespace per tenant (or namespace per team)
- ResourceQuotas to cap resource consumption per namespace
- LimitRanges to set default requests/limits and prevent unbounded pods

**RBAC isolation**:
- Each tenant gets a ServiceAccount and RoleBinding scoped to their namespace
- No cross-namespace RBAC unless explicitly granted
- No ClusterAdmin for tenant users

**Network isolation**:
- Default-deny NetworkPolicy per namespace
- Explicit allow rules for allowed communication paths

**Image policy**:
- Kyverno/OPA policies restricting which registries are allowed
- Admission webhooks enforcing image signing requirements

**Hard vs soft multi-tenancy**:
- **Soft**: All tenants share the same cluster; isolation is policy-enforced. Cost-effective but blast radius if isolation fails.
- **Hard**: Separate clusters per tenant (vcluster, Cluster API). True isolation but higher operational cost.

---

**Q41. What is a common cause of scheduling failures in large clusters?**

**Resource fragmentation**: The cluster has sufficient total CPU/memory, but no single node has enough free capacity for the pod's requests. This happens when many small pods fully occupy nodes but no node has a large enough contiguous gap for a big pod.

**Fix**: Use `topologySpreadConstraints` to spread pods evenly across nodes. Implement bin-packing or Descheduler to rebalance running pods. Use node autoscaling (Cluster Autoscaler, Karpenter) to add nodes sized to the pending pod.

Other common causes:
- `NodeAffinity` or `NodeSelector` with too few matching nodes
- All matching nodes tainted without matching pod tolerations
- PodAntiAffinity with `required` (hard) rules that cannot be satisfied
- VolumeZonePredicate: all nodes in the correct zone are full

---

**Q42. Describe your approach to debugging a performance regression after a deployment.**

1. **Correlate with deployment time** in Grafana: was the regression visible immediately after the deployment timestamp?
2. **Check application-level metrics**: request latency (p50, p95, p99), error rate, throughput
3. **Check resource utilization**: CPU throttling (`container_cpu_cfs_throttled_seconds_total`), memory usage, GC pauses (if JVM/Go)
4. **Check pod restarts**: OOMKills cause latency spikes during restart
5. **Compare the diff**: `kubectl diff -f deployment.yaml` — what changed? (image tag, env vars, resources, replicas)
6. **Roll back immediately** if degradation is severe: `kubectl rollout undo deployment/<name>`
7. **Post-mortem**: Re-deploy in staging with load testing (k6, Gatling) to reproduce and identify the root cause before re-deploying to production
