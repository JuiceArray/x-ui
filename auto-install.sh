#!/bin/bash
# x‑ui v0.3.2 适配，使用 /api/* json接口
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'
cur_dir=$(pwd)

[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
else
    echo -e "${red}未检测到系统版本${plain}\n" && exit 1
fi

arch=$(arch)
if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="amd64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="amd64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi
echo "架构: ${arch}"

if [ $(getconf WORD_BIT) != '32' ] && [ $(getconf LONG_BIT) != '64' ]; then
    echo "本软件不支持32位系统，请使用64位"
    exit -1
fi

os_version=""
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}请使用 CentOS7+${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}请使用 Ubuntu16+${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}请使用 Debian8+${plain}\n" && exit 1
    fi
fi

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install wget curl tar jq -y
    else
        apt install wget curl tar jq -y
    fi
}

config_after_install() {
    echo -e "${yellow}安装完成修改账户密码端口${plain}"
    if [[ -n "${XUI_AUTO_CONFIRM}" && -n "${XUI_USERNAME}" && -n "${XUI_PASSWORD}" && -n "${XUI_PORT}" ]]; then
        echo -e "${green}=====全自动模式=====${plain}"
        config_confirm="${XUI_AUTO_CONFIRM}"
        config_account="${XUI_USERNAME}"
        config_password="${XUI_PASSWORD}"
        config_port="${XUI_PORT}"
    else
        read -p "确认继续?[y/n]:" config_confirm
        if [[ x"${config_confirm}" == x"y" || x"${config_confirm}" == x"Y" ]]; then
            read -p "账户名:" config_account
            read -p "密码:" config_password
            read -p "面板端口:" config_port
        else
            echo -e "${red}取消，使用默认配置，请手动修改${plain}"
            return
        fi
    fi
    if [[ x"${config_confirm}" == x"y" || x"${config_confirm}" == x"Y" ]]; then
        /usr/local/x-ui/x-ui setting -username ${config_account} -password ${config_password}
        /usr/local/x-ui/x-ui setting -port ${config_port}
    fi
}

auto_create_vmess() {
    echo -e "\n${green}>>>等待x‑ui面板启动，调用JSON API创建VMess${plain}"
    SERVER_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 ipinfo.io/ip || hostname -I | awk '{print $1}')
    VMESS_PORT=${XUI_VMESS_PORT:-20001}
    PANEL_PORT="${config_port}"
    USER="${config_account}"
    PWD="${config_password}"
    BASE_URL="http://127.0.0.1:${PANEL_PORT}"

    ready=0
    for((i=0;i<35;i++));do
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 1 "${BASE_URL}/login")
        if [[ "${code}" == "200" ]];then
            ready=1
            break
        fi
        sleep 1
    done
    if [[ ${ready} -eq 0 ]];then
        echo -e "${red}面板35秒未就绪，跳过创建vmess，请查看x-ui log${plain}"
        return 1
    fi

    # ========== v0.3.2 真正登录接口 POST /api/login JSON ==========
    login_resp=$(curl -s -X POST "${BASE_URL}/api/login" \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"${USER}\",\"password\":\"${PWD}\"}")

    token=$(echo "${login_resp}" | jq -r '.data.token')
    if [[ -z "${token}" || "${token}" == "null" ]];then
        echo -e "${red}API登录失败！返回：${login_resp}${plain}"
        return 1
    fi
    echo -e "${green}面板登录成功，获取token${plain}"

    gen_uuid(){
        echo "$(head -c16 /dev/urandom | xxd -ps -c 16)-$(head -c8 /dev/urandom | xxd -ps -c8)-$(head -c8 /dev/urandom | xxd -ps -c8)-$(head -c24 /dev/urandom | xxd -ps -c24)"
    }
    VMESS_UUID=$(gen_uuid)

    # api/inbound/add json body，和前端提交一致
add_json=$(cat <<JSON
{
  "remark":"auto-vmess",
  "enable":true,
  "port":${VMESS_PORT},
  "protocol":"vmess",
  "settings":{
    "clients":[{"id":"${VMESS_UUID}","alterId":0}],
    "disableInsecureEncryption":false
  },
  "streamSettings":{
    "network":"tcp",
    "security":"none",
    "tcpSettings":{"header":{"type":"none"}}
  },
  "sniffing":{"enabled":true,"destOverride":["http","tls"]}
}
JSON
)

    add_resp=$(curl -s -X POST "${BASE_URL}/api/inbound/add" \
      -H "Authorization: ${token}" \
      -H "Content-Type: application/json" \
      -d "${add_json}")

    succ=$(echo "${add_resp}" | jq -r '.success')
    if [[ "${succ}" == "true" ]];then
        echo -e "${green}VMess入站创建成功${plain}"
    else
        echo -e "${red}创建入站失败，返回：${add_resp}${plain}"
        return 1
    fi

    list_resp=$(curl -s -X GET "${BASE_URL}/api/inbound/list" -H "Authorization: ${token}")
    VMESS_UUID=$(echo "${list_resp}" | jq -r '.[-1].settings.clients[0].id')
    ALTERID=0

