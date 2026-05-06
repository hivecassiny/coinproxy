#!/bin/sh
#
# CoinProxy — Interactive Installer
# https://github.com/hivecassiny/coinproxy
#
set -e

REPO="hivecassiny/coinproxy"
INSTALL_DIR="/usr/local/bin"
SERVICE_DIR="/etc/systemd/system"
BIN_NAME="coinproxy"
CONFIG_DIR="/etc/coinproxy"

# 仓库 main 分支根目录的 VERSION 文件总是指向最新发布版本，
# install.sh 自身不烧死版本号——这样脚本只发一次。
VERSION_URL="https://raw.githubusercontent.com/${REPO}/main/VERSION"
BIN_BASE_URL="https://raw.githubusercontent.com/${REPO}/main/bin"

# ─── Colors ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

IS_OPENWRT=false

print_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║          CoinProxy Installer             ║"
    echo "  ║      Multi-coin Stratum proxy            ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${RESET}"
}

info()    { echo -e "  ${GREEN}[✓]${RESET} $1"; }
warn()    { echo -e "  ${YELLOW}[!]${RESET} $1"; }
error()   { echo -e "  ${RED}[✗]${RESET} $1"; }
step()    { echo -e "\n  ${CYAN}${BOLD}▸ $1${RESET}"; }
prompt()  { echo -en "  ${BOLD}$1${RESET}"; }

# ─── HTTP fetch helper（curl 优先，wget 兜底，含 BusyBox/OpenWrt 兼容） ───
http_fetch() {
    # $1 = url, $2 = output path（- 为 stdout）
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$out" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$out" "$url"
    else
        error "Neither curl nor wget found. Please install one."
        exit 1
    fi
}

# ─── Detect Arch ──────────────────────────────────────────────────
detect_arch() {
    local os arch
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)

    if [ "$os" != "linux" ]; then
        error "Unsupported OS: $os (Linux only)"
        exit 1
    fi

    case "$arch" in
        x86_64|amd64)    arch="amd64"  ;;
        aarch64|arm64)   arch="arm64"  ;;
        armv7l|armhf)    arch="arm"    ;;
        mipsel|mipsle)   arch="mipsle" ;;
        *)               error "Unsupported architecture: $arch (supported: amd64/arm64/arm/mipsle)"; exit 1 ;;
    esac

    DETECTED_OS="$os"
    DETECTED_ARCH="$arch"
    PLATFORM="${os}-${arch}"

    if [ -f /etc/openwrt_release ]; then
        IS_OPENWRT=true
    fi
}

# ─── Resolve latest version ───────────────────────────────────────
resolve_version() {
    if [ -n "$COINPROXY_VERSION" ]; then
        VERSION="$COINPROXY_VERSION"
        return
    fi
    VERSION=$(http_fetch "$VERSION_URL" - 2>/dev/null | tr -d ' \r\n\t')
    if [ -z "$VERSION" ]; then
        error "Failed to fetch latest VERSION from $VERSION_URL"
        exit 1
    fi
    info "Latest version: ${BOLD}${VERSION}${RESET}"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# ─── Download Binary ──────────────────────────────────────────────
download_bin() {
    local url="$1" dest="$2"
    step "Downloading ${BIN_NAME}-${PLATFORM} ${VERSION}…"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --progress-bar -o "$dest" "$url" || { error "Download failed"; exit 1; }
    elif command -v wget >/dev/null 2>&1; then
        if wget --help 2>&1 | grep -q 'show-progress'; then
            wget -q --show-progress -O "$dest" "$url" || { error "Download failed"; exit 1; }
        else
            wget -O "$dest" "$url" || { error "Download failed"; exit 1; }
        fi
    fi
    chmod +x "$dest"
    info "Saved to ${dest}"
}

verify_sha256() {
    local file="$1" url="$2"
    local expected actual
    expected=$(http_fetch "$url" - 2>/dev/null | awk '{print $1}' | tr -d ' \r\n\t')
    if [ -z "$expected" ]; then
        warn "Could not fetch sha256 from $url; skipping verification"
        return
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$file" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
    else
        warn "No sha256sum/shasum tool; skipping verification"
        return
    fi
    if [ "$expected" != "$actual" ]; then
        error "SHA256 mismatch! expected=$expected got=$actual"
        rm -f "$file"
        exit 1
    fi
    info "SHA256 verified"
}

# ─── Install ──────────────────────────────────────────────────────
install_bin() {
    step "Installing CoinProxy (${PLATFORM} ${VERSION})"
    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

    local url="${BIN_BASE_URL}/${VERSION}/${BIN_NAME}-${PLATFORM}"
    local sha_url="${url}.sha256"
    local dest="${INSTALL_DIR}/${BIN_NAME}"

    download_bin "$url" "$dest"
    verify_sha256 "$dest" "$sha_url"

    echo ""
    local DEFAULT_LISTEN=":8088"
    echo -e "  ${DIM}Web UI listen address (e.g. :8088 or 192.168.1.10:8088)${RESET}"
    prompt "Web listen [${DEFAULT_LISTEN}]: "
    read -r WEB_LISTEN < /dev/tty || WEB_LISTEN=""
    WEB_LISTEN="${WEB_LISTEN:-$DEFAULT_LISTEN}"
    # 用户填了纯端口号（如 "8088"）补一个冒号，net.Listen 才能识别
    case "$WEB_LISTEN" in
        *:*) ;;
        ''|*[!0-9]*) ;;
        *) WEB_LISTEN=":${WEB_LISTEN}" ;;
    esac

    # 首次安装写一个最小 config.yaml；如果用户已经有就不动
    if [ ! -f "${CONFIG_DIR}/config.yaml" ]; then
        cat > "${CONFIG_DIR}/config.yaml" <<YAML
