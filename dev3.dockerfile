# debian:trixie-20251103
FROM docker.io/debian@sha256:01a723bf5bfb21b9dda0c9a33e0538106e4d02cce8f557e118dd61259553d598

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
USER root

COPY ./apt-packages /tmp/apt-packages
COPY --chmod=755 entrypoint.sh /tmp/entrypoint.sh

RUN apt-get update \
    && xargs -a /tmp/apt-packages apt-get install -y --no-install-recommends \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && rm /tmp/apt-packages

RUN localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8

ENV LANG=en_US.UTF-8
ENV TZ=UTC

RUN curl -s https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh

RUN git clone -q https://github.com/leonidgrishenkov/dotfiles.git /dotfiles \
    && chmod 774 /dotfiles
WORKDIR /dotfiles
# RUN stow atuin delta fsh git ipython lazydocker nvim ruff sqlfluff starship yazi zsh bat btop lazygit prettier ripgrep yamlfmt

COPY --chmod=755 ./mise.toml $HOME/.config/mise/config.toml
RUN mise install

# RUN source $HOME/dotfiles/scripts/deb/install/zsh-plugins.sh \
#     && fast-theme XDG:catppuccin-frappe \
#     && bat cache --build

ENV TERM=xterm-256color

ENTRYPOINT ["/entrypoint.sh"]

SHELL ["/usr/bin/zsh", "-c"]
