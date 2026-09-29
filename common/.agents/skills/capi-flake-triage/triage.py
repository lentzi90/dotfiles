#!/usr/bin/env python3
"""Agent-friendly CLI for the Kubernetes k8s-triage failure clusters.

k8s-triage (https://storage.googleapis.com/k8s-triage/index.html) groups CI
failures across all Kubernetes Prow jobs by similar failure text. The UI loads
public JSON files from the `k8s-triage` GCS bucket; this script downloads and
caches the same files, applies the same filters as the UI, and prints compact
summaries that fit in an agent's context window.

Subcommands:
  clusters  List failure clusters matching filters (like the triage UI).
  cluster   Show details for a single cluster ID.
  failures  Print failed junit test cases for a Prow build.
  log       Grep / tail a Prow build's build-log.txt without downloading it all into context.

Only the Python standard library is used.
"""
from __future__ import annotations

import argparse
import gzip
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from collections import defaultdict, deque
from datetime import datetime, timezone

TRIAGE_BASE = "https://storage.googleapis.com/k8s-triage/"
GCS_API = "https://storage.googleapis.com/storage/v1/b/"
GCS_PUBLIC = "https://storage.googleapis.com/"
PROW_VIEW = "https://prow.k8s.io/view/gs/"
USER_AGENT = "k8s-triage-agent-skill"

# Filter presets. Later sources override earlier ones: preset < --url < explicit flags.
PRESETS = {
    # Mirrors the CI signal handbook link in cluster-api docs, with an anchored repo filter
    # (a plain "cluster-api" repo regex also matches provider repos).
    "capi": {
        "job": r".*cluster-api.*(test|e2e)-(mink8s-)*",
        "xjob": r".*-provider-.*",
        "repo": r"^kubernetes-sigs/cluster-api$",
    },
    "capo": {
        "job": r"(test|e2e)",
        "repo": r"^kubernetes-sigs/cluster-api-provider-openstack$",
    },
}
FILTER_NAMES = ["text", "job", "test", "repo", "xtext", "xjob", "xtest", "xrepo"]

ANSI_RE = re.compile(r"(?:\x1b|\ufffd)\[[0-9;]*[A-Za-z]")
KLOG_PREFIX_RE = re.compile(
    r"^(?:[IWEF]\d{4} \d\d:\d\d:\d\d\.\d+\s+\d+\s+\S+:\d+\]\s*|TIME\s+\d+\s+\S+\]\s*)"
)
SIGNAL_RE = re.compile(
    r"error|fail|panic|timed out|timeout|expected|unexpected|not found|unable|cannot|can't|"
    r"could not|couldn't|refused|denied|forbidden|conflict|deadline|killed|oom|data race|"
    r"_test\.go:\d+|Error Trace|Messages:",
    re.I,
)
NOISE_RE = re.compile(
    r"^(?:=== (?:RUN|PAUSE|CONT|NAME)|--- PASS|PASS$|ok\s|Failed$|Expected$|Unexpected error:$|occurred$|"
    r"<[^>]*>:?\s*$|(?:error|cause|errs|err|s):\s*[<\"{\[])"
)
# Highlight lines that are too generic to be useful as a search phrase.
GENERIC_RE = re.compile(
    r"^(?:\[(?:FAILED|PANICKED|TIMEDOUT|INTERRUPTED)\]\s*)?(?:Timed out after|Expected|Unexpected error|"
    r"FAIL\s|--- FAIL|panic: test timed out|#\d+ failed|There is no failure as the matcher passed|"
    r"The function passed to Eventually)",
    re.I,
)
KLOG_INFO_RE = re.compile(r"^I\d{4} \d\d:\d\d:\d\d")
STRONG_SIGNAL_RE = re.compile(r"error|fail|panic", re.I)


# ---------------------------------------------------------------------------
# HTTP + cache helpers
# ---------------------------------------------------------------------------

def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def warn(msg: str) -> None:
    print(f"warning: {msg}", file=sys.stderr)


def http_get(url: str, headers: dict | None = None, timeout: int = 300):
    h = {"User-Agent": USER_AGENT, "Accept-Encoding": "gzip"}
    h.update(headers or {})
    return urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=timeout)


def maybe_gunzip(data: bytes) -> bytes:
    return gzip.decompress(data) if data[:2] == b"\x1f\x8b" else data


def read_body(resp) -> bytes:
    return maybe_gunzip(resp.read())


def cache_dir() -> str:
    d = os.environ.get("K8S_TRIAGE_CACHE") or os.path.join(
        os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "k8s-triage"
    )
    os.makedirs(d, exist_ok=True)
    return d


