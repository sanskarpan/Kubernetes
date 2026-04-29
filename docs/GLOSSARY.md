# Kubernetes and Cloud-Native Glossary

A comprehensive reference of Kubernetes and cloud-native terminology, alphabetically sorted. Definitions aim to be precise and production-oriented.

---

## A

## Admission Controller

A piece of code that intercepts requests to the Kubernetes API server after authentication and authorization but before persistence of the object. Admission controllers can be validating (reject non-conforming requests) or mutating (modify requests). Examples include `PodSecurity`, `LimitRanger`, `ResourceQuota`, `MutatingAdmissionWebhook`, and `ValidatingAdmissionWebhook`. They are the primary enforcement point for cluster-wide policy.

## API Server

The central management component of a Kubernetes control plane (`kube-apiserver`). It exposes the Kubernetes API over HTTPS, handles REST operations, performs authentication, authorization, and admission control, and writes state to etcd. All cluster components communicate exclusively through the API server — no component writes directly to etcd.

## AppArmor

A Linux Security Module (LSM) that confines programs to a limited set of resources using per-program profiles. In Kubernetes, AppArmor profiles can be applied to containers via pod annotations or the `securityContext.appArmorProfile` field (GA in 1.30), restricting which system calls and file paths a container process may access.

## ArgoCD

A declarative, GitOps continuous delivery tool for Kubernetes. ArgoCD monitors a Git repository and automatically reconciles the live cluster state with the desired state declared in the repository. It provides a web UI, CLI, and RBAC-aware sync policies. See `gitops/argocd/` in this repository.

---

## B

## BestEffort

The lowest Quality of Service (QoS) class in Kubernetes, assigned to pods that specify no resource requests or limits on any container. BestEffort pods are the first to be evicted under node memory pressure.

## Burstable

A QoS class assigned to pods where at least one container has a resource request or limit set, but where requests and limits are not equal across all containers. Burstable pods are evicted after BestEffort pods under node memory pressure.

---

## C

## CFS Quota

Completely Fair Scheduler quota — the Linux kernel mechanism used to enforce CPU limits in Kubernetes. When a container exceeds its CPU limit, the kernel throttles it using CFS quota periods (default 100 ms). Excessive CPU throttling can degrade latency-sensitive workloads without causing an OOMKill, making it difficult to diagnose.

## ClusterIP

The default Kubernetes Service type. It exposes the service on a cluster-internal virtual IP address. Traffic to this IP is load-balanced across all matching pods. ClusterIP services are not reachable from outside the cluster directly. See `networking/services/clusterip.yaml`.

## ClusterRole

A non-namespaced RBAC resource that grants permissions to cluster-scoped resources (nodes, PersistentVolumes) or to namespaced resources across all namespaces. A ClusterRole is bound to a subject using a ClusterRoleBinding (cluster-wide) or a RoleBinding (namespace-scoped grant of cluster-level role).

## ConfigMap

A Kubernetes API object that stores non-confidential configuration data as key-value pairs. ConfigMaps can be consumed by pods as environment variables, command-line arguments, or mounted as files in a volume. ConfigMaps are not encrypted at rest by default — never store sensitive data in a ConfigMap.

## Container Runtime

The low-level software responsible for running containers on a node. Kubernetes communicates with the container runtime through the Container Runtime Interface (CRI). Common runtimes include containerd, CRI-O, and (historically) Docker. The runtime pulls images, creates namespaces, manages cgroups, and starts container processes.

## Container Runtime Interface (CRI)

A plugin API that enables the Kubernetes kubelet to use different container runtimes without recompilation. Any runtime implementing the CRI gRPC interface can be used with Kubernetes.

## Controller

A control loop that watches the state of the cluster through the API server and makes changes to move the current state toward the desired state. Examples: Deployment controller, ReplicaSet controller, Job controller, Node controller. Controllers run as part of `kube-controller-manager`.

## CRD (Custom Resource Definition)

A Kubernetes extension mechanism that allows users to define new resource types. Once a CRD is installed, instances of the custom resource can be created, updated, and deleted via the Kubernetes API like any built-in resource. CRDs are the foundation of the Kubernetes operator pattern.

## CSI (Container Storage Interface)

A standardized API that allows storage vendors to develop plugins that work with Kubernetes without modifying core Kubernetes code. CSI drivers handle provisioning, attaching, mounting, and snapshotting of volumes. Examples: AWS EBS CSI, GCP PD CSI, Azure Disk CSI, Ceph CSI.

---

## D

## DaemonSet

