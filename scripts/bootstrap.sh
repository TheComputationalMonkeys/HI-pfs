#!/bin/bash
# HI-pfs Bootstrap Script — Master launcher with remote GitHub-sourced scripts

set -e

REPO="https://raw.githubusercontent.com/compmonks/HI-pfs/main/scripts"

read -p "Enter your Pi admin username (default: compmonks): " IPFS_USER
IPFS_USER="${IPFS_USER:-compmonks}"

read -p "Enter your email for node alerts and sync reports: " EMAIL
read -p "Enter a hostname for this node (e.g. ipfs-node-00): " NODE_NAME
read -p "Enter your desired Cloudflare Tunnel subdomain (e.g. ipfs0): " TUNNEL_SUBDOMAIN
read -p "Enter your Cloudflare domain (e.g. example.com): " CLOUDFLARE_DOMAIN
read -p "Is this the first (primary) node in the network? (y/n): " IS_PRIMARY_NODE
read -p "Enter minimum SSD size in GB (default: 1000): " MIN_SIZE_GB
MIN_SIZE_GB="${MIN_SIZE_GB:-1000}"

export IPFS_USER EMAIL NODE_NAME TUNNEL_SUBDOMAIN CLOUDFLARE_DOMAIN IS_PRIMARY_NODE MIN_SIZE_GB

ENVFILE="/etc/hi-pfs.env"
echo "Saving persistent environment to $ENVFILE"
sudo tee "$ENVFILE" > /dev/null <<EOF
IPFS_USER=$IPFS_USER
EMAIL=$EMAIL
NODE_NAME=$NODE_NAME
TUNNEL_SUBDOMAIN=$TUNNEL_SUBDOMAIN
CLOUDFLARE_DOMAIN=$CLOUDFLARE_DOMAIN
IS_PRIMARY_NODE=$IS_PRIMARY_NODE
MIN_SIZE_GB=$MIN_SIZE_GB
EOF

# Set hostname
echo "🔧 Setting hostname to $NODE_NAME..."
sudo hostnamectl set-hostname "$NODE_NAME"

# Optional firewall
echo "🛡️ Setting up UFW firewall rules (optional)..."
sudo apt install -y ufw
sudo ufw allow ssh
sudo ufw allow 80
sudo ufw allow 443
sudo ufw --force enable

# Optional fail2ban
sudo apt install -y fail2ban
sudo systemctl enable fail2ban
sudo systemctl start fail2ban

# Download and run setup scripts
SCRIPTS=(cloudflared.sh setup.sh self-maintenance.sh watchdog.sh diagnostics.sh)

for script in "${SCRIPTS[@]}"; do
  echo "⬇️ Downloading $script from GitHub..."
  if [[ "$script" == "self-maintenance.sh" || "$script" == "watchdog.sh" || "$script" == "diagnostics.sh" ]]; then
    mkdir -p "/home/$IPFS_USER/scripts"
    curl -fsSL "$REPO/$script" -o "/home/$IPFS_USER/scripts/$script"
    chmod +x "/home/$IPFS_USER/scripts/$script"
    chown $IPFS_USER:$IPFS_USER "/home/$IPFS_USER/scripts/$script"
  else
    curl -fsSL "$REPO/$script" -o "/tmp/$script"
    chmod +x "/tmp/$script"
    bash "/tmp/$script"
    rm -f "/tmp/$script"
  fi
  echo "✅ $script processed."
done

# Systemd timers
TIMER_PATH="/etc/systemd/system/self-maintenance.timer"
SERVICE_PATH="/etc/systemd/system/self-maintenance.service"
sudo tee "$SERVICE_PATH" > /dev/null <<EOF
[Unit]
Description=HI-pfs Self-Maintenance Service
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENVFILE
ExecStart=/home/$IPFS_USER/scripts/self-maintenance.sh
User=$IPFS_USER
EOF

sudo tee "$TIMER_PATH" > /dev/null <<EOF
[Unit]
Description=Runs HI-pfs Self-Maintenance Daily

[Timer]
OnCalendar=03:30
Persistent=true

[Install]
WantedBy=timers.target
EOF

WD_TIMER="/etc/systemd/system/watchdog.timer"
WD_SERVICE="/etc/systemd/system/watchdog.service"
sudo tee "$WD_SERVICE" > /dev/null <<EOF
[Unit]
Description=HI-pfs Watchdog Service
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENVFILE
ExecStart=/home/$IPFS_USER/scripts/watchdog.sh
User=$IPFS_USER
EOF

sudo tee "$WD_TIMER" > /dev/null <<EOF
[Unit]
Description=Run watchdog every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable self-maintenance.timer watchdog.timer
sudo systemctl start self-maintenance.timer watchdog.timer

# Alias suggestion
echo "\n💡 Add this to ~/.bashrc to check status:"
echo "alias hi-pfs='bash /home/$IPFS_USER/scripts/diagnostics.sh'"
echo "Then run: source ~/.bashrc"

echo -e "\n✅ HI-pfs bootstrap complete for node '$NODE_NAME'."