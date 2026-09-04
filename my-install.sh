#!/bin/bash
# ====================== 用户可通过环境变量传入参数 ======================
PANEL_USER="${PANEL_USER:-admin}"
PANEL_PASS="${PANEL_PASS:-admin123456}"
PANEL_PORT="${PANEL_PORT:-54321}"
VMESS_PORT="${VMESS_PORT:-20000}"
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
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
fi

get_arch(){
    arch=$(uname -m)
    if [[ $arch == x86_64* ]]; then
        arch="amd64"
    elif [[ $arch == aarch64* ]]; then
        arch="arm64"
    elif [[ $arch == armv7* ]]; then
        arch="armv7"
    elif [[ $arch == armv6* ]]; then
        arch="armv6"
    else
        echo -e "${red}不支持的架构: ${arch}${plain}"
        exit 1
    fi
}
get_arch

if [[ $arch != "amd64" && $arch != "arm64" && $arch != "armv7" && $arch != "armv6" ]]; then
    echo -e "${red}不支持的架构${plain}"
    exit 1
fi

echo -e "${green}检测系统: ${release} 架构: ${arch}${plain}"

install_x-ui() {
    systemctl stop x-ui >/dev/null 2>&1
    systemctl disable x-ui >/dev/null 2>&1
    cd /usr/local/
    last_version=$(curl -Ls "https://api.github.com/repos/vaxilu/x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ ! -n "$last_version" ]]; then
        echo -e "${yellow}Github API限流，尝试使用固定版本 v1.7.8${plain}"
        last_version="v1.7.8"
    fi
    echo -e "${green}使用 x-ui 版本：${last_version}${plain}"
    wget -N --no-check-certificate -O /usr/local/x-ui-linux-${arch}.tar.gz https://github.com/vaxilu/x-ui/releases/download/${last_version}/x-ui-linux-${arch}.tar.gz
    if [[ $? -ne 0 ]]; then
        echo -e "${red}下载 x-ui 失败，请确保你的服务器可以访问 Github${plain}"
        exit 1
    fi
    tar zxvf x-ui-linux-${arch}.tar.gz
    rm x-ui-linux-${arch}.tar.gz -f
    cd x-ui
    chmod +x x-ui bin/xray-linux-${arch}
    cp -f x-ui.service /etc/systemd/system/
    cp -f x-ui.sh /usr/bin/x-ui
    chmod +x /usr/bin/x-ui
    systemctl daemon-reload

    # =========关键：启动一次程序生成 x-ui.db 数据库文件，然后杀掉=========
    echo -e "${green}生成初始数据库文件...${plain}"
    ./x-ui >/dev/null 2>&1 &
    sleep 2
    kill %1 2>/dev/null
    sleep 1

    cd - >/dev/null
    echo -e "${green}x-ui 文件解压、数据库初始化完成${plain}"
}

install_x-ui

# ====================== 自定义扩展部分开始 ======================
echo ""
echo "====================================="
echo "面板账号: $PANEL_USER"
echo "面板密码: $PANEL_PASS"
echo "面板端口: $PANEL_PORT"
echo "VMess代理端口: $VMESS_PORT"
echo "====================================="

# 此时 x-ui.db 已经存在，服务完全停止，修改配置会真正写入
x-ui setting -username "${PANEL_USER}" -password "${PANEL_PASS}"
x-ui setting -port "${PANEL_PORT}"

# 校验修改结果
echo -e "${green}校验当前配置：${plain}"
x-ui setting -show

# 正式启动服务
systemctl enable x-ui
systemctl start x-ui

echo "等待面板服务启动..."
sleep 8

VMESS_UUID="$(cat /proc/sys/kernel/random/uuid)"
VMESS_ALTERID=0
PANEL_ADDR="http://127.0.0.1:${PANEL_PORT}"

# 获取服务器对外IP，多备用源
SERVER_IP=$(curl -s --max-time 3 ifconfig.me || curl -s --max-time 3 ipinfo.io/ip || curl -s --max-time 3 icanhazip.com)
if [[ -z "$SERVER_IP" ]];then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

# 防火墙放行
if command -v firewall-cmd &>/dev/null;then
    firewall-cmd --add-port=${PANEL_PORT}/tcp --permanent
    firewall-cmd --add-port=${VMESS_PORT}/tcp --permanent
    firewall-cmd --reload
elif command -v ufw &>/dev/null;then
    ufw allow ${PANEL_PORT}/tcp
    ufw allow ${VMESS_PORT}/tcp
fi

COOKIE_FILE=$(mktemp)
curl -s -c "$COOKIE_FILE" -X POST "${PANEL_ADDR}/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${PANEL_USER}\",\"password\":\"${PANEL_PASS}\"}" >/dev/null

curl -s -b "$COOKIE_FILE" -X POST "${PANEL_ADDR}/panel/inbound/add" \
-H "Content-Type: application/json" \
-d '{
  "up":0,
  "down":0,
  "total":0,
  "remark":"auto-vmess",
  "enable":true,
  "expiry":0,
  "listen":"",
  "port":'${VMESS_PORT}',
  "protocol":"vmess",
  "settings":"{\"clients\":[{\"id\":\"'${VMESS_UUID}'\",\"alterId\":'${VMESS_ALTERID}'}],\"disableInsecureEncryption\":false}",
  "streamSettings":"{\"network\":\"tcp\",\"security\":\"none\",\"tcpSettings\":{}}",
  "sniffing":"{\"enabled\":false,\"destOverride\":[\"http\",\"tls\"]}"
}'

sleep 2
rm -f "$COOKIE_FILE"
x-ui restart

# ========== 生成 vmess:// 链接核心代码 ==========
VMESS_JSON=$(cat <<EOF
{
  "v":"2",
  "ps":"auto-vmess",
  "add":"${SERVER_IP}",
  "port":"${VMESS_PORT}",
  "id":"${VMESS_UUID}",
  "aid":"${VMESS_ALTERID}",
  "scy":"auto",
  "net":"tcp",
  "type":"none",
  "host":"",
  "path":"",
  "tls":"none"
}
EOF
)
VMESS_B64=$(echo "$VMESS_JSON" | base64 -w 0)
VMESS_LINK="vmess://${VMESS_B64}"

echo ""
echo "======================= 部署完成 ======================="
echo "面板地址: http://${SERVER_IP}:${PANEL_PORT}"
echo "面板账号: ${PANEL_USER}"
echo "面板密码: ${PANEL_PASS}"
echo "VMess端口: ${VMESS_PORT}"
echo "VMess UUID: ${VMESS_UUID}"
echo "alterId: ${VMESS_ALTERID}"
echo ""
echo -e "${green}VMess完整链接：${plain}"
echo "${VMESS_LINK}"
echo "========================================================"
echo ""
echo "⚠️记得云服务器控制台安全组放行 ${PANEL_PORT}、${VMESS_PORT} 端口"
