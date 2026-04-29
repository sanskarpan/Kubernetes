# CI/CD for Kubernetes

## Overview

Continuous Integration (CI) and Continuous Delivery (CD) are the automation backbone
for deploying applications to Kubernetes. This guide covers the pipeline stages,
tooling options, GitOps integration, and rollback strategies.

---

## The CI/CD Pipeline for Kubernetes

```
Developer → Git Push
               │
               ▼
    ┌─────────────────────┐
    │  1. BUILD           │  docker build -t myapp:${GIT_SHA} .
    │     (CI Server)     │
    └──────────┬──────────┘
               │
               ▼
    ┌─────────────────────┐
    │  2. TEST            │  Unit tests, integration tests, linting
    │     (CI Server)     │
    └──────────┬──────────┘
               │
               ▼
    ┌─────────────────────┐
    │  3. SECURITY SCAN   │  Trivy, Grype, Snyk, Checkov
    │     (CI Server)     │
    └──────────┬──────────┘
               │
               ▼
    ┌─────────────────────┐
    │  4. PUSH            │  docker push myrepo/myapp:${GIT_SHA}
    │     (CI Server)     │  Also push :latest and :<branch>-latest
    └──────────┬──────────┘
               │
               ├─── Push-Based ─────────────────────────────────┐
               │                                                 │
               ▼                                                 ▼
    ┌─────────────────────┐              ┌───────────────────────────────┐
    │  5a. UPDATE         │              │  5b. UPDATE GIT               │
    │  CLUSTER DIRECTLY   │              │  (GitOps/Pull-Based)          │
    │  kubectl set image  │              │  Update values.yaml or        │
    │  kubectl apply -f   │              │  manifest with new image tag, │
    └──────────┬──────────┘              │  commit, push to Git.         │
               │                         └──────────────┬────────────────┘
               │                                        │
               ▼                                        ▼
    ┌─────────────────────┐              ┌───────────────────────────────┐
    │  6a. VERIFY         │              │  6b. GITOPS OPERATOR          │
    │  kubectl rollout    │              │  ArgoCD / Flux detects Git    │
    │  status             │              │  change and syncs to cluster. │
    └─────────────────────┘              └───────────────────────────────┘
```

---

## Build → Test → Push → Deploy Flow

### Stage 1: Build

The build stage produces an immutable, tagged container image.

**Best practices:**
- Tag with the Git commit SHA (`${GIT_COMMIT:0:8}`) for traceability
- Use multi-stage Dockerfiles to keep images small and secure
- Never use `:latest` as the primary tag — it is mutable and not reproducible
- Build once, promote the same image through environments (dev → staging → prod)

```bash
# Deterministic, traceable tag
docker build \
  --label "git.commit=${GIT_SHA}" \
  --label "build.date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -t myrepo/myapp:${GIT_SHA} \
  -t myrepo/myapp:${BRANCH}-latest \
  .
```

### Stage 2: Test

Tests must run BEFORE the image is pushed to prevent broken images from reaching any registry.

**Test types:**
- **Unit tests:** Fast, no external dependencies. Always run.
- **Integration tests:** Test component interactions. Run against ephemeral test environments.
- **End-to-end tests:** Full stack tests. Run in staging, not in every PR build (too slow).
- **Linting / SAST:** ESLint, Pylint, Hadolint (Dockerfile), Checkov (K8s manifests).

```bash
# Run tests inside the built image (no dependency on host)
docker run --rm myrepo/myapp:${GIT_SHA} python manage.py test

# Lint Kubernetes manifests
checkov -d k8s/ --framework kubernetes
```

### Stage 3: Security Scanning

Scan the image for known CVEs before pushing to a registry.

**Tools:**
| Tool      | Scope                        | Notes                                          |
|-----------|------------------------------|------------------------------------------------|
| Trivy     | Image, IaC, repo             | Fast, comprehensive, CNCF project              |
| Grype     | Image, SBOM                  | Anchore project, good for SBOM generation      |
| Snyk      | Image, code, dependencies    | SaaS with developer-friendly UI                |
| Checkov   | Kubernetes manifests, IaC    | Policy-as-code for misconfigurations           |
| kube-score| Kubernetes manifests         | Scores manifests against best practices        |

```bash
# Trivy image scan (fail on HIGH or CRITICAL)
trivy image \
  --exit-code 1 \
  --severity HIGH,CRITICAL \
  --ignore-unfixed \
  myrepo/myapp:${GIT_SHA}

# Generate SBOM for compliance
trivy image \
  --format cyclonedx \
  --output sbom.json \
  myrepo/myapp:${GIT_SHA}
```

### Stage 4: Push

After all checks pass, push the image to the registry.

```bash
# Push the SHA-tagged image (immutable)
docker push myrepo/myapp:${GIT_SHA}

# Push the branch-specific latest tag (mutable — for dev environments)
docker push myrepo/myapp:${BRANCH}-latest

# In production, also push the digest-pinned reference
docker inspect --format='{{index .RepoDigests 0}}' myrepo/myapp:${GIT_SHA}
```

### Stage 5 & 6: Deploy

See "GitOps vs Push-Based" section below.

---

## Jenkins, GitHub Actions, GitLab CI Overview

### Jenkins

- **Pros:** Extremely mature, self-hosted, unlimited plugins, Groovy DSL (Jenkinsfile)
- **Cons:** High maintenance overhead, UI is dated, plugin quality varies
- **Best for:** Enterprises with existing Jenkins investment, complex pipeline graphs