A workload resource that ensures a copy of a pod runs on all (or a subset of) nodes in a cluster. DaemonSets are used for cluster-wide services such as log collectors (Fluentd), metrics agents (node-exporter), and network plugins (Calico, Cilium). When nodes are added, the DaemonSet controller schedules a pod on the new node automatically. See `core/workloads/daemonset/`.

## Deployment

The most common workload resource for stateless applications. A Deployment manages a ReplicaSet, which in turn manages pods. Deployments support declarative rolling updates and rollbacks. Key fields: `replicas`, `selector`, `strategy` (RollingUpdate or Recreate), `template`. See `core/workloads/deployment/`.

## DownwardAPI

A mechanism that allows pods to access metadata about themselves (pod name, namespace, node name, resource requests/limits, labels, annotations) as environment variables or volume-mounted files, without calling the Kubernetes API directly.

---

## E

## Endpoint / EndpointSlice

An Endpoint object tracks the IP addresses and ports of pods that match a Service's label selector. EndpointSlices (GA in 1.21) replace Endpoints for large clusters, sharding pod IPs into smaller, more scalable slices. Kube-proxy reads EndpointSlices to program network rules.

## etcd

A distributed key-value store used by Kubernetes as its primary backing store for all cluster data. etcd provides strong consistency (via Raft consensus) and watch semantics that enable the API server to stream changes to controllers. etcd should be encrypted at rest, backed up regularly, and run with odd-numbered member counts (3 or 5) for quorum tolerance.

## ExternalName

A Service type that maps a Service DNS name to an external DNS name using a CNAME record. No proxying occurs — the cluster DNS resolver returns the CNAME. Useful for abstracting access to external services (e.g., a managed database) behind a Kubernetes Service name.

## ExternalSecret

A custom resource provided by External Secrets Operator (ESO) that syncs secrets from external providers (AWS Secrets Manager, GCP Secret Manager, HashiCorp Vault, etc.) into Kubernetes Secret objects. ESO is the recommended approach for secrets management in production. See `platform/security/eso/`.

---

## F

## Falco

An open-source cloud-native runtime security tool that detects anomalous behavior in containers and hosts using system call monitoring. Falco rules can alert on actions such as shell spawning inside a container, unexpected network connections, or privilege escalation attempts.

## Finalizer

A namespaced key registered in a resource's `metadata.finalizers` list. When a resource with finalizers is deleted, Kubernetes places it in a "terminating" state and notifies the registered controller. The controller performs cleanup and removes the finalizer, allowing the resource to be garbage-collected. Orphaned finalizers can cause resources to be stuck terminating.

---

## G

## Gateway API

A Kubernetes SIG-Networking project that provides a more expressive, extensible, and role-oriented alternative to Ingress. Gateway API defines GatewayClass, Gateway, HTTPRoute, TCPRoute, and other resources. It reached GA (for core resources) in Kubernetes 1.31.

## GitOps

An operational model where the desired state of infrastructure and applications is stored in Git and automatically reconciled with the live environment by a controller (ArgoCD, Flux). Git becomes the single source of truth; changes are made via pull requests, providing auditability, rollback, and consistency.

## Guaranteed

The highest QoS class in Kubernetes. A pod is Guaranteed when every container in the pod has equal and non-zero CPU and memory requests and limits. Guaranteed pods are the last to be evicted under node memory pressure.

---

## H

## Helm

The de facto package manager for Kubernetes. Helm packages (called charts) are templates of Kubernetes manifests parameterized by values. Helm manages release lifecycle: install, upgrade, rollback, uninstall. Helm 3 removed the server-side Tiller component; releases are stored as Secrets in the target namespace. See `helm/` in this repository.

## HPA (Horizontal Pod Autoscaler)

A Kubernetes controller that automatically scales the number of pod replicas in a Deployment, ReplicaSet, or StatefulSet based on observed metrics (CPU utilization, memory, or custom metrics via the metrics API). HPA queries the Metrics Server or Prometheus Adapter every 15 seconds (default) and adjusts replicas within configured min/max bounds. See `platform/autoscaling/hpa/`.

## hostPath

A volume type that mounts a file or directory from the host node's filesystem into a pod. hostPath volumes are a security risk (they break container isolation) and should be avoided in production workloads. They are used by privileged infrastructure components such as node-exporter and Falco.

---

## I

## IaC (Infrastructure as Code)

The practice of managing and provisioning infrastructure through declarative or imperative code rather than manual processes. In the Kubernetes ecosystem, IaC tools include Terraform, Pulumi, and Crossplane (Kubernetes-native). All cluster configuration in this repository follows IaC principles.

