# Dev Container

## Description

Source of the image for development container where most of the tools I use preinstalled.

## Image Layout

The `Dockerfile` has two stages on the same digest-pinned Debian base:

- **`go-builder`** cross-compiles the Go CLIs (`direnv`, `lazygit`, `fzf`, `shfmt`, `glow`, `task`) with a pinned Go
  toolchain. It runs on the build host's native platform and targets `$TARGETARCH`, so the arm64 release does not
  compile Go under QEMU.
- **The final stage** installs the tools from `mise.toml`, copies in only the Go binaries, and stows the dotfiles.

Keeping the Go toolchain out of the final image is a security property, not just a size optimisation: its stdlib, test
fixtures and build tools never ship, so they cannot carry vulnerabilities into the image or into the Trivy gate.

### Build Arguments

| Argument       | Default | Purpose                                                                                                                                                                                                 |
| -------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GO_VERSION`   | pinned  | Go toolchain for the `go-builder` stage. The single source of truth for Go; it is deliberately not in `mise.toml`.                                                                                      |
| `DOTFILES_REF` | `main`  | Branch, tag or full 40-char commit SHA of the [dotfiles](https://github.com/leonidgrishenkov/dotfiles). The default follows `main`, so two builds of one commit can differ; pin a SHA to reproduce one. |
| `MISE_VERSION` | pinned  | mise release installed in both stages.                                                                                                                                                                  |
| `APT_REFRESH`  | `local` | Cache key for the apt layer. CI passes the ISO week, so OS packages are re-fetched (with Debian security fixes) at least weekly instead of being reused from the registry cache.                        |

The dotfiles commit an image was built from is printed in the build log and kept in `/etc/devcr-dotfiles-sha`.
Release images also carry it as the `io.github.leonidgrishenkov.devcr.dotfiles.revision` label.

### Building and Checking Locally

```bash
GITHUB_TOKEN=$(gh auth token) docker buildx build \
  --secret id=github_token,env=GITHUB_TOKEN --load -t devcr:local .

# Same gate as CI
trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
  --ignorefile .trivyignore.yaml devcr:local

