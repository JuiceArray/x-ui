```bash
#!/usr/bin/env bash

# x-ui 安装 / API 自检版
# 修复：
# 1. 不再向 /usr/bin/x-ui 追加非法 add-vmess case
# 2. 删除重复执行的创建逻辑
# 3. 统一 XUI_USERNAME / XUI_PASSWORD / XUI_PORT
# 4. 正确等待 x-ui 服务
# 5. 使用 /api/login JSON 接口进行 API 自检
# 6. 严格检查 HTTP 状态码及 JSON 返回
# 7. 修复 UUID 生成逻辑
#
# 环境变量：
# XUI_AUTO_CONFIRM=y
# XUI_USERNAME=admin
# XUI_PASSWORD=你的密码
# XUI_PORT=54321

set -u
set -o pipefail

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
plain='\033[0m'

cur_dir="$(pwd)"

log() {
    echo -e "${green}[INFO]${plain} $*"
}

warn() {
    echo -e "${yellow}[WARN]${plain} $*"
}

error() {
    echo -e "${red}[ERROR]${plain} $*" >&2
}

die() {
    error "$*"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

cleanup() {
    :
}

trap cleanup EXIT

# ------------------------------------------------------------
# root
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    die "必须使用 root 用户运行此脚本。"
fi

# ------------------------------------------------------------
# system detection
# ------------------------------------------------------------

detect_system() {
    release=""

    if [[ -f /etc/redhat-release ]]; then
        release="centos"
    elif [[ -f /etc/os-release ]]; then
        . /etc/os-release

        case "${ID:-}" in
            ubuntu)
                release="ubuntu"
                ;;
            debian)
                release="debian"
                ;;
            centos|rhel|rocky|almalinux|ol)
                release="centos"
                ;;
        esac

        if [[ -z "${release}" && "${ID_LIKE:-}" =~ (debian|ubuntu) ]]; then
            release="debian"
        elif [[ -z "${release}" && "${ID_LIKE:-}" =~ (rhel|fedora|centos) ]]; then
            release="centos"
        fi
    fi

    [[ -n "${release}" ]] || die "无法识别当前 Linux 发行版。"

    os_version=""

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        os_version="${VERSION_ID:-}"
    fi

    log "系统：${release}"
    log "版本：${os_version:-unknown}"
}

# ------------------------------------------------------------
# architecture
# ------------------------------------------------------------

detect_arch() {
    local machine
    machine="$(uname -m)"

    case "${machine}" in
        x86_64|amd64)
            arch="amd64"
            ;;
        aarch64|arm64)
            arch="arm64"
            ;;
        s390x)
            arch="s390x"
            ;;
        *)
            die "不支持的 CPU 架构：${machine}"
            ;;
    esac

    log "架构：${arch}"
}

# ------------------------------------------------------------
# 64 bit check
# ------------------------------------------------------------

check_64bit() {
    if [[ "$(getconf LONG_BIT 2>/dev/null)" != "64" ]]; then
        die "当前系统不是 64 位系统。"
    fi
}

# ------------------------------------------------------------
# version check
# ------------------------------------------------------------

version_ge() {
    # version_ge "目标版本" "最低版本"
    printf '%s\n%s\n' "$1" "$2" | sort -V -C
}

check_os_version() {
    case "${release}" in
        ubuntu)
            if [[ -n "${os_version}" ]] && ! version_ge "${os_version}" "16"; then
                die "Ubuntu 版本过低，请使用 Ubuntu 16+。"
            fi
            ;;
        debian)
            if [[ -n "${os_version}" ]] && ! version_ge "${os_version}" "8"; then
                die "Debian 版本过低，请使用 Debian 8+。"
            fi
            ;;
        centos)
            if [[ -n "${os_version}" ]] && ! version_ge "${os_version}" "7"; then
                die "CentOS 版本过低，请使用 CentOS 7+。"
            fi
            ;;
    esac
}

# ------------------------------------------------------------
# package manager
# ------------------------------------------------------------

install_base() {
    log "安装依赖..."

    case "${release}" in
        centos)
            if command_exists dnf; then
                dnf install -y wget curl tar jq ca-certificates
            else
                yum install -y wget curl tar jq ca-certificates
            fi
            ;;
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive

            apt-get update -y

            apt-get install -y \
                wget \
                curl \
                tar \
                jq \
                ca-certificates \
                coreutils
            ;;
        *)
            die "不支持的发行版：${release}"
            ;;
    esac

    command_exists curl || die "curl 安装失败。"
    command_exists wget || die "wget 安装失败。"
    command_exists tar || die "tar 安装失败。"
    command_exists jq || die "jq 安装失败。"

    log "基础依赖安装完成。"
}

# ------------------------------------------------------------
# configuration
# ------------------------------------------------------------

config_after_install() {
    echo
    echo -e "${yellow}========== x-ui 面板配置 ==========${plain}"

    # 自动模式
    if [[ -n "${XUI_AUTO_CONFIRM:-}" ]] &&
       [[ -n "${XUI_USERNAME:-}" ]] &&
       [[ -n "${XUI_PASSWORD:-}" ]] &&
       [[ -n "${XUI_PORT:-}" ]]; then

        config_confirm="${XUI_AUTO_CONFIRM}"
        config_account="${XUI_USERNAME}"
        config_password="${XUI_PASSWORD}"
        config_port="${XUI_PORT}"

        log "检测到全自动配置模式。"

    else
        read -r -p "确认修改 x-ui 账户、密码和端口？[y/n]: " config_confirm

        if [[ "${config_confirm}" =~ ^[Yy]$ ]]; then

            read -r -p "账户名: " config_account

            while [[ -z "${config_account}" ]]; do
                read -r -p "账户名不能为空，请重新输入: " config_account
            done

            read -r -s -p "密码: " config_password
            echo

            while [[ -z "${config_password}" ]]; do
                read -r -s -p "密码不能为空，请重新输入: " config_password
                echo
            done

            read -r -p "面板端口: " config_port

            if ! [[ "${config_port}" =~ ^[0-9]+$ ]] ||
               (( config_port < 1 || config_port > 65535 )); then
                die "面板端口无效：${config_port}"
            fi

        else
            warn "取消修改，继续使用 x-ui 当前配置。"

            return 0
        fi
    fi

    [[ -n "${config_account}" ]] || die "账户名为空。"
    [[ -n "${config_password}" ]] || die "密码为空。"

    if ! [[ "${config_port}" =~ ^[0-9]+$ ]] ||
       (( config_port < 1 || config_port > 65535 )); then
        die "面板端口无效：${config_port}"
    fi

    # 统一变量
    XUI_USERNAME="${config_account}"
    XUI_PASSWORD="${config_password}"
    XUI_PORT="${config_port}"

    export XUI_USERNAME
    export XUI_PASSWORD
    export XUI_PORT

    log "正在修改 x-ui 账户..."

    /usr/local/x-ui/x-ui setting \
        -username "${XUI_USERNAME}" \
        -password "${XUI_PASSWORD}" \
        || die "修改 x-ui 用户名/密码失败。"

    log "正在修改 x-ui 面板端口..."

    /usr/local/x-ui/x-ui setting \
        -port "${XUI_PORT}" \
        || die "修改 x-ui 端口失败。"

    log "x-ui 配置修改完成。"
}

# ------------------------------------------------------------
# get latest version
# ------------------------------------------------------------

get_latest_version() {
    local api
    api="https://api.github.com/repos/vaxilu/x-ui/releases/latest"

    last_version="$(
        curl -fsSL \
            --connect-timeout 10 \
            --max-time 30 \
            "${api}" |
        jq -r '.tag_name // empty'
    )"

    [[ -n "${last_version}" ]] ||
        die "无法获取 x-ui 最新版本。"

    log "检测到最新版本：${last_version}"
}

# ------------------------------------------------------------
# download x-ui
# ------------------------------------------------------------

download_xui() {
    local version="$1"

    local url
    local package

    package="/usr/local/x-ui-linux-${arch}.tar.gz"

    url="https://github.com/vaxilu/x-ui/releases/download/${version}/x-ui-linux-${arch}.tar.gz"

    log "下载 x-ui：${version}"
    log "下载地址：${url}"

    rm -f "${package}"

    wget \
        --no-check-certificate \
        --timeout=30 \
        --tries=3 \
        -O "${package}" \
        "${url}" ||
        die "x-ui 下载失败。"

    [[ -s "${package}" ]] ||
        die "下载文件为空。"
}

# ------------------------------------------------------------
# install x-ui
# ------------------------------------------------------------

install_x_ui() {
    local requested_version="${1:-}"

    systemctl stop x-ui 2>/dev/null || true

    cd /usr/local || die "无法进入 /usr/local。"

    if [[ -n "${requested_version}" ]]; then
        last_version="${requested_version}"
        log "使用指定版本：${last_version}"
    else
        get_latest_version
    fi

    download_xui "${last_version}"

    if [[ -d /usr/local/x-ui ]]; then
        log "删除旧的 /usr/local/x-ui..."
        rm -rf /usr/local/x-ui
    fi

    log "解压 x-ui..."

    tar -zxf "/usr/local/x-ui-linux-${arch}.tar.gz" ||
        die "x-ui 解压失败。"

    rm -f "/usr/local/x-ui-linux-${arch}.tar.gz"

    [[ -d /usr/local/x-ui ]] ||
        die "解压后没有找到 /usr/local/x-ui。"

    cd /usr/local/x-ui || die "无法进入 /usr/local/x-ui。"

    chmod +x x-ui 2>/dev/null || true
    chmod +x x-ui.sh 2>/dev/null || true
    chmod +x "bin/xray-linux-${arch}" 2>/dev/null || true

    [[ -f /usr/local/x-ui/x-ui.service ]] ||
        die "没有找到 x-ui.service。"

    cp -f \
        /usr/local/x-ui/x-ui.service \
        /etc/systemd/system/x-ui.service

    # 注意：
    # 不再 wget 覆盖 /usr/bin/x-ui。
    # 不再向 /usr/bin/x-ui 追加 add-vmess case。
    #
    # 原脚本这里是一个重要错误来源。

    if [[ -f /usr/local/x-ui/x-ui.sh ]]; then
        chmod +x /usr/local/x-ui/x-ui.sh

        ln -sf \
            /usr/local/x-ui/x-ui.sh \
            /usr/bin/x-ui
    fi

    systemctl daemon-reload

    systemctl enable x-ui >/dev/null 2>&1 ||
        die "设置 x-ui 开机启动失败。"

    log "x-ui 文件安装完成。"
}

# ------------------------------------------------------------
# start x-ui
# ------------------------------------------------------------

start_x_ui() {
    log "启动 x-ui..."

    systemctl restart x-ui ||
        die "x-ui 启动失败。"

    sleep 2

    if ! systemctl is-active --quiet x-ui; then
        error "x-ui 服务没有正常运行。"
        echo
        systemctl status x-ui --no-pager -l || true
        echo
        journalctl -u x-ui --no-pager -n 50 || true
        exit 1
    fi

    log "x-ui systemd 服务运行正常。"
}

# ------------------------------------------------------------
# wait panel
# ------------------------------------------------------------

wait_xui_panel() {
    local port="$1"
    local max_wait=35
    local waited=0

    log "等待 x-ui Web 服务启动：127.0.0.1:${port}"

    while (( waited < max_wait )); do

        if curl \
            -sS \
            --connect-timeout 1 \
            --max-time 2 \
            -o /dev/null \
            "http://127.0.0.1:${port}/login"; then

            log "x-ui Web 服务已经就绪。"
            return 0
        fi

        sleep 1
        waited=$((waited + 1))
    done

    error "等待 x-ui Web 服务超过 ${max_wait} 秒。"

    echo
    echo "========== systemctl status =========="
    systemctl status x-ui --no-pager -l || true

    echo
    echo "========== x-ui journal =========="
    journalctl -u x-ui --no-pager -n 50 || true

    return 1
}

# ------------------------------------------------------------
# API login diagnostic
# ------------------------------------------------------------

api_login_test() {
    local panel_port="$1"
    local username="$2"
    local password="$3"

    local base_url
    local response_file
    local http_code
    local body
    local success
    local message
    local token

    base_url="http://127.0.0.1:${panel_port}"
    response_file="$(mktemp)"

    log "测试 x-ui /api/login..."

    http_code="$(
        curl \
            -sS \
            --connect-timeout 5 \
            --max-time 15 \
            -o "${response_file}" \
            -w '%{http_code}' \
            -X POST \
            "${base_url}/api/login" \
            -H 'Content-Type: application/json' \
            --data "$(jq -cn \
                --arg username "${username}" \
                --arg password "${password}" \
                '{username:$username,password:$password}')"
    )"

    body="$(cat "${response_file}")"
    rm -f "${response_file}"

    if [[ "${http_code}" != "200" ]]; then
        error "/api/login HTTP 状态异常：${http_code}"
        echo "响应：${body}"
        return 1
    fi

    if ! echo "${body}" | jq empty >/dev/null 2>&1; then
        error "/api/login 返回的不是合法 JSON。"
        echo "响应：${body}"
        return 1
    fi

    success="$(echo "${body}" | jq -r '.success // false')"
    message="$(echo "${body}" | jq -r '.msg // .message // empty')"
    token="$(echo "${body}" | jq -r '.data.token // empty')"

    if [[ "${success}" != "true" ]]; then
        error "x-ui API 登录失败。"
        [[ -n "${message}" ]] && echo "API message: ${message}"
        return 1
    fi

    # 某些版本返回 token，某些版本认证方式不同。
    if [[ -n "${token}" ]]; then
        log "API 登录成功，服务器返回 token。"
    else
        log "API 登录成功，但当前版本没有返回 token。"
    fi

    return 0
}

# ------------------------------------------------------------
# API inbound list diagnostic
# ------------------------------------------------------------

api_inbound_list_test() {
    local panel_port="$1"
    local username="$2"
    local password="$3"

    local base_url
    local cookie_file
    local login_body
    local login_code
    local list_code
    local list_body

    base_url="http://127.0.0.1:${panel_port}"
    cookie_file="$(mktemp)"

    login_body="$(
        jq -cn \
            --arg username "${username}" \
            --arg password "${password}" \
            '{username:$username,password:$password}'
    )"

    log "测试面板认证 Cookie..."

    login_code="$(
        curl \
            -sS \
            --connect-timeout 5 \
            --max-time 15 \
            -c "${cookie_file}" \
            -o /tmp/xui-login-response.json \
            -w '%{http_code}' \
            -X POST \
            "${base_url}/login" \
            -H 'Content-Type: application/json' \
            --data "${login_body}"
    )"

    if [[ "${login_code}" != "200" ]]; then
        warn "/login 返回 HTTP ${login_code}。"
        rm -f "${cookie_file}" /tmp/xui-login-response.json
        return 1
    fi

    if ! grep -q 'x-ui' "${cookie_file}" 2>/dev/null; then
        warn "没有在 Cookie Jar 中发现 x-ui Cookie。"
        rm -f "${cookie_file}" /tmp/xui-login-response.json
        return 1
    fi

    log "Cookie 登录认证成功。"

    log "测试 /panel/inbound/list..."

    list_code="$(
        curl \
            -sS \
            --connect-timeout 5 \
            --max-time 15 \
            -b "${cookie_file}" \
            -o /tmp/xui-inbound-response.json \
            -w '%{http_code}' \
            "${base_url}/panel/api/inbounds/list"
    )"

    list_body="$(cat /tmp/xui-inbound-response.json 2>/dev/null || true)"

    rm -f "${cookie_file}"
    rm -f /tmp/xui-login-response.json
    rm -f /tmp/xui-inbound-response.json

    if [[ "${list_code}" != "200" ]]; then
        warn "inbound list HTTP 状态：${list_code}"
        [[ -n "${list_body}" ]] && echo "响应：${list_body}"
        return 1
    fi

    log "面板 inbound API 可以访问。"

    return 0
}

# ------------------------------------------------------------
# public IP diagnostic
# ------------------------------------------------------------

get_public_ip() {
    local ip=""

    ip="$(
        curl \
            -4 \
            -sS \
            --connect-timeout 5 \
            --max-time 10 \
            https://api.ipify.org 2>/dev/null || true
    )"

    if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "${ip}"
        return 0
    fi

    ip="$(
        curl \
            -4 \
            -sS \
            --connect-timeout 5 \
            --max-time 10 \
            https://ifconfig.me 2>/dev/null || true
    )"

    if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "${ip}"
        return 0
    fi

    hostname -I 2>/dev/null | awk '{print $1}'
}

# ------------------------------------------------------------
# final diagnostic
# ------------------------------------------------------------

diagnostic() {
    echo
    echo -e "${green}========================================${plain}"
    echo -e "${green}          x-ui 安装 / API 自检          ${plain}"
    echo -e "${green}========================================${plain}"

    echo
    echo "x-ui 版本：${last_version}"
    echo "面板地址：http://127.0.0.1:${XUI_PORT}"
    echo "面板端口：${XUI_PORT}"

    public_ip="$(get_public_ip || true)"

    if [[ -n "${public_ip}" ]]; then
        echo "检测到公网 IPv4：${public_ip}"
    else
        echo "公网 IPv4：获取失败"
    fi

    echo
    echo "---------- systemd ----------"

    if systemctl is-active --quiet x-ui; then
        echo -e "${green}x-ui：运行中${plain}"
    else
        echo -e "${red}x-ui：未运行${plain}"
    fi

    echo
    echo "---------- API /api/login ----------"

    if api_login_test \
        "${XUI_PORT}" \
        "${XUI_USERNAME}" \
        "${XUI_PASSWORD}"; then

        echo -e "${green}API 登录：OK${plain}"
    else
        echo -e "${red}API 登录：FAILED${plain}"
    fi

    echo
    echo "---------- Cookie / inbound API ----------"

    if api_inbound_list_test \
        "${XUI_PORT}" \
        "${XUI_USERNAME}" \
        "${XUI_PASSWORD}"; then

        echo -e "${green}Inbound API：OK${plain}"
    else
        echo -e "${yellow}Inbound API：当前版本/路由可能不同，请查看上面的响应。${plain}"
    fi

    echo
    echo -e "${green}========================================${plain}"
    echo "x-ui 安装完成。"
    echo
    echo "管理命令：x-ui"
    echo "服务状态：systemctl status x-ui"
    echo "服务日志：journalctl -u x-ui -n 100 --no-pager"
    echo -e "${green}========================================${plain}"
}

# ------------------------------------------------------------
# main
# ------------------------------------------------------------

main() {
    echo -e "${green}"
    echo "========================================"
    echo "          x-ui Installation"
    echo "========================================"
    echo -e "${plain}"

    detect_system
    detect_arch
    check_64bit
    check_os_version
    install_base

    # 第一个参数可以指定 x-ui 版本
    install_x_ui "${1:-}"

    config_after_install

    # 如果用户没有修改配置，则从 x-ui 当前配置中获取端口。
    if [[ -z "${XUI_PORT:-}" ]]; then
        warn "没有设置 XUI_PORT。"
        warn "请确认 x-ui 当前实际监听端口。"
        XUI_PORT="${XUI_PORT:-54321}"
    fi

    start_x_ui

    wait_xui_panel "${XUI_PORT}" || {
        die "x-ui Web 服务启动失败，请检查日志。"
    }

    diagnostic
}

main "$@"
```