See [`jenkins/Jenkinsfile`](./jenkins/Jenkinsfile) for a production-quality example.

```groovy
// Minimal Jenkins pipeline
pipeline {
    agent { label 'docker-agent' }
    stages {
        stage('Build') { steps { sh 'docker build .' } }
        stage('Test')  { steps { sh 'docker run --rm myapp pytest' } }
    }
}
```

### GitHub Actions

- **Pros:** Zero infrastructure, tight GitHub integration, marketplace of actions, free for public repos
- **Cons:** Vendor lock-in, limited for complex cross-repo pipelines, runner minutes cost
- **Best for:** Open-source projects, startups, teams already on GitHub

```yaml
# .github/workflows/deploy.yml
name: Build and Deploy
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: docker build -t myapp:${{ github.sha }} .
      - name: Test
        run: docker run --rm myapp pytest
      - name: Push
        run: |
          echo "${{ secrets.DOCKER_PASSWORD }}" | docker login -u ${{ secrets.DOCKER_USERNAME }} --password-stdin
          docker push myapp:${{ github.sha }}
```

### GitLab CI

- **Pros:** Integrated with GitLab, built-in container registry, Docker-native, MR pipelines
- **Cons:** Requires GitLab, runner management (similar to Jenkins)
- **Best for:** Teams on self-hosted GitLab, monorepos, compliance-heavy environments

```yaml
# .gitlab-ci.yml
stages: [build, test, push, deploy]

build:
  stage: build
  script:
    - docker build -t $CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA .

deploy:
  stage: deploy
  script:
    - kubectl set image deployment/myapp myapp=$CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA
  only:
    - main
```

---

## GitOps vs Push-Based Deployment

### Push-Based (CI server applies directly)

```
CI Server → kubectl apply -f k8s/ (or helm upgrade)
```

**Pros:**
- Simple to set up
- Works well for small teams and simple deployments
- Immediate feedback from the pipeline

**Cons:**
- CI server requires cluster credentials (high-privilege secret in CI)
- No drift detection — manual `kubectl apply` changes are invisible
- Rollback is complex (re-run pipeline)
- No audit trail beyond CI logs

**When to use:** Dev/preview environments, simple projects, early stage.

### GitOps / Pull-Based (operator reconciles from Git)

```
CI Server → git push (manifest change) → ArgoCD/Flux → kubectl apply
```

**Pros:**
- Cluster never needs to be reachable from CI (pull model)
- Continuous drift detection and self-healing
- Full audit trail in Git (author, timestamp, diff)
- Rollback = `git revert` + automatic sync
- Declarative — cluster state is always readable in Git

**Cons:**
- More components to manage (GitOps operator)
- Slower feedback loop (Git poll interval + reconciliation)
- More complex initial setup

**When to use:** Production environments, regulated industries, multi-cluster, teams > 5 engineers.

---

## Rollback Strategies

### 1. Kubernetes Native Rollback

```bash
# View rollout history
kubectl rollout history deployment/myapp -n production

# Roll back to the previous version
kubectl rollout undo deployment/myapp -n production

# Roll back to a specific revision
kubectl rollout undo deployment/myapp --to-revision=3 -n production

# Monitor the rollback
kubectl rollout status deployment/myapp -n production
```

### 2. Helm Rollback

```bash
# View Helm release history
helm history myapp -n production

# Roll back to the previous revision
helm rollback myapp -n production

# Roll back to revision 2
helm rollback myapp 2 -n production
```

### 3. GitOps Rollback

```bash
# Identify the last good commit
git log --oneline gitops/apps/myapp.yml

# Revert the commit that caused the issue
git revert <bad-commit-sha>
git push origin main

# ArgoCD/Flux will automatically sync the reverted state to the cluster
# No manual kubectl commands needed
```

### 4. Blue/Green Deployment (zero-downtime rollback)

Maintain two identical environments. Switch traffic between them by updating the Service selector.

```bash
# Switch Service selector from blue to green
kubectl patch service myapp \
  -p '{"spec":{"selector":{"version":"green"}}}' \
  -n production

# Rollback: switch back to blue in seconds
kubectl patch service myapp \
  -p '{"spec":{"selector":{"version":"blue"}}}' \
  -n production
```

### 5. Canary Deployment (progressive rollback)

Route a percentage of traffic to the new version using Ingress annotations or a service mesh.
Roll back by setting canary weight to 0.

```bash
# Set canary weight to 0 (stop canary traffic)
kubectl annotate ingress myapp-canary \
  nginx.ingress.kubernetes.io/canary-weight="0" \
  --overwrite \
  -n production
```

---

## Security Best Practices for CI/CD Pipelines

1. **Never store credentials in code** — use CI secrets management (GitHub Secrets, Jenkins Credentials)
2. **Least privilege** — the service account used by CI should only have the minimum RBAC permissions
3. **Pin action/image versions** — use `uses: actions/checkout@v4` (not `@main`)
4. **Scan secrets in code** — use `trufflesecurity/trufflehog` or `gitleaks` in CI
5. **Sign images** — use `cosign` to sign and verify images (SLSA compliance)
6. **Pin Dockerfiles FROM** — use `FROM node:20.18.0@sha256:...` not `FROM node:latest`
7. **Separate CI from CD** — CI builds and tests; CD deploys. Different systems, different credentials.
