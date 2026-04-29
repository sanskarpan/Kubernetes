# Blue-Green Deployment Strategy

## What Is It?

Blue-Green deployment maintains **two identical production environments** — "blue" (current live version) and "green" (new version). Traffic is served entirely by one environment at a time. When the green environment is ready and verified, a single switch redirects all traffic from blue to green instantly.

The previous environment (blue after switching to green) is kept as a hot standby for instant rollback.

---

## How Traffic Switching Works

In Kubernetes, the traffic switch is implemented by changing the Service's label selector:

**Initial state:** Service points to blue (v1)
```yaml
selector:
  app.kubernetes.io/name: nginx-bluegreen
  version: v1   # Traffic goes to blue deployment
```

**After verification:** Switch to green (v2)
```bash
kubectl patch service nginx-bluegreen -n blue-green-demo \
  -p '{"spec":{"selector":{"version":"v2"}}}'
```

**Service now routes:** 100% of traffic goes to green pods. Blue pods still exist but receive no traffic.

The switch propagates via kube-proxy's iptables/ipvs rules — typically within milliseconds cluster-wide.

---

## Step-by-Step Deployment Procedure

```bash
# Step 1: Apply blue deployment (this is your current production)
kubectl apply -f blue-deployment.yml

# Step 2: Deploy green (new version) — no traffic goes to it yet
kubectl apply -f green-deployment.yml

# Step 3: Verify green is healthy and Ready
kubectl rollout status deployment/nginx-green -n blue-green-demo
kubectl get pods -n blue-green-demo -l version=v2

# Step 4: Smoke test green BEFORE switching (optional: use port-forward to test directly)
kubectl port-forward deployment/nginx-green 8080:8080 -n blue-green-demo &
curl http://localhost:8080/
# Verify the response is correct for v2

# Step 5: Switch traffic from blue to green
kubectl patch service nginx-bluegreen -n blue-green-demo \
  -p '{"spec":{"selector":{"version":"v2"}}}'

# Step 6: Verify traffic is going to green
kubectl describe service nginx-bluegreen -n blue-green-demo
# Check 'Endpoints' — should show green pod IPs

# Step 7: Monitor for errors in green
kubectl logs -n blue-green-demo -l version=v2 --tail=100 -f

# Step 8: (After confidence period) Scale down blue to save resources
kubectl scale deployment/nginx-blue --replicas=0 -n blue-green-demo
# Do NOT delete blue yet — keep it for emergency rollback for at least 24h
```

---

## Rollback Procedure

If green has problems after the switch:

```bash
# Instant rollback — switch selector back to blue (v1)
kubectl patch service nginx-bluegreen -n blue-green-demo \
  -p '{"spec":{"selector":{"version":"v1"}}}'

# Verify rollback took effect
kubectl describe endpoints nginx-bluegreen -n blue-green-demo
# Should show blue pod IPs again
```

Rollback is instant because blue pods are still running — no pod creation or startup time required. This is blue-green's key advantage over rolling update rollback (which requires starting old pods).

---

## Resource Cost

Blue-green requires **2x the normal pod count** for the duration of the release window. With 4 replicas in production, blue-green means 8 pods running simultaneously (4 blue + 4 green) during the switchover.

For large deployments, this is significant. Mitigation strategies:
- Scale green down to 1 replica for testing, scale to full replicas just before the switch.
- Use cluster autoscaling so the extra capacity is provisioned only when needed.
- Limit the release window — switch quickly and scale down blue within hours.

---

## Database Schema Compatibility

Blue-green requires that the database schema is compatible with both versions simultaneously (during the brief window where green is deployed but before the switch). The recommended pattern:

1. **Expand:** Deploy a migration that adds new columns/tables but keeps old ones. Blue and green both work with the expanded schema.
2. **Switch:** Flip the service selector to green.
3. **Contract:** After confidence, deploy another migration to drop the old columns (now only green is running).

This "expand-contract" pattern avoids schema-induced downtime in blue-green deployments.

---

## When to Use Blue-Green

**Use when:**
- High-stakes releases where instant rollback is non-negotiable.
- You need to test the new version with production-like traffic before declaring success.
- Your release involves multiple coordinated components that must all switch simultaneously.
- Regulatory requirements mandate zero-downtime with a verified rollback path.

**Do NOT use when:**
- You cannot afford 2x resource cost.
- Your application has many stateful dependencies that cannot easily be duplicated.
- You deploy many times per day (cost of maintaining two environments adds up).
