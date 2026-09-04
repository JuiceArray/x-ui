```bash
#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# JuiceArray/x-ui - y-install.sh
#
# 用法：
#   bash y-install.sh <用户名> <密码> <面板端口>
#
# 示例：
#   bash y-install.sh admin 'MyPassword123!' 54321
#
# 可选：
#   XUI_VERSION=0.3.2 bash y-install.sh admin 'password' 54321
# ============================================================

REPO_OWNER="JuiceArray"
REPO_NAME="x-ui"
REPO_BRANCH="main"

INSTALL_DIR="/usr/local/x-ui"
SERVICE_FILE="/etc/systemd/system/x-ui.service"
CLI_FILE="/usr/bin/x-ui"

USERNAME="${1:-}"
PASSWORD="${2:-}"
PANEL_PORT="${3:-}"

XUI_VERSION="${XUI_VERSION:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

log() {
    echo -e "${CYAN}[x-ui]${PLAIN} $*"
}

success() {
    echo -e "${GREEN}[OK]${PLAIN} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${PLAIN} $*"
}

error() {
    echo -e "${RED}[ERROR]${PLAIN} $*" >&2
}

die() {
    error "$*"
    exit 1
}

cleanup() {
    rm -f /tmp/x-ui-download.tar.gz
}

trap cleanup EXIT

# ------------------------------------------------------------
# 参数检查
# ------------------------------------------------------------

usage() {
    cat <<EOF

用法：

  bash y-install.sh <用户名> <密码> <面板端口>

例如：

  bash y-install.sh admin 'MyPassword123!' 54321

也可以指定版本：

  XUI_VERSION=0.3.2 bash y-install.sh admin 'MyPassword123!' 54321

EOF
}

if [[ $# -ne 3 ]]; then
    usage
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    die "必须使用 root 用户运行。"
fi

if [[ -z "$USERNAME" ]]; then
    die "用户名不能为空。"
fi

if [[ -z "$PASSWORD" ]]; then
    die "密码不能为空。"
fi

if ! [[ "$PANEL_PORT" =~ ^[0-9]+$ ]]; then
    die "面板端口必须是数字。"
fi

if (( PANEL_PORT < 1 || PANEL_PORT > 65535 )); then
    die "面板端口必须在 1-65535 范围内。"
fi

# ------------------------------------------------------------
# 检测系统
# ------------------------------------------------------------

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "无法检测系统。"
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"

    case "$OS_ID" in
        ubuntu|debian)
            PKG_MANAGER="apt-get"
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        *)
            die "暂不支持的系统：${OS_ID}"
            ;;
    esac

    log "系统：${OS_ID} ${OS_VERSION}"
}

# ------------------------------------------------------------
# 检测架构
# ------------------------------------------------------------

detect_arch() {
    local machine
    machine="$(uname -m)"

    case "$machine" in
        x86_64|amd64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        s390x)
            ARCH="s390x"
            ;;
        *)
            die "暂不支持的 CPU 架构：${machine}"
            ;;
    esac

    log "架构：${ARCH}"
}

# ------------------------------------------------------------
# 安装基础依赖
# ------------------------------------------------------------

install_dependencies() {
    log "安装基础依赖……"

    if [[ "$PKG_MANAGER" == "apt-get" ]]; then
        export DEBIAN_FRONTEND=noninteractive

        apt-get update -y
        apt-get install -y \
            curl \
            wget \
            tar \
            ca-certificates
    else
        "$PKG_MANAGER" install -y \
            curl \
            wget \
            tar \
            ca-certificates
    fi

    success "基础依赖安装完成"
}

# ------------------------------------------------------------
# 获取版本
# ------------------------------------------------------------

get_version() {
    if [[ -n "$XUI_VERSION" ]]; then
        log "使用指定版本：${XUI_VERSION}"
        return
    fi

    log "获取最新 Release 版本……"

    local api
    api="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"

    XUI_VERSION="$(
        curl -fsSL "$api" |
        grep '"tag_name":' |
        head -n 1 |
        sed -E 's/.*"([^"]+)".*/\1/'
    )"

    [[ -n "$XUI_VERSION" ]] ||
        die "无法获取 ${REPO_OWNER}/${REPO_NAME} 最新版本。"

    log "检测到版本：${XUI_VERSION}"
}

# ------------------------------------------------------------
# 下载 Release
# ------------------------------------------------------------

download_release() {
    local url
    url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${XUI_VERSION}/x-ui-linux-${ARCH}.tar.gz"

    log "下载：${url}"

    rm -f /tmp/x-ui-download.tar.gz

    curl -fL \
        --retry 3 \
        --connect-timeout 15 \
        "$url" \
        -o /tmp/x-ui-download.tar.gz

    [[ -s /tmp/x-ui-download.tar.gz ]] ||
        die "x-ui 安装包下载失败。"

    success "安装包下载完成"
}

# ------------------------------------------------------------
# 安装文件
# ------------------------------------------------------------

install_files() {
    log "安装 x-ui 文件……"

    systemctl stop x-ui 2>/dev/null || true

    rm -rf "$INSTALL_DIR"

    mkdir -p /usr/local

    tar -xzf /tmp/x-ui-download.tar.gz -C /usr/local

    [[ -d "$INSTALL_DIR" ]] ||
        die "解压后没有找到 ${INSTALL_DIR}"

    chmod +x "${INSTALL_DIR}/x-ui" 2>/dev/null || true
    chmod +x "${INSTALL_DIR}/x-ui.sh" 2>/dev/null || true

    if [[ -f "${INSTALL_DIR}/bin/xray-linux-${ARCH}" ]]; then
        chmod +x "${INSTALL_DIR}/bin/xray-linux-${ARCH}"
    fi

    # 使用你 Fork 仓库中的管理脚本，而不是继续下载上游 vaxilu/x-ui。
    local cli_url
    cli_url="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/x-ui.sh"

    log "安装管理命令：${cli_url}"

    curl -fsSL "$cli_url" -o "$CLI_FILE"

    chmod +x "$CLI_FILE"

    success "x-ui 文件安装完成"
}

# ------------------------------------------------------------
# 设置面板
# ------------------------------------------------------------

configure_panel() {
    log "设置面板账号……"

    [[ -x "${INSTALL_DIR}/x-ui" ]] ||
        die "找不到 ${INSTALL_DIR}/x-ui"

    "${INSTALL_DIR}/x-ui" setting \
        -username "$USERNAME" \
        -password "$PASSWORD"

    "${INSTALL_DIR}/x-ui" setting \
        -port "$PANEL_PORT"

    success "面板账号和端口设置完成"
}

# ------------------------------------------------------------
# systemd
# ------------------------------------------------------------

configure_service() {
    if [[ -f "${INSTALL_DIR}/x-ui.service" ]]; then
        cp -f "${INSTALL_DIR}/x-ui.service" "$SERVICE_FILE"
    else
        die "找不到 ${INSTALL_DIR}/x-ui.service"
    fi

    systemctl daemon-reload

    systemctl enable x-ui

    systemctl restart x-ui

    sleep 2

    if systemctl is-active --quiet x-ui; then
        success "x-ui 服务启动成功"
    else
        error "x-ui 服务启动失败"
        systemctl --no-pager --full status x-ui || true
        exit 1
    fi
}

# ------------------------------------------------------------
# 获取服务器 IP
# ------------------------------------------------------------

get_server_ip() {
    SERVER_IP=""

    # 优先获取公网 IPv4
    SERVER_IP="$(
        curl -4 -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || true
    )"

    # 获取不到时尝试本机路由地址
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP="$(
            ip route get 1.1.1.1 2>/dev/null |
            awk '
                {
                    for (i=1; i<=NF; i++) {
                        if ($i == "src") {
                            print $(i+1)
                            exit
                        }
                    }
                }
            '
        )"
    fi

    [[ -n "$SERVER_IP" ]] || SERVER_IP="YOUR_SERVER_IP"
}

# ------------------------------------------------------------
# 输出
# ------------------------------------------------------------

print_result() {
    get_server_ip

    echo
    echo "=============================================="
    echo -e "${GREEN}        x-ui 安装完成${PLAIN}"
    echo "=============================================="
    echo
    echo "版本       : ${XUI_VERSION}"
    echo "服务器 IP  : ${SERVER_IP}"
    echo "面板地址   : http://${SERVER_IP}:${PANEL_PORT}"
    echo "用户名     : ${USERNAME}"
    echo "密码       : ${PASSWORD}"
    echo
    echo "服务状态   : $(systemctl is-active x-ui || true)"
    echo
    echo "管理命令："
    echo "  x-ui"
    echo "  x-ui start"
    echo "  x-ui stop"
    echo "  x-ui restart"
    echo "  x-ui status"
    echo "  x-ui log"
    echo
    echo "=============================================="
}

# ------------------------------------------------------------
# 主流程
# ------------------------------------------------------------

main() {
    echo
    echo "=============================================="
    echo "      JuiceArray/x-ui y-install"
    echo "=============================================="
    echo

    detect_os
    detect_arch
    install_dependencies
    get_version
    download_release
    install_files
    configure_panel
    configure_service
    print_result
}

main "$@"
```
