# Pre-FROM ARGs are shared by every stage that re-declares them (bare `ARG NAME`).
ARG MISE_VERSION=v2026.7.3

# trixie-20260713-slim
# https://hub.docker.com/layers/library/debian/trixie-20260713-slim/images/sha256-53dfdbcd6fbc78c5052f35d2a5c798259f4c615cd93582b4ff5ad4f04249c7e3
# Builder for the Go CLIs. Same digest-pinned base as the final stage, so there is one
# base image to track. It runs natively ($BUILDPLATFORM) and cross-compiles for
# $TARGETARCH: the arm64 release build goes through QEMU, and compiling six Go
# programs under emulation is extremely slow.
FROM --platform=$BUILDPLATFORM docker.io/debian@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd AS go-builder

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ARG DEBIAN_FRONTEND=noninteractive
ARG MISE_VERSION
# Single source of truth for the Go toolchain; it is deliberately not in mise.toml.
ARG GO_VERSION=1.26.9

# ca-certificates for TLS to the module proxy, curl for the mise installer, git for
# the GOPROXY "direct" fallback. Same version pins as ./apt-packages.
RUN apt-get update -q \
    && apt-get install -y --no-install-recommends -q ca-certificates=2025* curl=8.14.* git=1:2.47.* \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://mise.run \
    | MISE_VERSION=${MISE_VERSION} MISE_INSTALL_PATH=/usr/local/bin/mise sh \
    && mise install --yes go@${GO_VERSION}

ARG TARGETARCH
# All six tools are pure Go, so CGO_ENABLED=0 is safe and makes cross-compiling trivial.
# GOTOOLCHAIN=local: fail rather than silently download a different Go than GO_VERSION.
ENV CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} GOTOOLCHAIN=local \
    GOPATH=/root/go GOCACHE=/root/.cache/go-build

# Build the Go-based CLIs with the pinned Go toolchain so their embedded stdlib is
# current. They are not in mise.toml because the mise prebuilts ship a stale Go stdlib
# and some (glow) have no newer release at all. Dependencies resolve exactly as
# each upstream pins them: `go install pkg@ver` builds against the tool's own go.mod.
# Earlier revisions force-bumped golang.org/x/* and grpc per tool to keep Trivy green;
# that was dropped on purpose once the toolchain stopped shipping in the final image.
# What Trivy still flags inside these binaries is handled in .trivyignore.yaml.
# DL3062 false positive: hadolint cannot see the @<version> through the loop variable
# and reports `go install` as unpinned, but every entry in TOOLS IS pinned.
# hadolint ignore=DL3062
RUN --mount=type=cache,id=go-build,target=/root/.cache/go-build,sharing=locked \
    --mount=type=cache,id=go-mod,target=/root/go/pkg/mod,sharing=locked \
    PATH="$(mise where go@${GO_VERSION})/bin:${PATH}" && \
    go version && \
    # glow v2: NOTE the /v2 module path (v1 is a different, older major).
    TOOLS=( \
        direnv=github.com/direnv/direnv/v2@v2.38.2 \
        lazygit=github.com/jesseduffield/lazygit@v0.65.1 \
        fzf=github.com/junegunn/fzf@v0.74.0 \
        shfmt=mvdan.cc/sh/v3/cmd/shfmt@v3.13.1 \
        glow=github.com/charmbracelet/glow/v2@v2.1.2 \
        task=github.com/go-task/task/v3/cmd/task@v3.54.0 \
    ) && \
    # go install puts native binaries in bin/ but cross-compiled ones in bin/<os>_<arch>/.
    BIN_DIR="${GOPATH}/bin" && \
    if [ "$(go env GOHOSTARCH)" != "${GOARCH}" ]; then BIN_DIR="${BIN_DIR}/${GOOS}_${GOARCH}"; fi && \
    mkdir -p /out && \
    for spec in "${TOOLS[@]}"; do \
        go install "${spec#*=}" && mv "${BIN_DIR}/${spec%%=*}" /out/; \
    done

# Same pinned base as go-builder above.
FROM docker.io/debian@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd

USER root

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ARG DEBIAN_FRONTEND=noninteractive

COPY ./apt-packages /tmp/apt-packages
RUN apt-get update -q \
    && xargs -a /tmp/apt-packages apt-get install -y --no-install-recommends -q \
    && apt-get upgrade -y -q curl libcap2 libcurl3t64-gnutls libcurl4t64 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/apt-packages

ARG MISE_VERSION
ARG MISE_HTTP_TIMEOUT=60
ARG MISE_HTTP_RETRIES=5
ARG MISE_VERBOSE=true
ARG MISE_JOBS=4