## Ingress

A Kubernetes API object that manages external HTTP/HTTPS access to services within a cluster. An Ingress resource defines routing rules (host, path) and optionally TLS termination. An IngressController (e.g., ingress-nginx, Traefik, HAProxy Ingress) must be installed to satisfy Ingress rules. See `networking/ingress/`.

## Init Container

A specialized container that runs to completion before any app containers in a pod start. Init containers run sequentially. They are used for setup tasks such as waiting for a dependency, migrating a database schema, or populating a shared volume. Init containers do not need to include the app image.

---

## J

## Job

A Kubernetes workload resource that creates one or more pods and ensures they run to successful completion. Jobs are used for batch tasks, database migrations, and one-off scripts. Key fields: `completions`, `parallelism`, `backoffLimit`, `completionMode` (Indexed, available since 1.24 GA). See `core/workloads/jobs/`.

---

## K

## Kube-proxy

A network proxy that runs on each node and implements the Kubernetes Service abstraction. Kube-proxy programs iptables (or IPVS) rules to intercept traffic destined for Service ClusterIPs and redirect it to one of the backing pod IPs. In newer CNI plugins (Cilium in eBPF mode), kube-proxy can be replaced entirely.

## Kubelet

The primary node agent that runs on each worker node. The kubelet watches the API server for pods assigned to its node, interacts with the container runtime via CRI to start/stop containers, reports node and pod status, manages volume mounts, and runs readiness/liveness probes.

## Kustomize

A Kubernetes-native configuration management tool (built into `kubectl apply -k`) that customizes raw YAML manifests without templating. Kustomize uses overlays and patches to produce environment-specific configurations from a base. Unlike Helm, Kustomize requires no separate CLI and produces plain Kubernetes YAML. See `core/workloads/deployment/kustomize/`.

---

## L

## LimitRange

A policy object that enforces resource constraints (min, max, default requests, default limits) per container or pod within a namespace. When a pod is created without explicit resource requests or limits, LimitRange applies the default values. See `core/storage/limitrange.yml`.

## LivenessProbe

A diagnostic that the kubelet runs periodically to determine if a container is still alive. If a liveness probe fails, the kubelet kills the container and restarts it according to the pod's `restartPolicy`. Common probe types: `httpGet`, `tcpSocket`, `exec`, `grpc`.

## LoadBalancer

A Service type that provisions an external load balancer (typically a cloud provider LLB) in front of the Service. The cloud controller manager handles provisioning. NodePort and ClusterIP are automatically created as well. On bare-metal clusters, tools like MetalLB or kube-vip provide LoadBalancer support.

---

## N

## Namespace

A mechanism for dividing cluster resources between multiple users or teams. Namespaces provide a scope for names (resource names must be unique within a namespace), and they are the boundary for RBAC policies, ResourceQuotas, LimitRanges, and NetworkPolicies. Cluster-scoped resources (Nodes, PersistentVolumes, ClusterRoles) are not namespaced.

## NetworkPolicy

A Kubernetes resource that controls traffic flow to and from pods at the IP/port level using label selectors. NetworkPolicy rules are additive (no deny overrides). A common pattern is to apply a default-deny-all policy to a namespace and then explicitly allow necessary traffic. CNI plugins must support NetworkPolicy; the default kubenet CNI does not. See `networking/network-policies/`.

## NodePort

A Service type that exposes the service on a static port on each node's IP address (range 30000–32767 by default). Any traffic sent to `<NodeIP>:<NodePort>` is routed to the service. NodePort is suitable for development and bare-metal clusters without a cloud load balancer.

---

## O

## Observability

The ability to understand the internal state of a system by examining its outputs. In the Kubernetes ecosystem, observability is built from three pillars: metrics (Prometheus, Grafana), logs (Loki, EFK stack), and traces (Jaeger, Tempo). See `observability/` in this repository.

## Operator

A method of packaging, deploying, and managing a Kubernetes application using Custom Resources and controllers that encode operational domain knowledge. An Operator extends the Kubernetes API to automate the lifecycle of complex stateful applications (databases, message queues, ML pipelines).

---

## P

## PersistentVolume (PV)

A piece of storage in the cluster that has been provisioned by an administrator or dynamically by a StorageClass. A PV is a cluster-scoped resource with its own lifecycle independent of any pod. It captures details of the storage implementation (NFS path, EBS volume ID, Ceph RBD image). See `core/storage/persistent-volume.yml`.

## PersistentVolumeClaim (PVC)

