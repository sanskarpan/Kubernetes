# Kubernetes Troubleshooting Guide

Organized by symptom. For each issue: quick-diagnosis commands, root cause explanation, and fix. Use this guide when something is broken and you need to narrow down why.

---

## Table of Contents

1. [Pod Won't Start](#1-pod-wont-start)
2. [Service Not Reachable](#2-service-not-reachable)
3. [PVC Stuck in Pending](#3-pvc-stuck-in-pending)
4. [Node Issues](#4-node-issues)
5. [Ingress Not Routing](#5-ingress-not-routing)
6. [RBAC Permission Denied](#6-rbac-permission-denied)
7. [Performance Issues](#7-performance-issues)
8. [Networking Issues](#8-networking-issues)

---

## 1. Pod Won't Start

Start every pod investigation with a broad status check, then drill down:

```bash
kubectl get pod <pod-name> -n <namespace>
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> --previous   # logs from the crashed container
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

---

### 1.1 ImagePullBackOff / ErrImagePull

**Symptom**: Pod status is `ImagePullBackOff` or `ErrImagePull`.

**Diagnosis**:
```bash
kubectl describe pod <pod-name> -n <namespace>
# Look for: "Failed to pull image ... authentication required" or "manifest not found"
```

**Root causes and fixes**:

| Root Cause | Fix |
|-----------|-----|
| Image name/tag typo | Correct `spec.containers[].image`; verify with `docker pull` locally |
| Image does not exist | Push the image or use the correct digest |
| Private registry requires credentials | Create an `imagePullSecret` from registry credentials and reference it in the pod spec or ServiceAccount |
| Registry rate-limited (Docker Hub) | Use a private mirror or authenticate with credentials |
| Node cannot reach the registry | Check node network/firewall rules; verify DNS from the node |

```bash
# Create imagePullSecret
kubectl create secret docker-registry regcred \
  --docker-server=ghcr.io \
  --docker-username=<user> \
  --docker-password=<token> \
  -n <namespace>
```

---

### 1.2 CrashLoopBackOff

**Symptom**: Pod repeatedly crashes and restarts; status is `CrashLoopBackOff`.

**Diagnosis**:
```bash
kubectl logs <pod-name> -n <namespace>                  # current container logs
kubectl logs <pod-name> -n <namespace> --previous       # logs before last crash
kubectl describe pod <pod-name> -n <namespace>          # check exit code and last state
```

**Exit code interpretation**:

| Exit Code | Meaning |
|-----------|---------|
| 0 | Successful exit — container exited on its own (wrong entrypoint?) |
| 1 | Application error — check logs for stack trace |
| 137 | SIGKILL — OOMKilled or manual kill |
| 139 | Segfault (SIGSEGV) — application bug or missing dependency |
| 143 | SIGTERM — graceful termination; likely liveness probe failure |

**Common fixes**:
- Application bug: check logs for exception stack trace and fix the code
- Missing environment variable or config: add the required ConfigMap/Secret reference
- Dependency not ready: add an init container that waits for the dependency
- Wrong command/entrypoint: verify `spec.containers[].command` and `args`
- Liveness probe too aggressive: increase `initialDelaySeconds` and `failureThreshold`

---

### 1.3 Pending

**Symptom**: Pod is stuck in `Pending` for more than a few seconds.

**Diagnosis**:
```bash
kubectl describe pod <pod-name> -n <namespace>
# Look for: "0/3 nodes are available: 3 Insufficient cpu"
# or: "0/3 nodes are available: 3 node(s) had untolerated taint"
```

**Root causes and fixes**:

| Root Cause | Diagnosis command | Fix |
|-----------|-------------------|-----|
| Insufficient CPU/memory | `kubectl describe node` — check Allocatable vs Requests | Scale up nodes or reduce pod requests |
| No nodes match NodeSelector/Affinity | `kubectl describe pod` — Events section | Fix label selector or label the target node |
| Taint not tolerated | `kubectl describe node` — Taints section | Add matching Toleration to pod spec |
| All nodes have a pod anti-affinity conflict | `kubectl describe pod` | Relax anti-affinity or add more nodes |
| PVC not bound | `kubectl get pvc -n <ns>` | See Section 3 |

```bash
# Check node capacity vs requests
kubectl describe nodes | grep -A5 "Allocated resources"
```

---

### 1.4 OOMKilled

**Symptom**: Pod is restarting with `OOMKilled` exit code (137).

**Diagnosis**:
```bash
kubectl describe pod <pod-name> -n <namespace>
# Look for: "Last State: Terminated  Reason: OOMKilled"

kubectl top pod <pod-name> -n <namespace> --containers
```

**Root cause**: The container exceeded its memory limit. The Linux kernel killed the process with SIGKILL.

**Fixes**:
- Increase the memory limit: `resources.limits.memory`
- Profile the application's memory usage and fix memory leaks
- Switch from Burstable to Guaranteed QoS (set requests == limits) to prevent eviction under pressure
- Use VPA in recommendation mode to find the right memory ceiling (`platform/autoscaling/vpa/`)

---

### 1.5 CreateContainerConfigError

**Symptom**: Pod status is `CreateContainerConfigError`.

**Diagnosis**:
```bash
kubectl describe pod <pod-name> -n <namespace>
# Look for: "secret "my-secret" not found" or "configmap "my-config" not found"
```

**Root cause**: The pod references a Secret or ConfigMap that does not exist in the same namespace.

**Fix**: Create the missing resource, or correct the reference name/namespace in the pod spec. Verify:
```bash
kubectl get secret <secret-name> -n <namespace>
kubectl get configmap <configmap-name> -n <namespace>
```

---

## 2. Service Not Reachable

**Initial diagnosis**:
```bash
kubectl get svc <svc-name> -n <namespace>
kubectl describe svc <svc-name> -n <namespace>
kubectl get endpoints <svc-name> -n <namespace>   # crucial: must not be empty
```

---

### 2.1 Empty Endpoints (Wrong Selector)

**Symptom**: `kubectl get endpoints <svc>` shows `<none>` or `Endpoints: <none>`.

**Diagnosis**:
```bash
# Check Service selector
kubectl get svc <svc-name> -n <namespace> -o jsonpath='{.spec.selector}'

# Check pod labels
kubectl get pods -n <namespace> --show-labels
```

**Root cause**: The Service's `spec.selector` does not match any pod's labels. Label key typos, missing labels, or pods in a different namespace.

**Fix**: Either update the Service selector to match pod labels, or add the matching labels to the pods.

---

### 2.2 Port Mismatch

**Symptom**: Endpoints are populated but requests still fail.

**Diagnosis**:
```bash
kubectl describe svc <svc-name> -n <namespace>
# Check: port, targetPort, containerPort must align

kubectl describe pod <pod-name> -n <namespace>
# Check: containerPort in pod spec (informational only, but should match)
```

**Root cause**: Service `targetPort` does not match the port the container is actually listening on.

**Fix**: Align `spec.ports[].targetPort` with the application's listen port. Verify the application is listening:
```bash
kubectl exec -it <pod-name> -n <namespace> -- ss -tlnp
```

---

### 2.3 DNS Issues

**Diagnosis**:
```bash
# Test DNS resolution from within the cluster
kubectl run dns-test --image=busybox:1.35 --rm -it --restart=Never -- \
  nslookup <svc-name>.<namespace>.svc.cluster.local

# Check CoreDNS pods
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns
```

**Common fixes**:
- CoreDNS pods are down: restart them and check resource limits
- Wrong DNS name format: use `<service>.<namespace>.svc.cluster.local`
- ndots configuration: check `/etc/resolv.conf` inside the pod

---

### 2.4 Kube-proxy Issues

**Diagnosis**:
```bash
kubectl get pods -n kube-system -l k8s-app=kube-proxy
kubectl logs -n kube-system -l k8s-app=kube-proxy

# Check iptables rules on a node (requires SSH or privileged pod)
iptables -t nat -L KUBE-SERVICES | grep <svc-clusterip>
```

**Fix**: Restart kube-proxy pods. If using IPVS mode, check `ipvsadm -Ln` for the service virtual server.

---

## 3. PVC Stuck in Pending

**Diagnosis**:
```bash
kubectl get pvc -n <namespace>
kubectl describe pvc <pvc-name> -n <namespace>
# Look for: "no persistent volumes available" or "storageclass not found"
```

---

### 3.1 No Matching PV

**Root cause**: Static provisioning — a PVC exists but no PV with matching access mode and capacity is available.

**Fix**: Create a PV that matches the PVC's `accessModes`, `capacity`, and `storageClassName`. Or switch to dynamic provisioning with a StorageClass.

---

### 3.2 StorageClass Not Found

```bash
kubectl get storageclass
```

**Root cause**: The PVC references a `storageClassName` that does not exist.

**Fix**: Create the StorageClass or correct the `storageClassName` in the PVC. Check if there is a default StorageClass (`kubectl get sc` — look for `(default)` annotation).

---

### 3.3 Capacity or Access Mode Mismatch

**Root cause**: PVs exist but none satisfy the PVC's capacity request or access mode.

**Diagnosis**:
```bash
kubectl get pv
# Compare CAPACITY and ACCESS MODES columns against PVC spec
```

**Fix**: Provision a larger PV or adjust the PVC request (must be done before binding). For ReadWriteMany (RWX), ensure the storage backend supports it (NFS, Ceph CephFS, AWS EFS — not EBS).

---

### 3.4 WaitForFirstConsumer Binding Mode

**Symptom**: PVC stays Pending until a pod is scheduled.

**Root cause**: StorageClass `volumeBindingMode: WaitForFirstConsumer` is intentional — the PV is not provisioned until a pod is placed on a specific node, ensuring topology alignment.

**This is expected behavior.** Once a pod using the PVC is scheduled, the PVC will bind.

---

## 4. Node Issues

**Diagnosis**:
```bash
kubectl get nodes
kubectl describe node <node-name>
kubectl get events --field-selector involvedObject.name=<node-name>
```

---

### 4.1 NotReady

**Diagnosis**:
```bash
kubectl describe node <node-name>
# Look for: Conditions section — KubeletNotReady, DiskPressure, MemoryPressure, etc.

# Check kubelet on the node (requires SSH)
systemctl status kubelet
journalctl -u kubelet -n 100
```

**Common causes**:
- Kubelet crashed: restart with `systemctl restart kubelet`
- Network partition between node and API server: check firewall/VPC routes
- Container runtime crashed: `systemctl restart containerd` (or cri-o)
- Certificate expired: renew node certificates

---

### 4.2 Disk Pressure

**Symptom**: Node condition `DiskPressure=True`; pods are evicted.

**Diagnosis**:
```bash
kubectl describe node <node-name> | grep -A5 "Conditions"
# On the node:
df -h
du -sh /var/lib/kubelet/*
du -sh /var/lib/containerd/*
```

**Fix**:
- Clean unused container images: `crictl rmi --prune`
- Clean unused volumes: `crictl rm $(crictl ps -q --state Exited)`
- Add more disk to the node or expand the partition
- Lower `--eviction-hard=imagefs.available<15%` threshold if too aggressive

---

### 4.3 Memory Pressure

**Symptom**: Node condition `MemoryPressure=True`; BestEffort pods evicted.

**Diagnosis**:
```bash
kubectl top nodes
kubectl describe node <node-name> | grep -A3 "Allocatable"
```

**Fix**:
- Add nodes to the cluster
- Reduce memory requests on pods to reflect actual usage
- Investigate pods with memory leaks using `kubectl top pods`
- Check for pods without memory limits consuming unbounded memory

---

### 4.4 Taint Conflicts

**Symptom**: Pods can't schedule because of untolerated taints.

**Diagnosis**:
```bash
kubectl describe node <node-name> | grep Taints
kubectl describe pod <pod-name> | grep -A3 Tolerations
```

**Fix**: Add a matching Toleration to the pod spec, or remove the taint from the node (if the restriction is no longer needed):
```bash
kubectl taint node <node-name> key:Effect-   # the trailing dash removes the taint
```

---

## 5. Ingress Not Routing

**Diagnosis**:
```bash
kubectl get ingress -n <namespace>
kubectl describe ingress <ingress-name> -n <namespace>
kubectl get pods -n ingress-nginx    # or whichever IngressController namespace
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx
```

---

### 5.1 Wrong IngressClass

**Symptom**: Ingress exists but traffic is not routed; no log entries in the controller.

**Diagnosis**:
```bash
kubectl get ingressclass
kubectl get ingress <name> -n <namespace> -o jsonpath='{.spec.ingressClassName}'
```

**Root cause**: `spec.ingressClassName` does not match any IngressClass, or the annotation `kubernetes.io/ingress.class` is missing/wrong.

**Fix**: Set `spec.ingressClassName` to the correct class name (e.g., `nginx`) or set the `--watch-ingress-without-class` flag on the controller.

---

### 5.2 Backend Service Issues

**Symptom**: Ingress controller logs show `Service "my-svc" not found` or `no endpoints`.

**Diagnosis**:
```bash
kubectl get svc <backend-svc> -n <namespace>
kubectl get endpoints <backend-svc> -n <namespace>
```

**Fix**: Ensure the backend Service and its endpoints exist in the same namespace as the Ingress. Correct the `backend.service.name` and `backend.service.port` fields.

---

### 5.3 Path Regex / RewriteTarget Issues

**Symptom**: Some paths return 404 from the application.

**Root cause**: nginx Ingress uses PCRE regex for path matching. A missing `nginx.ingress.kubernetes.io/rewrite-target` annotation causes paths to be forwarded verbatim to the backend.

**Fix**: Add annotations:
```yaml
annotations:
  nginx.ingress.kubernetes.io/rewrite-target: /$2
  nginx.ingress.kubernetes.io/use-regex: "true"
```

---

### 5.4 TLS Certificate Issues

**Symptom**: Browser shows certificate error; `curl` returns SSL handshake failure.

**Diagnosis**:
```bash
kubectl get secret <tls-secret> -n <namespace>
kubectl describe secret <tls-secret> -n <namespace>
# Check cert expiry
kubectl get secret <tls-secret> -n <namespace> -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -text -noout | grep "Not After"
```

**Fix**: Renew the certificate (cert-manager auto-renews), or check that the secret name in `spec.tls[].secretName` matches the actual Secret.

---

## 6. RBAC Permission Denied

**Symptom**: API calls return HTTP 403 `Forbidden`.

**Diagnosis**:
```bash
# Test a specific permission
kubectl auth can-i <verb> <resource> \
  --as=system:serviceaccount:<namespace>:<sa-name> \
  -n <namespace>

# List all permissions of a ServiceAccount
kubectl auth can-i --list \
  --as=system:serviceaccount:<namespace>:<sa-name> \
  -n <namespace>

# Check what RoleBindings exist
kubectl get rolebindings,clusterrolebindings -n <namespace> \
  -o wide | grep <sa-name>
```

---

### 6.1 ServiceAccount Not Bound to a Role

**Root cause**: The pod's ServiceAccount has no RoleBinding or ClusterRoleBinding granting the required permission.

**Fix**: Create a Role with the required permissions and bind it to the ServiceAccount:
```bash
kubectl create role <role-name> \
  --verb=get,list,watch \
  --resource=pods \
  -n <namespace>

kubectl create rolebinding <binding-name> \
  --role=<role-name> \
  --serviceaccount=<namespace>:<sa-name> \
  -n <namespace>
```

---

### 6.2 Namespace Scope Mismatch

**Root cause**: A Role + RoleBinding grants permissions in namespace A, but the pod is making requests to namespace B.

**Fix**: Use a ClusterRole + ClusterRoleBinding, or create matching Roles in each target namespace.

---

### 6.3 Resource Name vs Kind

**Common mistakes**:
- Using `pod` instead of `pods` (must be plural)
- Using the full API group path when the Role uses shorthand
- Confusing `subresources` — `pods/log`, `pods/exec`, `pods/status` are separate permissions

---

## 7. Performance Issues

---

### 7.1 CPU Throttling

**Symptom**: Latency increases; no OOMKill; CPU usage appears high.

**Diagnosis**:
```bash
kubectl top pods -n <namespace>

# Check throttling metrics in Prometheus (if available)
# container_cpu_cfs_throttled_seconds_total
# container_cpu_cfs_periods_total
# Throttle ratio = throttled / total > 0.25 is significant
```

**Root cause**: The container is hitting its CPU limit. The Linux CFS scheduler throttles it every 100 ms quota period.

**Fix**:
- Increase `resources.limits.cpu`
- Consider removing CPU limits for latency-sensitive workloads (keep requests for scheduling)
- Profile the application to identify CPU hotspots

---

### 7.2 HPA Not Scaling

**Diagnosis**:
```bash
kubectl describe hpa <hpa-name> -n <namespace>
# Look for: "unable to get metrics", "insufficient data", or scaling conditions

kubectl get --raw /apis/metrics.k8s.io/v1beta1/namespaces/<ns>/pods/<pod>
```

**Common causes**:

| Cause | Fix |
|-------|-----|
| Metrics Server not installed | Install metrics-server Helm chart |
| Resource requests not set on pods | HPA requires `requests.cpu` to calculate utilization — set them |
| Scale-down cooldown (`scaleDown.stabilizationWindowSeconds`) | Normal behavior — HPA waits before scale-down |
| Max replicas already reached | Increase `maxReplicas` |
| Custom metrics adapter not configured | Deploy Prometheus Adapter if using custom metrics |

---

### 7.3 Memory Pressure and Evictions

**Diagnosis**:
```bash
kubectl get events -n <namespace> | grep Evicted
kubectl describe pod <evicted-pod> -n <namespace>
kubectl top nodes
```

**Root cause**: Node memory is exhausted; kubelet evicts BestEffort then Burstable pods.

**Fix**:
- Set accurate memory requests so the scheduler places pods on nodes with enough capacity
- Add nodes or increase node size
- Investigate and fix memory leaks in the evicted pods
- Check for pods with no memory requests (BestEffort) — they are evicted first

---

## 8. Networking Issues

---

### 8.1 NetworkPolicy Too Restrictive

**Symptom**: Application works in a namespace without NetworkPolicy but fails after policy is applied.

**Diagnosis**:
```bash
kubectl get networkpolicy -n <namespace>
kubectl describe networkpolicy <policy-name> -n <namespace>

# Test connectivity from a pod (temporarily):
kubectl run nettest --image=busybox:1.35 --rm -it --restart=Never \
  -n <namespace> -- wget -qO- http://<target-svc>:<port>
```

**Fix**:
- Add an explicit allow policy for the blocked traffic
- Verify pod labels match the NetworkPolicy `podSelector`
- Check both ingress (from) and egress (to) — both directions may need rules
- Remember that DNS (port 53) requires an egress allow rule to kube-dns

---

### 8.2 CNI Misconfiguration

**Symptom**: Pods on different nodes cannot communicate; kube-proxy rules look correct.

**Diagnosis**:
```bash
kubectl get pods -n kube-system | grep -E "calico|cilium|weave|flannel"
kubectl logs -n kube-system <cni-pod-name>

# Check node CIDR assignments
kubectl get nodes -o custom-columns='NAME:.metadata.name,PODCIDR:.spec.podCIDR'
```

**Common CNI issues**:
- CIDR overlap between pod network and node/host network
- CNI plugin DaemonSet pods in CrashLoopBackOff (check logs)
- MTU mismatch causing packet fragmentation on overlay networks — set `--net-mtu` to match the underlay MTU minus encapsulation overhead (usually 50 bytes for VXLAN)
- Missing CNI plugin binary on new nodes

**Fix**: Consult CNI-specific documentation for the plugin in use. For Calico, use `calicoctl node status` to check BGP peering. For Cilium, use `cilium status`.

---

### 8.3 Pod-to-Pod Connectivity Across Namespaces

**Symptom**: A pod in namespace A cannot reach a pod in namespace B despite no obvious NetworkPolicy.

**Diagnosis**:
```bash
# Verify NetworkPolicy in both namespaces
kubectl get networkpolicy -A

# Check if a default-deny exists in namespace B
kubectl get networkpolicy -n <namespace-B>
```

**Root cause**: A default-deny policy in the destination namespace blocks all ingress unless explicitly allowed.

**Fix**: Add a NetworkPolicy in namespace B that allows ingress from namespace A using `namespaceSelector`:
```yaml
spec:
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: namespace-A
```

---

## General Debugging Tips

```bash
# Get a shell in a running pod
kubectl exec -it <pod-name> -n <namespace> -- /bin/sh

# Run a temporary debugging pod with network tools
kubectl run debug --image=nicolaka/netshoot --rm -it --restart=Never \
  -n <namespace> -- bash

# Watch events in real-time
kubectl get events -n <namespace> -w --sort-by='.lastTimestamp'

# Port-forward to test a service directly
kubectl port-forward svc/<svc-name> 8080:80 -n <namespace>

# Check all resources in a namespace
kubectl get all -n <namespace>

# Dump all pod logs to files
for pod in $(kubectl get pods -n <namespace> -o name); do
  kubectl logs $pod -n <namespace> > "${pod//\//-}.log" 2>&1
done
```