def fetch_triage_file(name: str, max_age: float, offline: bool) -> bytes:
    """Fetch a file from the k8s-triage bucket, cached on disk and revalidated via ETag."""
    path = os.path.join(cache_dir(), name.replace("/", "_") + ".gz")
    etag_path = path + ".etag"
    have = os.path.exists(path)
    if have and (offline or time.time() - os.path.getmtime(path) < max_age):
        with open(path, "rb") as f:
            return maybe_gunzip(f.read())
    if offline:
        die(f"{name} is not cached and --offline was given")

    headers = {}
    if have and os.path.exists(etag_path):
        with open(etag_path) as f:
            headers["If-None-Match"] = f.read().strip()
    url = TRIAGE_BASE + name
    try:
        print(f"fetching {url} ...", file=sys.stderr)
        with http_get(url, headers) as resp:
            raw = resp.read()
            etag = resp.headers.get("ETag")
    except urllib.error.HTTPError as e:
        if e.code == 304 and have:
            os.utime(path)
            with open(path, "rb") as f:
                return maybe_gunzip(f.read())
        if have:
            warn(f"GET {url} failed with HTTP {e.code}; using stale cache")
            with open(path, "rb") as f:
                return maybe_gunzip(f.read())
        hint = " (no data for that date?)" if name.startswith("history/") else ""
        die(f"GET {url}: HTTP {e.code}{hint}")
    except urllib.error.URLError as e:
        if have:
            warn(f"GET {url} failed ({e.reason}); using stale cache")
            with open(path, "rb") as f:
                return maybe_gunzip(f.read())
        die(f"GET {url}: {e.reason}")

    stored = raw if raw[:2] == b"\x1f\x8b" else gzip.compress(raw)
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(stored)
    os.replace(tmp, path)
    if etag:
        with open(etag_path, "w") as f:
            f.write(etag)
    return maybe_gunzip(raw)


# ---------------------------------------------------------------------------
# Triage data model (mirrors model.js from the triage UI)
# ---------------------------------------------------------------------------

class Triage:
    def __init__(self, data: dict, job_repos: dict):
        b = data["builds"]
        self.jobs = b["jobs"]
        self.job_paths = b["job_paths"]
        cols = b["cols"]
        self.started = cols["started"]
        self.pr = cols.get("pr", [])
        self.result = cols.get("result", [])
        self.clusters = data["clustered"]
        self.job_repos = job_repos
        self.window = (min(self.started), max(self.started)) if self.started else (0, 0)

    def index(self, job: str, number) -> int | None:
        ix = self.jobs.get(job)
        if ix is None:
            return None
        if isinstance(ix, list):
            start, count, base = ix
            n = int(number)
            if n < start or n > start + count:
                return None
            return base + (n - start)
        return ix.get(str(number))

    def job_indices(self, job: str):
        ix = self.jobs.get(job)
        if ix is None:
            return []
        if isinstance(ix, list):
            _, count, base = ix
            return range(base, base + count)
        return ix.values()

    def job_stats(self, job: str, since: float = 0) -> tuple[int, int]:
        """Return (runs, non-successful runs) for a job in the data window."""
        runs = failed = 0
        for i in self.job_indices(job):
            if i >= len(self.started) or self.started[i] < since:
                continue
            runs += 1
            if i < len(self.result) and self.result[i].upper() != "SUCCESS":
                failed += 1
        return runs, failed

    def started_at(self, job: str, number) -> int | None:
        i = self.index(job, number)
        return self.started[i] if i is not None and i < len(self.started) else None

    def repo_for_job(self, job: str) -> str:
        name = job[3:] if job.startswith("pr:") else job
        if name in self.job_repos:
            return self.job_repos[name]
        m = re.search(r"/pr-logs/pull/([^/]+)/", self.job_paths.get(job, ""))
        if not m:
            return ""
        ident = m.group(1)
        if ident.isdigit():
            return "kubernetes/kubernetes"
        if "_" in ident:
            org, repo = ident.split("_", 1)
            return f"{org}/{repo}"
        return f"kubernetes/{ident}"

    def build_path(self, job: str, number) -> str:
        """Return 'bucket/path/to/job/build' for a job build."""
        path = self.job_paths.get(job, "")
        if path.startswith("gs://"):
            path = path[5:]
        if job.startswith("pr:"):
            # job_paths holds a single PR's path; each build has its own PR number.
            i = self.index(job, number)
            pr = self.pr[i] if i is not None and i < len(self.pr) else ""
            m = re.match(r"^(.*/pr-logs/pull/)([^/]+)/[^/]+/([^/]+)$", path)
            if m and pr:
                if pr == "batch":
                    path = f"{m.group(1)}batch/{m.group(3)}"
                else:
                    path = f"{m.group(1)}{m.group(2)}/{pr}/{m.group(3)}"
        return f"{path}/{number}"

    def pr_number(self, job: str, number) -> str:
        i = self.index(job, number)
        return self.pr[i] if i is not None and i < len(self.pr) else ""


