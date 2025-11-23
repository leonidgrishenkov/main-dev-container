# Dockerfile Optimization Guide

## Key Optimizations Applied

### 1. **BuildKit Cache Mounts** (`--mount=type=cache`)

Cache mounts persist data between builds, dramatically speeding up rebuilds:

```dockerfile
# APT cache - avoids re-downloading packages
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install ...

# Mise cache - reuses downloaded tools
RUN --mount=type=cache,target=/home/dev/.local/share/mise,uid=1000,gid=1000 \
    mise install

# Neovim plugins - reuses mason/lazy/treesitter downloads
RUN --mount=type=cache,target=/home/dev/.cache,uid=1000,gid=1000 \
    nvim --headless -c 'Lazy! sync' -c "qall"
```

**Impact**: Rebuilds can be 5-10x faster after the first build.

### 2. **Layer Order Optimization**

Reordered operations from least-to-most frequently changed:

**Original Order** (problems):
```
apt packages → locale → mise → user → dotfiles clone → stow → mise install → plugins → nvim
                                         ↑
                        Changes here invalidate everything after
```

**Optimized Order**:
```
apt packages → locale → mise → user → mise.toml + mise install → dotfiles clone → stow → plugins → nvim
                                       ↑                           ↑
                        Rarely changes (stable)      More frequently changes
```

**Benefit**: Changing dotfiles no longer rebuilds mise tools.

### 3. **Multi-Stage Build Benefits**

The `Dockerfile.multistage` version separates concerns into stages:

- **system-setup**: Base OS and packages
- **tool-builder**: Mise tool installation
- **dotfiles-setup**: Dotfiles configuration
- **final**: Shell and editor plugins

**Advantages**:
- Can target specific stages during development: `docker build --target tool-builder`
- Better layer organization and debugging
- Can potentially use different base images per stage (though not needed here)

### 4. **BuildKit Syntax**

Added `# syntax=docker/dockerfile:1.4` to enable modern BuildKit features.

**Required for**:
- Cache mounts
- Better build performance
- Parallel builds

## Comparison Table

| Feature | Original | Optimized | Multi-Stage |
|---------|----------|-----------|-------------|
| Cache mounts | ❌ | ✅ | ✅ |
| Layer ordering | ❌ | ✅ | ✅ |
| Build stages | ❌ | ❌ | ✅ |
| Rebuild speed | Baseline | 5-10x faster | 5-10x faster |
| Debugging | Good | Good | Excellent |
| Complexity | Low | Low | Medium |

## Build Time Comparison

Estimated build times (after first build):

| Scenario | Original | Optimized | Multi-Stage |
|----------|----------|-----------|-------------|
| No changes | ~5min | ~10sec | ~10sec |
| mise.toml change | ~8min | ~2min | ~2min |
| dotfiles change | ~8min | ~3min | ~3min |
| apt-packages change | ~10min | ~5min | ~5min |

## How to Use

### Enable BuildKit

```bash
# Method 1: Environment variable
export DOCKER_BUILDKIT=1
docker build -t my-dev-container .

# Method 2: Docker CLI flag
docker build --progress=plain -t my-dev-container .

# Method 3: Docker Compose (add to docker-compose.yml)
version: "3.8"
services:
  dev:
    build:
      context: .
      dockerfile: Dockerfile.optimized
```

### Build with Optimized Dockerfile

```bash
# Use the optimized single-stage version
docker build -f Dockerfile.optimized -t my-dev-container .

# Use the multi-stage version
docker build -f Dockerfile.multistage -t my-dev-container .

# Target a specific stage (multi-stage only)
docker build -f Dockerfile.multistage --target tool-builder -t my-dev-tools .
```

### Clear Cache (if needed)

```bash
# Clear build cache
docker builder prune

# Clear specific cache mount
docker builder prune --filter type=exec.cachemount
```

## Additional Optimization Ideas

### 1. Pin Dotfiles to Specific Commit

Replace:
```dockerfile
git clone -q https://github.com/leonidgrishenkov/dotfiles.git $HOME/dotfiles
```

With:
```dockerfile
# Pin to specific commit for cache stability
ARG DOTFILES_VERSION=abc123
RUN git clone -q https://github.com/leonidgrishenkov/dotfiles.git $HOME/dotfiles \
    && cd $HOME/dotfiles \
    && git checkout $DOTFILES_VERSION
```

**Benefit**: Rebuild only when you explicitly change `DOTFILES_VERSION`.

### 2. Use .dockerignore

Create `.dockerignore`:
```
.git
.github
*.md
.dockerignore
```

**Benefit**: Faster build context transfer.

### 3. Parallel Tool Installation

If mise supports it, increase parallelism:
```dockerfile
RUN mise config set jobs 8 \
    && mise install
```

### 4. Pre-download Heavy Assets

For nvim plugins that download large binaries (LSPs, formatters):
```dockerfile
# Cache LSP servers separately
RUN --mount=type=cache,target=/home/dev/.local/share/nvim/mason,uid=1000 \
    nvim --headless -c 'MasonInstall lua-language-server' -c "qall"
```

## Which Version to Use?

- **`Dockerfile.optimized`**: Best for most cases. Simple and fast.
- **`Dockerfile.multistage`**: Best if you want to:
  - Build different variants (minimal vs full)
  - Debug specific stages
  - Share common base images

## Monitoring Cache Hit Rates

```bash
# Build with verbose output to see cache hits
docker build --progress=plain -f Dockerfile.optimized . 2>&1 | grep -i "cache\|cached"

# Check build cache size
docker system df -v | grep "Build Cache"
```

## Troubleshooting

### Cache Not Working?

1. Ensure BuildKit is enabled: `DOCKER_BUILDKIT=1`
2. Check syntax directive: `# syntax=docker/dockerfile:1.4`
3. Verify cache permissions (uid/gid for user mounts)

### Build Slower Than Expected?

1. Clear stale cache: `docker builder prune`
2. Check network speed (for downloads)
3. Increase mise jobs: `mise config set jobs 8`

### Permission Errors with Cache Mounts?

Always specify `uid` and `gid` for user caches:
```dockerfile
RUN --mount=type=cache,target=/home/dev/.cache,uid=1000,gid=1000 \
    command-here
```

## References

- [BuildKit Documentation](https://docs.docker.com/build/buildkit/)
- [Dockerfile Best Practices](https://docs.docker.com/develop/develop-images/dockerfile_best-practices/)
- [Cache Mounts](https://docs.docker.com/build/cache/optimize/#use-cache-mounts)
