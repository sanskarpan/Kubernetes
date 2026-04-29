# Deployment Strategies — Overview

Kubernetes supports multiple patterns for deploying new versions of your application. Each strategy involves different tradeoffs between downtime risk, resource cost, rollback speed, and operational complexity.

## Strategies Covered

| Strategy | Subdirectory | Summary |
|---|---|---|
| **Recreate** | [`recreate/`](./recreate/) | Kill all old pods, then start new ones. Causes downtime. Only for dev/staging. |
| **Rolling Update** | [`rolling-update/`](./rolling-update/) | Replace pods incrementally. Zero downtime when done correctly. Default Kubernetes behavior. |
| **Blue-Green** | [`blue-green/`](./blue-green/) | Run two complete environments; switch traffic instantly by flipping a service selector. |
| **Canary** | [`canary/`](./canary/) | Route a small percentage of traffic to the new version; promote or roll back based on metrics. |

## Decision Guide

```
Is downtime acceptable?
├── Yes → Recreate (only for dev/staging)
└── No → Continue...
    │
    Do you need instant rollback capability?
    ├── Yes, and you can afford 2x resources → Blue-Green
    └── No, or resource cost is a concern → Continue...
        │
        Do you need to validate with real user traffic before full rollout?
        ├── Yes → Canary
        └── No → Rolling Update (default — use this for most deployments)
```

## Full Comparison

See [`comparison.md`](./comparison.md) for a detailed comparison table including downtime, resource overhead, rollback speed, risk level, complexity, and industry examples.

## How to Apply Each Strategy

```bash
# Recreate
kubectl apply -f recreate/

# Rolling Update
kubectl apply -f rolling-update/

# Blue-Green (apply both deployments, traffic goes to blue initially)
kubectl apply -f blue-green/

# Canary (apply stable first, then canary — ~80/20 traffic split)
kubectl apply -f canary/
```