def load_triage(date: str | None, cluster_id: str | None, args) -> Triage:
    today = datetime.now(timezone.utc).strftime("%Y%m%d")
    if date:
        d = date.replace("-", "")
        if not re.fullmatch(r"\d{8}", d):
            die(f"invalid --date {date!r}, expected YYYY-MM-DD")
        name = f"history/{d}.json"
        max_age = args.max_age if d >= today else float("inf")
    elif cluster_id:
        name = f"slices/failure_data_{cluster_id[:2]}.json"
        max_age = args.max_age
    else:
        name = "failure_data.json"
        max_age = args.max_age
    data = json.loads(fetch_triage_file(name, max_age, args.offline))
    try:
        repos = json.loads(fetch_triage_file("job_repos.json", max_age, args.offline))
    except SystemExit:
        warn("job_repos.json unavailable; repo filters fall back to PR job paths")
        repos = {}
    return Triage(data, repos)


# ---------------------------------------------------------------------------
# Filtering (mirrors Clusters.refilter in model.js)
# ---------------------------------------------------------------------------

def compile_re(pattern: str | None):
    if not pattern:
        return None
    try:
        return re.compile(pattern, re.I | re.M)
    except re.error:
        return re.compile(re.escape(pattern), re.I | re.M)


def resolve_opts(args) -> dict:
    opts = {n: None for n in FILTER_NAMES}
    opts.update(ci=True, pr=False, sig=[], date=None, fragment=None)
    if getattr(args, "preset", None):
        opts.update(PRESETS[args.preset])
    if getattr(args, "url", None):
        u = urllib.parse.urlparse(args.url)
        qs = dict(urllib.parse.parse_qsl(u.query, keep_blank_values=True))
        for n in FILTER_NAMES:
            if qs.get(n):
                opts[n] = qs[n]
        if qs.get("ci") == "0":
            opts["ci"] = False
        if qs.get("pr") == "1":
            opts["pr"] = True
        if qs.get("sig"):
            opts["sig"] = qs["sig"].split(",")
        opts["date"] = qs.get("date") or None
        opts["fragment"] = u.fragment or None
    for n in FILTER_NAMES:
        v = getattr(args, n, None)
        if v is not None:
            opts[n] = v or None  # an explicit empty string clears a preset/url filter
    if getattr(args, "pr", False):
        opts["pr"] = True
    if getattr(args, "no_ci", False):
        opts["ci"] = False
    if getattr(args, "sig", None):
        opts["sig"] = args.sig
    if getattr(args, "date", None):
        opts["date"] = args.date
    return opts


def filter_clusters(t: Triage, opts: dict, only_id: str | None = None):
    res = {n: compile_re(opts[n]) for n in FILTER_NAMES}
    for c in t.clusters:
        if only_id and c["id"] != only_id:
            continue
        text = c.get("text", "")
        if (res["text"] and not res["text"].search(text)) or (res["xtext"] and res["xtext"].search(text)):
            continue
        if opts["sig"] and c.get("owner") not in opts["sig"]:
            continue
        tests_out = []
        for test in c["tests"]:
            name = test["name"]
            if (res["test"] and not res["test"].search(name)) or (res["xtest"] and res["xtest"].search(name)):
                continue
            jobs_out = []
            for job in test["jobs"]:
                jn = job["name"]
                if (res["job"] and not res["job"].search(jn)) or (res["xjob"] and res["xjob"].search(jn)):
                    continue
                if res["repo"] or res["xrepo"]:
                    repo = t.repo_for_job(jn)
                    if (res["repo"] and not res["repo"].search(repo)) or (res["xrepo"] and res["xrepo"].search(repo)):
                        continue
                if jn.startswith("pr:"):
                    ok = opts["pr"]
                else:
                    ok = opts["ci"] and ":" not in jn
                if ok:
                    jobs_out.append(job)
            if jobs_out:
                tests_out.append({"name": name, "jobs": jobs_out})
        if tests_out:
            yield c, tests_out


# ---------------------------------------------------------------------------
# Text helpers
# ---------------------------------------------------------------------------

def strip_ansi(s: str) -> str:
    return ANSI_RE.sub("", s)


def highlights(text: str, limit: int = 12) -> list[str]:
    """Pick distinct lines that look like actual errors, skipping log noise."""
    out, seen = [], set()
    for line in strip_ansi(text).splitlines():
        s = line.strip()
        if not s or NOISE_RE.match(s) or not SIGNAL_RE.search(s):
            continue
        if KLOG_INFO_RE.match(s) and not STRONG_SIGNAL_RE.search(KLOG_PREFIX_RE.sub("", s)):
            continue
        norm = re.sub(r"\d+", "N", KLOG_PREFIX_RE.sub("", s))[:200]
        if norm in seen:
            continue
        seen.add(norm)
        out.append(s if len(s) <= 400 else s[:400] + " …")
        if len(out) >= limit:
            break
    return out


def truncate(s: str, n: int) -> str:
    if n <= 0 or len(s) <= n:
        return s
    head = int(n * 0.6)
    return s[:head] + f"\n… [{len(s) - n} chars omitted] …\n" + s[-(n - head):]


def summary_line(hl: list[str]) -> str:
    """The most specific highlight: the first one that is not a generic assertion wrapper."""
    for h in hl:
        if not GENERIC_RE.match(KLOG_PREFIX_RE.sub("", h)):
            return h
    return hl[0] if hl else ""


