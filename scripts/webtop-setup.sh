#!/usr/bin/env bash
# Fresh linux webtop box: install the open-source Minds desktop app (latest minds-v* tag)
# under Xvfb + x11vnc + noVNC/websockify, exposed restricted to OPERATOR_IP.
#   webtop-setup.sh <webtop-pub-ip> <operator-ip>
set -euo pipefail
HOST="${1:?usage: webtop-setup.sh <webtop-pub-ip> <operator-ip>}"
OP_IP="${2:?usage: webtop-setup.sh <webtop-pub-ip> <operator-ip>}"
TAG="${TAG:-latest}"
[ "$TAG" = latest ] && TAG="$(git ls-remote --tags --refs https://github.com/imbue-ai/mngr.git 2>/dev/null | sed 's#.*refs/tags/##' | grep -E '^minds-v[0-9]' | sort -V | tail -1)"
USER="studio"
VNC_PORT=5900
WEB_PORT=6080          # noVNC over HTTP
VNC_PASS="${VNC_PASS:-$(openssl rand -base64 12 2>/dev/null | tr -d '/+=' | head -c 12)}"

echo "==> [$HOST] create user $USER + sudo + ssh key"
ssh -o StrictHostKeyChecking=no root@$HOST bash -s "$USER" <<'REMOTE'
set -euo pipefail
U="$1"
id -u "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash "$U"
echo "$U ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$U
mkdir -p /home/$U/.ssh
cp /root/.ssh/authorized_keys /home/$U/.ssh/authorized_keys
chown -R "$U:$U" /home/$U/.ssh
chmod 700 /home/$U/.ssh
REMOTE

echo "==> [$HOST] install Xvfb + x11vnc + websockify + openbox + firewall"
ssh -o StrictHostKeyChecking=no root@$HOST "
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq xvfb x11vnc openbox websockify novnc python3-numpy ufw >/dev/null
# noVNC web dir (Debian ships /usr/share/novnc)
ls /usr/share/novnc >/dev/null 2>&1 || true
"

echo "==> [$HOST] install Minds desktop app @$TAG (as $USER, no-launch)"
ssh -o StrictHostKeyChecking=no $USER@$HOST "
  set -euo pipefail
  if [ ! -d ~/mngr/.git ]; then
    curl -fsSL https://raw.githubusercontent.com/imbue-ai/mngr/main/apps/minds/scripts/install-linux.sh \
      | bash -s -- --version $TAG --install-dir \$HOME/mngr --yes --no-launch --skip-docker
  fi
  # verify launcher
  ls -la ~/.local/bin/minds-desktop
"

echo "==> [$HOST] write VNC password + launch scripts + systemd unit"
ssh -o StrictHostKeyChecking=no $USER@$HOST bash -s "$VNC_PASS" "$VNC_PORT" "$WEB_PORT" <<'REMOTE'
set -euo pipefail
VPASS="$1"; VPORT="$2"; WPORT="$3"
mkdir -p ~/.vnc ~/.local/bin
# x11vnc password file
x11vnc -storepasswd "$VPASS" ~/.vnc/passwd

cat > ~/.local/bin/desktop-session.sh <<'SESSION'
#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
# an Xvfb display for the app
Xvfb :100 -screen 0 1280x800x24 -nolisten tcp &
XVFB_PID=$!
sleep 1
export DISPLAY=:100
# a window manager so the frameless app + any dialogs behave
openbox &
OB_PID=$!
# the Minds desktop app (dev mode from source, against production)
exec "$HOME/.local/bin/minds-desktop"
SESSION
chmod +x ~/.local/bin/desktop-session.sh

cat > ~/.local/bin/vnc-web.sh <<'VNCWEB'
#!/usr/bin/env bash
set -euo pipefail
export DISPLAY=:100
# wait for the X server
for i in $(seq 1 20); do [ -e /tmp/.X100-lock ] && break; sleep 1; done
# x11vnc: bind to all interfaces (firewall restricts who can reach it)
x11vnc -display :100 -rfbport 5900 -rfbauth "$HOME/.vnc/passwd" \
  -localhost -forever -shared -bg -o "$HOME/.vnc/x11vnc.log" -nopw 2>/dev/null || \
x11vnc -display :100 -rfbport 5900 -rfbauth "$HOME/.vnc/passwd" -forever -shared -bg -o "$HOME/.vnc/x11vnc.log"
# noVNC web client over HTTP
websockify -D --web=/usr/share/novnc 0.0.0.0:6080 localhost:5900
VNCWEB
chmod +x ~/.local/bin/vnc-web.sh
echo "scripts written"
REMOTE

echo "==> [$HOST] systemd units (survive reboot)"
ssh -o StrictHostKeyChecking=no root@$HOST bash -s "$USER" <<'REMOTE'
set -euo pipefail
U="$1"
cat > /etc/systemd/system/minds-desktop.service <<SVC
[Unit]
Description=Minds desktop app (Xvfb :100)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$U
ExecStart=/home/$U/.local/bin/desktop-session.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC

cat > /etc/systemd/system/vnc-web.service <<SVC
[Unit]
Description=x11vnc + noVNC webtop
After=minds-desktop.service
Requires=minds-desktop.service

[Service]
Type=simple
User=$U
ExecStart=/home/$U/.local/bin/vnc-web.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable --now minds-desktop.service
sleep 8
systemctl enable --now vnc-web.service
sleep 3
systemctl --no-pager status minds-desktop.service --lines=3 || true
systemctl --no-pager status vnc-web.service --lines=3 || true
REMOTE

echo "==> [$HOST] firewall: allow only $OP_IP to VNC ($VNC_PORT) + webtop ($WEB_PORT)"
ssh -o StrictHostKeyChecking=no root@$HOST "
  ufw --force reset >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow from $OP_IP to any port $VNC_PORT proto tcp >/dev/null
  ufw allow from $OP_IP to any port $WEB_PORT proto tcp >/dev/null
  ufw allow OpenSSH >/dev/null
  ufw --force enable >/dev/null
  ufw status verbose | head -20
"
echo "==> [$HOST] desktop setup complete"
echo "    VNC:  <ip>:$VNC_PORT  (password: $VNC_PASS)"
echo "    Webtop: http://<ip>:$WEB_PORT/vnc.html  (password: $VNC_PASS)"
