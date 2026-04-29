# Kubernetes Services: Complete Reference

## What Is a Service?

A Kubernetes Service is a stable network endpoint that provides a consistent IP address and DNS name to a group of pods. Pods are ephemeral — they can be rescheduled to different nodes, their IP addresses change, and they can be killed and replaced at any time. A Service solves this by acting as a stable front-end whose selector continuously tracks matching pods through the Endpoints (or EndpointSlice) controller.

Without a Service, consumers of a pod would need to discover its current IP via the API server on every call — which is brittle and does not support load balancing.

---

## Service Types

### 1. ClusterIP (Default — Internal Only)

ClusterIP allocates a virtual IP address that is reachable only from within the cluster. kube-proxy programs iptables (or IPVS) rules on every node so that traffic to the ClusterIP:port is transparently DNAT'd to one of the ready backing pods.

**Use when:** Any service that should only be reached by other workloads inside the cluster (databases, internal APIs, caches).

**DNS name format:** `<service-name>.<namespace>.svc.cluster.local`

```yaml
spec:
  type: ClusterIP        # or omit; ClusterIP is the default
  clusterIP: ""          # auto-assigned; set to "None" for Headless
```

**Example DNS lookup from inside a pod:**
```bash
nslookup nginx-clusterip.networking-demo.svc.cluster.local
```

---

### 2. NodePort (External — Development / Testing)

NodePort extends ClusterIP by additionally opening a static port (default range: 30000–32767) on **every** node's external IP. Traffic arriving at `<any-node-IP>:<nodePort>` is forwarded to the Service's ClusterIP, then to a backing pod.

**Use when:** Quick external access during development or in environments where you control the firewall and do not have a cloud load balancer. Not recommended for production external traffic because:
- Exposes a port on every single node, including control-plane nodes in some setups.
- Port range is non-standard (not 80/443).
- No built-in health checking at the LB layer.

**WARNING:** Every node in the cluster listens on the NodePort. An attacker who reaches any node on that port can reach the service, even if that node is running zero matching pods.

---

### 3. LoadBalancer (Cloud — Production External Access)

LoadBalancer extends NodePort by additionally requesting that the cloud provider's CCM (Cloud Controller Manager) provision an external load balancer (e.g., AWS ALB/NLB, GCP L4 LB, Azure LB). The provisioned LB's IP or hostname is populated into `status.loadBalancer.ingress`.

**Use when:** Production workloads that need external access in cloud environments. For bare-metal clusters, pair with **MetalLB** to provide the same functionality.

**Cost awareness:** Each LoadBalancer service provisions a separate cloud load balancer, which costs money. For HTTP/HTTPS traffic, use a single Ingress + Ingress Controller instead of one LoadBalancer per service.

---

### 4. ExternalName (DNS Alias)

ExternalName does not proxy traffic through kube-proxy at all. Instead, the cluster DNS server returns a CNAME record pointing to the external hostname you specify. The pod's TCP connection goes directly to that external host.

**Use when:** Giving an in-cluster DNS name to an external dependency (e.g., a managed RDS database, a SaaS API endpoint). Allows you to change the external endpoint without updating application config — just update the Service.

```yaml
spec:
  type: ExternalName
  externalName: mydb.prod.us-east-1.rds.amazonaws.com
```

**Limitation:** No port remapping. No load balancing. Returns a CNAME, so the application must support following CNAMEs.

---

### 5. Headless Service (StatefulSets / Direct Pod Addressing)

A Headless Service is a ClusterIP Service with `clusterIP: None`. No virtual IP is allocated and no kube-proxy rules are installed. Instead, the cluster DNS server returns **A records for each individual pod IP** that matches the selector.

**Use when:**
- StatefulSets, where each pod needs a stable DNS name (`pod-0.my-svc.namespace.svc.cluster.local`).
- Client-side load balancing where the application needs to discover and connect to individual pod IPs.
- Databases that use consensus protocols (etcd, Cassandra, Kafka) and need to address specific nodes.

**DNS behavior for StatefulSet pods:**
```
<pod-name>.<service-name>.<namespace>.svc.cluster.local
```
e.g., `mysql-0.mysql-headless.database.svc.cluster.local`

---

## Service Type Decision Matrix

| Scenario | Recommended Type | Notes |
|---|---|---|
| Internal microservice communication | ClusterIP | Default. Use DNS, not env vars. |
| Expose to cluster pods only | ClusterIP | Add NetworkPolicy to restrict further |
| Dev/test external access, no cloud LB | NodePort | Never use nodePort in production HTTP paths |
| Production HTTP/HTTPS external traffic | Ingress + ClusterIP | One Ingress Controller = one LoadBalancer |
| Production non-HTTP external traffic (TCP) | LoadBalancer | e.g., a game server, MQTT broker |
| Alias to external DNS (RDS, SaaS) | ExternalName | — |
| StatefulSet stable per-pod DNS | Headless (clusterIP: None) | Required for StatefulSet pod DNS |
| Kafka, Cassandra cluster discovery | Headless | Clients get all pod IPs from DNS |

