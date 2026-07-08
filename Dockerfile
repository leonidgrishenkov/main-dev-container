# syntax=docker/dockerfile:1.7
#
# Two-stage build.
#
#   1. `dev-builder`  — has build-essential, compiles everything (mise tools,
#      nvim plugins/parsers, zsh plugins, pi extensions) into /home/devel.
#
#   2. `runtime`       — slim final image: apt set minus build-essential, plus
#      the mise binary and the fully provisioned /home/devel copied across.
#      No compiler in the final image (see README for the treesitter caveat).
#
# debian:trixie-20251103
FROM docker.io/debian@sha256:01a723bf5bfb21b9dda0c9a33e0538106e4d02cce8f557e118dd61259553d598 AS dev-builder

USER root

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ARG DEBIAN_FRONTEND=noninteractive
# Pin mise itself (not just the tools) for reproducible, supply-chain-hardened
# builds. `mise.run` would otherwise grab the latest mise on every build.
ARG MISE_VERSION=v2026.7.3

COPY ./apt-packages /tmp/apt-packages
RUN apt-get update -q \
    && xargs -a /tmp/apt-packages apt-get install -y --no-install-recommends -q \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/apt-packages

RUN localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8 TZ=UTC

# Install the pinned mise binary.
RUN curl -fsSL https://mise.run \
    | MISE_VERSION=${MISE_VERSION} MISE_INSTALL_PATH=/usr/local/bin/mise sh

# Provision the full dev environment into a build-time user's home.
# At runtime the entrypoint hands this home to whatever UID/GID the host
# passes in, so mounted files keep correct ownership.
RUN groupadd -g 1000 devel \
    && useradd -m -u 1000 -g 1000 -G sudo -s /usr/bin/zsh devel \
    && echo "devel ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/devel \
    && chmod 0440 /etc/sudoers.d/devel

# Shallow-clone dotfiles (no history we'd immediately throw away), drop the
# .git dir, and hand the tree to devel so build steps (nvim's lazy-lock.json
# update, `pi install` into ~/.pi) can write through the stow symlinks.
ENV DOTFILES_DIR=/dotfiles
RUN git clone -q --depth=1 https://github.com/leonidgrishenkov/dotfiles.git "${DOTFILES_DIR}" \
    && rm -rf "${DOTFILES_DIR}/.git" \
    && chown -R devel:devel "${DOTFILES_DIR}"

USER devel

ENV HOME=/home/devel TERM=xterm-256color DOTFILES_DIR=/dotfiles
SHELL ["/usr/bin/zsh", "-euo", "pipefail", "-c"]

# ── Cache unit 1: mise tools ─────────────────────────────────────────────────
# Only changes when mise.toml changes (COPY'd just above). Cache + download
# dirs are purged in the same RUN so they never bloat a layer.
COPY --chown=devel:devel ./mise.toml $HOME/.config/mise/config.toml
RUN mise install -y \
    && mise cache clear \
    && rm -rf "${HOME}/.local/share/mise/downloads"

# ── Cache unit 2: dotfiles + zsh plugins ──────────────────────────────
# Stow dotfiles. Plugin repos cloned by the install script (next RUN) have their
# .git dirs stripped there so history never survives into the image.
WORKDIR ${DOTFILES_DIR}
RUN stow atuin delta fsh ipython nvim ruff starship yazi zsh bat prettier ripgrep yamlfmt glow editorconfig pi

# Install ZSH plugins. Kept as a separate step on purpose: combining it with the
# stow step above fails for some reason, so don't merge them. Set the desired
# syntax theme and strip the cloned plugins' .git dirs in the same layer.
WORKDIR ${DOTFILES_DIR}
RUN task install-zsh-plugins \
    && source "${XDG_DATA_HOME}/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh" \
    && fast-theme XDG:catppuccin-frappe \
    && find "${XDG_DATA_HOME}" -maxdepth 2 -type d -name .git -prune -exec rm -rf {} +

# ── Cache unit 3: nvim (Lazy + Mason + treesitter) + bat cache ────────────────
# The heavy, rarely-changing layer. Pre-compile the common treesitter parsers
# now (the builder has gcc) so the slim runtime image doesn't need a compiler
# for the common case. Lazy plugin .git dirs are stripped afterwards.
RUN mise reshim \
    && export PATH="${HOME}/.local/share/mise/shims:${PATH}" \
    && nvim --headless -c 'Lazy sync' -c 'qall' \
    && { nvim --headless -c 'TSInstall lua vim vimdoc query bash python json yaml toml markdown markdown_inline regex html css javascript typescript tsx' -c 'qall' || true ; } \
    && bat cache --build \
    && find "${HOME}/.local/share/nvim/lazy" -type d -name .git -prune -exec rm -rf {} + \
    && rm -rf "${HOME}/.cache/nvim" "${HOME}/.local/state/nvim/log"

# ── Cache unit 4: pi extensions + agent skills ───────────────────────────────
# Independent of nvim and more volatile, so split out: a pi-extension change
# busts only this cheap layer, not the expensive nvim one. `pi install git:`
# clones full repos into ~/.pi/agent/git; strip their .git + npm caches here.
RUN mise reshim \
    && export PATH="${HOME}/.local/share/mise/shims:${PATH}" \
    && pi install git:github.com/leonidgrishenkov/pi-extensions \
    && pi install git:github.com/leonidgrishenkov/agent-skills \
    && find "${HOME}/.pi/agent/git" -type d -name .git -prune -exec rm -rf {} + \
    && rm -rf "${HOME}/.npm" "${HOME}/.cache/npm" "${HOME}/.cache/pip"

# ─────────────────────────────────────────────────────────────────────────────
# Slim runtime stage: no build-essential, just the runtime apt set plus the
# pre-provisioned home and the mise binary.
# ─────────────────────────────────────────────────────────────────────────────
FROM docker.io/debian@sha256:01a723bf5bfb21b9dda0c9a33e0538106e4d02cce8f557e118dd61259553d598 AS runtime

USER root

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ARG DEBIAN_FRONTEND=noninteractive

# Runtime apt set = build set minus build-essential (no compiler in the image).
COPY ./apt-packages /tmp/apt-packages
RUN apt-get update -q \
    && grep -v -E '^build-essential=' /tmp/apt-packages | xargs -r apt-get install -y --no-install-recommends -q \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/apt-packages

RUN localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8 TZ=UTC \
    HOME=/home/devel TERM=xterm-256color DOTFILES_DIR=/dotfiles

# Recreate the devel account with the same UID/GID as the builder so the copied
# home keeps correct ownership. We don't create the home dir (the COPY below
# does); the entrypoint remaps this account to the host ids at runtime.
RUN groupadd -g 1000 devel \
    && useradd -u 1000 -g 1000 -G sudo -s /usr/bin/zsh -d /home/devel devel \
    && echo "devel ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/devel \
    && chmod 0440 /etc/sudoers.d/devel

# Bring across the pinned mise binary and the fully provisioned home + dotfiles.
COPY --from=dev-builder /usr/local/bin/mise /usr/local/bin/mise
COPY --from=dev-builder /home/devel /home/devel
COPY --from=dev-builder /dotfiles /dotfiles

COPY --chmod=755 entrypoint.sh /entrypoint.sh

# Back to root so the entrypoint can adjust the runtime user before dropping
# privileges with gosu.
USER root
WORKDIR /home/devel

SHELL ["/bin/bash", "-c"]
ENTRYPOINT ["/entrypoint.sh"]
CMD ["zsh"]
