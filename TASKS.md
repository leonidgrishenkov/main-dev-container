# Work plan: multi-stage build + CVE policy

Branch: `multistage-build-and-cve-policy`

Instructions for an agent picking this up. Phases are **ordered by dependency** — do not reorder.
Phase 1 changes what Trivy reports, so Phase 2 cannot be designed until Phase 1 is measured.

Delete this file in Phase 7.

## Why this work exists

Two unrelated-looking blocks in the `Dockerfile` — the Go source-rebuild loop
(currently lines 35-104) and the npm tarball patching (currently lines 106-127) — exist
**only to make the Trivy gate green**. Roughly 100 lines, re-derived by hand on every
upstream release, protecting against CVEs in interactive dev CLIs (`fzf`, `lazygit`,
`glow`, `task`, `direnv`, `shfmt`) running in a single-user container.

The fix is two-sided:

1. Move the Go build to a builder stage so the Go toolchain and its stdlib **leave the
   final image**. Trivy stops seeing them, and a large share of the findings disappear
   without any suppression at all.
2. For whatever genuinely remains, suppress it **explicitly, with written justification
   and an expiry date**, instead of hand-patching dependency graphs.

Keep the gate strict for the OS/base layer and anything that handles untrusted input.
Relax it only for local dev tooling, and say so in writing.

## Ground rules

- **One phase per commit.** Conventional commit prefixes, matching repo history
  (`ci:`, `chore:`, `refactor:`, `docs:`, `fix:`). End every commit message with:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
- **Do not push and do not open a PR** without asking the user first.
- **Line numbers in this file refer to `main`.** Every phase shifts them. Re-grep for the
  anchor text before editing; never trust a line number from an earlier phase.
- **Preserve the existing comments.** The `Dockerfile` comments explain non-obvious
  reasoning (e.g. why deleting a file in a later layer does not clear it from the earlier
  layer diff Trivy scans). When a comment's subject moves to the builder stage, move the
  comment with it. When its subject is deleted, delete it. Do not silently drop it.
- **A local build is required to verify.** The build needs a GitHub token secret:

  ```bash
  GITHUB_TOKEN=$(gh auth token) docker buildx build \
    --secret id=github_token,env=GITHUB_TOKEN \
    --load -t devcr:local .
  ```

  Scan it the same way CI does:

  ```bash
  trivy image --severity HIGH,CRITICAL --ignore-unfixed devcr:local
  ```

  If Docker or `trivy` is unavailable locally, **stop and tell the user** which phases
  you could not verify. Do not mark a phase done on reasoning alone.

---

## Phase 1 — Multi-stage Go build

The highest-value change. It simplifies the `Dockerfile` *and* shrinks the attack
surface, which is why it comes first.

### 1.1 Capture a baseline

Before changing anything, record what you are starting from. You need these numbers to
prove the phase worked and to size Phase 2.

```bash
GITHUB_TOKEN=$(gh auth token) docker buildx build \
  --secret id=github_token,env=GITHUB_TOKEN --load -t devcr:baseline .
docker image inspect devcr:baseline --format '{{.Size}}'
trivy image --severity HIGH,CRITICAL --ignore-unfixed devcr:baseline \
  > /tmp/trivy-baseline.txt
```

Write the image size and the finding count into the Phase 1 commit message. If the build
fails on `main` before you have touched anything, stop and report — that is a
pre-existing break, not yours to absorb silently.

### 1.2 Add the builder stage

Use **the same digest-pinned Debian base** as the final stage, with Go installed via
mise. Rationale: one pinned base image instead of two, consistent with how this repo
already works.

> Alternative considered: `FROM golang:1.26.5-trixie AS go-builder`. Simpler, but adds a
> second base to pin and track. If you take it anyway, you **must** pin the
> manifest-list (index) digest from `docker buildx imagetools inspect`, not a
> platform-specific digest — the release workflow builds `linux/amd64,linux/arm64`
> (`.github/workflows/release.yml:14`) and a single-arch digest breaks the arm64 build.

Cross-compile rather than building under emulation. The release build reaches arm64
through QEMU (`setup-qemu-action`, `release.yml:69-70`); compiling six Go binaries under
emulation is extremely slow. `--platform=$BUILDPLATFORM` pins the builder to the native
architecture and `GOARCH=$TARGETARCH` targets the output. All six tools are pure Go, so
`CGO_ENABLED=0` is safe.

