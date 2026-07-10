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

# Install mise and its packages system-wide
ARG MISE_VERSION=v2026.7.3
COPY --chown=root:root --chmod=644 ./mise.toml /etc/mise/config.toml
RUN curl -fsSL https://mise.run \
    | MISE_VERSION=${MISE_VERSION} MISE_INSTALL_PATH=/usr/local/bin/mise sh \
    && chmod 755 /etc/mise \
    && mise install --system --yes \
    && ln -sf "$(mise where aqua:fish-shell/fish-shell)/fish" /usr/local/bin/fish \
    && echo /usr/local/bin/fish >> /etc/shells \
    && mise cache clear

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

USER ${USERNAME}

ARG DOTFILES_REPO_URL=https://github.com/leonidgrishenkov/dotfiles.git
ARG XDG_DATA_HOME=${HOME}/.local/share
WORKDIR ${DOTFILES_DIR}

RUN git clone -q --depth=1 -b "main" --single-branch ${DOTFILES_REPO_URL} "${DOTFILES_DIR}" \
    && eval "$(mise hook-env)" \
    && task stow:essentials pi:install nvim:install \
    && bat cache --build

WORKDIR ${HOME}
SHELL ["/usr/local/bin/fish"]
CMD ["fish"]