# Smoke test, mounted rather than baked into the image
docker run --rm -v "$PWD/scripts/smoke.sh:/opt/smoke.sh:ro" devcr:local bash /opt/smoke.sh
```

## CI/CD Workflow

This project uses a **branch-gated CI/CD pipeline** that avoids running heavy jobs where they are not needed. All
workflows are self-contained in this repository under `.github/workflows/`.

### Workflow Triggers

| Trigger                          | Workflow           | What runs                                                                                                                                                  | Purpose                          |
| -------------------------------- | ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| Push to any branch except `main` | `feature.yml`      | `hadolint` Dockerfile lint, Trivy config scan, `actionlint`, GitGuardian secret scan                                                                       | Fast feedback during development |
| PR into `main`                   | `pr.yml`           | Build amd64 image, Trivy scan (HIGH/CRITICAL, `.trivyignore.yaml`), SARIF upload, `scripts/smoke.sh`, Claude code review (on open)                         | Gate — must pass before merge    |
| Push tag `*.*`                   | `release.yml`      | Verify tag is on `main`, pin the dotfiles commit, build multi-arch (`linux/amd64`, `linux/arm64`), push to ECR Public, SBOM + SLSA provenance, cosign sign | Release                          |
| Weekly (Mon 06:00 UTC) or manual | `mise-updates.yml` | `mise outdated --bump`, rewrite the changed pins in `mise.toml`, open/update one PR                                                                        | Keep `mise.toml` pins current    |

### Design Goals

- **No heavy jobs on dev branches.** Only lint runs while developers iterate.
- **No duplicate scanning on release.** The image is already scanned during the PR gate. The tag workflow goes straight
  to multi-arch build and push.
- **No external reusable workflows.** All logic is inlined in this repo for full control.
- **Cross-run cache sharing.** PR and release builds share a **registry cache** in ECR Public (`devcr:buildcache`) so
  layers are reused across workflows.


### Security Checks

- **GitGuardian Scan** (part of `feature.yml`) — runs on every push to any branch except `main` to detect leaked
  secrets.
- **Trivy Image Scan** — runs during PR gate with severity `HIGH,CRITICAL` and `ignore-unfixed: true`, using the
  suppressions in `.trivyignore.yaml` (see [Vulnerability Policy](#vulnerability-policy)). Findings are uploaded to
  GitHub Code Scanning alerts.
- **Smoke Test** — `scripts/smoke.sh` asserts that every `mise.toml` tool and Go CLI runs, the dotfiles are stowed,
  nvim plugins are restored and start cleanly, the user and shell are right, and the Go toolchain is absent.
- **Tag Origin Verification** — the release workflow verifies that the pushed tag points to a commit that is an ancestor
  of `main`, preventing releases from arbitrary branches.
- **Image Signing** — every release image is signed with **cosign** using keyless OIDC via GitHub Actions.

### Vulnerability Policy

The Trivy gate fails on any fixable `HIGH` or `CRITICAL` finding. Findings fall into two buckets:

- **Fixed, never suppressed:** the base OS packages, `curl`, `git`, `gnupg`, OpenSSL, the Go stdlib, anything in a
  TLS/crypto path, and anything that parses untrusted network input. The fix is to bump the package, the toolchain
  (`GO_VERSION`) or the tool. If no fix exists, that blocks the release.
- **Suppressed with justification:** dev tools driven interactively by the single trusted user of the container, and
  their vendored dependencies, when the finding is not exploitable here and no upstream release fixes it (or the fix
  belongs to another repo, e.g. `pi-extensions`).

Every suppression in `.trivyignore.yaml` is scoped with `paths` (so the same CVE in an OS package or another tool still
fails the gate), carries a `statement` saying why it is not exploitable here, and has an `expired_at` date about six
months out. Expiry is intentional pressure: when an entry expires the finding reappears and the gate fails, so the
decision is revisited deliberately rather than left to rot. Before extending a date, check whether an upstream release
now makes the entry unnecessary.

Use Trivy's key `expired_at`; an unknown key such as `expired-at` is silently ignored and the entry never expires. In
CI, `limit-severities-for-sarif: true` keeps the gate at `HIGH,CRITICAL`; without it `trivy-action` drops the severity
filter whenever the output format is SARIF.

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

| Name                 | Type     | Source                       | Purpose                                                                                     |
| -------------------- | -------- | ---------------------------- | ------------------------------------------------------------------------------------------- |
| `AWS_ROLE_ARN`       | variable | `vars.AWS_ROLE_ARN`          | IAM role assumed via GitHub OIDC to push to `public.ecr.aws/a8c0b5z6/devcr`                 |
| `GITHUB_TOKEN`       | secret   | auto-provided                | Authenticated GitHub API requests for `mise` package downloads; opens the `mise-updates` PR |
| `OPENROUTER_API_KEY` | secret   | `secrets.OPENROUTER_API_KEY` | OpenRouter token used to authenticate the Claude PR review                                  |

The `AWS_ROLE_ARN` role needs ECR Public push permissions (e.g. the `AmazonElasticContainerRegistryPublicPowerUser`
managed policy, which includes `sts:GetServiceBearerToken`) and a trust policy for the GitHub OIDC provider
(`token.actions.githubusercontent.com`) that allows the subjects
`repo:leonidgrishenkov/main-dev-container:pull_request` (`pr.yml`) and
`repo:leonidgrishenkov/main-dev-container:ref:refs/tags/*` (`release.yml`).

`mise-updates.yml` deliberately uses the default `GITHUB_TOKEN` instead of a PAT, which has two consequences:

- The repository setting **Allow GitHub Actions to create and approve pull requests** must be enabled.
- GitHub does not start workflows for events created with that token, so `pr.yml` does not run on the update PR by
  itself. **Close and reopen the PR** to run the gate; the PR body says so too.

### Cache Strategy

PR and release builds share a **registry cache** stored in ECR Public at `public.ecr.aws/a8c0b5z6/devcr:buildcache`.

- **PR build** (`pr.yml`) writes cache after scanning.
- **Release build** (`release.yml`) reads the same cache before building multi-arch, significantly reducing
  redundant layer builds.

This avoids the limitations of GHA cache (`type=gha`), where PR caches are isolated to the merge ref and invisible to
release workflows.

Cached layers never pick up Debian security updates on their own, because nothing in the apt layer's cache key changes
when Debian ships them. Both workflows therefore pass the ISO week as `APT_REFRESH`, which rebuilds the apt layer and
everything after it once a week; within a week, a release reuses the layers its PR scanned.

The release build passes the resolved dotfiles commit as `DOTFILES_REF`, so its dotfiles layer is rebuilt for that
exact commit rather than reused from whatever `main` was when the PR cache was written.