Structure:

```dockerfile
FROM docker.io/debian@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd AS go-builder

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ARG DEBIAN_FRONTEND=noninteractive
ARG GO_VERSION=1.26.5
ARG MISE_VERSION=v2026.7.3
ARG TARGETARCH

# ca-certificates and git are needed for module fetching; curl for the mise installer.
RUN apt-get update -q \
    && apt-get install -y --no-install-recommends -q ca-certificates curl git \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://mise.run \
    | MISE_VERSION=${MISE_VERSION} MISE_INSTALL_PATH=/usr/local/bin/mise sh \
    && mise install --yes go@${GO_VERSION}

ENV CGO_ENABLED=0 GOOS=linux
# ... build each tool into /out, then: COPY --from=go-builder /out/ /usr/local/bin/
```

Carry over from the existing block, unchanged in substance:

- the exact tool versions (`direnv` v2.37.1, `lazygit` v0.63.1, `fzf` v0.74.0,
  `shfmt` v3.13.1, `glow/v2` v2.1.2, `task` v3.52.0)
- the `--mount=type=cache` mounts for `go-build` and `go/pkg/mod`
- the `# hadolint ignore=DL3062` directive and the note explaining the false positive

**Drop** the `XSYS` array and every `go get golang.org/x/...@v...` and
`go get google.golang.org/grpc@...` line. Their only purpose was satisfying Trivy on
binaries that no longer ship a scannable toolchain. Resolve dependencies as upstream
pins them. Replace the long CVE-bookkeeping comment with a short one recording that
pins were deliberately removed and why, plus a pointer to `.trivyignore.yaml`.

The six near-identical build blocks should collapse into one loop over a
`tool=importpath@version` list. Six copy-pasted five-line blocks is the thing worth
removing here.

### 1.3 Strip Go from the final stage

1. Remove `go = "1.26.5"` and its two-line comment from `mise.toml:19-21`. Keep the
   version reachable — the builder stage's `GO_VERSION` arg is now the single source of
   truth, so note that in `mise.toml` where the entry used to be.
2. Delete `rm -f "$(mise where go)/src/crypto/x509/platform_root_key.pem"`
   (`Dockerfile:32`). With Go gone from mise this command **fails the build** rather than
   no-opping — `mise where go` exits non-zero under `pipefail`. Removing the line is
   mandatory, not cosmetic.
3. Replace the whole Go `RUN` block with `COPY --from=go-builder /out/ /usr/local/bin/`.
   Place it **before** the `USER ${USERNAME}` switch so ownership stays `root:root`.

### 1.4 Do NOT remove `build-essential` yet

`apt-packages:11` ships `build-essential`, and it looks like builder-only baggage. It is
probably not: nvim compiles tree-sitter parsers with a C compiler **at container
runtime**, and Mason may compile tools on install.

Leave it in place in this phase. If you want to test removing it, that is a separate
experiment with its own verification: start the container, run
`nvim --headless "+TSUpdateSync" +qa`, and confirm parsers build. Report the result;
do not remove it on reasoning alone.

### 1.5 Verify

- Build succeeds for `linux/amd64`.
- Cross-build works: `docker buildx build --platform linux/arm64 ...` (`--load` cannot
  take two platforms; build them separately, or use `--output=type=cacheonly`).
- All six binaries exist, are executable, and report the expected version:

  ```bash
  for t in direnv lazygit fzf shfmt glow task; do
    docker run --rm devcr:local "$t" --version || echo "FAILED: $t"
  done
  ```

- Mason's shfmt overwrite (`Dockerfile:167-168`) still finds its target. The `find ... ||
  true` swallows failure, so verify positively instead: confirm the Mason binary's
  version matches `/usr/local/bin/shfmt`.
- `go` is **absent** from the final image: `docker run --rm devcr:local which go` must
  fail. If anything in the dotfiles/Mason path needed Go at runtime, this is where it
  surfaces — report it rather than reinstating the toolchain.
- Record the new image size and the new Trivy finding count. Diff against
  `/tmp/trivy-baseline.txt` and put the delta in the commit message.

Commit: `refactor: build Go CLIs in a cross-compiling builder stage`

---

## Phase 2 — Re-baseline the CVE gate

Only now is it knowable what actually needs suppressing.

### 2.1 Measure

```bash
trivy image --severity HIGH,CRITICAL --ignore-unfixed devcr:local \
  > /tmp/trivy-after-phase1.txt