COPY --chown=root:root --chmod=644 ./mise.toml /etc/mise/config.toml
RUN --mount=type=cache,id=mise-downloads,target=/root/.local/share/mise,sharing=locked \
    --mount=type=secret,id=github_token,env=GITHUB_TOKEN,required=true \
    curl -fsSL https://mise.run \
    | MISE_VERSION=${MISE_VERSION} MISE_INSTALL_PATH=/usr/local/bin/mise sh \
    && chmod 755 /etc/mise \
    && mise install --system --yes \
    && ln -sf "$(mise where aqua:fish-shell/fish-shell)/fish" /usr/local/bin/fish \
    && echo /usr/local/bin/fish >> /etc/shells \
    && mise cache clear

# Only the Go binaries cross over from go-builder; the toolchain, its stdlib and its
# test fixtures never enter this image, so Trivy has nothing of Go's own to scan.
COPY --from=go-builder /out/ /usr/local/bin/

ARG USER_ID=1000
ARG GROUP_ID=1000
ARG USERNAME=devel

RUN groupadd -g ${GROUP_ID} ${USERNAME} \
    && useradd -l -m -u ${USER_ID} -g ${GROUP_ID} -G sudo -s /usr/local/bin/fish ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME} \
    && rm -f /var/log/lastlog /var/log/faillog \
    && install -m 0644 -o ${USER_ID} -g ${GROUP_ID} /dev/null /etc/devcr-dotfiles-sha

ENV HOME=/home/${USERNAME}
ENV DOTFILES_DIR=${HOME}/dotfiles
ENV TERM=xterm-256color
# Explicit override that tells nvim to access system clipboard via OSC52 excape sequence.
# It would work only in modern terminals such as iTerm2, WezTerm, Alacritty, Kitty, Ghostty, Windows Terminal, etc.
ENV NVIM_CLIPBOARD=osc52

USER ${USERNAME}

ARG DOTFILES_REPO_URL=https://github.com/leonidgrishenkov/dotfiles.git
# Branch, tag or full 40-char commit SHA of the dotfiles. The default tracks the tip
# of main, so two builds of the same commit can differ; pin a SHA to reproduce one.
# The resolved commit is printed in the build log and kept in /etc/devcr-dotfiles-sha.
ARG DOTFILES_REF=main
ARG XDG_DATA_HOME=${HOME}/.local/share

WORKDIR ${DOTFILES_DIR}

COPY ./stow-packages /tmp/stow-packages

# A branch or tag is cloned as before (a branch stays checked out, so `git pull` works
# in the container). `clone --branch` cannot take a commit SHA, so a SHA is fetched
# on its own and checked out detached.
RUN if [[ "${DOTFILES_REF}" =~ ^[0-9a-f]{40}$ ]]; then \
        git init -q "${DOTFILES_DIR}" \
        && git -C "${DOTFILES_DIR}" remote add origin "${DOTFILES_REPO_URL}" \
        && git -C "${DOTFILES_DIR}" fetch -q --depth=1 origin "${DOTFILES_REF}" \
        && git -C "${DOTFILES_DIR}" checkout -q FETCH_HEAD; \
    else \
        git clone -q --depth=1 --branch "${DOTFILES_REF}" --single-branch "${DOTFILES_REPO_URL}" "${DOTFILES_DIR}"; \
    fi \
    && DOTFILES_SHA="$(git -C "${DOTFILES_DIR}" rev-parse HEAD)" \
    && echo "dotfiles: ${DOTFILES_REPO_URL} ${DOTFILES_REF} -> ${DOTFILES_SHA}" \
    && echo "${DOTFILES_SHA}" > /etc/devcr-dotfiles-sha \
    && eval "$(mise hook-env)" \
    && cat /tmp/stow-packages | xargs -I {} stow {} \
    && nvim --headless "+Lazy! restore" +qa \
    && pi install git:github.com/leonidgrishenkov/pi-extensions \
    && npx -y github:leonidgrishenkov/agent-skills install --target pi --target claude \
    && bat cache --build

# Overwrite Mason's prebuilt shfmt (built with Go 1.26.1, vuln stdlib) with the copy
# built in the go-builder stage with the pinned GO_VERSION. Mason names the
# binary shfmt_v<ver>_linux_<arch> and symlinks bin/shfmt -> it; we swap the real
# file in place. No-op if Mason didn't install shfmt (find returns nothing).
RUN find "${HOME}/.local/share/nvim/mason/packages/shfmt" -type f -name 'shfmt_v*' \
        -exec cp /usr/local/bin/shfmt {} \; 2>/dev/null || true

WORKDIR ${HOME}
SHELL ["/usr/local/bin/fish"]

CMD ["fish"]
