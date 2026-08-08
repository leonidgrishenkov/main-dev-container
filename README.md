# Dev Container

## Description

Source of the image for development container where most of the tools I use preinstalled.

## CI/CD Workflow

This project uses a **branch-gated CI/CD pipeline** that avoids running heavy jobs where they are not needed. All
workflows are self-contained in this repository under `.github/workflows/`.

### Workflow Triggers

| Trigger                          | Workflow      | What runs                                                                                                                    | Purpose                          |
| -------------------------------- | ------------- | ---------------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| Push to any branch except `main` | `feature.yml` | `hadolint` Dockerfile lint, Trivy config scan, `actionlint`, GitGuardian secret scan                                        | Fast feedback during development |
| PR into `main`                   | `pr.yml`      | Build amd64 image, Trivy scan (HIGH/CRITICAL), SARIF upload, smoke test, Claude code review (on open)                       | Gate — must pass before merge    |
| Push tag `*.*`                   | `release.yml` | Verify tag is on `main`, build multi-arch (`linux/amd64`, `linux/arm64`), push to YC CR, SBOM + SLSA provenance, cosign sign | Release                          |

### Design Goals

- **No heavy jobs on dev branches.** Only lint runs while developers iterate.
- **No duplicate scanning on release.** The image is already scanned during the PR gate. The tag workflow goes straight
  to multi-arch build and push.
- **No external reusable workflows.** All logic is inlined in this repo for full control.
- **Cross-run cache sharing.** PR and release builds share a **registry cache** in YC CR (`cache/devcr`) so layers are
  reused across workflows.


### Security Checks

- **GitGuardian Scan** (part of `feature.yml`) — runs on every push to any branch except `main` to detect leaked
  secrets.
- **Trivy Image Scan** — runs during PR gate with severity `HIGH,CRITICAL` and `ignore-unfixed: true`. Findings are
  uploaded to GitHub Code Scanning alerts.
- **Tag Origin Verification** — the release workflow verifies that the pushed tag points to a commit that is an ancestor
  of `main`, preventing releases from arbitrary branches.
- **Image Signing** — every release image is signed with **cosign** using keyless OIDC via GitHub Actions.

### Claude Code Review

- **`claude-review`** (part of `pr.yml`) — runs once, when a PR into `main` is **opened**, and posts an automated
  code review (top-level + inline comments via `gh pr comment` / inline PR comments) using
  [`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action).
- Authenticates through **OpenRouter** rather than a direct Anthropic API key: the action's `ANTHROPIC_BASE_URL` is
  redirected to `https://openrouter.ai/api`, using `OPENROUTER_API_KEY` as the credential. This is an unofficial but
  working setup (OpenRouter exposes an Anthropic-compatible endpoint) — not a first-class integration, so it can break
  on action/CLI updates.
- Does **not** gate the merge — it's advisory feedback only, separate from the `build-and-scan` job.

### Secrets & Variables

| Name                 | Type     | Source                       | Purpose                                                        |
| -------------------- | -------- | ---------------------------- | -------------------------------------------------------------- |
| `YC_REGISTRY_ID`     | variable | `vars.YC_REGISTRY_ID`        | Yandex Container Registry ID                                   |
| `YC_CR_SA_AUTH_JSON` | secret   | `secrets.YC_CR_SA_AUTH_JSON` | YC service account JSON key for registry login                 |
| `GITHUB_TOKEN`       | secret   | auto-provided                | Authenticated GitHub API requests for `mise` package downloads |
| `OPENROUTER_API_KEY` | secret   | `secrets.OPENROUTER_API_KEY` | OpenRouter token used to authenticate the Claude PR review     |

### Cache Strategy

PR and release builds share a **registry cache** stored in YC CR at `cr.yandex/<id>/github/personal/cache/devcr:latest`.

- **PR build** (`pr.yml`) writes cache after scanning.
- **Release build** (`release.yml`) reads the same cache before building multi-arch, significantly reducing
  redundant layer builds.

This avoids the limitations of GHA cache (`type=gha`), where PR caches are isolated to the merge ref and invisible to
release workflows. release integrity.
