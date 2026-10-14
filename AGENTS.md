# Instructions for Agent

## Git branches

Before making any changes the user asked for, check the current branch (`git branch --show-current`). If it is a default
or long-lived environment branch — `main`, `master`, `prod`, `production`, `stage`, `staging`, `dev`, `develop`, or
similar — do not change it directly. Instead, create a new branch whose name reflects the user's task (short
kebab-case with a `feat/`, `fix/`, `chore/`, etc. prefix) in a separate git worktree, so the main checkout stays on the
default branch untouched. Put worktrees under `./.claude/worktrees/` unless the user explicitly names another location:

```sh
git worktree add -b feat/add-retention-dashboard .claude/worktrees/add-retention-dashboard
```

Then make all changes inside that worktree directory. Git-ignored files are not carried over to a new worktree, so if the
task needs them (e.g. `task ch:*` needs the per-cluster `*.env` files), copy them from the main checkout.

The only exception is when the user explicitly says to make the changes on the current default branch — then work on it
directly.

If the current branch is already a feature branch (including when you are already inside a linked worktree), keep
working on it. Check existing worktrees with `git worktree list` before creating a new one, and reuse a matching one if
it exists. Do not remove a worktree (`git worktree remove`) unless the user asks.

## GitHub

Use the `gh` CLI for all GitHub operations (PRs, issues, releases, reviews). It is more reliable than web scraping and
integrates seamlessly with local git.

### Pull requests

Create a PR with `gh pr create`:
```sh
gh pr create --title "Brief title" --body "$(cat <<'EOF'
## Summary
Bullet points describing the changes.

## Testing
How to verify the changes work.
EOF
)"
```

View PR details, reviews, and checks with `gh pr view <number>`. Add comments with `gh pr comment <number>`.
Merge with `gh pr merge <number> [--squash|--rebase]` (prefer squash for feature branches, rebase for bug fixes
to preserve history).

### Issues and discussions

Create issues with `gh issue create`, search/filter with `gh issue list`, and view details with `gh issue view <number>`.
Use `gh issue close <number>` to close an issue.

### Workflows and checks

Check CI/CD status without leaving the terminal: `gh run list --limit 1` shows the latest workflow run. Use
`gh run view <run-id>` for details, `gh run logs <run-id>` to stream logs.

### General workflow

Always push your branch before creating a PR (`git push -u origin <branch-name>`). Use `gh auth status` to verify
authentication. When a PR needs updates, push new commits to the same branch — GitHub tracks the PR by branch, not
commit hash.
