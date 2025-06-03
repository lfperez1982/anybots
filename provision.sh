#!/bin/bash

set -euo pipefail

LOG_FILE="/var/log/provision.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Determine if running in an LXC container
is_lxc=false
if grep -q container=lxc /proc/1/environ 2>/dev/null; then
    is_lxc=true
fi

# Function to create a new user if it doesn't exist
create_user() {
    local username="$1"
    if id "$username" &>/dev/null; then
        echo "User '$username' already exists. Skipping creation."
    else
        adduser "$username"
        usermod -aG sudo "$username"
    fi
}

# Prompt for a new username if in LXC
if $is_lxc; then
    read -rp "Enter the new username: " new_user
    create_user "$new_user"
fi

# Update and upgrade the system
apt update && apt upgrade -y

# Define common packages
common_packages=(
    ntp
    curl
    gnupg
    sudo
    ufw
    unattended-upgrades
    speedtest-cli
    fail2ban
    git
    python3
    openssh-server
    dnsutils
    htop
    net-tools
)

# Define VM-only packages
vm_only_packages=(
    iputils-ping
    nfs-common
    tmux
)

# Install packages based on environment
if $is_lxc; then
    apt install -y "${common_packages[@]}"
else
    apt install -y "${common_packages[@]}" "${vm_only_packages[@]}"
fi

# Append aliases and bash completion to .bashrc for all users
for home_dir in /home/* /root; do
    bashrc="$home_dir/.bashrc"
    # Ensure the file exists
    touch "$bashrc"
    # Add alias ll if not already present
    if ! grep -q "alias ll=" "$bashrc"; then
        echo "alias ll='ls \$LS_OPTIONS -l'" >> "$bashrc"
    fi
    # Add alias docker-upgrade if not already present
    if ! grep -q "alias docker-upgrade=" "$bashrc"; then
        echo "alias docker-upgrade='docker compose pull && docker compose up -d --force-recreate && docker image prune -a'" >> "$bashrc"
    fi
    # Add bash completion if not already present
    if ! grep -q "bash_completion" "$bashrc"; then
        echo "[ -f /etc/bash_completion ] && . /etc/bash_completion" >> "$bashrc"
    fi
done

# Set capability to allow ping in LXC containers
if $is_lxc; then
    setcap cap_net_raw+p /bin/ping
fi

# Install Docker if not already installed
if command -v docker &>/dev/null; then
    echo "Docker is already installed. Skipping installation."
else
    curl -fsSL https://get.docker.com | sh
fi

# Add the new user to the docker group if in LXC
if $is_lxc; then
    usermod -aG docker "$new_user"
fi

# Create the /docker directory and set ownership
mkdir -p /docker
if $is_lxc; then
    chown "$new_user:$new_user" /docker
fi

# Create the 'updateme' script if it doesn't exist
if [ ! -f /usr/local/bin/updateme ]; then
    cat << 'EOF' > /usr/local/bin/updateme
#!/bin/bash

# Update the system
sudo apt-get update && sudo apt-get upgrade -y

# Navigate to the /docker directory
cd /docker || { echo "Failed to enter /docker directory"; exit 1; }

# Loop through each subdirectory and update Docker services
for dir in */; do
    echo "Updating services in directory: $dir"
    if cd "$dir"; then
        if [ -f "docker-compose.yml" ] || [ -f "compose.yml" ]; then
            if docker compose pull && \
               docker compose up -d --force-recreate && \
               docker image prune -f; then
                echo "Successfully updated services in $dir"
            else
                echo "Error occurred while updating services in $dir"
            fi
        else
            echo "No docker-compose.yml or compose.yml found in $dir"
        fi
        cd ..
    else
        echo "Failed to enter directory: $dir"
    fi
done

echo "All services have been processed."
EOF

    chmod +x /usr/local/bin/updateme
else
    echo "'updateme' script already exists. Skipping creation."
fi
