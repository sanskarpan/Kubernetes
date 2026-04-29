# Custom Resource Definitions (CRDs)

## Overview

CRDs extend the Kubernetes API with custom resource types. Once a CRD is registered, you can create, read, update, and delete instances of the custom resource using `kubectl` and the Kubernetes API — just like built-in resources (Pods, Deployments, Services).

CRDs are the foundation of the Kubernetes operator pattern. Operators are controllers that watch custom resources and reconcile real-world state (e.g., a `Database` CRD instance triggers the operator to provision an actual PostgreSQL instance).

---

## API Group, Version, and Scope

Every Kubernetes resource is identified by a **Group/Version/Resource (GVR)** triple.

### API Group

CRDs are organized into API groups (like a namespace for resource types). The group appears in the `apiVersion` field:

```yaml
apiVersion: platform.example.com/v1alpha1  # group: platform.example.com, version: v1alpha1
kind: WebApplication
```

**Convention:** Use a domain you control as the group name (e.g., `platform.example.com`, `operators.company.io`). This avoids conflicts with built-in Kubernetes groups (`apps`, `batch`, `networking.k8s.io`).

### Version

API versions follow Kubernetes conventions:
- `v1alpha1` — early development, may change incompatibly
- `v1beta1` — feature-complete, minimal breaking changes
- `v1` — stable, full backward compatibility guaranteed

Multiple versions can coexist in a single CRD using conversion webhooks.

### Scope

| Scope | Meaning |
|-------|---------|
| `Namespaced` | Resource instances live within a namespace (like Pods, Deployments) |
| `Cluster` | Resource instances are cluster-wide (like Nodes, PersistentVolumes) |

Most application CRDs should be `Namespaced` to support multi-tenant clusters.

---

## Schema Validation with openAPIV3Schema

CRD schemas use the OpenAPI v3 / JSON Schema format to validate resource instances at admission time. Without a schema, the API server accepts any field in the resource spec.

```yaml
openAPIV3Schema:
  type: object
  properties:
    spec:
      type: object
      required: [image, replicas]
      properties:
        image:
          type: string
          description: "Container image to deploy"
        replicas:
          type: integer
          minimum: 1
          maximum: 100
        environment:
          type: string
          enum: [dev, staging, production]  # Only these values are valid
```

**Schema best practices:**
- Mark required fields with `required: [field1, field2]`
- Use `enum` to restrict string values to a known set
- Set `minimum` and `maximum` for numeric fields
- Add `description` to every field — it appears in `kubectl explain`
- Use `x-kubernetes-preserve-unknown-fields: true` sparingly (disables validation for that subtree)

---

## Short Names and Categories

### Short Names

Short names allow abbreviated `kubectl` commands:

```yaml
names:
  plural: webapplications
  singular: webapplication
  kind: WebApplication
  shortNames:
    - webapp      # kubectl get webapp  (instead of kubectl get webapplications)
    - wa
```

### Categories

Categories group resources for bulk operations:

```yaml
names:
  categories:
    - all         # Included in: kubectl get all
    - platform    # Custom category: kubectl get platform
```

---

## Subresources

### Status Subresource

The status subresource separates the `spec` (desired state, set by users) from `status` (actual state, set by controllers). This is the standard Kubernetes pattern.

```yaml
subresources:
  status: {}
```

With this enabled:
- `kubectl apply` only updates `spec` — status cannot be changed by users
- Controllers use `PATCH /apis/platform.example.com/v1/namespaces/x/webapplications/y/status`
- `kubectl get webapp my-app -o yaml` shows both spec and status

### Scale Subresource

Enables `kubectl scale` and HPA integration:

```yaml
subresources:
  scale:
    specReplicasPath: .spec.replicas
    statusReplicasPath: .status.availableReplicas
    labelSelectorPath: .status.labelSelector
```

---

## Printer Columns

Define which fields appear in `kubectl get` output (instead of the default NAME/AGE):

```yaml
additionalPrinterColumns:
  - name: Image
    type: string
    jsonPath: .spec.image
  - name: Replicas
    type: integer
    jsonPath: .spec.replicas
  - name: Environment
    type: string
    jsonPath: .spec.environment
  - name: Available
    type: integer
    jsonPath: .status.availableReplicas
  - name: Age
    type: date
    jsonPath: .metadata.creationTimestamp
```

Result:
```
NAME        IMAGE              REPLICAS   ENVIRONMENT   AVAILABLE   AGE
my-webapp   nginx:1.27.0       3          production    3           5d
```

---

## Conversion Webhooks

When a CRD has multiple versions (e.g., `v1alpha1` and `v1`), a conversion webhook translates objects between versions. This allows gradual API migration without breaking existing clients.

```yaml
conversion:
  strategy: Webhook
  webhook:
    conversionReviewVersions: ["v1", "v1beta1"]
    clientConfig:
      service:
        name: my-operator-converter
        namespace: operators
        path: /convert
```

For most CRDs, start with `strategy: None` (no conversion) and add webhooks when introducing breaking schema changes.

---

## Example Use Cases

| CRD | Managed By | What It Provisions |
|-----|-----------|-------------------|
| `Database` | CloudNativePG operator | PostgreSQL cluster |
| `Certificate` | cert-manager | TLS certificates via ACME/Let's Encrypt |
| `HelmRelease` | Flux CD | Helm chart deployment and reconciliation |
| `Ingress` | nginx/traefik controllers | HTTP routing rules |
| `WebApplication` (this repo) | Platform team operator | Deployment + Service + Ingress from one resource |
| `PrometheusRule` | Prometheus Operator | Prometheus alerting rules |

---

## kubectl Commands for CRDs

```bash
# List all CRDs in the cluster
kubectl get crd

# Inspect a CRD definition
kubectl describe crd webapplications.platform.example.com

# Create an instance
kubectl apply -f example-cr.yml

# List instances (using short name)
kubectl get webapp -n workloads

# Explain fields (uses openAPIV3Schema descriptions)
kubectl explain webapp.spec
kubectl explain webapp.spec.replicas

# Delete a CRD (also deletes all instances — be careful!)
kubectl delete crd webapplications.platform.example.com
```
