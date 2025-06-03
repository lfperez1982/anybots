#!/bin/bash

set -euo pipefail

# Determine if the environment is an LXC container
is_lxc=false
if grep -q container=lxc /proc/1/environ 2>/dev/null; then
    is_lxc=true
fi

# If running in an LXC container, prompt for a new username
if $is_lxc; then
    read -rp "Enter the new username: " new_user
    if id "$new_user" &>/dev/null; then
        echo "User '$new_user' already exists. Skipping creation."
    else
        adduser "$new_user"
        usermod -aG sudo "$new_user"
    fi
fi

# Update and upgrade the system
apt update && apt upgrade -y

# Install required packages
apt install -y ntp curl gnupg sudo ufw unattended-upgrades speedtest-cli \
    fail2ban git python3 openssh-server dnsutils htop net-tools iputils-ping

# Append aliases and bash completion to .bashrc for all users
for home_dir in /home/* /root; do
    bashrc="$home_dir/.bashrc"
    {
        echo "alias ll='ls \$LS_OPTIONS -l'"
        echo "alias docker-upgrade='docker compose pull && docker compose up -d --force-recreate && docker image prune -a'"
        echo "[ -f /etc/bash_completion ] && . /etc/bash_completion"
    } >> "$bashrc"
done

# Set capability to allow ping in LXC containers
if $is_lxc; then
    setcap cap_net_raw+p /bin/ping
fi

# Install Docker using the official convenience script
curl -fsSL https://get.docker.com | sh

# Add the new user to the docker group if in LXC
if $is_lxc; then
    usermod -aG docker "$new_user"
fi

# Create the /docker directory
mkdir -p /docker

# Create the 'updateme' script
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

# Make the 'updateme' script executable
chmod +x /usr/local/bin/updateme
