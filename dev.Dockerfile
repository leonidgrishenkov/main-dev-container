# debian:trixie-20251103
FROM docker.io/debian@sha256:01a723bf5bfb21b9dda0c9a33e0538106e4d02cce8f557e118dd61259553d598

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
USER root

ARG USER_ID=1000
ARG GROUP_ID=1000
ARG USERNAME=dev

RUN apt-get update \
    && apt-get install -y --no-install-recommends sudo curl vim gnupg \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN if ! getent group ${GROUP_ID}; then groupadd -g ${GROUP_ID} ${USERNAME}; fi \
    && useradd -ml -u ${USER_ID} -g ${GROUP_ID} -s /bin/bash ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME}

USER ${USERNAME}
WORKDIR /home/${USERNAME}

SHELL ["/bin/bash", "-c"]

