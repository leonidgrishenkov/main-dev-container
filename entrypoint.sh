#!/bin/bash
set -euo pipefail

# The image is provisioned at build time for the "devel" user (UID/GID 1000),
# whose home holds mise tools, dotfiles, nvim plugins, etc. At runtime we remap
# that account to the host UID/GID so bind-mounted files keep correct ownership
# while the full pre-built environment stays intact.
BUILD_USER=devel

# Get UID/GID/username from environment or use defaults.
USER_ID=${USER_ID:-1000}
GROUP_ID=${GROUP_ID:-1000}
USERNAME=${USERNAME:-$BUILD_USER}

CURRENT_UID=$(id -u "$BUILD_USER")
CURRENT_GID=$(id -g "$BUILD_USER")
PRIMARY_GROUP=$(id -gn "$BUILD_USER")
HOME_DIR=$(getent passwd "$BUILD_USER" | cut -d: -f6)

echo "entrypoint: Requested UID: $USER_ID, GID: $GROUP_ID, USERNAME: $USERNAME"

NEED_CHOWN=0

# Remap the primary group's GID if needed.
if [ "$GROUP_ID" != "$CURRENT_GID" ]; then
    if getent group "$GROUP_ID" >/dev/null 2>&1; then
        # Target GID already exists: make it the user's primary group.
        TARGET_GROUP=$(getent group "$GROUP_ID" | cut -d: -f1)
        usermod -g "$GROUP_ID" "$BUILD_USER"
        echo "entrypoint: Set primary group of $BUILD_USER to existing $TARGET_GROUP ($GROUP_ID)"
    else
        groupmod -g "$GROUP_ID" "$PRIMARY_GROUP"
        echo "entrypoint: Changed group $PRIMARY_GROUP GID $CURRENT_GID -> $GROUP_ID"
    fi
    NEED_CHOWN=1
fi

# Remap the user's UID if needed.
if [ "$USER_ID" != "$CURRENT_UID" ]; then
    if id -u "$USER_ID" >/dev/null 2>&1; then
        echo "entrypoint: WARNING: UID $USER_ID already exists as $(id -nu "$USER_ID"); keeping $BUILD_USER at $CURRENT_UID" >&2
    else
        usermod -u "$USER_ID" "$BUILD_USER"
        echo "entrypoint: Changed user $BUILD_USER UID $CURRENT_UID -> $USER_ID"
        NEED_CHOWN=1
    fi
fi

# Rename the account if a different username was requested (home path unchanged).
if [ "$USERNAME" != "$BUILD_USER" ]; then
    usermod -l "$USERNAME" "$BUILD_USER"
    echo "entrypoint: Renamed user $BUILD_USER -> $USERNAME"
else
    USERNAME=$BUILD_USER
fi

# Refresh sudoers entry for the (possibly renamed) user.
rm -f "/etc/sudoers.d/${BUILD_USER}"
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"
chmod 0440 "/etc/sudoers.d/${USERNAME}"

# Re-own the home only when ids actually changed (keeps the common path fast).
if [ "$NEED_CHOWN" -eq 1 ]; then
    echo "entrypoint: Re-owning $HOME_DIR to ${USER_ID}:${GROUP_ID} (one-time)"
    chown -R "${USER_ID}:${GROUP_ID}" "$HOME_DIR"
fi

export HOME="$HOME_DIR"

# Drop privileges with gosu and exec so the command becomes PID 1's child.
echo "entrypoint: Switching to user $USERNAME"
exec gosu "${USER_ID}:${GROUP_ID}" "$@"
