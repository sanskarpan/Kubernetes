# Policy Enforcement — Kyverno

## Overview

Admission controllers are plugins that intercept API server requests before objects are persisted to etcd. They run after authentication and authorization, and can both validate (reject bad requests) and mutate (modify requests) before they are stored.

Two types are relevant for policy enforcement:
- **ValidatingAdmissionWebhook** — validates and accepts/rejects requests
- **MutatingAdmissionWebhook** — modifies requests before validation (e.g., inject sidecars, set defaults)

Policy engines like Kyverno and OPA/Gatekeeper deploy as admission webhooks and allow writing policies in a declarative way, without writing Go code.

---

## Kubernetes Admission Controller Flow

```
kubectl apply → Authentication → Authorization (RBAC) → Mutating Webhooks → Object Validation → Validating Webhooks → etcd
```

Kyverno registers both mutating and validating webhooks. The order:
1. Kyverno **mutate** policies run first (add labels, set defaults, inject sidecars)
2. Kyverno **validate** policies run after mutation (reject non-compliant objects)

---

## Kyverno vs OPA/Gatekeeper

Both are CNCF projects widely used in production. Choose based on your team's needs.

| Feature | Kyverno | OPA/Gatekeeper |
|---------|---------|----------------|
| Policy language | YAML (Kubernetes-native) | Rego (purpose-built DSL) |
| Learning curve | Low — familiar YAML patterns | High — Rego is a new language to learn |
| Mutation support | Built-in (mutate policies) | Limited (external data only) |
| Generate resources | Yes (generate ConfigMaps, NetworkPolicies) | No |
| Policy reports | Built-in CRDs (PolicyReport) | Requires separate tooling |
| Image verification | Built-in (cosign integration) | Requires external tools |
| Community | Large, active | Larger (Rego is also used outside K8s) |
| Best for | Teams that prefer YAML; platform teams new to policy engines | Teams with existing Rego expertise; complex policy logic |

**Why Kyverno is chosen for this repository:**
- Policies are written in YAML — no new language to learn
- Mutation, validation, and generation in one tool
- Built-in PolicyReport CRDs for compliance reporting
- Active community and extensive policy library (kyverno.io/policies)

---

## Policy Modes: Audit → Enforce Rollout Strategy

Never enable `Enforce` mode on day one. Follow this rollout:

### Phase 1: Audit (days 1–14)

```yaml
validationFailureAction: Audit
```

Violations are logged but NOT blocked. Resources are created as normal. Check policy reports daily:

```bash
kubectl get policyreport -A
kubectl get clusterpolicyreport
```

Fix violations in team manifests and CI/CD pipelines before moving to Enforce.

### Phase 2: Warn (optional, Kyverno 1.7+)

```yaml
validationFailureAction: Audit
failurePolicy: Ignore  # Combined with warn in newer versions
```

Some Kyverno versions support returning warnings similar to PSA. Refer to Kyverno docs for your version.

### Phase 3: Enforce

```yaml
validationFailureAction: Enforce
```

Non-compliant resources are **rejected at admission**. CI/CD pipelines will fail for non-compliant manifests. Inform all teams before switching to Enforce mode.

**Recommended timeline:** Start Audit → review for 2 weeks → fix violations → switch to Enforce.

---

## Compliance Reporting

Kyverno generates `PolicyReport` (namespaced) and `ClusterPolicyReport` (cluster-wide) objects after evaluating existing resources.

```bash
# View all policy reports across namespaces
kubectl get policyreport -A

# View violations in a specific namespace
kubectl get policyreport -n workloads -o yaml | \
  jq '.items[].results[] | select(.result=="fail")'

# Count total violations
kubectl get policyreport -A -o json | \
  jq '[.items[].results[] | select(.result=="fail")] | length'

# Generate a report for a namespace
kubectl annotate ns workloads kyverno.io/generate-report=true
```

---

## Installation

See `install-kyverno.sh` for the full installation script.

```bash
./install-kyverno.sh

# Verify Kyverno is running
kubectl get pods -n kyverno

# Verify policies are applied
kubectl get clusterpolicy
```

### Kyverno components

- **kyverno** — main admission webhook controller
- **kyverno-background-controller** — reconciles existing resources against policies (generates PolicyReports)
- **kyverno-reports-controller** — aggregates policy reports
- **kyverno-cleanup-controller** — garbage collection

---

## Policy Structure Reference

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: my-policy
spec:
  validationFailureAction: Audit    # or Enforce
  background: true                  # Scan existing resources and generate PolicyReports
  rules:
    - name: rule-name
      match:
        any:
          - resources:
              kinds: [Pod]         # Apply to these resource types
              namespaces: []       # Empty = all namespaces; or list specific namespaces
      exclude:
        any:
          - resources:
              namespaces: [kyverno, kube-system]  # Exempt these namespaces
      validate:                    # or: mutate, generate, verifyImages
        message: "Failure message shown to the user"
        pattern:
          spec:
            containers:
              - name: "*"
                resources:
                  limits:
                    memory: "?*"    # Must be set (not empty)
```

---

## Kyverno Pattern Syntax

Kyverno uses YAML-based pattern matching. Key operators:

| Pattern | Meaning |
|---------|---------|
| `?*` | At least one character (field must be set and non-empty) |
| `*` | Any value including empty |
| `"!*:latest"` | String must not match `*:latest` |
| `">=1"` | Integer >= 1 |
| `"1024-65535"` | Integer in range |

For complex conditions, use `deny` rules with JMESPath expressions:

```yaml
deny:
  conditions:
    any:
      - key: "{{ request.object.spec.containers[].image | [?contains(@, ':latest')] | length(@) }}"
        operator: GreaterThan
        value: "0"
```
