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

  # Self-host runtime install (production)
  if [[ -f /opt/happier/self-host-state.json ]]; then
    local channel
    channel="$(jq -r '.channel // "stable"' /opt/happier/self-host-state.json 2>/dev/null || echo stable)"
    msg_info "Updating ${APP} self-host runtime (channel: ${channel})"
    if command -v hstack >/dev/null 2>&1; then
      hstack self-host update --mode=system --channel="${channel}"
    else
      msg_error "hstack not found on PATH. Try reinstalling self-host runtime."
      exit 1
    fi
    msg_ok "Updated ${APP}"
    exit
  fi

  # Legacy from-source stack install
  if [[ -x /home/happier/.happier-stack/bin/hstack ]]; then
    msg_error "There is no update function for the legacy from-source install yet."
    exit
  fi

  msg_error "No ${APP} installation found."
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
  HAPPIER_PVE_HSTACK_CHANNEL="${HAPPIER_PVE_HSTACK_CHANNEL:-stable}"
  HAPPIER_PVE_HSTACK_PACKAGE="${HAPPIER_PVE_HSTACK_PACKAGE:-}"

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

  while true; do
    HAPPIER_PVE_REMOTE_ACCESS=$(
      whiptail --backtitle "$BACKTITLE" --title "HAPPIER" --radiolist \
        "\nServer URL for QR/deep links (choose how other devices will reach this server):\n" 16 72 3 \
        "tailscale" "Tailscale HTTPS URL (recommended; works from your phone)" ON \
        "proxy" "Custom HTTPS URL (reverse proxy; works from your phone)" OFF \
        "none" "LAN-only (HTTP; not reachable off-LAN)" OFF \
        3>&1 1>&2 2>&3
    ) || exit_script

    if [[ "$HAPPIER_PVE_REMOTE_ACCESS" == "proxy" ]]; then
      HAPPIER_PVE_PUBLIC_URL=$(
        whiptail --backtitle "$BACKTITLE" --title "CUSTOM HTTPS URL" --inputbox \
          "\nEnter the HTTPS URL of your reverse proxy.\n\nExample:\n  https://happier.example.com\n\nThis URL will be embedded in QR codes/deep links and must be reachable from your phone.\n" 18 72 \
          3>&1 1>&2 2>&3
      ) || exit_script
      break
    fi

    if [[ "$HAPPIER_PVE_REMOTE_ACCESS" == "tailscale" ]]; then
      var_tun="yes"
      if (whiptail --backtitle "$BACKTITLE" --title "TAILSCALE" --yesno \
        "\nProvide a Tailscale pre-auth key now?\n\nRecommended: use an ephemeral, one-time key.\n\nIf you skip this, the installer will still install Tailscale and you can run 'tailscale up' later inside the container.\n" 14 72); then
        HAPPIER_PVE_TAILSCALE_AUTHKEY=$(
          whiptail --backtitle "$BACKTITLE" --title "TAILSCALE" --passwordbox \
            "\nPaste your Tailscale pre-auth key (optional; will not be saved).\n\nTip: leave blank to skip and enroll manually later.\n" 14 72 \
            3>&1 1>&2 2>&3
        ) || exit_script
      fi
      break
    fi

    # LAN-only. Confirm to reduce confusion around QR codes not working off-LAN.
    local lan_ui_note=""
    if [[ "${HAPPIER_PVE_SERVE_UI}" == "1" ]]; then
      lan_ui_note="\nIf you enabled serving the web UI, it will work only on your LAN/VPN.\nFor access from outside your LAN, you still need HTTPS (Tailscale Serve or a reverse proxy).\n"
    fi
    if (whiptail --backtitle "$BACKTITLE" --title "LAN-ONLY (HTTP)" --yesno \
      "\nLAN-only mode will embed an HTTP LAN URL in QR/deep links (example: http://<container-lan-ip>:3005).\n\nThis works only when your phone/laptop are on the same LAN/VPN.\n${lan_ui_note}\nContinue with LAN-only mode?\n" 20 72); then
      break
    fi
  done

  # HStack release channel selection (controls which npm dist-tag/version is installed via npx).
  local hstack_default="stable"
  if [[ -n "${HAPPIER_PVE_HSTACK_PACKAGE}" ]]; then
    if [[ "${HAPPIER_PVE_HSTACK_PACKAGE}" == "@happier-dev/stack@next" || "${HAPPIER_PVE_HSTACK_PACKAGE}" == "@happier-dev/stack@preview" ]]; then
      hstack_default="preview"
    elif [[ "${HAPPIER_PVE_HSTACK_PACKAGE}" == "@happier-dev/stack@latest" ]]; then
      hstack_default="stable"
    else
      hstack_default="custom"
    fi
  else
    if [[ "${HAPPIER_PVE_HSTACK_CHANNEL}" == "preview" ]]; then
      hstack_default="preview"
    fi
  fi

  HAPPIER_PVE_HSTACK_CHANNEL=$(
    whiptail --backtitle "$BACKTITLE" --title "HSTACK RELEASE CHANNEL" --radiolist \
      "\nChoose which HStack release channel to install via npm:\n\n- stable: @happier-dev/stack@latest\n- preview: @happier-dev/stack@next\n- custom: pin a version or use another spec\n" 18 72 3 \
      "stable" "Stable (recommended)  (@happier-dev/stack@latest)" $([[ "$hstack_default" == "stable" ]] && echo ON || echo OFF) \
      "preview" "Preview / pre-release (@happier-dev/stack@next)" $([[ "$hstack_default" == "preview" ]] && echo ON || echo OFF) \
      "custom" "Custom (version or package spec)" $([[ "$hstack_default" == "custom" ]] && echo ON || echo OFF) \
      3>&1 1>&2 2>&3
  ) || exit_script

  if [[ "${HAPPIER_PVE_HSTACK_CHANNEL}" == "stable" ]]; then
    HAPPIER_PVE_HSTACK_PACKAGE="@happier-dev/stack@latest"
  elif [[ "${HAPPIER_PVE_HSTACK_CHANNEL}" == "preview" ]]; then
    HAPPIER_PVE_HSTACK_PACKAGE="@happier-dev/stack@next"
  else
    local default_pkg="${HAPPIER_PVE_HSTACK_PACKAGE:-@happier-dev/stack@latest}"
    HAPPIER_PVE_HSTACK_PACKAGE=$(
      whiptail --backtitle "$BACKTITLE" --title "CUSTOM HSTACK PACKAGE" --inputbox \
        "\nEnter the npm package spec to install (examples):\n\n  @happier-dev/stack@1.2.3\n  @happier-dev/stack@latest\n  @happier-dev/stack@next\n\nThis will be used as: npx -p <spec> hstack setup\n" 18 72 \
        "${default_pkg}" \
        3>&1 1>&2 2>&3
    ) || exit_script
    HAPPIER_PVE_HSTACK_PACKAGE="$(echo "${HAPPIER_PVE_HSTACK_PACKAGE}" | xargs)"
    if [[ -z "${HAPPIER_PVE_HSTACK_PACKAGE}" ]]; then
      msg_error "Custom HStack package spec cannot be empty."
      exit_script
    fi
  fi

  export HAPPIER_PVE_INSTALL_TYPE
  export HAPPIER_PVE_SERVE_UI
  export HAPPIER_PVE_AUTOSTART
  export HAPPIER_PVE_REMOTE_ACCESS
  export HAPPIER_PVE_TAILSCALE_AUTHKEY
  export HAPPIER_PVE_PUBLIC_URL
  export HAPPIER_PVE_HSTACK_CHANNEL
  export HAPPIER_PVE_HSTACK_PACKAGE
}

if command -v pveversion >/dev/null 2>&1; then
  app_questions
fi

start
build_container
description

msg_ok "Completed successfully!\n"
