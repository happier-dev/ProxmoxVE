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
    # Optional: update Happier CLI binary if installed (devbox installs it by default).
    if command -v happier >/dev/null 2>&1; then
      msg_info "Updating ${APP} CLI (channel: ${channel})"
      happier self update --channel="${channel}" >/dev/null 2>&1 || true
      # Best-effort: restart any installed daemon system services to pick up the new binary.
      systemctl restart 'happier-daemon.*.service' >/dev/null 2>&1 || true
      msg_ok "Updated ${APP} CLI"
    fi
    msg_ok "Updated ${APP}"
    exit
  fi

  # Legacy from-source stack install
  if [[ -x /home/happier/.happier-stack/bin/hstack ]]; then
    local hstack_bin="/home/happier/.happier-stack/bin/hstack"
    local where_json=""
    local stack_home="/home/happier/.happier-stack"
    local stack_env="/home/happier/.happier/stacks/main/env"
    local stack_label="dev.happier.stack"
    local workspace_dir=""

    where_json="$(sudo -u happier -H "${hstack_bin}" where --json 2>/dev/null || true)"
    if [[ -n "${where_json}" ]] && command -v jq >/dev/null 2>&1; then
      _home="$(printf '%s' "${where_json}" | jq -r '.homeDir // empty' 2>/dev/null || true)"
      _env="$(printf '%s' "${where_json}" | jq -r '.envFiles.main.path // empty' 2>/dev/null || true)"
      _label="$(printf '%s' "${where_json}" | jq -r '.stack.label // empty' 2>/dev/null || true)"
      _ws="$(printf '%s' "${where_json}" | jq -r '.workspaceDir // .workspace.dir // .workspace.path // empty' 2>/dev/null || true)"
      [[ -n "${_home}" ]] && stack_home="${_home}"
      [[ -n "${_env}" ]] && stack_env="${_env}"
      [[ -n "${_label}" ]] && stack_label="${_label}"
      [[ -n "${_ws}" ]] && workspace_dir="${_ws}"
    fi

    if [[ -z "${workspace_dir}" ]]; then
      if [[ -d "${stack_home}/workspace/main" ]]; then
        workspace_dir="${stack_home}/workspace/main"
      elif [[ -d "${stack_home}/workspace" ]]; then
        workspace_dir="$(find "${stack_home}/workspace" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1 || true)"
      fi
    fi

    msg_warn "This Happier installation was created using setup-from-source."
    echo
    echo "Repo workspace:"
    if [[ -n "${workspace_dir}" ]]; then
      echo "  ${workspace_dir}"
    else
      echo "  (not detected) expected under: ${stack_home}/workspace/"
    fi
    echo
    echo "Manual update (advanced):"
    echo "  1) Enter the container and switch user:"
    echo "     pct enter <CTID>"
    echo "     su - happier"
    if [[ -n "${workspace_dir}" ]]; then
      echo "  2) Update the repo (fast-forward only):"
      echo "     cd \"${workspace_dir}\""
      echo "     git pull --ff-only"
    else
      echo "  2) Locate the repo and update it:"
      echo "     ls -la \"${stack_home}/workspace\""
      echo "     cd \"${stack_home}/workspace/<name>\""
      echo "     git pull --ff-only"
    fi
    echo "  3) Rebuild/restart:"
    echo "     ${hstack_bin} build --no-tauri   # only if you serve the UI"
    echo "     systemctl restart \"${stack_label}.service\"   # if autostart enabled"
    echo "     ${hstack_bin} start --restart    # if running manually"
    echo
    echo "Config file:"
    echo "  ${stack_env}"
    echo
    msg_ok "No automatic update was applied for setup-from-source installs."
    exit 0
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

  # Happier Stack release channel selection:
  # - legacy install uses npm (@happier-dev/stack@latest|@next)
  # - self-host runtime uses https://happier.dev/self-host(|-preview)
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
    whiptail --backtitle "$BACKTITLE" --title "HAPPIER RELEASE CHANNEL" --radiolist \
      "\nChoose a release channel:\n\n- stable: recommended for production\n- preview: pre-release (newer, less tested)\n\nNote: legacy installs use npm (@happier-dev/stack@latest|@next). Self-host runtime uses happier.dev installers.\n" 20 72 3 \
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
