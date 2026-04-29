# Kubernetes Security Guide: Defense in Depth

This guide presents a layered, defense-in-depth approach to securing Kubernetes clusters and workloads. Each layer addresses a distinct attack surface. Skipping any layer leaves gaps that adversaries can exploit.

---

## Table of Contents

1. [The 4C Security Model](#1-the-4c-security-model)
2. [Cluster Hardening](#2-cluster-hardening)
3. [RBAC Best Practices](#3-rbac-best-practices)
4. [Pod Security Standards](#4-pod-security-standards)
5. [Network Segmentation](#5-network-segmentation)
6. [Secrets Management](#6-secrets-management)
7. [Container Image Security](#7-container-image-security)
8. [Supply Chain Security](#8-supply-chain-security)
9. [Runtime Security](#9-runtime-security)
10. [Compliance References](#10-compliance-references)

---

## 1. The 4C Security Model

Kubernetes security is best understood through four concentric layers. An attacker who breaches an outer layer has a much larger attack surface against inner layers, so all four must be hardened independently.

```
┌──────────────────────────────────────────┐
│  Cloud (IAM, VPC, firewall, key mgmt)   │
│  ┌────────────────────────────────────┐  │
│  │  Cluster (API server, etcd, RBAC) │  │
│  │  ┌──────────────────────────────┐ │  │
│  │  │  Container (image, runtime)  │ │  │
│  │  │  ┌────────────────────────┐  │ │  │
│  │  │  │  Code (app, deps)     │  │ │  │
│  │  │  └────────────────────────┘  │ │  │
│  │  └──────────────────────────────┘ │  │
│  └────────────────────────────────────┘  │
└──────────────────────────────────────────┘
```

**Cloud layer**: IAM roles with least privilege, private node networks, encrypted storage, cloud-managed key management (KMS), firewall rules blocking direct access to the API server from the internet.

**Cluster layer**: API server hardening, etcd encryption, RBAC, audit logging, admission controllers, network policies.

**Container layer**: Non-root UIDs, read-only root filesystem, dropped capabilities, seccomp/AppArmor profiles, distroless base images.

**Code layer**: Dependency scanning, SAST/DAST, secrets not hardcoded, least-privilege service accounts in application code.

---

## 2. Cluster Hardening

### 2.1 API Server Flags

The API server is the single entry point to the cluster. Critical hardening flags:

```
--anonymous-auth=false                  # Disable anonymous access
--authorization-mode=Node,RBAC          # Never use AlwaysAllow
--enable-admission-plugins=NodeRestriction,PodSecurity,...
--audit-log-path=/var/log/kube-audit.log
--audit-log-maxage=30
--audit-log-maxbackup=10
--audit-log-maxsize=100
--tls-cipher-suites=TLS_AES_128_GCM_SHA256,...   # Restrict weak ciphers
--service-account-key-file=...
--service-account-signing-key-file=...
--service-account-issuer=https://kubernetes.default.svc
--oidc-issuer-url=...                   # Integrate with SSO/OIDC for human access
```

**Never expose the API server port (6443) to the public internet.** Use a private endpoint and restrict access via firewall/VPC.

### 2.2 etcd Encryption at Rest

By default, Kubernetes stores Secrets in etcd in base64 without encryption. Enable EncryptionConfiguration to encrypt sensitive resources using AES-GCM or KMS:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
      - configmaps   # optional but recommended
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: <base64-encoded-32-byte-key>
      - identity: {}   # fallback for already-stored unencrypted data
```

Pass `--encryption-provider-config=/etc/kubernetes/enc/enc.yaml` to the API server. Rotate encryption keys periodically. For managed clusters, use the cloud provider's KMS integration (AWS KMS, GCP CMEK, Azure Key Vault).

### 2.3 Audit Logging

Kubernetes audit logs record every API request — who made it, what they did, and what the response was. A production audit policy should record:

- `RequestResponse` level for secrets, configmaps, and RBAC changes
- `Request` level for pod creation/deletion
- `Metadata` level for read operations
- `None` for high-frequency read-only requests (watch, list nodes) to control log volume

Audit logs should be shipped to a SIEM (Splunk, Datadog, OpenSearch) and retained for at least 90 days for forensic analysis.

### 2.4 etcd Security

- Run etcd with mutual TLS (`--cert-file`, `--key-file`, `--trusted-ca-file`, `--client-cert-auth`)
- Restrict etcd access to the API server only — no other process should talk to etcd directly
- Back up etcd regularly (`etcdctl snapshot save`) and test restore procedures
- Run an odd number of etcd members (3 or 5) for quorum tolerance

### 2.5 Node Security

- Keep nodes on a supported Kubernetes version; apply OS security patches
- Disable SSH access to nodes in production; use `kubectl exec` with audit logging instead
- Enable read-only kubelet port (`--read-only-port=0`) and disable anonymous kubelet auth (`--anonymous-auth=false`)
- Use Node Authorization (`--authorization-mode=Node`) so kubelets can only read their own pods/secrets

---

## 3. RBAC Best Practices

See `platform/security/rbac/` for example manifests: `serviceaccount.yml`, `namespace-role.yml`, `rolebinding.yml`, `cluster-role.yml`, `cluster-rolebinding.yml`.

### 3.1 Least Privilege

Every workload should have a dedicated ServiceAccount with the minimum permissions required. Never use the `default` ServiceAccount for application pods — it may accumulate permissions over time as other teams add RoleBindings.

```yaml
# Good: workload-specific ServiceAccount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payment-service
  namespace: payments
automountServiceAccountToken: false   # Disable if the app doesn't call the Kubernetes API
```

### 3.2 No cluster-admin for Workloads

The `cluster-admin` ClusterRole grants unrestricted access to the entire cluster. It should be bound only to break-glass emergency accounts and never to:

- Application pods
- CI/CD pipeline service accounts (scope to specific namespaces and verbs instead)
- Shared automation accounts

Audit bindings of `cluster-admin` regularly:
```bash
kubectl get clusterrolebindings -o json | \
  jq '.items[] | select(.roleRef.name=="cluster-admin") | .subjects'
```

### 3.3 Principle of Namespace-Scoped Roles

Prefer `Role` + `RoleBinding` over `ClusterRole` + `ClusterRoleBinding` whenever possible. Namespace scope limits the blast radius if a ServiceAccount is compromised.

### 3.4 Regular RBAC Audits

- Use `kubectl auth can-i --list --as=system:serviceaccount:<ns>:<sa>` to enumerate permissions
- Use `rbac-police`, `rakkess`, or `kubectl-who-can` for comprehensive audits
- Remove unused ServiceAccounts and their RoleBindings quarterly
- Review RBAC changes in audit logs — look for new ClusterRoleBindings to high-privilege roles

### 3.5 Restrict Dangerous Verbs and Resources

Certain combinations grant effective cluster-admin access even without using that role:

| Dangerous permission | Why it's dangerous |
|---------------------|--------------------|
| `create` on `pods` in `kube-system` | Can schedule privileged pods |
| `get/list/watch` on `secrets` cluster-wide | Exposes all credentials |
| `bind` on ClusterRoles | Can escalate own privileges |
| `escalate` on Roles | Can add permissions to existing roles |
| `impersonate` on users/groups | Can act as any user |
| `exec` on pods | Shell access to running containers |

---

## 4. Pod Security Standards

See `platform/security/pod-security/restricted-namespace.yml` for an example namespace with PSA labels.

### 4.1 The Three Levels

| Level | Description | Use case |
|-------|-------------|----------|
| `privileged` | No restrictions | System namespaces only (kube-system, CNI, logging) |
| `baseline` | Minimal restrictions; prevents known privilege escalations | General workloads |
| `restricted` | Heavily restricted; current best practices | Production application namespaces |

### 4.2 Enforcing PSA with Namespace Labels

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
```

The three modes allow gradual adoption: start with `warn` to understand impact, add `audit` for logging, then promote to `enforce`.

### 4.3 Restricted-Level Pod Security Requirements

Pods in `restricted` namespaces must:

- Not run as root (`runAsNonRoot: true`)
- Not allow privilege escalation (`allowPrivilegeEscalation: false`)
- Drop all capabilities (`capabilities.drop: ["ALL"]`)
- Use a non-root UID/GID
- Use a `seccompProfile` of `RuntimeDefault` or a custom profile
- Not use `hostPath`, `hostPID`, `hostIPC`, `hostNetwork`

---

## 5. Network Segmentation

See `networking/network-policies/` for example manifests.

### 5.1 Default-Deny-All Policy

Apply a default-deny NetworkPolicy to every application namespace. This ensures no traffic flows unless explicitly permitted:

```yaml
# networking/network-policies/default-deny-all.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production
spec:
  podSelector: {}   # matches all pods in the namespace
  policyTypes:
    - Ingress
    - Egress
```

### 5.2 Explicit Allow Rules

After applying deny-all, add targeted allow policies:

```yaml
# Allow ingress from the ingress controller to app pods
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-controller
spec:
  podSelector:
    matchLabels:
      app: frontend
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - port: 8080
```

### 5.3 Namespace Isolation

Use namespaceSelector in NetworkPolicies to enforce namespace boundaries. Pods in namespace `payments` should not be able to reach pods in namespace `analytics` unless there is an explicit business reason with an approved policy.

### 5.4 Egress Control

Control egress to prevent data exfiltration and limit the blast radius of a compromised pod:

- Allow DNS (UDP/TCP port 53 to kube-dns)
- Allow traffic to specific internal namespaces
- Allow traffic to specific external CIDRs (third-party APIs)
- Block egress to cloud metadata endpoints (169.254.169.254) unless required

### 5.5 CNI Requirements

NetworkPolicy is only effective if the CNI plugin enforces it. Supported CNIs: Calico, Cilium, Weave, Antrea. The default kubenet/bridge CNI does not enforce NetworkPolicy.

---

## 6. Secrets Management

### 6.1 Hierarchy of Approaches (Best to Worst)

1. **External Secrets Operator (ESO)** with a dedicated secrets manager (AWS Secrets Manager, GCP Secret Manager, HashiCorp Vault): secrets never exist in Git; the ESO controller syncs them into Kubernetes Secrets on demand. See `platform/security/eso/`.

2. **SealedSecrets** (Bitnami): encrypt Secrets with a cluster-bound public key before committing to Git. The controller decrypts them. Acceptable for smaller teams without a dedicated secrets manager. See `platform/security/sealed-secrets/`.

3. **Native Kubernetes Secrets** with etcd encryption at rest: base64-encoded, stored encrypted in etcd, never in Git. Acceptable if etcd encryption is enabled and Git contains no Secret manifests.

4. **Never**: Plain base64-encoded Secret manifests committed to Git. Base64 is not encryption — anyone with Git access can decode them with `base64 -d`.

### 6.2 ESO Pattern

```
Git repo                 ESO Controller             AWS Secrets Manager
  ExternalSecret CR  →   reads SecretStore    →   fetches secret value
                      ←  creates/syncs Secret ←   returns plaintext
```

The `SecretStore` defines the provider and credentials. The `ExternalSecret` defines the mapping from provider keys to Kubernetes Secret keys.

### 6.3 Secret Hygiene

- Rotate secrets regularly; ESO supports automatic refresh intervals
- Limit Secret access via RBAC — only the pods that need a Secret should have `get` access to it
- Avoid environment variables for secrets when possible — prefer volume mounts (harder to leak via `/proc`)
- Scan Git history for accidentally committed secrets with `truffleHog`, `gitleaks`, or `git-secrets`

---

## 7. Container Image Security

### 7.1 Use Non-Root Users

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  allowPrivilegeEscalation: false
```

Running as root inside a container provides a trivial path to node-level compromise if container escape vulnerabilities exist.

### 7.2 Read-Only Root Filesystem

```yaml
securityContext:
  readOnlyRootFilesystem: true
```

Use `emptyDir` or ephemeral volumes for paths that need to be writable (tmp directories, caches). A read-only root filesystem prevents an attacker from modifying the container's application binaries.

### 7.3 Distroless and Minimal Base Images

Prefer distroless images (GoogleContainerTools/distroless) or scratch-based images. These images contain only the application runtime and have no shell, package manager, or debugging utilities — massively reducing the attack surface.

```dockerfile
FROM gcr.io/distroless/java21-debian12
COPY target/app.jar /app.jar
ENTRYPOINT ["/app.jar"]
```

### 7.4 Image Pinning by Digest

Pin images to their SHA256 digest rather than mutable tags:

```yaml
image: nginx@sha256:a484819eb60211f5299034ac80f6a681b06f89e65866ce91f356ed7c72af059c
```

Mutable tags like `latest` or `v1.0` can be overwritten by a supply chain attacker. Digest pinning guarantees you run exactly the image you tested.

### 7.5 Vulnerability Scanning

Scan images in CI before push and regularly against running images in the cluster:

- **Trivy**: fast, comprehensive scanner (CVEs, misconfigurations, secrets)
- **Grype**: Anchore's vulnerability scanner, integrates with SBOM
- **Snyk Container**: SaaS scanner with IDE integration

Enforce a policy that blocks images with `CRITICAL` CVEs from being deployed.

### 7.6 Drop Capabilities

```yaml
securityContext:
  capabilities:
    drop:
      - ALL
    add:
      - NET_BIND_SERVICE   # Only add back what's truly needed
```

---

## 8. Supply Chain Security

### 8.1 SBOM Generation

Generate a Software Bill of Materials for every container image build:

```bash
# Generate SBOM with Syft
syft ghcr.io/my-org/my-app:v1.2.3 -o spdx-json > sbom.spdx.json

# Scan SBOM for vulnerabilities with Grype
grype sbom:./sbom.spdx.json
```

Attach SBOMs to images as OCI artifacts so they travel with the image.

### 8.2 Image Signing with Cosign

```bash
# Sign image after push
cosign sign --key cosign.key ghcr.io/my-org/my-app@sha256:<digest>

# Verify signature before deployment
cosign verify --key cosign.pub ghcr.io/my-org/my-app@sha256:<digest>
```

Use Kyverno or Connaisseur to enforce signature verification in the admission chain — reject unsigned or unverified images at deployment time.

### 8.3 SLSA Levels

| Level | Requirements |
|-------|-------------|
| SLSA 1 | Build process documented; provenance generated |
| SLSA 2 | Version control + hosted build service + signed provenance |
| SLSA 3 | Auditable build platform; isolated builds |
| SLSA 4 | Hermetic, reproducible builds; two-party review |

Aim for SLSA 2+ for production images and SLSA 3 for critical infrastructure images.

### 8.4 Admission Enforcement

Use ValidatingAdmissionWebhook-based policy engines to enforce supply chain policies at deployment time:

- **Kyverno**: `verifyImages` rule to require cosign signatures
- **OPA/Gatekeeper**: Rego policies for image registry allowlisting
- **Ratify**: CNCF project for verifying supply chain artifact signatures

---

## 9. Runtime Security

### 9.1 Falco

Falco monitors system calls from running containers and generates alerts when behavior deviates from defined rules:

```yaml
# Example Falco rule: detect shell spawned in a container
- rule: Terminal shell in container
  desc: A shell was spawned in a container
  condition: >
    spawned_process and container
    and shell_procs and proc.tty != 0
  output: >
    Shell spawned (user=%user.name container=%container.name
    image=%container.image.repository)
  priority: WARNING
```

Deploy Falco as a DaemonSet. Ship alerts to a SIEM for correlation and response.

### 9.2 seccomp

Apply the `RuntimeDefault` seccomp profile to all production workloads. This blocks ~300 dangerous syscalls while allowing everything a typical application needs:

```yaml
securityContext:
  seccompProfile:
    type: RuntimeDefault
```

For high-security workloads, create custom `Localhost` seccomp profiles that allowlist only the specific syscalls the application requires.

### 9.3 AppArmor

Apply AppArmor profiles to containers for mandatory access control on file paths and capabilities. The container runtime's default AppArmor profile (`docker-default` or `cri-containerd`) provides a good baseline. Custom profiles can be loaded on nodes via DaemonSet.

### 9.4 Privileged Container Prevention

Block privileged containers using Kyverno policy (`platform/security/pod-security/`), PodSecurityAdmission `restricted` mode, or both:

```yaml
# Kyverno policy
spec:
  rules:
    - name: disallow-privileged
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: "Privileged containers are not allowed."
        pattern:
          spec:
            containers:
              - =(securityContext):
                  =(privileged): "false"
```

---

## 10. Compliance References

### 10.1 CIS Kubernetes Benchmark

The Center for Internet Security publishes a Kubernetes benchmark with scored and unscored controls across:

- Control Plane Components (API server, controller manager, scheduler, etcd)
- Worker Node Configuration (kubelet, node config)
- Policies (RBAC, network, pod security)

Run `kube-bench` against nodes to audit compliance:
```bash
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
kubectl logs job/kube-bench
```

### 10.2 NSA/CISA Kubernetes Hardening Guide

Published by the National Security Agency, this guide covers:

- Kubernetes Pod security (non-root, read-only FS, seccomp)
- Network separation (NetworkPolicy, namespaces)
- Authentication/Authorization (RBAC, MFA for human access)
- Audit logging and threat detection
- Upgrading and application security

### 10.3 SOC 2 / ISO 27001

Kubernetes clusters in regulated environments need controls mapped to SOC 2 Trust Service Criteria or ISO 27001 Annex A controls. Key areas: access control (CC6), change management (CC8), availability (A1), and incident response (CC7). Use audit logs, RBAC reports, and vulnerability scan results as evidence.

### 10.4 PCI DSS

For payment card workloads, isolate cardholder data environment (CDE) namespaces with strict NetworkPolicies, enforce encryption in transit (mTLS via service mesh), enable audit logging, and run regular vulnerability assessments.