def test_func(name: str) -> str:
    """Collapse a triage test name into a stable identifier for grouping/searching."""
    m = re.match(r"^(\S+) (Test\w+)", name)  # go test: "<pkg> TestFoo/sub"
    if m:
        # TestMain failures are per-package setup failures; keep the package.
        return name if m.group(2) == "TestMain" else m.group(2)
    m = re.match(r"^\S+ \[It\] (.*)$", name)  # ginkgo: "<suite> [It] <spec>"
    if m:
        return m.group(1)
    return name


def error_phrases(hl: list[str], limit: int = 2) -> list[str]:
    """Short digit-free phrases from the most specific highlights, suitable for GitHub search."""
    out = []
    for h in hl:
        s = KLOG_PREFIX_RE.sub("", h)
        m = re.search(r'err="((?:[^"\\]|\\.)*)"', s)
        if m:
            s = m.group(1).replace('\\"', '"')
        s = re.sub(r"\[(FAILED|PANICKED|TIMEDOUT|INTERRUPTED)\]", "", s).strip()
        if GENERIC_RE.match(s):
            continue
        words = [w for w in re.split(r"\s+", s) if w and not re.search(r"\d", w) and len(w) < 60]
        if len(words) < 2 or re.fullmatch(r"[\w/.]+_test\.go:\d+:?", s) or s.startswith(("Error Trace", "--- FAIL")):
            continue
        phrase = " ".join(words[:12]).strip(" :/,")
        if phrase not in out:
            out.append(phrase)
        if len(out) >= limit:
            break
    return out


def fmt_ts(ts) -> str:
    if not ts:
        return "?"
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d %H:%MZ")


def triage_link(opts: dict, cluster_id: str | None = None) -> str:
    params = [(n, opts[n]) for n in FILTER_NAMES if opts.get(n)]
    if opts.get("date"):
        params.insert(0, ("date", opts["date"]))
    if opts.get("pr"):
        params.append(("pr", "1"))
    if not opts.get("ci"):
        params.append(("ci", "0"))
    if opts.get("sig"):
        params.append(("sig", ",".join(opts["sig"])))
    q = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
    return TRIAGE_BASE + "index.html" + (f"?{q}" if q else "") + (f"#{cluster_id}" if cluster_id else "")


def build_links(t: Triage, job: str, number) -> dict:
    path = t.build_path(job, number)
    return {
        "prow": PROW_VIEW + path,
        "gcs": "gs://" + path,
        "build_log": GCS_PUBLIC + path + "/build-log.txt",
    }


# ---------------------------------------------------------------------------
# Summaries
# ---------------------------------------------------------------------------

