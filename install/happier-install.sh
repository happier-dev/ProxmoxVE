#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: happier-dev
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://happier.dev

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"

# Used by community-scripts helpers (e.g. motd_ssh in misc/install.func).
APP="Happier"
app="${app:-happier}"
APPLICATION="Happier"
SSH_ROOT="${SSH_ROOT:-no}"
PASSWORD="${PASSWORD:-}"
SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY:-}"

color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

INSTALL_TYPE="${HAPPIER_PVE_INSTALL_TYPE:-devbox}"      # devbox | server_only
SERVE_UI="${HAPPIER_PVE_SERVE_UI:-1}"                  # 1 | 0
AUTOSTART="${HAPPIER_PVE_AUTOSTART:-1}"                # 1 | 0
REMOTE_ACCESS="${HAPPIER_PVE_REMOTE_ACCESS:-none}"     # none | proxy | tailscale
TAILSCALE_AUTHKEY="${HAPPIER_PVE_TAILSCALE_AUTHKEY:-}" # optional
PUBLIC_URL_RAW="${HAPPIER_PVE_PUBLIC_URL:-}"           # required when REMOTE_ACCESS=proxy
TAILSCALE_ENABLE_SERVE="0"
TAILSCALE_HTTPS_URL=""

normalize_url_no_trailing_slash() {
  local v
  v="$(printf '%s' "$1" | tr -d '\r' | xargs || true)"
  v="${v%/}"
  while [[ "$v" == */ ]]; do v="${v%/}"; done
  printf '%s' "$v"
}

