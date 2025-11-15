#!/bin/bash
set -e

# # Get UID/GID from environment or use defaults
USER_ID=${USER_ID:-1000}
GROUP_ID=${GROUP_ID:-1000}
USERNAME=${USERNAME:-devuser}

echo "entrypoint: Starting with UID: $USER_ID, GID: $GROUP_ID"

# Create group if it doesn't exist
if ! getent group "$GROUP_ID" >/dev/null 2>&1; then
    groupadd -g "$GROUP_ID" "$USERNAME"
    echo "entrypoint: Created group with id $GROUP_ID"
else
    existing_group=$(getent group "$GROUP_ID" | cut -d: -f1)
    echo "entrypoint: Group $GROUP_ID already exists as $existing_group"
fi

# Create user if it doesn't exist
if ! id -u "$USER_ID" >/dev/null 2>&1; then
    useradd -u "$USER_ID" -g "$GROUP_ID" -ml -s /bin/bash "$USERNAME"
    echo "entrypoint: Created user $USERNAME with id $USER_ID"

    # Add to sudoers
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"
    chmod 0440 "/etc/sudoers.d/${USERNAME}"
else
    existing_user=$(id -nu "$USER_ID")
    echo "entrypoint: User $USER_ID already exists as $existing_user"
    USERNAME=$existing_user

    # Add to sudoers
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"
    chmod 0440 "/etc/sudoers.d/${USERNAME}"
fi

# Switch to user and execute command
echo "entrypoint: Switching to user $USERNAME"
exec sudo -u "#$USER_ID" -g "#$GROUP_ID" "$@"
