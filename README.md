# About

This is a light image based on Debian Trixie. When you run a container it automatically creates user and their group.

# How to run container

Run container with host user:

```sh
docker run -it --rm \
    -e USER_ID=$(id -u) \
    -e GROUP_ID=$(id -g) \
    -e USERNAME=$(whoami) \
    -v ./src:/app \
    ghcr.io/leonidgrishenkov/main-dev-container:light-0.1.4 \
    /bin/bash
```


Default user and group will be used (see in ./entrypoint.sh file):

```sh
docker run -it --rm \
    -v ./src:/app \
    ghcr.io/leonidgrishenkov/main-dev-container:light-0.1.4 \
    /bin/bash
```
