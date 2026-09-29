---
name: capi-flake-triage
description: Find, group and analyze flaky/failing CI tests for Cluster API (and CAPO) using k8s-triage data, cross-reference them with GitHub issues, and suggest fixes. Use when asked about CI signal, flakes, k8s-triage, or "what is failing in CI".
---

# Cluster API Flake Triage Skill

[k8s-triage](https://storage.googleapis.com/k8s-triage/index.html) clusters failures from every Kubernetes Prow job by similar failure text, across jobs and tests, over a rolling ~14-day window. This skill uses `triage.py` (in this skill's directory, Python 3 stdlib only) to read the same public data the UI uses, filter it like the UI, and print compact summaries.

**Never fetch the triage UI page or the raw JSON files yourself.** `failure_data.json` is ~100 MB uncompressed and covers all of Kubernetes CI. Always go through `triage.py`.

Run it as `python3 <skill-dir>/triage.py <subcommand> ...`. Use `--help` on any subcommand for all flags.

## Coverage

- Cluster API: `--preset capi` (periodic unit-test and e2e jobs on `main` and release branches, matching the CI signal handbook link in `docs/release/role-handbooks/ci-signal/README.md`).
- CAPO: `--preset capo`.
- Any k8s-triage UI URL: `--url '<url>'` copies its filters and date; explicit flags override preset/URL values.
- Metal3 jobs do **not** run on prow.k8s.io, so they are not in k8s-triage.

## Subcommands

| Command | Purpose |
|---|---|
| `clusters` | List failure clusters matching filters. Key flags: `--preset`, `--url`, `--group-by test`, `--sort total\|builds\|day\|last`, `--days N`, `--limit`, `--pr`, `--no-ci`, `--job/--xjob/--test/--xtest/--text/--xtext/--repo/--xrepo` (case-insensitive regex search, same semantics as the UI), `--date YYYY-MM-DD`, `--format json`. |
| `cluster <id>` | One cluster in detail: all tests, jobs, builds and links, longer failure text, `--show-key` for the normalized clustering key. Loads a small per-cluster slice file instead of the full dataset. Pass the same `--preset` to restrict to your jobs; without filters it shows every job in the cluster (including other repos, which is useful for spotting shared test-framework flakes). |
| `failures <build-url>` | Failed junit test cases for a build (Prow, gcsweb, `storage.googleapis.com` or `gs://` URL). Prints the repo commit the job ran on, failure message, highlighted error lines and truncated output. `--test REGEX`, `--system-err N` (tail of the ginkgo spec timeline). |
| `log <build-url>` | Stream `build-log.txt` (or `--file`) and print `--grep REGEX` matches with `-C` context, or the last `--tail` lines. Use this instead of fetching logs directly, since unit-test logs can have 100k+ lines. |

Data is cached in `~/.cache/k8s-triage` (override with `K8S_TRIAGE_CACHE`) and revalidated with ETags after `--max-age` seconds (default 1800). `--offline` uses the cache only.

## Reading the output

- **hits** is what the UI calls "count": one per (test, build). One broken build can produce many hits (for example `TestMain` failing in every package when `etcd` is missing). **builds** is the number of distinct failed runs; prefer it when judging frequency.
- **Jobs** lines show `cluster failures / runs in window (rate); job failed X/Y`. The job failure count includes aborted runs and every other failure reason.
- **Shares failed builds with** lists clusters that failed in the same builds. Typically this is a cascade: for example, `SynchronizedBeforeSuite failed` together with the real cause (`failed to get component source YAML ... 504`). Report such clusters as one problem.
- **`--group-by test`** merges clusters that hit the same test. One flake is often split into several clusters because the log text differs. Go subtests are collapsed to the top-level `TestXxx`, and ginkgo specs to the spec text. `TestMain` keeps its package because it is per-package setup.
- **Search terms** are the test identifiers plus digit-free error phrases, meant for GitHub issue search.
- **Highlights** are heuristically selected error lines. The sample text is a single example; for unit tests it is mostly log noise. Always confirm with `failures` before drawing conclusions.
- Job names encode the branch: `...-main`, `...-release-1-14`, `...-mink8s-...` (oldest supported Kubernetes), `...-latestk8s-...`, `...-upgrade-<from>-<to>-...`.

## Workflow

### 1. Overview

```sh
python3 triage.py clusters --preset capi --group-by test --limit 20
python3 triage.py clusters --preset capi --sort builds --limit 15 --text-chars 300
python3 triage.py clusters --preset capi --days 3 --sort day   # what is failing right now
```

If the user gives a triage URL, use `--url '<url>'` so the results match what they see. Only include `--pr` if asked: presubmit failures are often caused by the PR under test, not by flakes.

### 2. Classify each group

Put each group into one of these categories:

- **Infra / external**: GitHub 5xx or rate limits, image pulls, DNS, `docker info` failures, missing binaries (`etcd` not in `$PATH`), port conflicts (`address already in use`), node pressure. These are usually reported against test-infra or fixed with retries in the test framework.
- **Test flake**: timing and `Eventually` timeouts, cache/informer sync races, envtest conversion or webhook races, cleanup ordering.
- **Product bug**: the controller really misbehaves. Look for consistent failures across branches or Kubernetes versions, or failures that start at a specific commit.
- **Cascade**: the cluster shares its builds with another cluster that contains the real error.

Weigh the evidence: failure rate per job, whether it affects only one branch or Kubernetes version, the first-seen date (a new regression?), and whether the same cluster also shows up in other providers (run `cluster <id>` without a preset). A cluster shared across providers points at `test/framework` or `test/e2e` in CAPI.

### 3. Cross-reference with GitHub (use the GitHub MCP)

GitHub searches are the easiest way to blow the context budget: `search_issues` is a semantic search, it always reports a large `total_count` of loosely related issues, and by default it returns full issue bodies and label objects. Follow these rules strictly:

- **Always** pass `fields` and **never** include `body`, `labels`, `reactions` or `user`. Use `["number", "title", "state", "closed_at"]`.
- Set `perPage` explicitly: 30 for the candidate list below, **5** for targeted searches.
- Ignore `total_count`. Only the returned items matter, and results beyond the first 5 are almost never relevant.
- Don't page through results. Don't search once per cluster. Don't call `issue_read` except on a candidate you are about to cite.

**Step 3a: fetch the candidate list with one call.** CAPI flake issues are labeled `kind/flake` (occasionally `kind/failing-test`), and their titles usually contain the error message (e.g. `[e2e] error: resourceVersions never became stable`). Fetch every open or recently closed one in a single call, using qualifiers only:

```
search_issues(owner="kubernetes-sigs", repo="cluster-api",
  query="label:kind/flake,kind/failing-test updated:>YYYY-MM-DD",   # ~6 months ago
  fields=["number","title","state","closed_at"], perPage=30, sort="updated", order="desc")
```

(`label:a,b` means a OR b.) This typically returns 10–30 issues. Match each group against these titles yourself, by error message, test name or spec text. This is usually enough.

- A match with an **open** issue: link it.
- A match with a **closed** issue: this is a possible regression or an incomplete fix. Say so, link the issue and the PR that closed it, and compare the fix with the failure's `Repo commit`.

**Step 3b: targeted searches, only for important groups still unmatched.** At most one or two calls per group, with `perPage=5` and the same `fields`:

- `search_issues` with a plain natural-language query built from the group's search terms (for example `TestReconcileControlPlane Unexpected PendingHookAnnotation`). Do **not** combine `label:`/`is:` qualifiers with free text; that tends to return nothing. Treat results as candidates and only accept those whose title clearly matches.
- `search_pull_requests` with `is:open <test name or error phrase>` to find fixes already in flight.

If nothing matches, report the group as **untracked**. That's a valid result; don't keep searching.

### 4. Deep dive and fix suggestion

For groups with no issue, or where the user asks for a fix:

1. Run `failures <prow-url>` on 1–3 recent builds, taken from **Recent builds** or `cluster <id>`. Note the `Repo commit` and the assertion location (e.g. `reconcile_state_test.go:2049`, `test/framework/machines.go:59`).
2. Read the code **at that commit**, because the local checkout may differ: `git --no-pager show <commit>:<path>`. Fetch the commit first if needed. For release branches, use the matching `release-1.x` branch.
3. Use `log <prow-url> --grep '<test name or error>' -C 20` for surrounding context. For e2e failures, inspect the cluster artifacts under `<build>/artifacts/clusters/...` (resources, controller logs); `gcsweb.k8s.io/gcs/<bucket>/<path>/` gives a browsable listing. The `capo-e2e-analysis` skill describes the artifact layout for CAPO.
4. Propose a fix: a concrete code change with file and line, and the reasoning for why it removes the race or flake. Where possible, verify locally by running the unit test repeatedly, e.g. `go test ./path/... -run '^TestName$' -count=20 -race`. Don't claim a fix works unless you ran it.

### 5. Report

Summarize per problem (not per cluster), most impactful first:

| Problem | Category | Failed builds (jobs / branches) | First → last seen | Issue / PR | Root cause (confidence) | Suggested action |
|---|---|---|---|---|---|---|

Include the triage cluster link(s) and one or two Prow links for each problem.

### 6. Drafting new issues

Only when the user asks. Follow `.github/ISSUE_TEMPLATE/flaking_test.yaml` (or `failing_test.yaml` for consistent failures). Fill in the jobs, tests, since when (first seen), the triage link(s) with cluster ID fragments, Prow links, and the suspected reason. End with `/kind flake` and an `/area ...` label. Show the draft to the user before creating anything.
