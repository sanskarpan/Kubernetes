# RBAC (Role-Based Access Control) — Deep Dive

## Overview

Kubernetes RBAC controls **who** can perform **what actions** on **which resources**. Every API request is authenticated (who are you?) and then authorized (are you allowed to do this?). RBAC is the standard Kubernetes authorization mechanism for production clusters.

RBAC works with three core concepts: **Subjects**, **Roles**, and **Bindings**.

---

## Subjects

A subject is the identity making the API request. There are three types:

### User

Kubernetes does not manage users internally. Users are external identities authenticated via:
- X.509 client certificates (common name = username, organization = group)
- OIDC tokens (e.g., from Dex, Google, Okta)
- Bearer tokens

```yaml
subjects:
  - kind: User
    name: jane.doe@example.com  # Must match the identity the cluster sees
    apiGroup: rbac.authorization.k8s.io
```

### Group

Groups aggregate multiple users. In X.509 certificates, the `organization` field maps to groups. OIDC claims can also include groups.

```yaml
subjects:
  - kind: Group
    name: platform-team           # Organization in cert, or OIDC groups claim
    apiGroup: rbac.authorization.k8s.io
```

### ServiceAccount

ServiceAccounts are Kubernetes-native identities for **pods and automation**. They are namespaced, managed by the API server, and automatically receive a mounted token (unless `automountServiceAccountToken: false` is set).

```yaml
subjects:
  - kind: ServiceAccount
    name: my-service-account
    namespace: workloads          # ServiceAccounts are namespaced; namespace is required
    # No apiGroup field for ServiceAccount
```

---

## Role vs ClusterRole

### Role (Namespaced)

A Role grants permissions to resources **within a single namespace**. It cannot reference cluster-scoped resources (nodes, PVs, namespaces, ClusterRoles).

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: workloads  # Permissions only apply within this namespace
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
```

### ClusterRole (Cluster-Wide)

A ClusterRole grants permissions to resources **across all namespaces** or to cluster-scoped resources (nodes, PVs, StorageClasses, Namespaces, ClusterRoles themselves).

**A ClusterRole can be bound with a RoleBinding** to limit its scope to a single namespace — this is a common pattern for reusable roles.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-reader  # No namespace field — cluster-scoped
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
```

---

## RoleBinding vs ClusterRoleBinding

### RoleBinding (Namespaced)

Binds a Role or ClusterRole to subjects **within a single namespace**. Even if it references a ClusterRole, the resulting permissions are limited to the binding's namespace.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pod-reader-binding
  namespace: workloads
subjects:
  - kind: ServiceAccount
    name: my-app
    namespace: workloads
roleRef:
  kind: Role              # Can also be ClusterRole
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

### ClusterRoleBinding (Cluster-Wide)

Binds a ClusterRole to subjects **cluster-wide**. A ServiceAccount bound with a ClusterRoleBinding can act on all namespaces (or cluster-scoped resources).

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: node-reader-binding
subjects:
  - kind: ServiceAccount
    name: monitoring-agent
    namespace: monitoring
roleRef:
  kind: ClusterRole
  name: node-reader
  apiGroup: rbac.authorization.k8s.io
```

---

## Principle of Least Privilege

Grant **only the permissions required** for a specific task, to a specific subject, in a specific namespace. Audit regularly.

**Checklist:**
- [ ] Use ServiceAccounts, not User credentials, for in-cluster automation
- [ ] Set `automountServiceAccountToken: false` on ServiceAccounts — let pods opt in
- [ ] Use `Role` + `RoleBinding` unless cluster-scope is explicitly needed
- [ ] Scope secrets access to specific secret names using `resourceNames`
- [ ] Never grant `*` verbs or `*` resources (wildcard)
- [ ] Never bind to `cluster-admin` except for true cluster administrators
- [ ] Review bindings quarterly: `kubectl get clusterrolebindings -o wide`

---

## Auditing with `kubectl auth can-i`

```bash
# Can the current user create pods in the workloads namespace?
kubectl auth can-i create pods -n workloads

# Can the app-service-account ServiceAccount read secrets in workloads?
kubectl auth can-i get secrets -n workloads \
  --as=system:serviceaccount:workloads:app-service-account

# Can monitoring-agent list nodes (cluster-wide)?
kubectl auth can-i list nodes \
  --as=system:serviceaccount:monitoring:monitoring-agent

# List ALL permissions for a ServiceAccount
kubectl auth can-i --list -n workloads \
  --as=system:serviceaccount:workloads:app-service-account

# Check if a specific user can access a specific resource
kubectl auth can-i delete deployments -n production \
  --as=jane.doe@example.com
```

---

## Common Mistakes

### 1. Binding to `cluster-admin`

`cluster-admin` is a built-in ClusterRole with **full permissions on all resources in all namespaces**. It is appropriate only for cluster administrators. Binding it to a ServiceAccount for an application is a critical security vulnerability — if the pod is compromised, the attacker has full cluster access.

```bash
# Audit existing cluster-admin bindings
kubectl get clusterrolebindings -o json \
  | jq '.items[] | select(.roleRef.name=="cluster-admin") | {name: .metadata.name, subjects: .subjects}'
```

### 2. Wildcard Resources or Verbs

```yaml
# DANGEROUS — grants access to all resources and all actions
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["*"]
```

This effectively grants `cluster-admin`. Specify exact resources and verbs.

### 3. Forgetting to Scope Secrets with `resourceNames`

Without `resourceNames`, a rule like:
```yaml
resources: ["secrets"]
verbs: ["get"]
```
allows reading **all secrets** in the namespace, including other applications' secrets. Use `resourceNames` to restrict access to only the specific secrets your application needs.

### 4. Using the Default ServiceAccount

Every namespace has a `default` ServiceAccount. Many tools create pods without specifying a ServiceAccount — they get `default`. If you attach RBAC permissions to `default`, you're granting them to **every pod that doesn't specify a ServiceAccount**, which is dangerous.

**Fix:** Create dedicated ServiceAccounts per application. Set `automountServiceAccountToken: false` on the `default` ServiceAccount.

### 5. ClusterRoleBinding when RoleBinding would suffice

A ClusterRoleBinding grants access to all namespaces. If an application only needs to operate in one namespace, use a RoleBinding (even when binding a ClusterRole). The binding scope limits the permission scope.

---

## Scoping Secret Access with `resourceNames`

```yaml
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
    resourceNames: ["app-secret", "db-credentials"]  # ONLY these secrets
```

This is the correct pattern for application secrets. Without `resourceNames`, the `get` verb on `secrets` would allow reading any secret in the namespace — including other teams' secrets in the same namespace.

---

## Useful Commands

```bash
# List all Roles in a namespace
kubectl get roles -n workloads

# List all RoleBindings in a namespace
kubectl get rolebindings -n workloads -o wide

# List all ClusterRoles
kubectl get clusterroles

# List all ClusterRoleBindings
kubectl get clusterrolebindings

# Show the rules in a specific Role
kubectl describe role app-role -n workloads

# Show who is bound to a specific ClusterRole
kubectl get clusterrolebindings -o json \
  | jq '.items[] | select(.roleRef.name=="cluster-node-reader")'

# Detect RBAC issues (pod can't access resource)
kubectl logs <pod> -n workloads  # Look for "forbidden" in application logs
kubectl get events -n workloads  # Look for RBAC-related events
```
