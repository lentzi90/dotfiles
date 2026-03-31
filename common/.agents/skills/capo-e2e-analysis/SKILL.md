# CAPO E2E Test Analysis Skill

Analyze Cluster API Provider OpenStack (CAPO) end-to-end test failures from Prow CI jobs (PR-triggered and periodic).

## Deriving the GCS Base URL

Given a **PR number**, use the GitHub MCP to get commit statuses for `kubernetes-sigs/cluster-api-provider-openstack`. Look for context `pull-cluster-api-provider-openstack-e2e-test`. Its `target_url` is a Prow URL like:

```
https://prow.k8s.io/view/gs/kubernetes-ci-logs/pr-logs/pull/kubernetes-sigs_cluster-api-provider-openstack/{PR}/{JOB_NAME}/{JOB_ID}
```

Replace `https://prow.k8s.io/view/gs/` with `https://gcsweb.k8s.io/gcs/` to get the GCS base URL. **Never fetch the Prow page directly** — it's too large.

For periodic jobs: `https://gcsweb.k8s.io/gcs/kubernetes-ci-logs/logs/{JOB_NAME}/{JOB_ID}/`

## Analysis Procedure

### Step 1: Fetch the build log

```
{BASE_URL}/build-log.txt
```

This is the **primary source of truth** (~160KB). It contains the full Ginkgo output with:
- Every test's pass/fail/skip status and duration
- Cluster names: look for `Creating namespace e2e-{random}` and `using the "{flavor}" template`
- `[FAILED]`, `[INTERRUPTED]`, `[TIMEDOUT]` markers with error messages
- Goroutine dumps on timeouts (critical for diagnosing hangs)
- Final summary: `Ran N of M Specs ... X Passed | Y Failed | Z Skipped`

The log contains ANSI escape codes (e.g. `[38;5;10m`) — ignore them. Tests run on 2 parallel Ginkgo nodes, so logs from different tests interleave.

### Step 2: Map failing test to cluster name

From the build log, each test creates a namespace and cluster:
```
Creating a namespace for hosting the "e2e" test spec
INFO: Creating namespace e2e-{random}
INFO: Creating the workload cluster with name "cluster-e2e-{random}" using the "{flavor}" template
```

Use the random suffix (e.g. `e2e-7oit18`) to navigate artifacts for that specific cluster.

### Step 3: Investigate artifacts for the failing cluster

Fetch targeted artifacts in this order (cheapest first):

1. **Kubernetes resources** for the failing cluster — check `.status` and `.status.conditions`:
   ```
   {BASE_URL}/artifacts/clusters/bootstrap/resources/e2e-{name}/
   ```
   Key resources: `OpenStackCluster/`, `Cluster/`, `KubeadmControlPlane/`, `Machine/`, `OpenStackServer/`. Also check `events.log` (may be empty).

2. **OpenStack resource dumps** — shows actual OpenStack state at test end:
   ```
   {BASE_URL}/artifacts/clusters/bootstrap/openstack-resources/servers.json  (~8KB)
   ```
   Also: `networks.json`, `ports.json`, `secgrps.json`, `subnets.json`

3. **CAPO controller logs** (may be incomplete — see note below):
   ```
   {BASE_URL}/artifacts/clusters/bootstrap/logs/capo-system/
   ```

4. **Machine logs** (only for the specific failing machine):
   ```
   {BASE_URL}/artifacts/clusters/bootstrap/e2e-{name}/machines/{machine-name}/
   ```
   Contains: `kubelet.log`, `cloud-final.log`, `console.log`, `kern.log`, `containerd.log`, `server.txt` (Nova server JSON)

5. **ORC / CAPI controller logs** if relevant:
   ```
   {BASE_URL}/artifacts/clusters/bootstrap/logs/orc-system/
   {BASE_URL}/artifacts/clusters/bootstrap/logs/capi-system/
   ```

**Never fetch** `devstack/controller-devstack.log` (~60MB) or cluster templates (~570KB each) unless specifically needed. Prefer small, targeted files.

### Step 4: Understand the provisioning dependency chain

When a cluster is stuck in `Provisioning`, trace the chain:

```
OpenStackCluster (creates network, subnet, router, security groups, bastion)
  → Cluster.status.infrastructureReady = true
    → KubeadmControlPlane creates Machine
      → CAPO creates OpenStackServer → Nova VM
        → VM boots, cloud-init runs, kubeadm init
          → Control plane ready → MachineDeployment unblocked
```

Check where in this chain things stopped:
- **OpenStackCluster has no `.status`** → controller never completed a reconcile (hung on OpenStack API call, or never started)
- **OpenStackCluster provisioned but no Machine** → KCP blocked, check KCP conditions
- **Machine exists but no OpenStackServer** → CAPO couldn't create the VM
- **OpenStackServer exists but Machine not provisioned** → VM failed to boot or cloud-init failed

## Common Failure Patterns

| Symptom | Where to look | Likely cause |
|---------|--------------|--------------|
| Cluster stuck in `Provisioning`, OpenStackCluster has no status | CAPO controller logs, build log timeline | OpenStack became unreachable (sshuttle tunnel died, DevStack crashed) |
| Goroutine dump shows `gophercloud` stuck in `net/http.(*Transport).getConn` during `Authenticate` | Build log `[TIMEDOUT]` sections | OpenStack identity endpoint unreachable — transient infra failure |
| Control plane machine not ready | `machines/{name}/kubelet.log`, `cloud-final.log` | kubeadm init failure, image pull failure, cloud-init failure |
| Test `[INTERRUPTED]` | Build log | Another test failed with `--fail-fast`; not a real failure |
| All `[TIMEDOUT]` in AfterSuite/DeferCleanup | Goroutine dumps in build log | Usually OpenStack connectivity loss during teardown |
| No tests run at all | Build log early sections | DevStack setup failure, Boskos timeout, Docker build failure |
| Early tests pass, later tests fail | Build log timeline | Transient OpenStack/network issue mid-run |

## Important Notes

- **Controller logs may be incomplete.** They are collected from the Kind cluster pod and may only contain startup messages. If the controller was reconciling successfully (earlier tests passed) but the log shows no reconciliation, the log capture is likely truncated — do not conclude the controller wasn't working.
- **`openstack-resources/` is a point-in-time snapshot** taken during AfterSuite, not during the test. It shows what was left over, not what existed during the failure.
- **The `--fail-fast` flag** means one Ginkgo node's failure kills the other node's in-progress test. Always identify the *primary* failure (the `[FAILED]` one) vs the *secondary* (`[INTERRUPTED]`).
- **The `.99` version** (e.g. `v0.14.99`) in the repository artifacts is the dev build from the PR under test.

## Output Format

1. **Summary** — One-line verdict
2. **Test Results Table** — All tests with pass/fail/skip/interrupted status and duration
3. **Failure Details** — For each real failure: test name, error message, timeline, relevant log excerpts
4. **Root Cause Assessment** — Best guess with confidence level
5. **Suggested Next Steps** — What to investigate or whether to just re-trigger
6. **Useful Links** — Direct GCS links to relevant artifact files