web:
  listen: "${WEB_LISTEN}"
  language: "en"
log:
  level: "info"
data:
  dir: "${CONFIG_DIR}/data"
security:
  allow_external_miners: true
YAML
        info "Wrote ${CONFIG_DIR}/config.yaml"
    else
        info "${CONFIG_DIR}/config.yaml already exists; preserved"
    fi
    mkdir -p "${CONFIG_DIR}/data" "${CONFIG_DIR}/coins"

    if [ "$IS_OPENWRT" = true ]; then
        install_openwrt_service
    elif command -v systemctl >/dev/null 2>&1; then
        install_systemd_service
    else
        echo ""
        info "Run manually:"
        echo -e "    ${BIN_NAME} -config ${CONFIG_DIR}"
    fi

    echo ""
    info "Open http://<this-host>${WEB_LISTEN%%:*}:${WEB_LISTEN##*:} to set up the admin account."
}

install_systemd_service() {
    step "Creating systemd service…"
    cat > "${SERVICE_DIR}/${BIN_NAME}.service" <<UNIT
[Unit]
Description=CoinProxy multi-coin Stratum proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/${BIN_NAME} -config ${CONFIG_DIR}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable "$BIN_NAME"
    systemctl start "$BIN_NAME" || true
    sleep 1
    if systemctl is-active "$BIN_NAME" >/dev/null 2>&1; then
        info "Service started"
    else
        warn "Service installed but failed to start. Recent logs:"
        echo ""
        journalctl -u "$BIN_NAME" --no-pager -n 10 2>/dev/null || systemctl status "$BIN_NAME" --no-pager 2>/dev/null || true
    fi
    echo ""
    echo -e "  ${DIM}Manage with:${RESET}"
    echo -e "    systemctl status ${BIN_NAME}"
    echo -e "    systemctl restart ${BIN_NAME}"
    echo -e "    journalctl -u ${BIN_NAME} -f"
}

