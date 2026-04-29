# Recreate Strategy

## What Is It?

The Recreate strategy is the simplest deployment strategy in Kubernetes. When you update a Deployment with `strategy.type: Recreate`, the controller:

1. Scales the existing (old) ReplicaSet down to **0 replicas**.
2. Waits for all old pods to terminate completely.
3. Scales the new ReplicaSet up to the desired replica count.
4. Waits for new pods to become Ready.

There is a gap between steps 2 and 3 — during this time, **no pods are running** and the application is unavailable. This is the defining characteristic of the Recreate strategy: it always causes downtime.

---

## When Is Recreate Appropriate?

**Development and staging environments** where:
- Downtime is acceptable (no users are affected).
- You want the simplest possible deployment mechanism.
- You need to guarantee no two versions are running simultaneously (useful if your app crashes or misbehaves when two versions of the same process try to hold the same lock or port).

**Applications with hard version exclusivity:**
- Processes that acquire an exclusive lock that a new process cannot acquire until the old one releases it.
- Applications where running v1 and v2 simultaneously causes data corruption.
- Legacy applications that were never designed for concurrent multi-version operation.

**Database schema changes that are NOT backward-compatible:**
- If your migration drops a column that v1 reads from, you cannot run v1 and v2 simultaneously.
- Recreate guarantees v1 is dead before v2 starts (which runs the migration).
- In production, this scenario should be avoided by making schema changes backward-compatible (expand-contract pattern), but for dev/staging Recreate is fine.

---

## When Is Recreate NOT Appropriate?

**Never use Recreate in production for user-facing services** unless:
- You have a planned maintenance window in your SLA.
- The service is internal with no external SLA.
- You have verified the downtime window is acceptable to stakeholders.

The downtime duration = time to terminate old pods + time for new pods to pass their startupProbe/readinessProbe. For applications with slow startup (JVM warmup, ML model loading), this can be several minutes.

---

## How to Apply

```bash
# Apply all resources in order (Namespace, Service, Deployment)
kubectl apply -f recreate/

# Verify the deployment
kubectl rollout status deployment/nginx-recreate -n recreate-demo

# Trigger a recreate by updating the image
kubectl set image deployment/nginx-recreate nginx=nginx:1.25 -n recreate-demo

# Watch pods — you will see all old pods Terminate before new pods start
kubectl get pods -n recreate-demo -w
```

## Observing the Recreate Behavior

```bash
# In terminal 1: watch pods
kubectl get pods -n recreate-demo -w

# In terminal 2: trigger the update
kubectl set image deployment/nginx-recreate nginx=nginx:1.25 -n recreate-demo

# You will observe:
# 1. Old pods enter Terminating state
# 2. A period with 0 Running pods (the downtime window)
# 3. New pods enter ContainerCreating, then Running state
```

## Comparison to Rolling Update

```
Recreate timeline:
t=0   Old pods: [v1] [v1] [v1]
t=5s  Old pods: [Term] [Term] [Term]
t=10s No pods running ← DOWNTIME
t=15s New pods: [Init] [Init] [Init]
t=25s New pods: [v2] [v2] [v2]   ← Service restored

Rolling Update timeline:
t=0   Pods: [v1] [v1] [v1]
t=5s  Pods: [v1] [v1] [v2-init]
t=10s Pods: [v1] [v1-term] [v2]   ← Always serving
t=15s Pods: [v1] [v2] [v2]
t=20s Pods: [v2] [v2] [v2]
```
