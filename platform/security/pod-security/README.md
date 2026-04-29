# Pod Security Standards (PSA)

## Overview

Pod Security Standards (PSS) define three security profiles for pods, and Pod Security Admission (PSA) enforces them at the namespace level using namespace labels. PSA was introduced as stable in Kubernetes 1.25 and is the replacement for the deprecated PodSecurityPolicy (PSP).

---

## The Three Security Levels

### Privileged

No restrictions. Equivalent to having no security policy at all. Allows:
- Running as root
- Host namespace sharing (`hostNetwork`, `hostPID`, `hostIPC`)
- Privilege escalation
- Mounting host paths
- Any Linux capabilities

**Use for:** System-level workloads (CNI plugins, storage drivers, device plugins) that legitimately need elevated privileges. Restrict this to dedicated namespaces (`kube-system`, `cni-system`).

### Baseline

Prevents the most egregious security violations while remaining compatible with most containerized applications:

- No privileged containers
- No host namespace sharing (hostNetwork, hostPID, hostIPC)
- No hostPath volume mounts
- No specific dangerous capabilities (NET_ADMIN, SYS_ADMIN, etc.)
- No `hostPort` usage
- seccompProfile: Unconfined is disallowed

**Use for:** Most workloads that can't meet Restricted without modification. A good intermediate step when migrating from Privileged namespaces.

### Restricted

Hardened profile following container security best practices. Requirements include:

- `runAsNonRoot: true` — pods must not run as root
- `runAsUser` must be non-zero
- `seccompProfile: RuntimeDefault` or `Localhost` must be set
- `allowPrivilegeEscalation: false` is required
- `capabilities.drop: [ALL]` is required; only specific additions (`NET_BIND_SERVICE`) are allowed
- Volume types restricted to: configMap, csi, downwardAPI, emptyDir, ephemeral, persistentVolumeClaim, projected, secret
- No `hostPath` volumes

**Use for:** All application namespaces in production. This is the target state. The manifests in this repository are written to comply with the Restricted standard.

---

## PSA Modes

Each security level can be applied in three modes independently:

### `enforce`

Pods that violate the policy are **rejected** at admission. The request fails with an error message.

```
Error from server (Forbidden): pods "my-pod" is forbidden: violates PodSecurity "restricted:latest":
  allowPrivilegeEscalation != false (container "app" must set securityContext.allowPrivilegeEscalation=false)
```

### `audit`

Pods that violate the policy are **allowed** to run, but violations are **recorded in the audit log**. Use this to discover violations before enforcing.

```bash
# View audit events
kubectl get events -n secure-workloads | grep PodSecurity
```

### `warn`

Pods that violate the policy are **allowed** to run, but the API server returns a **warning message** in the response. Visible with `kubectl apply`.

```
Warning: would violate PodSecurity "restricted:latest": ...
```

---

## How to Label Namespaces

PSA is configured via **namespace labels**. No admission webhook installation is required — PSA is built into the Kubernetes API server.

```bash
# Apply restricted level in enforce+audit+warn modes
kubectl label namespace workloads \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest

# Or with a manifest (see restricted-namespace.yml)
kubectl apply -f restricted-namespace.yml
```

The label format is:
```
pod-security.kubernetes.io/<mode>: <level>
pod-security.kubernetes.io/<mode>-version: <version>
```

Where `<version>` can be `latest` or a specific Kubernetes version (e.g., `v1.28`). Using `latest` always uses the current cluster's version.

---

## Recommended Rollout Strategy: audit → warn → enforce

1. **Start with `audit` + `warn`** — Deploy on existing namespaces. Violations are logged but not blocked. Review audit logs and warnings for 1–2 weeks.
   ```bash
   kubectl label namespace workloads \
     pod-security.kubernetes.io/audit=restricted \
     pod-security.kubernetes.io/warn=restricted
   ```

2. **Fix violations** — Update Deployment specs to comply with the Restricted standard. This typically means adding `securityContext` blocks and removing privilege escalation.

3. **Add `enforce`** — Once no violations appear in audit/warn mode, add the enforce label.
   ```bash
   kubectl label namespace workloads \
     pod-security.kubernetes.io/enforce=restricted
   ```

---

## Migration from PodSecurityPolicy

PodSecurityPolicy (PSP) was removed in Kubernetes 1.25. PSA replaces it.

Key differences:

| Feature | PSP | PSA |
|---------|-----|-----|
| Granularity | Per-policy, per-cluster | Per-namespace |
| Configuration | Complex per-field | Three predefined levels |
| Mutation | Could mutate pods | Never mutates — only validates |
| RBAC dependency | Required (complex) | None — just namespace labels |
| API group | `policy/v1beta1` | Built into API server |

PSA does not support the same fine-grained per-field control as PSP. For advanced policies (e.g., "allow this specific privileged container but not others"), use Kyverno or OPA/Gatekeeper alongside PSA.

---

## What the Restricted Standard Requires

A pod spec must include (per container):

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
        # If runAsNonRoot is set at pod level, runAsUser is optional
        # but must be non-zero if specified
      # Volume types limited to: configMap, emptyDir, projected, secret,
      # persistentVolumeClaim, csi, downwardAPI, ephemeral
```

All manifests in this repository include these fields. Applying them to a Restricted namespace will succeed without warnings.

---

## Exemptions

Some namespaces need exemptions from PSA enforcement:

```yaml
# In API server configuration (--admission-plugins, --admission-control-config-file)
# Exemptions for namespaces that require privileged access:
exemptions:
  namespaces:
    - kube-system
    - kube-public
    - cni-system
    - storage-drivers
```

Or use per-namespace labels to set a lower standard for system namespaces:
```bash
kubectl label namespace kube-system \
  pod-security.kubernetes.io/enforce=privileged
```

---

## Useful Commands

```bash
# Check PSA labels on a namespace
kubectl get namespace workloads -o jsonpath='{.metadata.labels}' | jq .

# Dry-run: test if a pod spec would be admitted
kubectl apply -f my-pod.yml --dry-run=server -n secure-workloads

# List all namespaces with their PSA labels
kubectl get namespaces -o custom-columns=\
'NAME:.metadata.name,ENFORCE:.metadata.labels.pod-security\.kubernetes\.io/enforce,\
AUDIT:.metadata.labels.pod-security\.kubernetes\.io/audit'

# View PSA-related events
kubectl get events -n secure-workloads | grep -i podsecurity
```
