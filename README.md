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

# Build

The image is built in two stages:

- **`dev-builder`** — installs `build-essential`, compiles everything (mise
  tools, nvim plugins + treesitter parsers, zsh plugins, pi extensions) into
  `/home/devel`, and strips caches/`.git` history inside each layer.
- **`runtime`** — a slim final image with only the runtime apt set (no
  `build-essential`) plus the pinned `mise` binary and the fully provisioned
  `/home/devel` copied across.

Notable build properties:

- **mise is pinned** via the `MISE_VERSION` build arg (default `v2026.7.3`),
  so `mise.run` doesn't grab the latest mise on every build. Override with
  `docker build --build-arg MISE_VERSION=vX.Y.Z`.
- **Dotfiles are shallow-cloned** (`--depth=1`) and their `.git` is dropped in
  the same layer.
- **Caches are cleaned in the layer that creates them** — `mise cache clear`,
  `~/.local/share/mise/downloads`, npm/pip caches, Lazy plugin `.git` dirs, and
  `pi install git:` `.git` dirs never survive into a layer.
- **Tool installs are grouped into cache-friendly units** so a change to the pi
  extensions doesn't re-run the expensive nvim `Lazy sync` step.

> [!IMPORTANT]
> `build-essential` is **not** in the runtime image, so there is no C compiler
> available at runtime. Common treesitter parsers are pre-compiled during the
> build; opening a file whose parser isn't pre-compiled will log a `cc: command
> not found` warning (treesitter just won't be used for that language — it's
> non-fatal). If you need arbitrary runtime parser compilation or Mason tools
> that build from source, add `gcc`/`build-essential` back to the runtime apt
> set in the final stage.

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