install_openwrt_service() {
    step "Creating OpenWrt procd service…"
    cat > "/etc/init.d/${BIN_NAME}" <<INITD
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99
STOP=01

start_service() {
    procd_open_instance
    procd_set_param command ${INSTALL_DIR}/${BIN_NAME} -config ${CONFIG_DIR}
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
INITD
    chmod +x "/etc/init.d/${BIN_NAME}"
    "/etc/init.d/${BIN_NAME}" enable
    "/etc/init.d/${BIN_NAME}" start || true
    sleep 1
    info "Service created and enabled on boot"
    echo ""
    echo -e "  ${DIM}Manage with:${RESET}"
    echo -e "    /etc/init.d/${BIN_NAME} {start|stop|restart}"
    echo -e "    logread -e ${BIN_NAME}"
}

# ─── Update ───────────────────────────────────────────────────────
update_bin() {
    step "Updating CoinProxy…"
    if [ ! -f "${INSTALL_DIR}/${BIN_NAME}" ]; then
        warn "Not installed. Run install first."
        return
    fi

    local url="${BIN_BASE_URL}/${VERSION}/${BIN_NAME}-${PLATFORM}"
    local sha_url="${url}.sha256"
    local tmp="${INSTALL_DIR}/${BIN_NAME}.new"

    download_bin "$url" "$tmp"
    verify_sha256 "$tmp" "$sha_url"

    local was_running=false
    if [ "$IS_OPENWRT" = true ]; then
        if [ -f "/etc/init.d/${BIN_NAME}" ]; then
            "/etc/init.d/${BIN_NAME}" stop 2>/dev/null && was_running=true || true
        fi
    elif command -v systemctl >/dev/null 2>&1 && systemctl is-active "$BIN_NAME" >/dev/null 2>&1; then
        was_running=true
        systemctl stop "$BIN_NAME"
    fi

    mv -f "$tmp" "${INSTALL_DIR}/${BIN_NAME}"
    chmod +x "${INSTALL_DIR}/${BIN_NAME}"
    info "Binary replaced"

    if [ "$was_running" = true ]; then
        if [ "$IS_OPENWRT" = true ]; then
            "/etc/init.d/${BIN_NAME}" start
        else
            systemctl start "$BIN_NAME"
        fi
        info "Service restarted"
    fi
}

# ─── Uninstall ────────────────────────────────────────────────────
uninstall_bin() {
    step "Uninstalling CoinProxy…"

    if [ "$IS_OPENWRT" = true ]; then
        if [ -f "/etc/init.d/${BIN_NAME}" ]; then
            "/etc/init.d/${BIN_NAME}" stop 2>/dev/null || true
            "/etc/init.d/${BIN_NAME}" disable 2>/dev/null || true
            rm -f "/etc/init.d/${BIN_NAME}"
            info "Removed OpenWrt service"
        fi
    elif command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active "$BIN_NAME" >/dev/null 2>&1; then
            systemctl stop "$BIN_NAME"
            info "Stopped ${BIN_NAME}"
        fi
        if [ -f "${SERVICE_DIR}/${BIN_NAME}.service" ]; then
            systemctl disable "$BIN_NAME" 2>/dev/null || true
            rm -f "${SERVICE_DIR}/${BIN_NAME}.service"
            info "Removed systemd unit"
        fi
        systemctl daemon-reload
    fi

    if [ -f "${INSTALL_DIR}/${BIN_NAME}" ]; then
        rm -f "${INSTALL_DIR}/${BIN_NAME}"
        info "Removed ${INSTALL_DIR}/${BIN_NAME}"
    fi

    echo ""
    prompt "Also remove config + data in ${CONFIG_DIR}? [y/N]: "
    read -r RM_DATA < /dev/tty || RM_DATA=""
    case "$RM_DATA" in
        [yY]*) rm -rf "$CONFIG_DIR"; info "Removed ${CONFIG_DIR}" ;;
        *)     warn "Config preserved in ${CONFIG_DIR}" ;;
    esac

    info "Uninstall complete"
}

# ─── Status ───────────────────────────────────────────────────────
show_status() {
    step "CoinProxy Status"
    echo ""

    if [ -f "${INSTALL_DIR}/${BIN_NAME}" ]; then
        local v
        v=$("${INSTALL_DIR}/${BIN_NAME}" -version 2>/dev/null | awk '{print $2}')
        echo -e "  Binary:  ${GREEN}installed${RESET}  (${INSTALL_DIR}/${BIN_NAME}${v:+, ${v}})"
    else
        echo -e "  Binary:  ${DIM}not installed${RESET}"
    fi

    if [ "$IS_OPENWRT" = true ]; then
        if [ -f "/etc/init.d/${BIN_NAME}" ]; then
            if "/etc/init.d/${BIN_NAME}" status >/dev/null 2>&1; then
                echo -e "  Service: ${GREEN}running${RESET}"
            else
                echo -e "  Service: ${YELLOW}stopped${RESET}"
            fi
        else
            echo -e "  Service: ${DIM}not configured${RESET}"
        fi
    elif command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active "$BIN_NAME" >/dev/null 2>&1; then
            echo -e "  Service: ${GREEN}running${RESET}"
        elif [ -f "${SERVICE_DIR}/${BIN_NAME}.service" ]; then
            echo -e "  Service: ${YELLOW}stopped${RESET}"
        else
            echo -e "  Service: ${DIM}not configured${RESET}"
        fi
    fi

    echo ""
    echo -e "  Platform: ${BOLD}${PLATFORM}${RESET}"
    if [ "$IS_OPENWRT" = true ]; then
        echo -e "  System:   ${BOLD}OpenWrt${RESET}"
    fi
    echo -e "  Config:   ${CONFIG_DIR}"
}