---

## kube-proxy Modes

kube-proxy runs on every node and is responsible for implementing the Service virtual IP abstraction. It watches the API server for Service and Endpoints changes and programs the local node's networking stack.

### iptables Mode (Default in most clusters)

kube-proxy installs iptables DNAT rules in the `KUBE-SERVICES` chain. For each service, a chain of rules randomly selects a backend pod using the `statistic` module (probability-based).

**Pros:** No extra dependency, widely supported.
**Cons:** O(n) rule matching — clusters with tens of thousands of Services and endpoints see measurable latency from iptables traversal. Rules are not incrementally updated; the full ruleset is replaced on any change (can cause brief packet drops).

### IPVS Mode (Recommended for large clusters)

kube-proxy programs the Linux kernel's IPVS (IP Virtual Server) subsystem. IPVS uses a hash table so lookup is O(1) regardless of the number of services.

**Pros:** Much better performance at scale. Supports more load-balancing algorithms (round-robin, least-connections, shortest expected delay, etc.).
**Cons:** Requires the `ip_vs` kernel modules. Slightly more complex to debug.

**Enable IPVS:** In the kube-proxy ConfigMap, set `mode: "ipvs"` and `ipvs.scheduler: "rr"` (or `lc`, `sh`, etc.).

### nftables Mode (Kubernetes 1.31+, beta)

A modern replacement for iptables that offers better performance and atomic rule updates. Becoming the default in newer Kubernetes versions. Check your distribution's support before enabling.

---

## Service Discovery

Kubernetes offers two mechanisms for services to discover each other.

### DNS (Recommended)

The cluster DNS server (CoreDNS by default) automatically creates DNS records for every Service. Pods are configured by the kubelet to use the cluster DNS server via `/etc/resolv.conf`.

```
# From any pod in the cluster:
curl http://nginx-clusterip.networking-demo.svc.cluster.local

# From a pod in the same namespace, the short name resolves:
curl http://nginx-clusterip

# From a pod in a different namespace, use the FQDN:
curl http://nginx-clusterip.networking-demo.svc.cluster.local
```

DNS is the right approach: it is dynamic (updates when pods change), human-readable, and does not have ordering constraints.

### Environment Variables (Legacy — AVOID for new workloads)

When a pod starts, kubelet injects environment variables for every Service that exists in the same namespace at that moment. For a Service named `REDIS`, kubelet injects:
```
REDIS_SERVICE_HOST=10.96.1.45
REDIS_SERVICE_PORT=6379
```

**CRITICAL ORDERING PROBLEM:** The environment variables are injected at pod startup time. If the Service does not exist yet when the pod starts, the variables will not be present. If you create the Service after the pods, those pods will never see the variables unless they are restarted. This creates hard-to-diagnose bugs where the app cannot connect to a service that definitely exists.

**Additionally:** The variables are not updated if the Service's ClusterIP changes (which can happen if the Service is deleted and recreated). You would need to restart all pods in the namespace.

**Conclusion:** Use DNS. Disable environment variable injection if you want to reduce pod startup time and avoid confusion:
```yaml
spec:
  enableServiceLinks: false  # Disables env var injection for this pod
```

---

## Endpoint Slices

Since Kubernetes 1.19, the Endpoints API has been supplemented (and in 1.21+ largely replaced) by EndpointSlices. EndpointSlices shard the backend pod list into slices of up to 100 endpoints each, dramatically reducing the size of API objects and the watch traffic kube-proxy must process in large clusters.

You rarely interact with EndpointSlices directly — they are managed automatically by the EndpointSlice controller. But when debugging, inspect them:

```bash
kubectl get endpointslices -n networking-demo
kubectl describe endpointslice <name> -n networking-demo
```

---

## Debugging Services

```bash
# Check that the service exists and has the correct ClusterIP
kubectl get svc -n networking-demo

# Check that endpoints are populated (if Endpoints is empty, selector doesn't match any pod)
kubectl get endpoints nginx-clusterip -n networking-demo

# Describe the service for event details
kubectl describe svc nginx-clusterip -n networking-demo

# Test connectivity from within a pod (exec into a debug pod)
kubectl run debug --image=curlimages/curl --rm -it --restart=Never -- \
  curl -s http://nginx-clusterip.networking-demo.svc.cluster.local

# Check kube-proxy logs on a node
kubectl logs -n kube-system -l k8s-app=kube-proxy --tail=50

# Verify iptables rules exist for the service (run on a node)
sudo iptables-save | grep nginx-clusterip
```

---

## Related Files

- `clusterip.yml` — ClusterIP Service example (internal communication)
- `nodeport.yml` — NodePort Service example (dev/test external access)
- `loadbalancer.yml` — LoadBalancer Service example (cloud production external access)
- `../ingress/` — Ingress resources for HTTP/HTTPS routing (recommended over LoadBalancer for HTTP)
- `../network-policy/` — NetworkPolicy to restrict which pods can reach a Service