A request for storage by a user. A PVC specifies access mode, storage class, and capacity. Kubernetes binds a PVC to a matching PV. Pods consume storage by referencing PVCs in their volume specifications. See `core/storage/persistent-volume-claim.yml`.

## Pod

The smallest deployable unit in Kubernetes. A pod encapsulates one or more containers that share a network namespace (same IP), IPC namespace, and optional storage volumes. Containers in a pod communicate via `localhost`. Pods are ephemeral — they are created and destroyed rather than moved or migrated.

## PodDisruptionBudget (PDB)

A policy that limits the number of pods of a replicated application that are simultaneously disrupted during voluntary disruptions (node drain, rolling update). PDB specifies `minAvailable` or `maxUnavailable`. PDBs are enforced by the eviction API and are respected by the scheduler during draining and upgrades.

## PodSecurityAdmission (PSA)

A built-in admission controller (GA in 1.25) that enforces Pod Security Standards at the namespace level using labels. Three policy levels: `privileged` (no restrictions), `baseline` (minimal restrictions), `restricted` (hardened). Three modes per level: `enforce` (reject), `audit` (log), `warn` (warning). Replaced the deprecated PodSecurityPolicy. See `platform/security/pod-security/`.

## PodSecurityContext

The security settings applied at the pod level (applying to all containers): `runAsUser`, `runAsGroup`, `fsGroup`, `runAsNonRoot`, `seccompProfile`, `supplementalGroups`. Container-level `securityContext` overrides pod-level settings for individual containers.

---

## Q

## QoS Class

Quality of Service class assigned by Kubernetes to pods based on resource requests and limits. Three classes in descending priority: Guaranteed (requests == limits for all containers), Burstable (at least one container has requests/limits, not all equal), BestEffort (no requests or limits). QoS class determines eviction priority under node memory pressure.

---

## R

## RBAC (Role-Based Access Control)

The authorization mechanism in Kubernetes that regulates access to the API based on the roles assigned to users, groups, or service accounts. Core objects: Role (namespaced permissions), ClusterRole (cluster-wide permissions), RoleBinding (bind role to subject in a namespace), ClusterRoleBinding (bind role to subject cluster-wide). See `platform/security/rbac/`.

## ReadinessProbe

A diagnostic that the kubelet runs to know when a container is ready to accept traffic. Until the readiness probe passes, the pod's IP is removed from the Service's endpoints, preventing traffic from reaching an unready pod. ReadinessProbes should reflect actual application readiness (e.g., a `/healthz` HTTP check that verifies database connectivity).

## ReplicaSet

A workload resource that ensures a specified number of pod replicas are running at any given time. ReplicaSets are rarely created directly — Deployments manage ReplicaSets automatically to enable rolling updates and rollbacks. The ReplicaSet controller reconciles the actual pod count against `spec.replicas`.

## ResourceQuota

A policy object that limits aggregate resource consumption per namespace. ResourceQuota can cap CPU, memory, storage, object count (pods, services, configmaps), and QoS class usage. When a quota is exceeded, the API server rejects new resource creation with a 403 error.

---

## S

## SBOM (Software Bill of Materials)

A formal inventory of all components, libraries, and dependencies in a software artifact (container image). SBOMs support supply chain security by enabling vulnerability scanning and license auditing. Tools: Syft (generate), Grype (scan), in-toto (attestation).

## Secret

A Kubernetes API object for storing small amounts of sensitive data (passwords, tokens, TLS certificates). Secrets are base64-encoded (not encrypted) by default. In production, enable etcd encryption at rest and use External Secrets Operator to sync from a secrets manager. Never commit plain Secrets to Git. See `platform/security/eso/`.

## SealedSecret

A custom resource from the Bitnami Sealed Secrets controller that encrypts a Kubernetes Secret using a public key so it can be safely stored in Git. Only the controller in the target cluster holds the private key to decrypt it. See `platform/security/sealed-secrets/`.

## seccomp

Secure Computing Mode — a Linux kernel feature that restricts the system calls available to a process. In Kubernetes, seccomp profiles can be applied via `securityContext.seccompProfile`. The `RuntimeDefault` profile (available since 1.27 as stable) applies the container runtime's default seccomp policy, blocking dangerous syscalls.

## Service

A stable network endpoint that provides load-balanced access to a set of pods. A Service has a persistent ClusterIP and DNS name (even as pods come and go), and routes traffic to pods selected by a label selector. Types: ClusterIP, NodePort, LoadBalancer, ExternalName. See `networking/services/`.

## ServiceAccount

