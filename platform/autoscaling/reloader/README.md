# Stakater Reloader

## What Reloader Does

Stakater Reloader watches ConfigMaps and Secrets in your cluster. When a watched resource changes, Reloader triggers a rolling restart of Deployments, StatefulSets, or DaemonSets that reference it.

This solves a common problem: Kubernetes does not automatically restart pods when a ConfigMap or Secret they consume is updated. Without Reloader (or an equivalent mechanism), configuration changes silently take no effect until the next pod restart.

## Installation

```bash
helm repo add stakater https://stakater.github.io/stakater-charts
helm repo update

helm install reloader stakater/reloader \
  --namespace reloader \
  --create-namespace \
  --version 1.0.72
```

Verify:

```bash
kubectl get pods -n reloader
kubectl get deployment -n reloader reloader-reloader
```

## Usage

### Option 1: Auto-reload (watch all ConfigMaps and Secrets)

Add the annotation to your Deployment:

```yaml
metadata:
  annotations:
    reloader.stakater.com/auto: "true"
```

Reloader will watch ALL ConfigMaps and Secrets referenced by this Deployment (via `envFrom`, `env.valueFrom`, or `volumes`) and trigger a rolling restart when any of them change.

### Option 2: Watch specific ConfigMaps/Secrets only

```yaml
metadata:
  annotations:
    # Only restart when these specific resources change
    configmap.reloader.stakater.com/reload: "myapp-config,myapp-feature-flags"
    secret.reloader.stakater.com/reload: "myapp-tls,myapp-credentials"
```

This is more precise and avoids unexpected restarts from unrelated ConfigMap changes.

### Option 3: Watch by search key (label-based)

```yaml
metadata:
  annotations:
    reloader.stakater.com/search: "true"
```

With this annotation, Reloader only watches ConfigMaps/Secrets that have the label `reloader.stakater.com/match: "true"`. This inverts the control: you label the ConfigMaps that should trigger restarts, rather than annotating every Deployment.

## Alternative: Checksum Annotation Pattern

Without Reloader, teams often use a checksum annotation to trigger restarts on config change. This is the GitOps-native approach (no additional controller required):

```yaml
# In your Helm chart's deployment.yaml template:
spec:
  template:
    metadata:
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

When the ConfigMap content changes, the checksum annotation changes, which changes the pod template spec, which triggers a rolling restart.

## When to Use Reloader vs Checksum Annotations

| Approach | Use When |
|---|---|
| **Reloader** | GitOps workflow where ConfigMaps are updated imperatively (e.g., `kubectl edit`, automation scripts). You want restarts to happen automatically without re-deploying the Deployment. |
| **Checksum annotations** | Helm-based GitOps (ArgoCD, Flux) where all changes go through Git. The checksum is computed at render time and baked into the Deployment spec — no external controller needed. |
| **Reloader** | You update ConfigMaps outside of Helm (e.g., CI pipeline updates a ConfigMap directly) and need the Deployment to pick up changes immediately. |
| **Checksum annotations** | You want the restart to be atomic with the config change (same Git commit, same ArgoCD sync). |

**Recommendation for GitOps**: use checksum annotations in Helm charts (see `platform/helm/advanced/`). Reserve Reloader for imperative config updates or environments where Helm is not used.

## Verifying Reloader is Working

```bash
# Check Reloader logs for reload events
kubectl logs -n reloader -l app=reloader-reloader --tail=50

# Simulate a config change and watch for restart
kubectl patch configmap myapp-config -n default \
  --type=merge -p '{"data":{"key":"new-value"}}'

# Watch for the rolling restart
kubectl rollout status deployment/myapp -n default
```
