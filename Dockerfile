# debian:trixie-20251103
FROM docker.io/debian@sha256:01a723bf5bfb21b9dda0c9a33e0538106e4d02cce8f557e118dd61259553d598

USER root

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ARG DEBIAN_FRONTEND=noninteractive

COPY ./apt-packages /tmp/apt-packages
RUN apt-get update -q \
    && xargs -a /tmp/apt-packages apt-get install -y --no-install-recommends -q \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/apt-packages

RUN curl -s https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh

# Provision the full dev environment into a build-time user's home.
# At runtime the entrypoint hands this home to whatever UID/GID the host
# passes in, so mounted files keep correct ownership.
RUN groupadd -g 1000 devel \
    && useradd -m -u 1000 -g 1000 -G sudo -s /usr/bin/zsh devel \
    && echo "devel ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/devel \
    && chmod 0440 /etc/sudoers.d/devel

ENV DOTFILES_DIR=/dotfiles
RUN git clone -q https://github.com/leonidgrishenkov/dotfiles.git "${DOTFILES_DIR}"

USER devel

ENV HOME=/home/devel TERM=xterm-256color DOTFILES_DIR=/dotfiles
SHELL ["/usr/bin/zsh", "-euo", "pipefail", "-c"]

# Install tools with mise.
COPY --chown=devel:devel ./mise.toml $HOME/.config/mise/config.toml

RUN mise install -y

# Stow dotfiles.
WORKDIR ${DOTFILES_DIR}
RUN stow atuin delta fsh ipython nvim ruff starship yazi zsh bat prettier ripgrep yamlfmt glow editorconfig pi

RUN task install-zsh-plugins

# Set desired ZSH syntax theme.
RUN source $XDG_DATA_HOME/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh \
    && fast-theme XDG:catppuccin-frappe

# Install lazyvim plugins, mason tools and treesitter parsers.
RUN mise reshim \
    && export PATH="$HOME/.local/share/mise/shims:$PATH" \
    && nvim --headless -c 'Lazy sync' -c "qall" \
    && bat cache --build \
    && pi install git:github.com/leonidgrishenkov/pi-extensions \
    && pi install git:github.com/leonidgrishenkov/agent-skills

# Back to root so the entrypoint can adjust the runtime user before dropping
# privileges with gosu.
USER root
WORKDIR /home/devel

RUN groupadd -g 1000 devels \
    && useradd -m -u 1000 -G sudo,devels -s /usr/bin/zsh devel \
    && echo "devel ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/devel \
    && chmod 0440 /etc/sudoers.d/devel

USER devel

ENV HOME=/home/devel TERM=xterm-256color
SHELL ["/usr/bin/zsh", "-euo", "pipefail", "-c"]

# Install tools with mise.
COPY --chown=devel:devels ./mise.toml $HOME/.config/mise/config.toml

RUN mise install -y

# Stow dotfiles.
RUN git clone -q https://github.com/leonidgrishenkov/dotfiles.git $HOME/dotfiles
WORKDIR $HOME/dotfiles
RUN stow atuin delta fsh git ipython nvim ruff sqlfluff starship yazi zsh bat btop lazygit prettier ripgrep yamlfmt

# Install ZSH plugins. I do this in separate step cuz in other case it fails for some reason.
RUN source $HOME/dotfiles/scripts/deb/install/zsh-plugins.sh

# Set desired ZSH syntax theme.
RUN source $XDG_DATA_HOME/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh \
    && fast-theme XDG:catppuccin-frappe

# Install lazyvim plugins, mason tools and treesitter parsers.
RUN  mise reshim \
    && export PATH="$HOME/.local/share/mise/shims:$PATH" \
    && nvim --headless -c 'Lazy sync' -c "qall" \
    && bat cache --build

WORKDIR /home/devel
SHELL ["/usr/bin/zsh", "-c"]

ARG DOTFILES_REPO_URL=https://github.com/leonidgrishenkov/dotfiles.git
ENV XDG_DATA_HOME=${HOME}/.local/share
WORKDIR ${DOTFILES_DIR}

RUN git clone -q --depth=1 -b "feat/dev-container-integration" --single-branch ${DOTFILES_REPO_URL} "${DOTFILES_DIR}" \
    && eval "$(mise hook-env)" \
    && task stow:essentials pi:install \
    && bat cache --build \
    && nvim --headless "+Lazy! restore" +qa

WORKDIR ${HOME}
SHELL ["/usr/local/bin/fish"]
CMD ["fish"]