def summarize(t: Triage, c: dict, tests: list, opts: dict, since: float, n_links: int, text_chars: int,
              max_hl: int, full: bool = False) -> dict | None:
    day_cut = t.window[1] - 86400
    hits = day_hits = 0
    first = last = None
    job_builds: dict[str, set] = defaultdict(set)
    test_hits: dict[str, list[int]] = {}
    builds: list[tuple] = []
    for test in tests:
        th = td = 0
        for job in test["jobs"]:
            for b in job["builds"]:
                ts = t.started_at(job["name"], b)
                if since and (ts is None or ts < since):
                    continue
                hits += 1
                th += 1
                job_builds[job["name"]].add(str(b))
                builds.append((ts or 0, job["name"], str(b), test["name"]))
                if ts:
                    first = ts if first is None else min(first, ts)
                    last = ts if last is None else max(last, ts)
                    if ts > day_cut:
                        day_hits += 1
                        td += 1
        if th:
            test_hits[test["name"]] = [th, td]
    if not hits:
        return None

    jobs = []
    for jn, bs in sorted(job_builds.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        runs, failed = t.job_stats(jn, since)
        jobs.append({
            "job": jn,
            "cluster_failures": len(bs),
            "runs": runs,
            "job_failures": failed,
            "rate": round(len(bs) / runs, 3) if runs else None,
        })

    seen, recent = set(), []
    for ts, jn, b, tn in sorted(builds, reverse=True):
        if (jn, b) in seen:
            continue
        seen.add((jn, b))
        entry = {"job": jn, "build": b, "started": fmt_ts(ts), "test": tn}
        pr = t.pr_number(jn, b)
        if pr:
            entry["pr"] = pr
        entry.update(build_links(t, jn, b))
        recent.append(entry)
        if not full and len(recent) >= n_links:
            break

    text = strip_ansi(c.get("text", ""))
    hl = highlights(text, max_hl)
    funcs = sorted({test_func(n) for n in test_hits})
    terms = funcs[:5] + error_phrases(hl)

    out = {
        "id": c["id"],
        "hits": hits,
        "hits_24h": day_hits,
        "failed_builds": sum(len(v) for v in job_builds.values()),
        "first_seen": fmt_ts(first),
        "last_seen": fmt_ts(last),
        "_last": last or 0,
        "_builds": {(jn, b) for jn, bs in job_builds.items() for b in bs},
        "owner": c.get("owner") or "",
        "triage_url": triage_link(opts, c["id"]),
        "tests": [{"name": n, "hits": h, "hits_24h": d}
                  for n, (h, d) in sorted(test_hits.items(), key=lambda kv: -kv[1][0])],
        "jobs": jobs,
        "recent_builds": recent,
        "search_terms": terms,
        "summary": summary_line(hl),
        "highlights": hl,
        "text": truncate(text, text_chars),
    }
    if full:
        out["key"] = strip_ansi(c.get("key", ""))
    return out


def group_by_test(summaries: list[dict]) -> list[dict]:
    groups: dict[str, dict] = {}
    for s in summaries:
        for tst in s["tests"]:
            k = test_func(tst["name"])
            g = groups.setdefault(k, {"test": k, "hits": 0, "hits_24h": 0, "clusters": {}, "jobs": set(),
                                      "first_seen": s["first_seen"], "last_seen": s["last_seen"],
                                      "_last": 0, "names": set()})
            g["hits"] += tst["hits"]
            g["hits_24h"] += tst["hits_24h"]
            c = g["clusters"].setdefault(s["id"], {"id": s["id"], "hits": 0, "summary": s["summary"]})
            c["hits"] += tst["hits"]
            g["jobs"].update(j["job"] for j in s["jobs"])
            g["names"].add(tst["name"])
            g["first_seen"] = min(g["first_seen"], s["first_seen"])
            g["last_seen"] = max(g["last_seen"], s["last_seen"])
            g["_last"] = max(g["_last"], s["_last"])
    out = []
    for g in groups.values():
        g["clusters"] = sorted(g["clusters"].values(), key=lambda c: -c["hits"])
        g["jobs"] = sorted(g["jobs"])
        g["names"] = sorted(g["names"])
        out.append(g)
    return out


def add_related(summaries: list[dict]) -> None:
    """Link clusters that failed in the same builds (e.g. a BeforeSuite abort and its root cause)."""
    by_build: dict[tuple, list[str]] = defaultdict(list)
    for s in summaries:
        for b in s["_builds"]:
            by_build[b].append(s["id"])
    for s in summaries:
        shared: dict[str, int] = defaultdict(int)
        for b in s["_builds"]:
            for other in by_build[b]:
                if other != s["id"]:
                    shared[other] += 1
        s["related"] = [{"id": k, "shared_builds": v}
                        for k, v in sorted(shared.items(), key=lambda kv: -kv[1])[:5]]


def sort_items(items: list[dict], how: str) -> list[dict]:
    keys = {
        "total": lambda s: (-s["hits"], -s["_last"]),
        "builds": lambda s: (-len(s.get("_builds") or s.get("clusters")), -s["hits"]),
        "day": lambda s: (-s["hits_24h"], -s["hits"]),
        "last": lambda s: (-s["_last"], -s["hits"]),
    }
    return sorted(items, key=keys[how])


def clean(obj):
    if isinstance(obj, dict):
        return {k: clean(v) for k, v in obj.items() if not k.startswith("_")}
    if isinstance(obj, list):
        return [clean(v) for v in obj]
    return obj


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def md_cluster(i: int | None, s: dict, max_tests: int = 5, max_jobs: int = 8) -> str:
    L = []
    title = (f"`{s['id']}` — {s['hits']} hits in {s['failed_builds']} builds ({s['hits_24h']} hits in last 24h), "
             f"{len(s['jobs'])} jobs, {len(s['tests'])} tests")
    L.append(f"### {i}. {title}" if i is not None else f"## Cluster {title}")
    L.append(f"- Seen: {s['first_seen']} → {s['last_seen']}" + (f" · owner: {s['owner']}" if s["owner"] else ""))
    L.append(f"- Triage: {s['triage_url']}")
    L.append("- Tests:")
    for tst in s["tests"][:max_tests]:
        L.append(f"  - ({tst['hits']}) {tst['name']}")
    if len(s["tests"]) > max_tests:
        L.append(f"  - … {len(s['tests']) - max_tests} more")
    L.append("- Jobs (cluster failures / runs in window, job failures of any kind):")
    for j in s["jobs"][:max_jobs]:
        rate = f"{j['rate'] * 100:.1f}%" if j["rate"] is not None else "?"
        L.append(f"  - {j['job']}: {j['cluster_failures']}/{j['runs']} ({rate}); job failed {j['job_failures']}/{j['runs']}")
    if len(s["jobs"]) > max_jobs:
        L.append(f"  - … {len(s['jobs']) - max_jobs} more")
    L.append("- Recent builds:")
    for b in s["recent_builds"]:
        pr = f" PR #{b['pr']}" if b.get("pr") and b["pr"] != "batch" else ""
        L.append(f"  - {b['started']} {b['job']}{pr}: {b['prow']}")
    if s["search_terms"]:
        L.append("- Search terms: " + " | ".join(f"`{x}`" for x in s["search_terms"]))
    if s.get("related"):
        L.append("- Shares failed builds with: " + ", ".join(f"`{r['id']}` ({r['shared_builds']})" for r in s["related"]))
    if s["highlights"]:
        L.append("- Highlights:")
        L.append("```text")
        L.extend(s["highlights"])
        L.append("```")
    if s.get("text"):
        L.append("- Sample failure text:")
        L.append("```text")
        L.append(s["text"].rstrip())
        L.append("```")
    if s.get("key"):
        L.append("- Normalized key (what triage clusters on):")
        L.append("```text")
        L.append(s["key"].rstrip())
        L.append("```")
    return "\n".join(L)


def md_group(i: int, g: dict) -> str:
    L = [f"### {i}. {g['test']} — {g['hits']} hits ({g['hits_24h']} in last 24h) across {len(g['clusters'])} clusters",
         f"- Seen: {g['first_seen']} → {g['last_seen']}",
         f"- Jobs: {', '.join(g['jobs'])}"]
    if len(g["names"]) > 1:
        L.append("- Full test names:")
        L.extend(f"  - {n}" for n in g["names"][:8])
    L.append("- Clusters:")
    for c in g["clusters"]:
        L.append(f"  - `{c['id']}` ({c['hits']}): {c['summary'][:200]}")
    return "\n".join(L)


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

def cmd_clusters(args) -> None:
    opts = resolve_opts(args)
    t = load_triage(opts["date"], None, args)
    since = t.window[1] - args.days * 86400 if args.days else 0
    summaries = []
    for c, tests in filter_clusters(t, opts):
        s = summarize(t, c, tests, opts, since, args.links, args.text_chars, args.highlights)
        if s and s["hits"] >= args.min_hits:
            summaries.append(s)
    add_related(summaries)

    header = {
        "window": f"{fmt_ts(t.window[0])} → {fmt_ts(t.window[1])}",
        "counted_since": fmt_ts(since) if since else None,
        "filters": {k: opts[k] for k in FILTER_NAMES + ["ci", "pr", "sig", "date"] if opts.get(k)},
        "triage_url": triage_link(opts),
        "clusters": len(summaries),
        "hits": sum(s["hits"] for s in summaries),
    }

    if args.group_by == "test":
        items = sort_items(group_by_test(summaries), args.sort)[: args.limit]
        if args.format == "json":
            print(json.dumps(clean({**header, "tests": items}), indent=1))
            return
        print(md_header(header))
        for i, g in enumerate(items, 1):
            print(md_group(i, g) + "\n")
        return

    items = sort_items(summaries, args.sort)[: args.limit]
    if args.format == "json":
        print(json.dumps(clean({**header, "items": items}), indent=1))
        return
    print(md_header(header))
    for i, s in enumerate(items, 1):
        print(md_cluster(i, s) + "\n")
    if len(summaries) > len(items):
        print(f"_{len(summaries) - len(items)} more clusters not shown (use --limit)._")


def md_header(h: dict) -> str:
    L = ["# k8s-triage failure clusters",
         f"- Data window: {h['window']}" + (f" (counting since {h['counted_since']})" if h["counted_since"] else ""),
         f"- Filters: " + ", ".join(f"{k}=`{v}`" for k, v in h["filters"].items()),
         f"- Triage UI: {h['triage_url']}",
         f"- Matched: {h['clusters']} clusters, {h['hits']} hits", ""]
    return "\n".join(L)


def cmd_cluster(args) -> None:
    opts = resolve_opts(args)
    cid = args.id
    if not re.fullmatch(r"[0-9a-f]{20}", cid):
        die(f"invalid cluster id {cid!r} (expected 20 hex chars)")
    t = load_triage(opts["date"], cid, args)
    found = list(filter_clusters(t, opts, cid))
    if not found:
        if any(c["id"] == cid for c in t.clusters):
            die(f"cluster {cid} exists but no builds match the given filters")
        die(f"cluster {cid} not found" + (" for that date" if opts["date"] else " in current data (try --date)"))
    c, tests = found[0]
    s = summarize(t, c, tests, opts, 0, 0, args.text_chars, args.highlights, full=True)
    s["recent_builds"] = s["recent_builds"][: args.max_builds]
    if not args.show_key:
        s.pop("key", None)
    if args.format == "json":
        print(json.dumps(clean(s), indent=1))
        return
    print(md_cluster(None, s, max_tests=50, max_jobs=50))


def parse_build_ref(ref: str) -> tuple[str, str]:
    r = ref.strip()
    for p in ("https://prow.k8s.io/view/gs/", "https://prow.k8s.io/view/gcs/", "https://gcsweb.k8s.io/gcs/",
              "https://storage.googleapis.com/", "https://console.cloud.google.com/storage/browser/", "gs://"):
        if r.startswith(p):
            r = r[len(p):]
            break
    r = r.split("?")[0].split("#")[0].strip("/")
    if r.endswith("build-log.txt"):
        r = r.rsplit("/", 1)[0]
    bucket, _, path = r.partition("/")
    if not path:
        die(f"cannot parse build reference {ref!r}; pass a Prow, gcsweb, storage.googleapis.com or gs:// URL")
    return bucket, path


def gcs_url(bucket: str, name: str) -> str:
    return GCS_PUBLIC + bucket + "/" + urllib.parse.quote(name)


def gcs_list(bucket: str, prefix: str, glob: str) -> list[dict]:
    items, token = [], None
    while True:
        q = {"prefix": prefix, "matchGlob": glob, "fields": "items(name,size),nextPageToken"}
        if token:
            q["pageToken"] = token
        with http_get(GCS_API + bucket + "/o?" + urllib.parse.urlencode(q)) as resp:
            d = json.loads(read_body(resp))
        items += d.get("items", [])
        token = d.get("nextPageToken")
        if not token:
            return items


def gcs_json(bucket: str, name: str) -> dict | None:
    try:
        with http_get(gcs_url(bucket, name)) as resp:
            return json.loads(read_body(resp))
    except (urllib.error.HTTPError, ValueError):
        return None


def cmd_failures(args) -> None:
    bucket, path = parse_build_ref(args.build)
    print(f"# Failures for gs://{bucket}/{path}")
    print(f"- Prow: {PROW_VIEW}{bucket}/{path}")
    print(f"- Build log: {gcs_url(bucket, path + '/build-log.txt')}")
    started = gcs_json(bucket, path + "/started.json") or {}
    finished = gcs_json(bucket, path + "/finished.json") or {}
    if finished:
        print(f"- Result: {finished.get('result', '?')} (finished {fmt_ts(finished.get('timestamp'))})")
    repos = started.get("repos") or {}
    for repo, ref in repos.items():
        print(f"- Repo: {repo} @ {ref}")
    if started.get("repo-commit"):
        print(f"- Repo commit: {started['repo-commit']}")
    if started.get("pull"):
        print(f"- Pull: {started['pull']}")

    files = gcs_list(bucket, path + "/", "**/junit*.xml")
    if not files:
        print("\nNo junit*.xml files found; use the `log` subcommand to inspect build-log.txt.")
        return
    test_re = compile_re(args.test)
    shown = 0
    print(f"- junit files: {len(files)}")
    for f in files:
        try:
            with http_get(gcs_url(bucket, f["name"])) as resp:
                root = ET.fromstring(read_body(resp))
        except (urllib.error.HTTPError, ET.ParseError) as e:
            warn(f"skipping {f['name']}: {e}")
            continue
        cases = []
        for tc in root.iter("testcase"):
            fail = tc.find("failure")
            if fail is None:
                fail = tc.find("error")
            if fail is None:
                continue
            name = " ".join(x for x in (tc.get("classname"), tc.get("name")) if x)
            if test_re and not test_re.search(name):
                continue
            cases.append((name, tc, fail))
        rel = f["name"][len(path) + 1:]
        if not cases:
            continue
        print(f"\n## {rel} — {len(cases)} failed test cases")
        for name, tc, fail in cases:
            if shown >= args.max_cases:
                print(f"\n_Stopped after {args.max_cases} test cases (use --max-cases or --test)._")
                return
            shown += 1
            body = strip_ansi((fail.text or "").strip())
            msg = strip_ansi(fail.get("message") or "").strip()
            print(f"\n### {name}" + (f" ({tc.get('time')}s)" if tc.get("time") else ""))
            if msg and msg not in ("Failed",):
                print("Message:\n```text\n" + truncate(msg, 1500) + "\n```")
            hl = highlights(body, args.highlights)
            if hl:
                print("Highlights:\n```text\n" + "\n".join(hl) + "\n```")
            if args.max_chars:
                print("Output:\n```text\n" + truncate(body, args.max_chars) + "\n```")
            if args.system_err:
                se = tc.find("system-err")
                if se is not None and se.text:
                    print("system-err (tail):\n```text\n" + strip_ansi(se.text.strip())[-args.system_err:] + "\n```")
    if not shown:
        print("\nNo failed test cases in junit files" + (" matching --test" if test_re else "")
              + "; the job may have failed outside of tests. Use the `log` subcommand.")


def cmd_log(args) -> None:
    bucket, path = parse_build_ref(args.build)
    name = path + "/" + args.file
    url = gcs_url(bucket, name)
    try:
        resp = http_get(url)
    except urllib.error.HTTPError as e:
        die(f"GET {url}: HTTP {e.code}")
    stream = gzip.GzipFile(fileobj=resp) if resp.headers.get("Content-Encoding") == "gzip" else resp
    grep = compile_re(args.grep)
    max_line = args.max_line

    def fmt(n: int, line: str, sep: str) -> str:
        line = strip_ansi(line)
        return f"{n}{sep}{line if len(line) <= max_line else line[:max_line] + ' …'}"

    if not grep:
        tail = deque(maxlen=args.tail)
        for n, raw in enumerate(stream, 1):
            tail.append((n, raw.decode("utf-8", "replace").rstrip("\n")))
        for n, line in tail:
            print(fmt(n, line, ":"))
        return

    before = deque(maxlen=args.context)
    after = matches = 0
    last_printed = 0
    for n, raw in enumerate(stream, 1):
        line = raw.decode("utf-8", "replace").rstrip("\n")
        if grep.search(line):
            matches += 1
            if matches > args.max_matches:
                print(f"… stopped after {args.max_matches} matches (use --max-matches)")
                break
            if last_printed and before and before[0][0] > last_printed + 1:
                print("--")
            for bn, bl in before:
                print(fmt(bn, bl, "-"))
            before.clear()
            print(fmt(n, line, ":"))
            last_printed = n
            after = args.context
        elif after > 0:
            print(fmt(n, line, "-"))
            last_printed = n
            after -= 1
        else:
            before.append((n, line))
    if matches == 0:
        print(f"no lines matched {args.grep!r} in {url}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def add_data_args(p) -> None:
    p.add_argument("--offline", action="store_true", help="only use cached data")
    p.add_argument("--max-age", type=float, default=1800,
                   help="seconds before cached data is revalidated with the server (default 1800)")
    p.add_argument("--format", choices=["md", "json"], default="md")


def add_filter_args(p) -> None:
    p.add_argument("--preset", choices=sorted(PRESETS), help="filter preset")
    p.add_argument("--url", help="k8s-triage UI URL to copy filters/date (and #cluster) from")
    p.add_argument("--date", help="use the daily snapshot for YYYY-MM-DD instead of the latest data")
    for n in FILTER_NAMES:
        kind = "exclude" if n.startswith("x") else "include"
        field = n[1:] if n.startswith("x") else n
        p.add_argument(f"--{n}", help=f"{kind} regex on {'failure text' if field == 'text' else field}")
    p.add_argument("--pr", action="store_true", help="include presubmit (PR) jobs")
    p.add_argument("--no-ci", action="store_true", help="exclude CI (periodic/postsubmit) jobs")
    p.add_argument("--sig", action="append", help="only clusters owned by this SIG (repeatable)")


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("clusters", help="list failure clusters matching filters")
    add_filter_args(p)
    add_data_args(p)
    p.add_argument("--sort", choices=["total", "builds", "day", "last"], default="total",
                   help="total hits (UI default), unique failed builds, hits in the last 24h, or most recently seen")
    p.add_argument("--group-by", choices=["cluster", "test"], default="cluster",
                   help="'test' merges clusters that hit the same test (flakes often split across clusters)")
    p.add_argument("--days", type=float, help="only count failures from the last N days of the window")
    p.add_argument("--min-hits", type=int, default=1)
    p.add_argument("--limit", type=int, default=25)
    p.add_argument("--links", type=int, default=3, help="recent build links per cluster")
    p.add_argument("--text-chars", type=int, default=600, help="max chars of sample failure text (0 = all)")
    p.add_argument("--highlights", type=int, default=8, help="max highlighted error lines per cluster")
    p.set_defaults(func=cmd_clusters)

    p = sub.add_parser("cluster", help="show one cluster in detail (all tests, jobs, builds)")
    p.add_argument("id", help="20-hex-char cluster id (the #fragment in triage URLs)")
    add_filter_args(p)
    add_data_args(p)
    p.add_argument("--max-builds", type=int, default=30)
    p.add_argument("--text-chars", type=int, default=4000)
    p.add_argument("--highlights", type=int, default=20)
    p.add_argument("--show-key", action="store_true", help="also print the normalized clustering key")
    p.set_defaults(func=cmd_cluster)

    p = sub.add_parser("failures", help="print failed junit test cases of a Prow build")
    p.add_argument("build", help="Prow / gcsweb / storage.googleapis.com / gs:// URL of a build")
    p.add_argument("--test", help="only test cases whose 'classname name' matches this regex")
    p.add_argument("--max-cases", type=int, default=15)
    p.add_argument("--max-chars", type=int, default=2500, help="max chars of failure output per case (0 = none)")
    p.add_argument("--highlights", type=int, default=15)
    p.add_argument("--system-err", type=int, default=0, metavar="N",
                   help="also print the last N chars of <system-err> (ginkgo spec timeline)")
    p.set_defaults(func=cmd_failures)

    p = sub.add_parser("log", help="grep or tail a build's build-log.txt (streamed)")
    p.add_argument("build", help="Prow / gcsweb / storage.googleapis.com / gs:// URL of a build")
    p.add_argument("--file", default="build-log.txt", help="file relative to the build dir")
    p.add_argument("--grep", help="regex (case-insensitive) to search for")
    p.add_argument("-C", "--context", type=int, default=3)
    p.add_argument("--max-matches", type=int, default=40)
    p.add_argument("--tail", type=int, default=150, help="lines to show when --grep is not given")
    p.add_argument("--max-line", type=int, default=600, help="truncate printed lines to N chars")
    p.set_defaults(func=cmd_log)

    args = ap.parse_args(argv)
    try:
        args.func(args)
    except BrokenPipeError:
        pass


if __name__ == "__main__":
    main()
