# debian:trixie-20251103
FROM docker.io/debian@sha256:01a723bf5bfb21b9dda0c9a33e0538106e4d02cce8f557e118dd61259553d598

USER root

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ARG DEBIAN_FRONTEND=noninteractive

COPY ./apt-packages /tmp/apt-packages
RUN apt-get update -q \
    && xargs -a /tmp/apt-packages apt-get install -y --no-install-recommends -q \
    && apt-get upgrade -y -q curl libcap2 libcurl3t64-gnutls libcurl4t64 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/apt-packages

ARG MISE_VERSION=v2026.7.3
ARG MISE_HTTP_TIMEOUT=60
ARG MISE_HTTP_RETRIES=5
ARG MISE_VERBOSE=true
ARG MISE_JOBS=4

COPY --chown=root:root --chmod=644 ./mise.toml /etc/mise/config.toml
RUN --mount=type=cache,id=mise-downloads,target=/root/.local/share/mise,sharing=locked \
    curl -fsSL https://mise.run \
    | MISE_VERSION=${MISE_VERSION} MISE_INSTALL_PATH=/usr/local/bin/mise sh \
    && chmod 755 /etc/mise \
    && mise install --system --yes \
    && ln -sf "$(mise where aqua:fish-shell/fish-shell)/fish" /usr/local/bin/fish \
    && echo /usr/local/bin/fish >> /etc/shells \
    && rm -f "$(mise where go)/src/crypto/x509/platform_root_key.pem" \
    && mise cache clear

# Build the Go-based CLIs from source with the Go 1.26.5 toolchain installed above,
# so their embedded stdlib (and golang.org/x/* deps) are patched. We do NOT pin
# these in mise.toml because the mise prebuilts ship stale Go and some (direnv,
# glow) have no newer release at all. Trivy scans the binaries on disk, so leaving
# the vulnerable mise copies around would keep the gate red — hence source builds.
#   direnv / lazygit / fzf : only stdlib is vulnerable (golang.org/x/* clean) -> `go install @latest` with Go 1.26.5
#   glow                  : also golang.org/x/net v0.40.0 (HIGH) -> bump to v0.55.0
#   task                  : golang.org/x/net v0.52.0 + golang.org/x/crypto v0.49.0 (HIGH) -> bump both
RUN --mount=type=cache,id=go-build,target=/root/.cache/go-build,sharing=locked \
    --mount=type=cache,id=go-mod,target=/root/go/pkg/mod,sharing=locked \
    eval "$(mise hook-env)" && \
    export GOPATH=/root/go GOBIN=/usr/local/bin \
           GOCACHE=/root/.cache/go-build GOMODCACHE=/root/go/pkg/mod && \
    go version && \
    # direnv/lazygit/fzf/shfmt: only stdlib was vulnerable -> rebuild @latest pinned versions with Go 1.26.5.
    # shfmt: latest tag (v3.13.1) ships a prebuilt built with Go 1.26.1 and has NO newer release,
    # so source-rebuild is the only fix. The Mason copy installed later by nvim is overwritten in a post-step.
    go install github.com/direnv/direnv/v2@v2.37.1 && \
    go install github.com/jesseduffield/lazygit@v0.63.1 && \
    go install github.com/junegunn/fzf@v0.74.0 && \
    go install mvdan.cc/sh/v3/cmd/shfmt@v3.13.1 && \
    # glow v2: also had golang.org/x/net v0.40.0 (HIGH) -> bump to v0.55.0.
    # NOTE the /v2 module path (v1 is a different, older major).
    rm -rf /tmp/glow && mkdir -p /tmp/glow && \
    go -C /tmp/glow mod init glow && \
    go -C /tmp/glow get github.com/charmbracelet/glow/v2@v2.1.2 && \
    go -C /tmp/glow get golang.org/x/net@v0.55.0 && \
    go -C /tmp/glow build -o /usr/local/bin/glow github.com/charmbracelet/glow/v2 && \
    rm -rf /tmp/glow && \
    # task v3: golang.org/x/net v0.52.0 + golang.org/x/crypto v0.49.0 (HIGH) -> bump both.
    rm -rf /tmp/task && mkdir -p /tmp/task && \
    go -C /tmp/task mod init task && \
    go -C /tmp/task get github.com/go-task/task/v3/cmd/task@v3.52.0 && \
    go -C /tmp/task get golang.org/x/net@v0.55.0 golang.org/x/crypto@v0.52.0 && \
    go -C /tmp/task build -o /usr/local/bin/task github.com/go-task/task/v3/cmd/task && \
    rm -rf /tmp/task

# Post-install patch: replace npm's bundled undici (6.26.0, CVE-2026-12151 HIGH) with
# 6.27.0 (fix available, same major -> drop-in). Node's bundled npm/undici is NOT
# updated by Node minor bumps (26.3.1, 26.4.0, 26.5.0 all still ship 6.26.0), so
# patch in place. (The Go test-fixture PEM is deleted in the mise-install RUN above,
# in the same layer it's created in — deleting it in a later layer wouldn't clear it
# from the earlier layer diff that Trivy scans.)
RUN NODE_INSTALL="$(mise where node)" && \
    NM="$NODE_INSTALL/lib/node_modules/npm/node_modules" && \
    rm -rf "$NM/undici" && \
    curl -fsSL https://registry.npmjs.org/undici/-/undici-6.27.0.tgz | tar xz -C "$NM" && \
    mv "$NM/package" "$NM/undici" && \
    grep -q '"version": "6.27.0"' "$NM/undici/package.json"

ARG USER_ID=1000
ARG GROUP_ID=1000
ARG USERNAME=devel

RUN groupadd -g ${GROUP_ID} ${USERNAME} \
    && useradd -l -m -u ${USER_ID} -g ${GROUP_ID} -G sudo -s /usr/local/bin/fish ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME} \
    && rm -f /var/log/lastlog /var/log/faillog

ENV HOME=/home/${USERNAME}
ENV DOTFILES_DIR=${HOME}/dotfiles
ENV TERM=xterm-256color

USER ${USERNAME}

ARG DOTFILES_REPO_URL=https://github.com/leonidgrishenkov/dotfiles.git
ARG XDG_DATA_HOME=${HOME}/.local/share
WORKDIR ${DOTFILES_DIR}

RUN git clone -q --depth=1 -b "main" --single-branch ${DOTFILES_REPO_URL} "${DOTFILES_DIR}" \
    && eval "$(mise hook-env)" \
    && task stow:essentials pi:install nvim:install \
    && bat cache --build

# Overwrite Mason's prebuilt shfmt (built with Go 1.26.1, vuln stdlib) with the
# source-built copy from the Go step above (built with Go 1.26.5). Mason names the
# binary shfmt_v<ver>_linux_<arch> and symlinks bin/shfmt -> it; we swap the real
# file in place. No-op if Mason didn't install shfmt (find returns nothing).
RUN find "${HOME}/.local/share/nvim/mason/packages/shfmt" -type f -name 'shfmt_v*' \
        -exec cp /usr/local/bin/shfmt {} \; 2>/dev/null || true

WORKDIR ${HOME}
SHELL ["/usr/local/bin/fish"]

CMD ["fish"]