A Kubernetes identity for processes running in pods. Every pod runs under a ServiceAccount (default: `default`). ServiceAccounts are used to grant pods specific RBAC permissions to interact with the Kubernetes API. Best practice: create dedicated ServiceAccounts per workload with least-privilege roles.

## ServiceMonitor

A Custom Resource from the Prometheus Operator that declaratively configures Prometheus to scrape metrics from a Service. ServiceMonitor selects services by label and defines scrape parameters (path, interval, TLS). See `observability/prometheus/`.

## SLSA (Supply chain Levels for Software Artifacts)

A security framework providing standards and controls for software supply chain integrity, defined in levels 1–4. Higher levels require more provenance guarantees: source integrity (version control), build integrity (hermetic builds), and artifact signing.

## SRE (Site Reliability Engineering)

A discipline that applies software engineering principles to reliability, scalability, and operational problems. SRE practices include defining SLOs (Service Level Objectives), error budgets, blameless postmortems, and toil reduction through automation.

## StartupProbe

A probe for slow-starting containers that prevents the liveness probe from killing a container before the application has had a chance to initialize. Once the startup probe succeeds, the liveness and readiness probes take over.

## StatefulSet

A workload resource for stateful applications that require stable network identities, ordered deployment/scaling, and persistent storage. Each pod in a StatefulSet gets a stable hostname (`<name>-<ordinal>`) and its own PVC created from a `volumeClaimTemplate`. See `core/workloads/statefulset/`.

## StorageClass

A cluster-level resource that describes the "class" of storage offered by a provisioner. StorageClasses parameterize the provisioner, reclaim policy, volume binding mode, and allowed topologies. Dynamic volume provisioning uses StorageClasses to create PVs on demand.

---

## T

## Taint

A key-value-effect triplet applied to a node that repels pods unless the pod has a matching Toleration. Effects: `NoSchedule` (do not schedule new pods), `PreferNoSchedule` (avoid scheduling if possible), `NoExecute` (evict existing pods). Taints are used to reserve nodes for specific workloads (GPU nodes, control-plane nodes).

## Toleration

A field in a pod spec that allows the pod to be scheduled onto nodes with matching Taints. A Toleration does not guarantee scheduling on a tainted node — a NodeSelector or NodeAffinity is still needed for positive selection. Tolerations and Taints together enable node dedication patterns.

## topologySpreadConstraints

A pod scheduling feature (GA in 1.19) that controls how pods are spread across topology domains (zones, nodes, racks). topologySpreadConstraints replaces the older PodAntiAffinity approach for spreading workloads and is more expressive, supporting `maxSkew`, `whenUnsatisfiable`, and label selectors.

---

## V

## ValidatingAdmissionWebhook

An admission controller that calls an external HTTPS webhook to validate a Kubernetes API request. If the webhook returns a deny response, the request is rejected. Used by policy engines such as Kyverno and OPA/Gatekeeper to enforce custom constraints.

## VolumeMount

A field in a container spec that mounts a volume (defined in `pod.spec.volumes`) into the container's filesystem at a specified `mountPath`. Multiple containers in a pod can mount the same volume to share data.

## VolumeSnapshot

A point-in-time copy of a PersistentVolumeClaim, provided by the VolumeSnapshot API (GA in 1.20). VolumeSnapshots require a CSI driver that supports snapshot operations. They can be used to provision new PVCs pre-populated with snapshot data.

## VPA (Vertical Pod Autoscaler)

A controller that automatically adjusts pod CPU and memory requests based on observed usage. VPA operates in recommendation mode (suggest values), auto mode (evict and restart pods with new resources), or off mode (only record recommendations). See `platform/autoscaling/vpa/`.

---

## W

## WaitForFirstConsumer

A volume binding mode for StorageClasses that delays PV provisioning and binding until a pod that references the PVC is scheduled. Required for topology-aware storage (zonal SSDs, local volumes) to ensure the volume is provisioned in the same zone as the pod.

## Webhook

An HTTP callback that receives notification when a specific event occurs. In Kubernetes, admission webhooks (MutatingAdmissionWebhook, ValidatingAdmissionWebhook) intercept API requests for validation or mutation. Also used by GitOps tools (ArgoCD, Flux) to trigger syncs on Git push events.

---

## Z

## Zero-trust

A security model that assumes no implicit trust based on network location. Every request — internal or external — must be authenticated, authorized, and encrypted. In Kubernetes, zero-trust is approached through mTLS (service meshes like Istio/Linkerd), strict RBAC, NetworkPolicies, and short-lived tokens.
