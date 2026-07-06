# About

A ready-to-go development image based on Debian Trixie. It bundles a full
environment provisioned at build time — [mise](https://mise.jdx.dev)-managed
tools (Node, Neovim, ripgrep, fzf, bat, eza, starship, lazygit, atuin, and
more), dotfiles, ZSH plugins, and LazyVim with Mason tools and Treesitter
parsers.

At runtime the container remaps its built-in `devel` user to whatever host
UID/GID you pass in, so bind-mounted files keep the correct ownership while the
pre-built environment stays intact. Privileges are dropped from root to that
user with `gosu`.

# How to run container

Run with your host identity so mounted files keep correct ownership:

```sh
docker run -it --rm --init \
    -e USER_ID=$(id -u) \
    -e GROUP_ID=$(id -g) \
    -e USERNAME=$(whoami) \
    -v "$PWD":/home/devel/work \
    -w /home/devel/work \
    ghcr.io/leonidgrishenkov/main-dev-container:latest \
    zsh
```

> [!NOTE]
> `--init` runs a small init process as PID 1 to reap zombies and forward
> signals cleanly. If your host UID/GID is already `1000:1000`, the env vars are
> optional — the container remaps only when the requested ids differ, so the
> common case is instant.

Run with the default `devel` user (UID/GID 1000):

```sh
docker run -it --rm --init \
    -v "$PWD":/home/devel/work \
    -w /home/devel/work \
    ghcr.io/leonidgrishenkov/main-dev-container:latest \
    zsh
```
