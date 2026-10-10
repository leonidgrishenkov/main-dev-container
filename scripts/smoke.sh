#!/usr/bin/env bash
# Smoke test for the devcr image. Asserts the things that actually break: tools
# missing from mise, broken Go binaries, unstowed dotfiles, unrestored nvim
# plugins, the wrong user/shell, and the Go toolchain creeping back in.
#
# Runs inside the image; mount it rather than baking it in:
#   docker run --rm -v "$PWD/scripts/smoke.sh:/opt/smoke.sh:ro" devcr:local bash /opt/smoke.sh
#
# Every check runs; failures are collected and reported together at the end.
set -euo pipefail

MISE_CONFIG=/etc/mise/config.toml
GO_TOOLS=(direnv lazygit fzf shfmt glow task)
# Stowed files that exist in the dotfiles repo. stow folds whole directories into
# one symlink (e.g. ~/.config/fish -> dotfiles/...), so check where the path
# resolves to, not whether the file itself is a symlink.
STOWED=(.config/fish/config.fish .config/nvim/init.lua .config/lazygit/config.yml
    .config/direnv/direnv.toml .config/bat/config)
# mise tool name -> binary, only where they differ. Any other tool is expected to
# provide a binary named after the last segment of its name; a new mise.toml
# entry that does not will fail here until it is mapped.
declare -A BIN_FOR=(
    [neovim]=nvim
    [ripgrep]=rg
    [aqua:fish-shell/fish-shell]=fish
    [aqua:tealdeer-rs/tealdeer]=tldr
)

FAILURES=()
PASSED=0

# check <description> <command...>: run the command, record a failure with its
# output instead of exiting.
check() {
    local desc=$1 out
    shift
    if out=$("$@" 2>&1); then
        PASSED=$((PASSED + 1))
        printf 'ok    %s\n' "$desc"
    else
        out=${out//$'\n'/ | }
        ((${#out} <= 300)) || out="${out:0:300}..."
        FAILURES+=("$desc${out:+: $out}")
        printf 'FAIL  %s\n' "$desc"
    fi
}

runs() { "$1" --version >/dev/null; }

resolves_under() {
    local bin=$1 prefix=$2 path
    path=$(command -v "$bin") || { echo "$bin not on PATH"; return 1; }
    [[ $path == "$prefix"* ]] || { echo "$bin resolves to $path, not under $prefix"; return 1; }
}

stowed() {
    local real
    real=$(realpath -e "$HOME/$1") || return 1
    [[ $real == "$DOTFILES_DIR/"* ]] || { echo "resolves to $real, not into $DOTFILES_DIR"; return 1; }
    [[ $real != "$HOME/$1" ]] || { echo "regular file, not reached through a stow symlink"; return 1; }
}

lazy_restored() {
    local dir=$HOME/.local/share/nvim/lazy
    [[ -n $(ls -A "$dir" 2>/dev/null) ]] || { echo "$dir is missing or empty"; return 1; }
}

nvim_starts_clean() {
    local err
    err=$(cd /tmp && timeout 120 nvim --headless +qa 2>&1 >/dev/null) || { echo "exit $?: $err"; return 1; }
    [[ -z $err ]] || { echo "stderr: $err"; return 1; }
}

go_absent() {
    local where
    if where=$(command -v go); then echo "go on PATH: $where"; return 1; fi
    if where=$(fish -c 'command -v go'); then echo "go on fish PATH: $where"; return 1; fi
    if mise which go >/dev/null 2>&1; then echo "mise still provides go"; return 1; fi
    [[ ! -e /usr/local/share/mise/installs/go ]] || { echo "mise go install dir present"; return 1; }
}

# 1. Every tool in mise.toml is installed, on PATH via mise and runs.
TOOLS=()
while IFS= read -r tool; do TOOLS+=("$tool"); done < <(
    awk '/^\[/ { in_tools = ($0 == "[tools]") }
         in_tools && /^[^#[]/ && /=/ { name = $1; gsub(/"/, "", name); print name }' "$MISE_CONFIG"
)
check "mise.toml lists tools (${#TOOLS[@]})" test "${#TOOLS[@]}" -gt 0
eval "$(mise hook-env -s bash)"
for tool in "${TOOLS[@]}"; do
    bin=${BIN_FOR[$tool]:-${tool##*/}}
    check "mise tool $tool ($bin) is on PATH" resolves_under "$bin" /usr/local/share/mise/installs/
    check "mise tool $tool ($bin) runs" runs "$bin"
done

# 2. The Go CLIs copied from the go-builder stage.
for bin in "${GO_TOOLS[@]}"; do
    check "go-builder binary $bin is on PATH" resolves_under "$bin" /usr/local/bin/
    check "go-builder binary $bin runs" runs "$bin"
done

# 3. Dotfiles are stowed.
check "DOTFILES_DIR is a git checkout" git -C "$DOTFILES_DIR" rev-parse --git-dir
for path in "${STOWED[@]}"; do
    check "\$HOME/$path is stowed from DOTFILES_DIR" stowed "$path"
done

# 4. nvim plugins were restored at build time, and nvim starts without errors.
check "lazy.nvim plugin dir is non-empty" lazy_restored
check "nvim --headless +qa exits 0 with empty stderr" nvim_starts_clean

# 5. Identity and shell.
check "running as devel" test "$(whoami)" = devel
check "SHELL is /usr/local/bin/fish" test "${SHELL:-}" = /usr/local/bin/fish
check "fish is listed in /etc/shells" grep -qx /usr/local/bin/fish /etc/shells
check "fish starts" fish -c true

# 6. The Go toolchain stays out of the final image (multi-stage invariant).
check "go is absent" go_absent

echo
if ((${#FAILURES[@]})); then
    printf '%d passed, %d FAILED:\n' "$PASSED" "${#FAILURES[@]}"
    printf '  - %s\n' "${FAILURES[@]}"
    exit 1
fi
printf 'all %d checks passed\n' "$PASSED"
