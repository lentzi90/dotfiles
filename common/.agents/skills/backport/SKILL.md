# Skill: Backporting a PR to a Release Branch

## Steps

### 1. Fetch latest upstream

```sh
git fetch upstream
```

### 2. Find the commit SHA to cherry-pick

Use the GitHub MCP to inspect the PR. Look for the **actual commit** (not the merge commit).
If the PR was already backported to a newer release branch (e.g., `release-1.12`), list commits
on that branch to find the cherry-pick commit SHA.

```sh
# list_commits owner=metal3-io repo=cluster-api-provider-metal3 sha=release-1.12
```

The commit to cherry-pick is the non-merge commit (i.e., the one authored by a person, not
`metal3-io-bot`). Note the SHA.

### 3. Create a branch from the target release branch

```sh
git checkout -b lentzi90/<topic>-release-<X.Y> upstream/release-<X.Y>
```

### 4. Cherry-pick with `-x` flag

The `-x` flag appends a `(cherry picked from commit ...)` line to the commit message.

```sh
git cherry-pick -x <SHA>
```

### 5. Resolve conflicts

Conflicts typically arise from code that diverged between branches.

After editing conflicting files:

```sh
git add <file>
```

Also check files that merged automatically — they may still reference renamed
symbols from the source branch (e.g., the test file). Building or running
tests/linters is usually enough to catch these issues.

Fix any compilation errors before continuing.

### 6. Complete the cherry-pick

```sh
GIT_EDITOR=true git cherry-pick --continue
```

### 7. Verify

```sh
git log --oneline -5   # confirm commit looks correct
git show --stat HEAD   # confirm the right files changed
make test              # or similar
```
