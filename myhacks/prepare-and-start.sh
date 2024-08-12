#!/bin/bash
set -e

VERBOSE=${VERBOSE:-0}
[ "${VERBOSE}" = "verbose" ] && set -x

source /balena-docker.inc

trap 'balena_docker_stop fail' SIGINT SIGTERM

INSTALL_DIR="/work"

# Create the normal user to be used for bitbake (barys)
getent passwd $BUILDER_UID
if $?; then
  echo "[INFO] User $BUILDER_UID already exists"
  USER="$(id -nu $BUILDER_UID)"
else
  USER="builder"
  echo "[INFO] Creating and setting $USER user $BUILDER_UID:$BUILDER_GID."
  groupadd -g $BUILDER_GID $USER
  if ! cat "/etc/group" | grep docker > /dev/null; then  groupadd docker; fi
  useradd -m -u $BUILDER_UID -g $BUILDER_GID -G docker $USER && newgrp docker
fi

# Make the "$USER" user inherit the $SSH_AUTH_SOCK variable set-up so he can use the host ssh keys for various operations
# (like being able to clone private git repos from within bitbake using the ssh protocol)
echo 'Defaults env_keep += "SSH_AUTH_SOCK"' > /etc/sudoers.d/ssh-auth-sock

# Disable host authenticity check when accessing git repos using the ssh protocol
# (not disabling it will make this script fail because /home/$USER/.ssh/known_hosts file is empty)
mkdir -p /home/$USER/.ssh/
echo "StrictHostKeyChecking no" > /home/$USER/.ssh/config

# Start docker
balena_docker_start
balena_docker_wait

sudo -H -u $USER git config --global user.name "Resin Builder"
sudo -H -u $USER git config --global user.email "buildy@builder.com"
echo "[INFO] The configured git credentials for user $USER are:"
sudo -H -u $USER git config --get user.name
sudo -H -u $USER git config --get user.email

# Start barys with all the arguments requested
echo "[INFO] Running build as $USER user..."
if [ -d "${INSTALL_DIR}/balena-yocto-scripts" ]; then
    sudo -H -u $USER "${INSTALL_DIR}/balena-yocto-scripts/build/barys" $@ &
else
    sudo -H -u $USER "${INSTALL_DIR}/resin-yocto-scripts/build/barys" $@ &
fi
barys_pid=$!
wait $barys_pid || true

balena_docker_stop
exit 0
