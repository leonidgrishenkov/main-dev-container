#!/bin/bash
set -euo pipefail

# Get UID/GID/username from environment or use defaults.
USER_ID=${USER_ID:-1000}
GROUP_ID=${GROUP_ID:-1000}
USERNAME=${USERNAME:-devuser}

echo "entrypoint: Starting with UID: $USER_ID, GID: $GROUP_ID"

# Resolve/create the group by GID.
if getent group "$GROUP_ID" >/dev/null 2>&1; then
    GROUP_NAME=$(getent group "$GROUP_ID" | cut -d: -f1)
    echo "entrypoint: Group $GROUP_ID already exists as $GROUP_NAME"
else
    # GID is free. Make sure the target group name is not taken with another GID.
    if getent group "$USERNAME" >/dev/null 2>&1; then
        GROUP_NAME="${USERNAME}_${GROUP_ID}"
    else
        GROUP_NAME="$USERNAME"
    fi
    groupadd -g "$GROUP_ID" "$GROUP_NAME"
    echo "entrypoint: Created group $GROUP_NAME with id $GROUP_ID"
fi

# Resolve/create the user by UID.
if id -u "$USER_ID" >/dev/null 2>&1; then
    USERNAME=$(id -nu "$USER_ID")
    echo "entrypoint: User $USER_ID already exists as $USERNAME"
else
    useradd -u "$USER_ID" -g "$GROUP_ID" -ml -s /bin/bash "$USERNAME"
    echo "entrypoint: Created user $USERNAME with id $USER_ID"
fi

# Grant passwordless sudo.
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"
chmod 0440 "/etc/sudoers.d/${USERNAME}"

# Ensure HOME is set and owned by the user for both new and pre-existing users.
export HOME="/home/${USERNAME}"
if [ ! -d "$HOME" ]; then
    mkdir -p "$HOME"
    chown "$USER_ID:$GROUP_ID" "$HOME"
fi

# Drop privileges with gosu and exec so the command becomes PID 1's child.
echo "entrypoint: Switching to user $USERNAME"
exec gosu "$USER_ID:$GROUP_ID" "$@"
