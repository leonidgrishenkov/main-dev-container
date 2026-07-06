# About

This is a main image based on Debian Trixie for development purposes with some apps pre-installed.

# How to run container

Run with your host identity so mounted files keep correct ownership:

```sh
docker run -it --rm \
    ghcr.io/leonidgrishenkov/main-dev-container:1.1.2 \
    zsh
```

