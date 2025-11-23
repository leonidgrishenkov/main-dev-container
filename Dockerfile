# debian:trixie-20251103
FROM docker.io/debian@sha256:01a723bf5bfb21b9dda0c9a33e0538106e4d02cce8f557e118dd61259553d598 AS base

USER root

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive

COPY ./apt-packages /tmp/apt-packages

RUN apt-get update \
    && xargs -a /tmp/apt-packages apt-get install -y --no-install-recommends \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && rm /tmp/apt-packages

RUN localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8

ENV LANG=en_US.UTF-8
ENV TZ=UTC

RUN curl -s https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh

RUN groupadd -g 1000 devs \
    && useradd -m -u 1000 -G sudo,devs -s /usr/bin/zsh dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev \
    && chmod 0440 /etc/sudoers.d/dev

USER dev

ENV HOME=/home/dev
ENV TERM=xterm-256color

SHELL ["/usr/bin/zsh", "-euo", "pipefail", "-c"]

RUN git clone -q https://github.com/leonidgrishenkov/dotfiles.git $HOME/dotfiles

WORKDIR $HOME/dotfiles
RUN stow atuin delta fsh git ipython nvim ruff sqlfluff starship yazi zsh bat btop lazygit prettier ripgrep yamlfmt

# Install tools with mise.
COPY --chown=dev:devs ./mise.toml $HOME/.config/mise/config.toml
RUN mise install

# Add mise shims to PATH so tools are available in subsequent RUN commands
ENV PATH="$HOME/.local/share/mise/shims:$PATH"

# Install ZSH plugins. I do this in separate step cuz in other case it fails for some reason.
RUN source $HOME/dotfiles/scripts/deb/install/zsh-plugins.sh

# Set desired ZSH syntax theme.
RUN source $XDG_DATA_HOME/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh \
    && fast-theme XDG:catppuccin-frappe

# Install lazyvim plugins, mason tools and treesitter parsers.
RUN mise exec -- nvim --headless -c 'Lazy! sync' -c "qall"

# BUG: for some reason zsh can't find bat at this point
# RUN bat cache --build

WORKDIR /home/dev

SHELL ["/usr/bin/zsh", "-c"]
