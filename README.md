# About

This is a light image based on Debian Trixie. When you run a container it automatically creates a user and their group matching the host UID/GID passed via environment variables, so bind-mounted files keep the correct ownership. Privileges are dropped from root to that user with `gosu`.

# How to run container

Run container with host user:

```sh
docker run -it --rm --init \
    -e USER_ID=$(id -u) \
    -e GROUP_ID=$(id -g) \
    -e USERNAME=$(whoami) \
    -v ./src:/app \
    ghcr.io/leonidgrishenkov/main-dev-container:light-0.1.4 \
    /bin/bash
```

> [!note]: `--init` runs a small init process as PID 1 to reap zombies and forward signals cleanly.

Default user and group will be used (see in ./entrypoint.sh file):

```sh
docker run -it --rm --init \
    -v ./src:/app \
    ghcr.io/leonidgrishenkov/main-dev-container:light-0.1.4 \
    /bin/bash
```