svc_start()   { _svc start; }
svc_stop()    { _svc stop; }
svc_restart() { _svc restart; }

_svc() {
    local action="$1"
    if [ "$IS_OPENWRT" = true ]; then
        if [ ! -f "/etc/init.d/${BIN_NAME}" ]; then error "Service not installed"; exit 1; fi
        "/etc/init.d/${BIN_NAME}" "$action" && info "${BIN_NAME} ${action}ed" || error "Failed to ${action}"
    else
        if ! command -v systemctl >/dev/null 2>&1; then error "systemd not available"; exit 1; fi
        if [ ! -f "${SERVICE_DIR}/${BIN_NAME}.service" ]; then error "Service not installed"; exit 1; fi
        systemctl "$action" "$BIN_NAME" && info "${BIN_NAME} ${action}ed" || error "Failed to ${action}"
    fi
}

svc_logs() {
    if [ "$IS_OPENWRT" = true ]; then
        if command -v logread >/dev/null 2>&1; then
            logread -f -e "$BIN_NAME"
        else
            error "logread not available"; exit 1
        fi
    else
        if ! command -v journalctl >/dev/null 2>&1; then error "journalctl not available"; exit 1; fi
        journalctl -u "$BIN_NAME" -f --no-pager -n 50
    fi
}

# ─── Menu ─────────────────────────────────────────────────────────
main_menu() {
    print_banner
    detect_arch
    info "Detected platform: ${BOLD}${PLATFORM}${RESET}"
    if [ "$IS_OPENWRT" = true ]; then
        info "Detected system:   ${BOLD}OpenWrt${RESET}"
    fi
    resolve_version
    echo ""

    echo -e "  ${BOLD}Select an option:${RESET}"
    echo ""
    echo -e "    ${CYAN}1)${RESET}  Install"
    echo -e "    ${CYAN}2)${RESET}  Update"
    echo -e "    ${CYAN}3)${RESET}  Uninstall"
    echo -e "    ${DIM}────────────────────${RESET}"
    echo -e "    ${CYAN}4)${RESET}  Start"
    echo -e "    ${CYAN}5)${RESET}  Stop"
    echo -e "    ${CYAN}6)${RESET}  Restart"
    echo -e "    ${CYAN}7)${RESET}  View Logs"
    echo -e "    ${DIM}────────────────────${RESET}"
    echo -e "    ${CYAN}8)${RESET}  Show Status"
    echo -e "    ${CYAN}0)${RESET}  Exit"
    echo ""
    prompt "Enter choice [0-8]: "
    read -r choice < /dev/tty

    case "$choice" in
        1) check_root; install_bin ;;
        2) check_root; update_bin ;;
        3) check_root; uninstall_bin ;;
        4) check_root; svc_start ;;
        5) check_root; svc_stop ;;
        6) check_root; svc_restart ;;
        7) svc_logs ;;
        8) show_status ;;
        0) echo "  Bye."; exit 0 ;;
        *) error "Invalid choice"; exit 1 ;;
    esac

    echo ""
    info "Done!"
    echo ""
}

case "${1:-}" in
    install)   detect_arch; resolve_version; check_root; install_bin ;;
    update)    detect_arch; resolve_version; check_root; update_bin ;;
    uninstall) detect_arch; check_root; uninstall_bin ;;
    start)     detect_arch; check_root; svc_start ;;
    stop)      detect_arch; check_root; svc_stop ;;
    restart)   detect_arch; check_root; svc_restart ;;
    logs)      detect_arch; svc_logs ;;
    status)    detect_arch; show_status ;;
    *)         main_menu ;;
esac
