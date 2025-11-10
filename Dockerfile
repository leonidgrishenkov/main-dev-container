# debian:trixie-20251103
FROM docker.io/debian@sha256:01a723bf5bfb21b9dda0c9a33e0538106e4d02cce8f557e118dd61259553d598

SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]
USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends sudo curl git ca-certificates zsh locales gpg stow \
    && rm -rf /var/lib/apt/lists/*

RUN localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8
ENV LANG en_US.UTF-8

RUN echo "Installing mise" > /log \
    && curl https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh

RUN groupadd -g 1000 devs \
    && useradd -m -u 1000 -G sudo,devs -s /bin/bash dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev \
    && chmod 0440 /etc/sudoers.d/dev

USER dev
ENV HOME /home/dev

RUN git clone -q https://github.com/leonidgrishenkov/dotfiles.git $HOME/dotfiles

WORKDIR $HOME/dotfiles
RUN echo "Running stow" > /log \
    && stow atuin delta fsh git ipython lazydocker nvim ruff sqlfluff starship yazi zsh bat btop lazygit prettier ripgrep yamlfmt

COPY ./mise.toml /home/dev/.config/mise/config.toml

# TODO: add zsh plugs install here

USER dev
WORKDIR /home/dev
ENV TERM xterm-256color

SHELL ["/usr/bin/zsh", "-c"]
