# debian:trixie-20251103
FROM docker.io/debian@sha256:01a723bf5bfb21b9dda0c9a33e0538106e4d02cce8f557e118dd61259553d598

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
USER root

COPY --chmod=755 entrypoint.sh /entrypoint.sh

RUN apt-get update \
    && apt-get install -y --no-install-recommends sudo curl vim gnupg \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["/entrypoint.sh"]

SHELL ["/bin/bash", "-c"]