PUBLIC_URL="$(normalize_url_no_trailing_slash "$PUBLIC_URL_RAW")"
if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
  if [[ -z "${PUBLIC_URL}" ]]; then
    msg_error "REMOTE_ACCESS=proxy requires HAPPIER_PVE_PUBLIC_URL (public HTTPS URL)."
    exit 1
  fi
  if [[ "${PUBLIC_URL}" != https://* ]]; then
    msg_error "HAPPIER_PVE_PUBLIC_URL must start with https:// (got: ${PUBLIC_URL})"
    exit 1
  fi
fi

msg_info "Installing Dependencies"
$STD apt-get install -y \
  ca-certificates \
  curl \
  git \
  build-essential \
  gnupg \
  python3
msg_ok "Installed Dependencies"

msg_info "Installing Node.js"
NODE_VERSION="24" setup_nodejs
msg_ok "Installed Node.js"

msg_info "Enabling Corepack (yarn)"
if ! command -v corepack >/dev/null 2>&1; then
  msg_error "corepack not found (required for yarn)."
  exit 1
fi
$STD corepack enable
msg_ok "Enabled Corepack"

msg_info "Creating user"
if ! id happier &>/dev/null; then
  $STD useradd -m -s /bin/bash happier
fi
msg_ok "User ready"

SETUP_BIND="loopback"
SERVER_HOST="127.0.0.1"
if [[ "${REMOTE_ACCESS}" == "proxy" || "${REMOTE_ACCESS}" == "none" ]]; then
  SETUP_BIND="lan"
  SERVER_HOST="0.0.0.0"
fi

SETUP_ENV=()
SETUP_ENV+=("HAPPIER_SERVER_HOST=${SERVER_HOST}")
SETUP_ENV+=("HAPPIER_STACK_BIND_MODE=${SETUP_BIND}")
if [[ "${INSTALL_TYPE}" == "server_only" ]]; then
  SETUP_ENV+=("HAPPIER_STACK_DAEMON=0")
fi
if [[ "${SERVE_UI}" != "1" ]]; then
  SETUP_ENV+=("HAPPIER_STACK_SERVE_UI=0")
fi

SETUP_ARGS=()
SETUP_ARGS+=("--profile=selfhost")
SETUP_ARGS+=("--server-flavor=light")
SETUP_ARGS+=("--non-interactive")
SETUP_ARGS+=("--no-auth")
SETUP_ARGS+=("--no-autostart")
SETUP_ARGS+=("--no-start-now")
SETUP_ARGS+=("--bind=${SETUP_BIND}")
if [[ "${SERVE_UI}" != "1" ]]; then
  SETUP_ARGS+=("--no-ui-deps" "--no-ui-build")
fi

msg_info "Installing Happier (hstack setup)"
sudo -u happier -H env "${SETUP_ENV[@]}" \
  npx --yes -p @happier-dev/stack@latest hstack setup "${SETUP_ARGS[@]}" </dev/null
msg_ok "Installed Happier (hstack setup)"

STACK_ENV_FILE="/home/happier/.happier/stacks/main/env"
mkdir -p "$(dirname "$STACK_ENV_FILE")"
touch "$STACK_ENV_FILE"
chown happier:happier "$STACK_ENV_FILE"

set_env_kv() {
  local file="$1" key="$2" value="$3"
  local escaped
  escaped="$(printf '%s' "$value" | sed -e 's/[|&]/\\\\&/g')"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

set_env_kv "$STACK_ENV_FILE" "HAPPIER_SERVER_HOST" "${SERVER_HOST}"
set_env_kv "$STACK_ENV_FILE" "HAPPIER_STACK_BIND_MODE" "${SETUP_BIND}"
if [[ "${INSTALL_TYPE}" == "server_only" ]]; then
  set_env_kv "$STACK_ENV_FILE" "HAPPIER_STACK_DAEMON" "0"
fi
if [[ "${SERVE_UI}" != "1" ]]; then
  set_env_kv "$STACK_ENV_FILE" "HAPPIER_STACK_SERVE_UI" "0"
fi
if [[ "${INSTALL_TYPE}" == "devbox" ]]; then
  set_env_kv "$STACK_ENV_FILE" "HAPPIER_STACK_DAEMON_WAIT_FOR_AUTH" "1"
fi

# Set a best-effort server URL early so autostart/manual start uses it on first boot.
get_lxc_ip
if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
  set_env_kv "$STACK_ENV_FILE" "HAPPIER_STACK_SERVER_URL" "${PUBLIC_URL}"
elif [[ "${REMOTE_ACCESS}" != "tailscale" ]]; then
  set_env_kv "$STACK_ENV_FILE" "HAPPIER_STACK_SERVER_URL" "http://${LOCAL_IP}:3005"
fi

if [[ "${SERVE_UI}" == "1" ]]; then
  msg_info "Building Happier web UI (required to serve UI)"
  sudo -u happier -H /home/happier/.happier-stack/bin/hstack build --no-tauri </dev/null
  msg_ok "Built Happier web UI"
fi

if [[ "${AUTOSTART}" != "1" ]]; then
  msg_info "Starting Happier"
  mkdir -p /home/happier/.happier/logs
  chown -R happier:happier /home/happier/.happier/logs
  sudo -u happier -H bash -lc "
    HAPPIER_NO_BROWSER_OPEN=1 nohup /home/happier/.happier-stack/bin/hstack start --restart </dev/null >/home/happier/.happier/logs/hstack-start.out.log 2>&1 &
  "
  msg_ok "Started Happier"
fi

if [[ "${REMOTE_ACCESS}" == "tailscale" ]]; then
  msg_info "Installing Tailscale"
  ID=$(grep "^ID=" /etc/os-release | cut -d"=" -f2)
  VER=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d"=" -f2)
  curl -fsSL "https://pkgs.tailscale.com/stable/${ID}/${VER}.noarmor.gpg" \
    | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/${ID} ${VER} main" \
    >/etc/apt/sources.list.d/tailscale.list
  $STD apt-get update -qq
  $STD apt-get install -y tailscale
  systemctl enable -q --now tailscaled
  msg_ok "Installed Tailscale"

  if [[ -n "${TAILSCALE_AUTHKEY}" ]]; then
    msg_info "Enrolling Tailscale (pre-auth key)"
    tailscale up --auth-key="${TAILSCALE_AUTHKEY}" >/dev/null 2>&1 || true
    msg_ok "Tailscale enrollment attempted"
    TAILSCALE_ENABLE_SERVE="1"
  fi
fi

if [[ "${AUTOSTART}" == "1" ]]; then
  msg_info "Enabling autostart (systemd system service)"
  HOME=/home/happier \
  HAPPIER_STACK_HOME_DIR=/home/happier/.happier-stack \
  HAPPIER_STACK_ENV_FILE=/home/happier/.happier/stacks/main/env \
  /home/happier/.happier-stack/bin/hstack service install --mode=system --system-user=happier
  msg_ok "Autostart enabled"
fi

if [[ "${REMOTE_ACCESS}" == "tailscale" && "${TAILSCALE_ENABLE_SERVE}" == "1" ]]; then
  msg_info "Enabling Tailscale Serve (best-effort)"
  sudo -u happier -H /home/happier/.happier-stack/bin/hstack tailscale enable >/dev/null 2>&1 || true
  TAILSCALE_HTTPS_URL="$(sudo -u happier -H /home/happier/.happier-stack/bin/hstack tailscale url 2>/dev/null | tail -n 1 | tr -d '\r' || true)"
  if [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
    set_env_kv "$STACK_ENV_FILE" "HAPPIER_STACK_SERVER_URL" "${TAILSCALE_HTTPS_URL}"
  fi
  if [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
    msg_ok "Tailscale Serve enabled"
  else
    msg_ok "Tailscale Serve attempted (no HTTPS URL detected yet)"
  fi
fi

msg_ok "Install complete"

if [[ "${SETUP_BIND}" == "loopback" ]]; then
  echo -e "${INFO}${YW} Access (HTTP, inside container): ${CL}${TAB}${GATEWAY}${BGN}http://127.0.0.1:3005${CL}"
  echo -e "${INFO}${YW} Note:${CL} bind=loopback is not reachable from your LAN."
else
  echo -e "${INFO}${YW} Access (HTTP): ${CL}${TAB}${GATEWAY}${BGN}http://${LOCAL_IP}:3005${CL}"
fi

if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
  echo -e "${INFO}${YW} Access (HTTPS): ${CL}${TAB}${GATEWAY}${BGN}${PUBLIC_URL}${CL}"
else
  echo -e "${INFO}${YW} IMPORTANT: ${CL}For remote web UI access you need HTTPS (Tailscale Serve or reverse proxy)."
fi
if [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
  echo -e "${INFO}${YW} Access (HTTPS): ${CL}${TAB}${GATEWAY}${BGN}${TAILSCALE_HTTPS_URL}${CL}"
elif [[ "${REMOTE_ACCESS}" == "tailscale" ]]; then
  if [[ -z "${TAILSCALE_AUTHKEY}" ]]; then
    echo -e "${INFO}${YW} Tailscale:${CL} enroll it inside the container, then enable Serve:"
    echo -e "${TAB}${GATEWAY}${BGN}tailscale up${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}su - happier -c \"/home/happier/.happier-stack/bin/hstack tailscale enable\"${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}su - happier -c \"/home/happier/.happier-stack/bin/hstack tailscale url\"${CL}"
  elif [[ "${TAILSCALE_ENABLE_SERVE}" == "1" ]]; then
    echo -e "${INFO}${YW} Tailscale Serve:${CL} was attempted but no HTTPS URL was detected yet."
    echo -e "${TAB}${YW}Try again in a minute:${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}su - happier -c \"/home/happier/.happier-stack/bin/hstack tailscale url\"${CL}"
  fi
fi
echo -e "${INFO}${YW} Next steps:${CL}"
echo -e "${TAB}${YW}1)${CL} Configure your Happier app/web to use this server (then sign in/create account)."
echo -e "${TAB}${TAB}${YW}Recommended:${CL} use the mobile app first (easiest way to connect more devices later)."

urlencode_component() {
  python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

CLIENT_SERVER_URL=""
if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
  CLIENT_SERVER_URL="${PUBLIC_URL}"
elif [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
  CLIENT_SERVER_URL="${TAILSCALE_HTTPS_URL}"
elif [[ "${REMOTE_ACCESS}" == "tailscale" ]]; then
  CLIENT_SERVER_URL="<your-tailscale-https-url>"
elif [[ "${SETUP_BIND}" == "loopback" ]]; then
  CLIENT_SERVER_URL="http://127.0.0.1:3005"
else
  CLIENT_SERVER_URL="http://${LOCAL_IP}:3005"
fi

CLIENT_WEBAPP_URL=""
if [[ "${SERVE_UI}" == "1" ]]; then
  if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
    CLIENT_WEBAPP_URL="${PUBLIC_URL}"
  elif [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
    CLIENT_WEBAPP_URL="${TAILSCALE_HTTPS_URL}"
  elif [[ "${REMOTE_ACCESS}" == "tailscale" ]]; then
    CLIENT_WEBAPP_URL=""
  elif [[ "${SETUP_BIND}" == "loopback" ]]; then
    CLIENT_WEBAPP_URL="http://127.0.0.1:3005"
  else
    CLIENT_WEBAPP_URL="http://${LOCAL_IP}:3005"
  fi
else
  CLIENT_WEBAPP_URL="https://app.happier.dev"
fi

echo -e "${TAB}${TAB}${YW}Configure links:${CL}"
if [[ "${CLIENT_SERVER_URL}" == "<"*">" ]]; then
  echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}happier://server?url=${CLIENT_SERVER_URL}${CL}"
  if [[ -n "${CLIENT_WEBAPP_URL}" ]]; then
    echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${CLIENT_WEBAPP_URL}/server?url=${CLIENT_SERVER_URL}&auto=1${CL}"
  fi
else
  CLIENT_SERVER_URL_ENC="$(urlencode_component "${CLIENT_SERVER_URL}")"
  echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}happier://server?url=${CLIENT_SERVER_URL_ENC}${CL}"
  if [[ "${CLIENT_WEBAPP_URL}" == "https://app.happier.dev" && "${CLIENT_SERVER_URL}" != https://* ]]; then
    echo -e "${TAB}${TAB}${TAB}${YW}Web app note:${CL} requires an HTTPS server URL (use Tailscale Serve or reverse proxy)."
  elif [[ -n "${CLIENT_WEBAPP_URL}" ]]; then
    echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}${CLIENT_WEBAPP_URL}/server?url=${CLIENT_SERVER_URL_ENC}&auto=1${CL}"
  fi
fi

if [[ "${REMOTE_ACCESS}" == "tailscale" && -z "${TAILSCALE_HTTPS_URL}" ]]; then
  echo -e "${TAB}${TAB}${YW}After you have your Tailscale HTTPS URL:${CL} re-run these to get the correct links/QR codes:"
  echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}su - happier -c \"/home/happier/.happier-stack/bin/hstack tailscale url\"${CL}"
  echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}su - happier -c \"/home/happier/.happier-stack/bin/hstack auth login --print\"${CL}"
fi

if [[ "${INSTALL_TYPE}" == "devbox" ]]; then
  echo -e "${TAB}${YW}2)${CL} Connect the daemon running in this devbox (run inside the container):"
  echo -e "${TAB}${TAB}${GATEWAY}${BGN}sudo -u happier -H /home/happier/.happier-stack/bin/hstack auth login --method=mobile --no-open${CL}"
  echo -e "${TAB}${YW}3)${CL} After login, restart the stack to start the daemon:"
  if [[ "${AUTOSTART}" == "1" ]]; then
    echo -e "${TAB}${TAB}${GATEWAY}${BGN}sudo -u happier -H /home/happier/.happier-stack/bin/hstack service restart --mode=system${CL}"
  else
    echo -e "${TAB}${TAB}${GATEWAY}${BGN}sudo -u happier -H /home/happier/.happier-stack/bin/hstack start --restart${CL}"
  fi
else
  echo -e "${TAB}${YW}2)${CL} To connect a terminal/daemon from your laptop/desktop:"
  echo -e "${TAB}${TAB}${YW}a)${CL} Add/select this server in your CLI:"
  if [[ "${REMOTE_ACCESS}" == "proxy" ]]; then
    echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}happier server add --server-url ${PUBLIC_URL} --use${CL}"
  elif [[ -n "${TAILSCALE_HTTPS_URL}" ]]; then
    echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}happier server add --server-url ${TAILSCALE_HTTPS_URL} --use${CL}"
  elif [[ "${REMOTE_ACCESS}" == "tailscale" ]]; then
    echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}happier server add --server-url <your-tailscale-https-url> --use${CL}"
  else
    echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}happier server add --server-url http://${LOCAL_IP}:3005 --use${CL}"
  fi
  echo -e "${TAB}${TAB}${YW}b)${CL} Then run:"
  echo -e "${TAB}${TAB}${TAB}${GATEWAY}${BGN}happier auth login${CL}"
fi

motd_ssh
customize
cleanup_lxc
