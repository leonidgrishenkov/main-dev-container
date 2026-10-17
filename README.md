# Dev Container

## About

A Docker development container image with pre-installed tools and utilities, featuring automated CI/CD pipelines, security scanning (Trivy, GitGuardian), multi-architecture builds, and image signing.

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

| Trigger                          | Workflow           | What runs                                                                                                                                                   | Purpose                          |
| -------------------------------- | ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| Push to any branch except `main` | `feature.yml`      | `hadolint` Dockerfile lint, Trivy config scan, `actionlint`, GitGuardian secret scan                                                                        | Fast feedback during development |
| PR into `main`                   | `pr.yml`           | Build amd64 image, Trivy scan (HIGH/CRITICAL, `.trivyignore.yaml`), SARIF upload, `scripts/smoke.sh`                                                        | Gate — must pass before merge    |
| Push tag `*.*`                   | `release.yml`      | Verify tag is on `main`, pin the dotfiles commit, build multi-arch (`linux/amd64`, `linux/arm64`), push to private ECR, SBOM + SLSA provenance, cosign sign | Release                          |

Dependency update PRs come from Renovate, not from a workflow here (see [Dependency Updates](#dependency-updates)).

### Design Goals

- **No heavy jobs on dev branches.** Only lint runs while developers iterate.
- **No duplicate scanning on release.** The image is already scanned during the PR gate. The tag workflow goes straight
  to multi-arch build and push.
- **No external reusable workflows.** All logic is inlined in this repo for full control.
- **Cross-run cache sharing.** PR and release builds share a **registry cache** in ECR (`buildcache/devcr`) so layers
  are reused across workflows.


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
- **Immutable Release Tags** — published `devcr` tags can't be overwritten. A failed release can't be re-run as is
  (delete its tags first), and a second version tag on an already released commit fails on the commit-SHA tag.

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

### Dependency Updates

[Renovate](https://docs.renovatebot.com/) (the hosted Mend Renovate GitHub App, configured in `.github/renovate.json5`)
opens update PRs on Monday mornings (UTC) and keeps a **Dependency Dashboard** issue that lists everything it tracks:

| What                                                              | Where                                           | PR       |
| ----------------------------------------------------------------- | ----------------------------------------------- | -------- |
| Debian base image: newer dated `trixie-*-slim` tag and its digest | both `FROM` lines in `Dockerfile`               | own      |
| GitHub Actions and runner images                                  | `.github/workflows/*.yml`                       | grouped  |
| Tools in `mise.toml`                                              | `mise.toml`                                     | grouped  |
| Go CLIs (`direnv`, `lazygit`, `fzf`, `shfmt`, `glow`, `task`)     | `TOOLS` in the `go-builder` stage               | grouped  |
| `MISE_VERSION`, `GO_VERSION`                                      | `Dockerfile` ARGs under a `# renovate:` comment | one each |

- Major updates get a PR of their own. A Go CLI major is only listed on the dashboard for approval: it also changes the
  module path (`/v2` → `/v3`), which has to be edited by hand.
- Renovate PRs come from branches of this repository, so they get its secrets and run the full `pr.yml` gate (build,
  Trivy, smoke test).
- Closing a Renovate PR without merging it ignores that version.
- To track another pinned version in the `Dockerfile`, put `# renovate: datasource=<datasource> depName=<name>` on the
  line right above its `ARG NAME=<version>`.

### Secrets & Variables

| Name                   | Type   | Source                         | Purpose                                                                               |
| ---------------------- | ------ | ------------------------------ | ------------------------------------------------------------------------------------- |
| `AWS_PR_ROLE_ARN`      | secret | `secrets.AWS_PR_ROLE_ARN`      | IAM role for `pr.yml` (GitHub OIDC): read/write on the build cache repository only    |
| `AWS_RELEASE_ROLE_ARN` | secret | `secrets.AWS_RELEASE_ROLE_ARN` | IAM role for `release.yml` (GitHub OIDC): push to `devcr`, read/write the build cache |
| `GITHUB_TOKEN`         | secret | auto-provided                  | Authenticated GitHub API requests for `mise` package downloads                        |

The ECR repositories and the roles live in the infra repository (`cloud/aws/live/us-east-1/container/ecr/devcr`,
`container/ecr/buildcache/devcr` and `iam/ecr/devcr`); the secrets are that unit's `pr_role_arn` and `release_role_arn`
outputs. `gha-devcr-pr` trusts pull requests of this repository and can only touch the cache repository, so pull request
code can't change published images; `gha-devcr-release` trusts version tags. The role ARNs are secrets rather than
variables, and the workflows mask the account ID, so neither shows up in this public repository's logs.

### Cache Strategy

PR and release builds share a **registry cache** stored in its own private ECR repository, `buildcache/devcr` (tag
`latest`). The image repository `devcr` has immutable tags, so the moving cache tag can't live there. The cache
repository's lifecycle policy expires the untagged cache manifests that each build leaves behind after 7 days.

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
