# Jobs and CronJobs — Deep Dive

## What Is a Job?

A Job creates one or more pods and ensures that a **specified number of them successfully complete**. Unlike Deployments (which run pods indefinitely), Jobs run pods to completion. When the required number of successful completions is reached, the Job is done.

Jobs are ideal for: database migrations, batch data processing, report generation, one-time setup tasks, and any finite work unit.

---

## Job Completions and Parallelism

These two fields control how the Job executes:

```yaml
spec:
  completions: 5    # How many pods must succeed in total
  parallelism: 2    # How many pods can run simultaneously
```

| Pattern | completions | parallelism | Use Case |
|---|---|---|---|
| **Single run** | 1 | 1 | DB migration, one-time task |
| **Parallel fixed** | 5 | 2 | Process 5 items, 2 at a time |
| **Work queue** | (unset) | 3 | Pods pull from queue until empty |
| **Indexed** | 5 | 5 | Sharded processing (pod gets index 0-4) |

**Indexed Jobs** (Kubernetes 1.21+):
```yaml
spec:
  completionMode: Indexed   # Each pod gets a unique index (JOB_COMPLETION_INDEX env var)
  completions: 5
  parallelism: 5
```
Each pod receives the `JOB_COMPLETION_INDEX` environment variable (0 through N-1), allowing pods to process specific data shards. Ideal for MapReduce-style workloads.

---

## Restart Policies

Only `Never` and `OnFailure` are valid for Jobs (`Always` is invalid — it would make the pod restart forever and the Job would never complete).

```yaml
restartPolicy: Never
# Pod is never restarted on failure.
# On failure, a NEW pod is created (up to backoffLimit attempts).
# Use when you want each attempt to be completely fresh (clean state).
# Pod history is preserved for debugging.
```

```yaml
restartPolicy: OnFailure
# The SAME pod is restarted on failure (in-place restart).
# The container restarts but the pod object persists.
# Use when startup cost is high and partial state can be reused.
# Risk: if the pod gets into a crash loop, it stays on the same node
# and can exhaust node resources.
```

> **Interview Callout:** "What's the difference between `restartPolicy: Never` and `OnFailure` in a Job?" — `Never` creates a new pod on failure (clean slate, preserves failure pods for debugging, backoffLimit controls total attempts). `OnFailure` restarts the same pod's container (faster restart, same node, same ephemeral state — but pollutes the pod with container restart count).

---

## backoffLimit

```yaml
spec:
  backoffLimit: 3   # Maximum number of retries before the Job is marked Failed
```

The backoff delay between retries follows exponential backoff: 10s, 20s, 40s, 80s... capped at 6 minutes. This prevents hammering a failing dependency.

If `backoffLimit` is exceeded, the Job enters a `Failed` state and all running pods are terminated. The Job does NOT clean itself up — it remains for inspection.

---

## activeDeadlineSeconds

```yaml
spec:
  activeDeadlineSeconds: 300   # Job must complete within 5 minutes or be killed
```

This is the job's **maximum wall-clock duration** from when it starts. If the Job hasn't completed after this time, all its pods are terminated and the Job is marked as Failed with reason `DeadlineExceeded`.

This is critical for:
- Preventing zombie jobs that run forever due to hangs
- SLA enforcement (e.g., "migrations must complete in under 5 minutes")
- Cost control in cloud environments (prevent accidentally long-running batch pods)

`activeDeadlineSeconds` takes precedence over `backoffLimit` — even if you have more retries available, if the deadline is hit, the Job fails.

---

## TTL After Completion

```yaml
spec:
  ttlSecondsAfterFinished: 86400   # Auto-delete the Job and its pods after 24 hours
```

Without TTL, completed and failed Jobs accumulate in the cluster forever, consuming etcd space and cluttering `kubectl get jobs` output. The TTL controller automatically cleans up Jobs after the specified duration.

`ttlSecondsAfterFinished: 0` deletes the Job immediately after completion — use with caution, as you lose the ability to inspect logs.

---

## CronJob Schedule Syntax

CronJobs use standard cron syntax with an optional seconds field (not supported by all versions):

```
┌───────────── minute (0–59)
│ ┌───────────── hour (0–23)
│ │ ┌───────────── day of month (1–31)
│ │ │ ┌───────────── month (1–12)
│ │ │ │ ┌───────────── day of week (0–6, Sunday=0)
│ │ │ │ │
* * * * *
```

| Schedule | Meaning |
|---|---|
| `0 2 * * *` | Every day at 2:00 AM |
| `*/15 * * * *` | Every 15 minutes |
| `0 8 * * 1` | Every Monday at 8:00 AM |
| `0 0 1 * *` | First day of every month at midnight |
| `@daily` | Equivalent to `0 0 * * *` |
| `@hourly` | Equivalent to `0 * * * *` |

All times are in the timezone of the kube-controller-manager (usually UTC). To use a specific timezone:
```yaml
spec:
  timeZone: "America/New_York"   # Kubernetes 1.27+
```

---

## ConcurrencyPolicy

Controls what happens when a CronJob's previous run is still active when the next schedule fires:

```yaml
spec:
  concurrencyPolicy: Allow    # Default — start new job even if previous is still running
  concurrencyPolicy: Forbid   # Skip new job if previous is still running (most common for jobs with side effects)
  concurrencyPolicy: Replace  # Terminate the running job and start a new one
```

> **Interview Callout:** "When would you use each ConcurrencyPolicy?" — `Allow` for independent, idempotent jobs. `Forbid` for jobs that have side effects or modify shared state (backups, report generation). `Replace` for jobs where only the latest run matters (cache warming, config sync).

---

## startingDeadlineSeconds

```yaml
spec:
  startingDeadlineSeconds: 300
```

If the CronJob controller misses a scheduled run (e.g., because the controller was down or the cluster was overloaded), it will only attempt to catch up within `startingDeadlineSeconds` of the missed schedule. Missed runs older than this window are skipped.

Without this field, a CronJob that misses 100 runs (say, after a controller restart) may try to run all 100 immediately, overwhelming the cluster.

---

## History Limits

```yaml
spec:
  successfulJobsHistoryLimit: 3    # Keep last 3 successful Job objects (and their pods)
  failedJobsHistoryLimit: 1        # Keep last 1 failed Job object for debugging
```

Set both to 0 to clean up immediately (no debugging capability). Production recommendation: 3 and 1 (enough for debugging without cluttering the cluster).

---

## Files in This Directory

| File | Purpose |
|---|---|
| `job.yml` | Production Job — database migration pattern |
| `cronjob.yml` | Production CronJob — backup pattern |

## Apply and Verify

```bash
# Run the Job
kubectl apply -f job.yml

# Watch the Job progress
kubectl get jobs -n workloads -w

# View logs from the Job pod
kubectl logs -n workloads -l job-name=db-migration

# Check Job status
kubectl describe job db-migration -n workloads

# Run the CronJob
kubectl apply -f cronjob.yml

# Manually trigger a CronJob run (for testing)
kubectl create job --from=cronjob/data-backup manual-backup-$(date +%s) -n workloads

# List all Jobs (including those from CronJob)
kubectl get jobs -n workloads
```
