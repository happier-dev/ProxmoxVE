#!/usr/bin/env bash
INSTALLER_REPO="${INSTALLER_REPO:-happier-dev/ProxmoxVE}"
INSTALLER_REF="${INSTALLER_REF:-main}"
export INSTALLER_REPO INSTALLER_REF

BUILD_FUNC_URL="https://raw.githubusercontent.com/${INSTALLER_REPO}/${INSTALLER_REF}/misc/build.func"
BUILD_FUNC="$(curl -fsSL "${BUILD_FUNC_URL}")" || {
  echo "Failed to download build.func from: ${BUILD_FUNC_URL}" >&2
  exit 1
}
if [[ -z "${BUILD_FUNC//[[:space:]]/}" ]]; then
  echo "Downloaded build.func is empty: ${BUILD_FUNC_URL}" >&2
  exit 1
fi
source /dev/stdin <<<"${BUILD_FUNC}"
# Copyright (c) 2021-2026 community-scripts ORG
# Author: happier-dev
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://happier.dev

APP="Happier"
var_tags="${var_tags:-ai;devtools}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-32}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -x /home/happier/.happier-stack/bin/hstack ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  msg_error "There is no update function for ${APP}."
  exit
}

function app_questions() {
  local BACKTITLE="Proxmox VE Helper Scripts"

  HAPPIER_PVE_INSTALL_TYPE=""
  HAPPIER_PVE_SERVE_UI="1"
  HAPPIER_PVE_AUTOSTART="1"
  HAPPIER_PVE_REMOTE_ACCESS="none"
  HAPPIER_PVE_TAILSCALE_AUTHKEY=""
  HAPPIER_PVE_PUBLIC_URL=""

  HAPPIER_PVE_INSTALL_TYPE=$(
    whiptail --backtitle "$BACKTITLE" --title "HAPPIER" --radiolist \
      "\nSelect installation type:\n" 12 72 2 \
      "devbox" "Dev box (server-light + daemon) (recommended)" ON \
      "server_only" "Server only (no daemon)" OFF \
      3>&1 1>&2 2>&3
  ) || exit_script

  if (whiptail --backtitle "$BACKTITLE" --title "HAPPIER" --yesno \
    "\nServe the built Happier web UI from this machine?\n\nNote: for remote access, the UI requires HTTPS (Tailscale Serve or your reverse proxy).\n" 12 72); then
    HAPPIER_PVE_SERVE_UI="1"
  else
    HAPPIER_PVE_SERVE_UI="0"
  fi

  if (whiptail --backtitle "$BACKTITLE" --title "HAPPIER" --yesno \
    "\nEnable autostart at boot?\n\nThis installs a systemd system service inside the container.\n" 12 72); then
    HAPPIER_PVE_AUTOSTART="1"
  else
    HAPPIER_PVE_AUTOSTART="0"
  fi

  HAPPIER_PVE_REMOTE_ACCESS=$(
    whiptail --backtitle "$BACKTITLE" --title "HAPPIER" --radiolist \
      "\nRemote access / HTTPS:\n" 14 72 3 \
      "tailscale" "Tailscale (recommended HTTPS URL)" ON \
      "proxy" "I will use my own reverse proxy (HTTPS)" OFF \
      "none" "None (local only)" OFF \
      3>&1 1>&2 2>&3
  ) || exit_script

  if [[ "$HAPPIER_PVE_REMOTE_ACCESS" == "proxy" ]]; then
    HAPPIER_PVE_PUBLIC_URL=$(
      whiptail --backtitle "$BACKTITLE" --title "REVERSE PROXY" --inputbox \
        "\nEnter the public HTTPS URL for your reverse proxy.\n\nExample:\n  https://happier.example.com\n\nThis URL is used for deep links/QR codes and should be reachable from your phone/browser.\n" 18 72 \
        3>&1 1>&2 2>&3
    ) || exit_script
  fi

  if [[ "$HAPPIER_PVE_REMOTE_ACCESS" == "tailscale" ]]; then
    var_tun="yes"
    if (whiptail --backtitle "$BACKTITLE" --title "TAILSCALE" --yesno \
      "\nProvide a Tailscale pre-auth key now?\n\nRecommended: use an ephemeral, one-time key.\n\nIf you skip this, you can run 'tailscale up' later inside the container.\n" 14 72); then
      HAPPIER_PVE_TAILSCALE_AUTHKEY=$(
        whiptail --backtitle "$BACKTITLE" --title "TAILSCALE" --passwordbox \
          "\nPaste your Tailscale pre-auth key (will not be saved):\n" 12 72 \
          3>&1 1>&2 2>&3
      ) || exit_script
    fi
  fi

  export HAPPIER_PVE_INSTALL_TYPE
  export HAPPIER_PVE_SERVE_UI
  export HAPPIER_PVE_AUTOSTART
  export HAPPIER_PVE_REMOTE_ACCESS
  export HAPPIER_PVE_TAILSCALE_AUTHKEY
  export HAPPIER_PVE_PUBLIC_URL
}

if command -v pveversion >/dev/null 2>&1; then
  app_questions
fi

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
if [[ "${HAPPIER_PVE_REMOTE_ACCESS}" == "tailscale" ]]; then
  echo -e "${INFO}${YW} Access (HTTP, inside container):${CL}"
  echo -e "${TAB}${GATEWAY}${BGN}http://127.0.0.1:3005${CL}"
  echo -e "${INFO}${YW} Note:${CL} bind=loopback is not reachable from your LAN."
else
  echo -e "${INFO}${YW} Access (HTTP):${CL}"
  echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:3005${CL}"
fi
if [[ "${HAPPIER_PVE_REMOTE_ACCESS}" == "proxy" && -n "${HAPPIER_PVE_PUBLIC_URL}" ]]; then
  echo -e "${INFO}${YW} Access (HTTPS):${CL}"
  echo -e "${TAB}${GATEWAY}${BGN}${HAPPIER_PVE_PUBLIC_URL}${CL}"
fi
echo -e "${INFO}${YW} IMPORTANT:${CL} The Happier web UI requires HTTPS for remote access (secure context)."
if [[ "${HAPPIER_PVE_REMOTE_ACCESS}" == "tailscale" ]]; then
  echo -e "${TAB}${YW}Tip:${CL} after install, Tailscale should be installed in the container."
  echo -e "${TAB}${YW}If not enrolled yet:${CL} run 'tailscale up' inside the container."
fi