diff /tmp/trivy-baseline.txt /tmp/trivy-after-phase1.txt
```

Sort every remaining finding into one of two buckets:

- **Bucket A — gate stays strict.** Base OS packages, `curl`, `git`, `gnupg`, OpenSSL,
  anything in the TLS/crypto path, anything that parses untrusted network input.
  These get **fixed**, never ignored. If a fix is unavailable, that is a release blocker
  worth raising with the user.
- **Bucket B — suppress with justification.** Dev CLIs driven interactively by a single
  trusted user, and vendored dependencies inside them.

If Bucket B is empty after Phase 1, **skip to Phase 3 and say so.** Do not create an
empty policy file for its own sake.

### 2.2 Write `.trivyignore.yaml`

Use the YAML form, not flat `.trivyignore`. It supports path scoping and expiry, which
the flat format does not — an un-expiring blanket ignore is how a suppression file rots
into a liability.

```yaml
vulnerabilities:
  - id: CVE-0000-00000
    paths:
      - usr/local/bin/glow
    statement: >
      Markdown renderer invoked interactively by the single trusted user of this
      dev container. No untrusted input path. Upstream has no patched release.
    expired-at: 2027-04-01
```

Rules:

- **Always scope with `paths`.** An unscoped `id` would also suppress the same CVE in a
  base OS package, which is exactly the Bucket A case the gate must keep catching.
- **Every entry needs a real `statement`** naming the reason it is not exploitable here.
  "Dev tool" alone is not a justification; "no untrusted input path, single-user
  container" is.
- **Every entry needs `expired-at`**, roughly six months out. On expiry Trivy fails again
  and the decision gets revisited deliberately.

### 2.3 Wire it into both scan paths

`.github/workflows/pr.yml:103-111` runs the image scan. Add
`trivyignores: .trivyignore.yaml` to the `with:` block. Trivy auto-detects the file, but
set it explicitly so the dependency is visible in the workflow rather than implied.

Check whether the config scan in `feature.yml:32-38` also needs it — it runs
`scan-type: config` against the repo and will not see image CVEs, so it probably does
not. Confirm, do not assume.

Also confirm `.trivyignore.yaml` is **not** excluded by `.dockerignore` if anything in
the build needs it (it should not be — it is CI-side only).

### 2.4 Verify

- `trivy image --severity HIGH,CRITICAL --ignore-unfixed --ignorefile .trivyignore.yaml devcr:local`
  exits 0.
- **Negative test, do not skip:** temporarily narrow one entry's `paths` to a wrong path
  and confirm the scan fails again. This proves the suppression is actually scoped and
  not silently matching everything. Revert afterwards.

Commit: `ci: scope the Trivy gate with a justified, expiring ignore policy`

---

## Phase 3 — Revisit the npm patching

`Dockerfile:106-127` hand-downloads `undici`, `tar`, and `brace-expansion` tarballs from
`registry.npmjs.org` and moves them into npm's bundled `node_modules`.

This block is **actively fragile**, independent of the CVE argument: each
`grep -q '"version": "X.Y.Z"'` guard **fails the build** once Node ships a bundled
version newer than the hardcoded pin. It does not degrade — it breaks, on a routine Node
bump.

Decide between two paths, in this order of preference:

**Option A — delete the block, suppress in `.trivyignore.yaml`.** Scope the paths to
`**/node_modules/npm/node_modules/...`. The exposure is npm's own bundled deps, used when
the user runs `npm`/`npx` by hand. Note that `Dockerfile:160` does run
`npx -y github:leonidgrishenkov/agent-skills` at build time, so state in the `statement`
that the inputs are first-party repos, not arbitrary registry content.

**Option B — keep the patching, make it idempotent.** Only if Bucket A reasoning puts
these in scope. Replace each hardcoded equality `grep` with a comparison that accepts
*at least* the target version, so a newer bundled copy is left alone instead of failing
the build. Use a real version comparison (e.g. `sort -V`), not string equality.

**Do not leave the current form.** Equality-pinned guards on dependencies you do not
control are a scheduled build break.

Whichever path you take, keep the explanatory comment about Node minor bumps not
refreshing bundled npm deps — that is the non-obvious fact justifying the whole block's
existence.

Verify: build succeeds; `npm --version` and `npx --version` work in the container;
the scan still exits 0.

Commit: `fix: stop equality-pinning npm bundled deps` (Option B) or
`refactor: drop npm bundled-dep patching in favour of scoped ignores` (Option A)

---

## Phase 4 — A smoke test that tests something

`pr.yml:163-182` effectively runs `fish --version`. That passes even if the dotfiles
never stowed, the nvim plugins never restored, and the Go binaries are broken — i.e. it
cannot fail for any of the reasons this image actually breaks.

### 4.1 Add `scripts/smoke.sh`

A script, not inline YAML, so it runs locally too:
`docker run --rm devcr:local bash /opt/smoke.sh`. Mount or `COPY` it in — prefer mounting
at test time (`-v`) so the script is not baked into the shipped image.

`set -euo pipefail`. Collect failures and report all of them at the end rather than
exiting on the first; a run that lists six broken tools is worth more than one that stops
at the first.

Cover:

1. **Every tool from `mise.toml` resolves and runs** — read the tool list from
   `/etc/mise/config.toml` rather than hardcoding a second copy that will drift.
   Watch for name/binary mismatches (`neovim` → `nvim`, the `aqua:` prefixes).
2. **The six Go binaries** from Phase 1 run and are on `PATH`.
3. **Dotfiles are stowed** — assert a known path is a symlink pointing into
   `$DOTFILES_DIR`, e.g. `[ -L "$HOME/.config/fish/config.fish" ]`. Pick a target that
   genuinely exists in the dotfiles repo; verify, do not guess.
4. **nvim plugins restored** — the plugin directory under
   `$HOME/.local/share/nvim/lazy` exists and is non-empty, and
   `nvim --headless +qa` exits 0 without errors on stderr.
5. **Identity and shell** — `whoami` is `devel`, `$SHELL` is `/usr/local/bin/fish`, and
   `fish` is listed in `/etc/shells`.
6. **`go` is absent** (Phase 1 invariant — this is what stops it quietly returning).

### 4.2 Replace the CI step

Swap the `run-smoke-test` step in `pr.yml` for a call to the script. Delete the
entrypoint/CMD-flag-detection logic (`pr.yml:166-180`) — it exists to make a bare
`--version` work and becomes dead once a real command is passed.

Verify: the script passes against `devcr:local`, **and** fails as expected when you
deliberately break something (rename a binary in a scratch layer). An assertion suite
nobody has seen fail is not known to work.

Commit: `ci: replace the version-check smoke test with real image assertions`

---

## Phase 5 — Automate the mise version bumps

`dependabot.yml` covers Docker and GitHub Actions, but the ~20 pinned versions in
`mise.toml` are bumped by hand. Pinning is this repo's whole strategy, so the manual step
is where it decays.

Add `.github/workflows/mise-updates.yml`:

- `on: schedule:` weekly, plus `workflow_dispatch:` for manual runs.
- Install mise, run `mise outdated` against `mise.toml`.
- Apply updates (`mise upgrade --bump` writes the new pins; confirm the flag against the
  installed mise version rather than trusting this line).
- Open a PR with `peter-evans/create-pull-request`, assigned to `leonidgrishenkov` to
  match the dependabot config. Put the `mise outdated` table in the PR body.

**Critical caveat — read before wiring this up:** a PR opened using the default
`GITHUB_TOKEN` **does not trigger other workflows**. The `pr.yml` gate would not run, and
the PR would sit there with no build, no scan, and no review. Options:

- Use a PAT (or GitHub App token) stored as a secret, so the PR triggers `pr.yml`. This
  is the only option that preserves the gate. It needs a new secret — **ask the user
  before adding a secret requirement**, and document it in the README secrets table.
- Or keep `GITHUB_TOKEN` and accept that a maintainer must close/reopen the PR to kick
  CI. Document this explicitly in the workflow so the behaviour is not mistaken for a bug.

Do not pick silently. State which you chose and why in the commit message.

Verify: `actionlint` passes (it runs in `feature.yml`); trigger via `workflow_dispatch`
on the branch and confirm it produces a sensible PR body. If it cannot be run without
pushing, say so rather than claiming it works.

Commit: `ci: open automated PRs for mise tool updates`

---

## Phase 6 — Make the dotfiles input traceable

`Dockerfile:155` clones the dotfiles with `--depth=1 -b main`, unpinned. Two builds of
the same commit therefore produce different images. For a personal container "always
latest dotfiles" is a defensible default — but it sits oddly beside digest-pinning
everything else, and it means the SLSA provenance from `release.yml:113-114` describes
something less reproducible than it looks.

Do not change the default behaviour. Make the input **visible**:

1. Add `ARG DOTFILES_REF=main` and use it in the clone, so a specific ref can be pinned
   on demand without editing the `Dockerfile`.
   - A plain `--depth=1 --branch "$DOTFILES_REF"` handles branches and tags but **not**
     arbitrary commit SHAs. If SHA support matters, use `--no-checkout` plus
     `git fetch --depth=1 origin "$DOTFILES_REF" && git checkout FETCH_HEAD`.
     Confirm which forms the user wants to support before building this out.
2. Capture the resolved SHA (`git rev-parse HEAD`) and surface it:
   - echo it into the build log, and
   - write it to a file in the image (e.g. `/etc/devcr-dotfiles-sha`) so a running
     container can report which dotfiles it was built from.
3. Add it as an OCI label in `release.yml`'s `derive-tags-and-labels` step, alongside the
   existing `image.source` and `image.revision` labels. The label value must come from the
   build, so this needs a build output or a pre-build resolve step — do not fabricate a
   label that is not actually wired to the real value.

Verify: default build still picks up `main`; an explicit
`--build-arg DOTFILES_REF=<some-tag>` checks out that ref; the recorded SHA matches
`git ls-remote` for the ref.

Commit: `feat: record and allow pinning the dotfiles ref used at build time`

---

## Phase 7 — Documentation

Last, so it documents what was actually built rather than what was planned.

1. **Fix the dangling fragment.** `README.md:68-69` currently ends:
   *"...where PR caches are isolated to the merge ref and invisible to release workflows.
   release integrity."* — the trailing `release integrity.` is an editing artifact.
   Remove it or complete the sentence.
2. **Add a "Vulnerability policy" section** covering the Bucket A / Bucket B split from
   Phase 2: what blocks a release, what gets suppressed, that every suppression carries a
   justification and an expiry, and that expiry is intentional pressure to revisit.
3. **Update the workflow trigger table** (`README.md:14-18`) for the new smoke test and,
   if added, the mise-updates workflow.
4. **Update the secrets table** (`README.md:53-58`) if Phase 5 introduced a PAT.
5. **Document the build args** now worth knowing: `DOTFILES_REF`, `GO_VERSION`.
6. **Note the multi-stage layout** in a sentence or two — that Go CLIs are cross-compiled
   in a builder stage and only the binaries are copied forward, and that this is a
   security property, not just a size optimisation.
7. **Delete `TASKS.md`** (this file).

Commit: `docs: document the multi-stage build and vulnerability policy`

---

## Done criteria

- `docker buildx build` succeeds for `linux/amd64` and `linux/arm64`.
- `trivy image --severity HIGH,CRITICAL --ignore-unfixed` exits 0, and every suppression
  is path-scoped, justified, and dated.
- `scripts/smoke.sh` passes, and has been **observed failing** when something is broken.
- `hadolint` and `actionlint` pass.
- Final image is measurably smaller than the Phase 1 baseline; the number is in a commit
  message.
- `go` is not present in the final image.
- No equality-pinned version guard remains that can fail the build on an upstream bump.
- `TASKS.md` is gone.

## Report back

Summarise: image size before/after, Trivy findings before/after, what landed in
`.trivyignore.yaml` and why, which option you took in Phases 3 and 5, and **anything you
could not verify locally.** An unverified phase reported as done is worse than one
reported as blocked.
