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
# Why source-build and not `go install pkg@ver`: `go install` rebuilds the stdlib
# with the new Go but leaves each tool's PINNED golang.org/x/{sys,net,text,crypto}
# untouched, so those ship stale and trip Trivy (CVE-2026-39824/46600/56852, plus the
# older x/crypto HIGH in task). Each tool gets a throwaway module where we `go get`
# the tool, then bump the four x/* modules to fixed versions; `go build` only links
# the ones the tool actually imports. Fixes applied (all four x/* bumped to their
# coordinated latest; CVE fix thresholds are 0.44/0.56/0.39 and crypto>0.49, so the
# pinned set clears them. The x/* modules are a tightly-coupled dependency set and
# must be bumped together to a consistent graph — a partial bump fails go.mod
# resolution, e.g. x/net@v0.56 requires x/crypto@v0.53):
#   direnv/lazygit/fzf/shfmt : golang.org/x/sys -> v0.47.0 (CVE-2026-39824)
#   glow/task                : golang.org/x/net -> v0.57.0 (CVE-2026-46600), x/text -> v0.40.0 (CVE-2026-56852)
#   lazygit/glow             : golang.org/x/text -> v0.40.0 (CVE-2026-56852)
#   task                     : golang.org/x/crypto -> v0.54.0 (older x/crypto HIGH)
# shfmt: latest tag (v3.13.1) has NO newer release, so source-rebuild is the only
# fix. The Mason prebuilt installed later by nvim is overwritten in a post-step.
# DL3062 false positive: hadolint mis-parses `go -C <dir> get pkg@ver` and reports
# it unpinned, but every go get below IS pinned with @<version>.
# hadolint ignore=DL3062
RUN --mount=type=cache,id=go-build,target=/root/.cache/go-build,sharing=locked \
    --mount=type=cache,id=go-mod,target=/root/go/pkg/mod,sharing=locked \
    eval "$(mise hook-env)" && \
    export GOPATH=/root/go GOBIN=/usr/local/bin \
           GOCACHE=/root/.cache/go-build GOMODCACHE=/root/go/pkg/mod && \
    go version && \
    XSYS=(golang.org/x/sys@v0.47.0 golang.org/x/net@v0.57.0 golang.org/x/text@v0.40.0 golang.org/x/crypto@v0.54.0) && \
    rm -rf /tmp/direnv && mkdir -p /tmp/direnv && \
    go -C /tmp/direnv mod init direnv && \
    go -C /tmp/direnv get github.com/direnv/direnv/v2@v2.37.1 && \
    go -C /tmp/direnv get "${XSYS[@]}" && \
    go -C /tmp/direnv build -o /usr/local/bin/direnv github.com/direnv/direnv/v2 && \
    rm -rf /tmp/direnv && \
    rm -rf /tmp/lazygit && mkdir -p /tmp/lazygit && \
    go -C /tmp/lazygit mod init lazygit && \
    go -C /tmp/lazygit get github.com/jesseduffield/lazygit@v0.63.1 && \
    go -C /tmp/lazygit get "${XSYS[@]}" && \
    go -C /tmp/lazygit build -o /usr/local/bin/lazygit github.com/jesseduffield/lazygit && \
    rm -rf /tmp/lazygit && \
    rm -rf /tmp/fzf && mkdir -p /tmp/fzf && \
    go -C /tmp/fzf mod init fzf && \
    go -C /tmp/fzf get github.com/junegunn/fzf@v0.74.0 && \
    go -C /tmp/fzf get "${XSYS[@]}" && \
    go -C /tmp/fzf build -o /usr/local/bin/fzf github.com/junegunn/fzf && \
    rm -rf /tmp/fzf && \
    rm -rf /tmp/shfmt && mkdir -p /tmp/shfmt && \
    go -C /tmp/shfmt mod init shfmt && \
    go -C /tmp/shfmt get mvdan.cc/sh/v3/cmd/shfmt@v3.13.1 && \
    go -C /tmp/shfmt get "${XSYS[@]}" && \
    go -C /tmp/shfmt build -o /usr/local/bin/shfmt mvdan.cc/sh/v3/cmd/shfmt && \
    rm -rf /tmp/shfmt && \
    # glow v2: NOTE the /v2 module path (v1 is a different, older major).
    rm -rf /tmp/glow && mkdir -p /tmp/glow && \
    go -C /tmp/glow mod init glow && \
    go -C /tmp/glow get github.com/charmbracelet/glow/v2@v2.1.2 && \
    go -C /tmp/glow get "${XSYS[@]}" && \
    go -C /tmp/glow build -o /usr/local/bin/glow github.com/charmbracelet/glow/v2 && \
    rm -rf /tmp/glow && \
    rm -rf /tmp/task && mkdir -p /tmp/task && \
    go -C /tmp/task mod init task && \
    go -C /tmp/task get github.com/go-task/task/v3/cmd/task@v3.52.0 && \
    go -C /tmp/task get "${XSYS[@]}" && \
    go -C /tmp/task build -o /usr/local/bin/task github.com/go-task/task/v3/cmd/task && \
    rm -rf /tmp/task

# Post-install patch: replace npm's bundled undici (6.26.0, CVE-2026-12151 HIGH) and
# tar (7.5.15, CVE-2026-53655 HIGH by vendor severity) with fixed, same-major
# drop-ins (undici 6.27.0, tar 7.5.16). Node's bundled npm deps are NOT updated by
# Node minor bumps (26.3.1/26.4.0/26.5.0 all still ship the old versions), so patch
# in place. (The Go test-fixture PEM is deleted in the mise-install RUN above,
# in the same layer it's created in — deleting it in a later layer wouldn't clear it
# from the earlier layer diff that Trivy scans.)
RUN NODE_INSTALL="$(mise where node)" && \
    NM="$NODE_INSTALL/lib/node_modules/npm/node_modules" && \
    rm -rf "$NM/undici" && \
    curl -fsSL https://registry.npmjs.org/undici/-/undici-6.27.0.tgz | tar xz -C "$NM" && \
    mv "$NM/package" "$NM/undici" && \
    grep -q '"version": "6.27.0"' "$NM/undici/package.json" && \
    rm -rf "$NM/tar" && \
    curl -fsSL https://registry.npmjs.org/tar/-/tar-7.5.16.tgz | tar xz -C "$NM" && \
    mv "$NM/package" "$NM/tar" && \
    grep -q '"version": "7.5.16"' "$NM/tar/package.json"

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
