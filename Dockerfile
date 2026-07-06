# debian:trixie-20251103
FROM docker.io/debian@sha256:01a723bf5bfb21b9dda0c9a33e0538106e4d02cce8f557e118dd61259553d598

USER root

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ARG DEBIAN_FRONTEND=noninteractive

COPY ./apt-packages /tmp/apt-packages
COPY --chmod=755 entrypoint.sh /entrypoint.sh

RUN apt-get update -q \
    && xargs -a /tmp/apt-packages apt-get install -y --no-install-recommends -q \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && rm /tmp/apt-packages

RUN localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8 TZ=UTC

RUN curl -s https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh

# Provision the full dev environment into a build-time user's home.
# At runtime the entrypoint hands this home to whatever UID/GID the host
# passes in, so mounted files keep correct ownership.
RUN groupadd -g 1000 devel \
    && useradd -m -u 1000 -g 1000 -G sudo -s /usr/bin/zsh devel \
    && echo "devel ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/devel \
    && chmod 0440 /etc/sudoers.d/devel

USER devel

ENV HOME=/home/devel TERM=xterm-256color DOTFILES_DIR=/dotfiles
SHELL ["/usr/bin/zsh", "-euo", "pipefail", "-c"]

# Install tools with mise.
COPY --chown=devel:devel ./mise.toml $HOME/.config/mise/config.toml

RUN mise install -y

# Stow dotfiles.
RUN git clone -q https://github.com/leonidgrishenkov/dotfiles.git ${DOTFILES_DIR}
WORKDIR ${DOTFILES_DIR}
RUN stow atuin delta fsh ipython nvim ruff starship yazi zsh bat prettier ripgrep yamlfmt glow editorconfig pi

# Install ZSH plugins. I do this in separate step cuz in other case it fails for some reason.
RUN source ${DOTFILES_DIR}/scripts/deb/install/zsh-plugins.sh

# Set desired ZSH syntax theme.
RUN source $XDG_DATA_HOME/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh \
    && fast-theme XDG:catppuccin-frappe

# Install lazyvim plugins, mason tools and treesitter parsers.
RUN  mise reshim \
    && export PATH="$HOME/.local/share/mise/shims:$PATH" \
    && nvim --headless -c 'Lazy sync' -c "qall" \
    && bat cache --build

# Back to root so the entrypoint can adjust the runtime user before dropping
# privileges with gosu.
USER root
WORKDIR /home/devel

SHELL ["/bin/bash", "-c"]
ENTRYPOINT ["/entrypoint.sh"]
CMD ["zsh"]
