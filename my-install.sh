#!/bin/bash
# 环境变量传入示例：PANEL_USER=admin PANEL_PASS=admin37 PANEL_PORT=1000 VMESS_PORT=20000 bash xxx.sh
PANEL_USER="${PANEL_USER:-admin}"
PANEL_PASS="${PANEL_PASS:-admin123456}"
PANEL_PORT="${PANEL_PORT:-54321}"
VMESS_PORT="${VMESS_PORT:-20000}"
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${red}必须root执行${plain}" && exit 1

# 系统判断
if [[ -f /etc/redhat-release ]]; then
    OS="centos"
elif cat /etc/issue | grep -Eqi "debian|ubuntu"; then
    OS="debian"
else
    echo -e "${red}不支持系统${plain}"
    exit 1
fi

get_arch(){
    arch=$(uname -m)
    case $arch in
        x86_64) echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l) echo "armv7" ;;
        armv6l) echo "armv6" ;;
        *) echo -e "${red}架构不支持:$arch${plain}"; exit 1 ;;
    esac
}
ARCH=$(get_arch)

# 清理旧
systemctl stop x-ui >/dev/null 2>&1
systemctl disable x-ui >/dev/null 2>&1
rm -rf /usr/local/x-ui
rm -f /usr/bin/x-ui
rm -f /etc/systemd/system/x-ui.service
systemctl daemon-reload

# 安装sqlite3
if ! command -v sqlite3 >/dev/null;then
    echo -e "${green}安装 sqlite3${plain}"
    if [[ $OS == "debian" ]];then
        apt update -y >/dev/null 2>&1
        apt install sqlite3 -y >/dev/null 2>&1
    else
        yum install sqlite -y >/dev/null 2>&1
    fi
fi

# 下载原版
cd /usr/local
LAST_VER=$(curl -Ls "https://api.github.com/repos/vaxilu/x-ui/releases/latest" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
[[ -z "$LAST_VER" ]] && LAST_VER="v1.7.8"
echo -e "${green}下载版本:${LAST_VER} arch:${ARCH}${plain}"
wget -q --no-check-certificate -O x-ui-linux-${ARCH}.tar.gz "https://github.com/vaxilu/x-ui/releases/download/${LAST_VER}/x-ui-linux-${ARCH}.tar.gz"
tar zxf x-ui-linux-${ARCH}.tar.gz
rm -f x-ui-linux-${ARCH}.tar.gz

cd /usr/local/x-ui
chmod +x x-ui bin/xray-linux-${ARCH}

# 修改service：删除硬编码 -port
cp -f x-ui.service /etc/systemd/system/x-ui.service
sed -i 's/ExecStart=\/usr\/local\/x-ui\/x-ui.*/ExecStart=\/usr\/local\/x-ui\/x-ui/' /etc/systemd/system/x-ui.service
cp -f x-ui.sh /usr/bin/x-ui
chmod +x /usr/bin/x-ui
systemctl daemon-reload

# ========== 直接本地生成全新预制x‑ui.db，不运行x‑ui程序 ==========
DB="/usr/local/x-ui/x-ui.db"
rm -f "$DB"
PASS_MD5=$(echo -n "${PANEL_PASS}" | md5sum | awk '{print $1}')

# 建表，插入初始配置、管理员账号
sqlite3 "$DB" <<SQL
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT,username TEXT UNIQUE,password TEXT);
INSERT INTO settings(key,value) VALUES('web_port','${PANEL_PORT}');
INSERT INTO users(username,password) VALUES('${PANEL_USER}','${PASS_MD5}');
SQL

chmod 644 "$DB"
echo -e "${green}预制数据库已生成，端口=${PANEL_PORT} user=${PANEL_USER}${plain}"

# 直接启动，不再需要54321那一套
systemctl enable x-ui
systemctl start x-ui

# 循环等待目标端口
WAIT_MAX=30
COUNT=0
while ! ss -tln | grep ":${PANEL_PORT}" >/dev/null ; do
    sleep 1
    COUNT=$((COUNT+1))
    if [ $COUNT -ge $WAIT_MAX ];then
        echo -e "${yellow}等待端口${PANEL_PORT}超时，请检查systemctl status x-ui${plain}"
        break
    fi
done

PANEL_ADDR="http://127.0.0.1:${PANEL_PORT}"
# 获取公网IP
SERVER_IP=$(curl -s --max-time 3 ifconfig.me || curl -s --max-time 3 ipinfo.io/ip || curl -s --max-time 3 icanhazip.com)
[[ -z "$SERVER_IP" ]] && SERVER_IP=$(hostname -I | awk '{print $1}')

# 防火墙放行
if [[ $OS == "centos" ]];then
    firewall-cmd --add-port=${PANEL_PORT}/tcp --permanent >/dev/null 2>&1
    firewall-cmd --add-port=${VMESS_PORT}/tcp --permanent >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
else
    ufw allow ${PANEL_PORT}/tcp >/dev/null 2>&1
    ufw allow ${VMESS_PORT}/tcp >/dev/null 2>&1
fi

VMESS_UUID=$(cat /proc/sys/kernel/random/uuid)
VMESS_ALTERID=0

# api添加vmess入站
COOKIE=$(mktemp)
curl -s -c "$COOKIE" -X POST "${PANEL_ADDR}/login" \
  -H "Content-Type:application/json" \
  -d "{\"username\":\"${PANEL_USER}\",\"password\":\"${PANEL_PASS}\"}" >/dev/null

curl -s -b "$COOKIE" -X POST "${PANEL_ADDR}/panel/inbound/add" \
-H "Content-Type:application/json" \
-d '{
"up":0,"down":0,"total":0,"remark":"auto-vmess","enable":true,"expiry":0,"listen":"","port":'${VMESS_PORT}',
"protocol":"vmess","settings":"{\"clients\":[{\"id\":\"'${VMESS_UUID}'\",\"alterId\":'${VMESS_ALTERID}'}],\"disableInsecureEncryption\":false}",
"streamSettings":"{\"network\":\"tcp\",\"security\":\"none\",\"tcpSettings\":{}}","sniffing":"{\"enabled\":false,\"destOverride\":[\"http\",\"tls\"]}"
}' >/dev/null

rm -f "$COOKIE"
x-ui restart >/dev/null 2>&1

# 生成vmess链接
VMESS_JSON=$(cat <<EOF
{"v":"2","ps":"auto-vmess","add":"${SERVER_IP}","port":"${VMESS_PORT}","id":"${VMESS_UUID}","aid":"${VMESS_ALTERID}","scy":"auto","net":"tcp","type":"none","host":"","path":"","tls":"none"}
EOF
)
VMESS_B64=$(echo -n "$VMESS_JSON" | base64 -w0)
VMESS_LINK="vmess://${VMESS_B64}"

echo ""
echo "====================部署完成===================="
echo "面板地址: http://${SERVER_IP}:${PANEL_PORT}"
echo "账号: ${PANEL_USER}"
echo "密码: ${PANEL_PASS}"
echo "vmess端口: ${VMESS_PORT}"
echo "UUID: ${VMESS_UUID}"
echo "alterId: ${VMESS_ALTERID}"
echo "vmess链接: ${VMESS_LINK}"
echo "================================================="
echo "⚠️务必云服务器安全组放行 ${PANEL_PORT},${VMESS_PORT}"