vmess_json="{\"v\":\"2\",\"ps\":\"auto-vmess\",\"add\":\"${SERVER_IP}\",\"port\":\"${VMESS_PORT}\",\"id\":\"${VMESS_UUID}\",\"aid\":\"${ALTERID}\",\"scy\":\"auto\",\"net\":\"tcp\",\"type\":\"none\",\"host\":\"\",\"path\":\"\",\"tls\":\"\"}"

    b64=$(echo -n "${vmess_json}" | base64 -w0)
    VMESS_LINK="vmess://${b64}"

    echo -e "${green}==================== VMess链接 ====================${plain}"
    echo "${VMESS_LINK}"
    echo -e "${green}=====================================================${plain}"
    echo "IP: ${SERVER_IP}"
    echo "端口: ${VMESS_PORT}"
    echo "UUID: ${VMESS_UUID}"
    echo "AlterId: ${ALTERID}"
    echo -e "\n⚠️云服务器安全组放行面板端口、vmess端口\n"
}

install_x-ui() {
    systemctl stop x-ui
    cd /usr/local/
    if [ $# == 0 ]; then
        last_version=$(curl -Ls "https://api.github.com/repos/vaxilu/x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$last_version" ]]; then
            echo -e "${red}获取版本失败${plain}"
            exit 1
        fi
        echo "检测最新版本：${last_version}"
        wget -N --no-check-certificate -O /usr/local/x-ui-linux-${arch}.tar.gz https://github.com/vaxilu/x-ui/releases/download/${last_version}/x-ui-linux-${arch}.tar.gz
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载x-ui失败${plain}"
            exit 1
        fi
    else
        last_version=$1
        url="https://github.com/vaxilu/x-ui/releases/download/${last_version}/x-ui-linux-${arch}.tar.gz"
        echo "安装版本 v$1"
        wget -N --no-check-certificate -O /usr/local/x-ui-linux-${arch}.tar.gz ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载失败${plain}"
            exit 1
        fi
    fi
    [[ -e /usr/local/x-ui/ ]] && rm -rf /usr/local/x-ui/
    tar zxvf x-ui-linux-${arch}.tar.gz
    rm -f x-ui-linux-${arch}.tar.gz
    cd x-ui
    chmod +x x-ui bin/xray-linux-${arch}
    cp -f x-ui.service /etc/systemd/system/
    wget --no-check-certificate -O /usr/bin/x-ui https://raw.githubusercontent.com/vaxilu/x-ui/main/x-ui.sh
    chmod +x /usr/local/x-ui/x-ui.sh
    chmod +x /usr/bin/x-ui

    config_after_install

    systemctl daemon-reload
    systemctl enable x-ui
    systemctl start x-ui

    auto_create_vmess

    echo -e "${green}x-ui v${last_version} 安装完成${plain}"
    echo "x-ui 管理命令：x-ui"
}

echo -e "${green}开始安装${plain}"
install_base
install_x-ui $1

# ========== 自动创建VMess节点 START ==========
sleep 10
# 加载面板自动生成配置
source /etc/x-ui/x-ui.conf

NEW_UUID=$(cat /proc/sys/kernel/random/uuid)

# 获取登录Cookie
COOKIE=$(curl -s -c - -X POST "http://127.0.0.1:${XUI_PORT}/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${XUI_USER}\",\"password\":\"${XUI_PASS}\"}" 2>/dev/null | grep -o "x-ui.*=[^;]*")

if [[ -n "${COOKIE}" ]];then
  echo ">>> 登录面板成功，正在自动创建VMess节点"
  # API新增inbound
  ADD_RET=$(curl -s -X POST "http://127.0.0.1:${XUI_PORT}/panel/inbound/add" \
  -H "Cookie: ${COOKIE}" \
  -H "Content-Type: application/json" \
  -d "{
    \"up\":0,
    \"down\":0,
    \"total\":0,
    \"remark\":\"auto-vmess-default\",
    \"enable\":true,
    \"expiry\":0,
    \"listen\":\"\",
    \"port\":20001,
    \"protocol\":\"vmess\",
    \"settings\":\"{\\\"clients\\\":[{\\\"id\\\":\\\"${NEW_UUID}\\\",\\\"alterId\\\":0}]}\",
    \"streamSettings\":\"{\\\"network\\\":\\\"tcp\\\",\\\"security\\\":\\\"none\\\",\\\"tcpSettings\\\":{\\\"header\\\":{\\\"type\\\":\\\"none\\\"}}}\",
    \"sniffing\":\"{\\\"enabled\\\":false,\\\"destOverride\\\":[\\\"http\\\",\\\"tls\\\"]}\"
  }")
  echo ">>> VMess节点创建完成，UUID: ${NEW_UUID}"
  echo ">>> VMess: vmess://$(echo -n "{\"v\":\"2\",\"ps\":\"auto-vmess-default\",\"add\":\"$(hostname -I | awk '{print $1}')\",\"port\":\"20001\",\"id\":\"${NEW_UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"tcp\",\"type\":\"none\",\"host\":\"\",\"path\":\"\",\"tls\":\"\"}" | base64 -w0)"
else
  echo "!!! 面板登录失败，跳过自动创建VMess"
fi
# ========== 自动创建VMess节点 END ==========

