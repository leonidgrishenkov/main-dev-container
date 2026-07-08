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
    && mise install --system --yes

CMD ["zsh"]
