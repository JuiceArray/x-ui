#!/bin/bash
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'
cur_dir=$(pwd)

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
elif cat /proc/version | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
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
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)，如果检测有误，请联系作者"
    exit -1
fi

os_version=""
# os version
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
    fi
fi

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install wget curl tar -y
    else
        apt install wget curl tar -y
    fi
}

# 自动获取公网IP
get_public_ip(){
    pub_ip=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 ipinfo.io/ip || curl -s --max-time 5 icanhazip.com)
    if [[ -z "${pub_ip}" ]]; then
        pub_ip="UnknownIP"
    fi
    echo "${pub_ip}"
}

config_after_install() {
    # 环境变量自动模式：直接赋值，不输出安全提示、不交互
    if [[ x"${XUI_AUTO_CONFIRM}" == x"y" || x"${XUI_AUTO_CONFIRM}" == x"Y" ]]; then
        config_confirm="y"
        config_account="${XUI_USERNAME:-admin}"
        config_password="${XUI_PASSWORD:-admin}"
        config_port="${XUI_PORT:-54321}"
    else
        # 普通交互模式才输出提示
        echo -e "${yellow}出于安全考虑，安装/更新完成后需要强制修改端口与账户密码${plain}"
        read -p "确认是否继续?[y/n]:" config_confirm
        if [[ x"${config_confirm}" == x"y" || x"${config_confirm}" == x"Y" ]]; then
            read -p "请设置您的账户名:" config_account
            echo -e "${yellow}您的账户名将设定为:${config_account}${plain}"
            read -p "请设置您的账户密码:" config_password
            echo -e "${yellow}您的账户密码将设定为:${config_password}${plain}"
            read -p "请设置面板访问端口:" config_port
            echo -e "${yellow}您的面板访问端口将设定为:${config_port}${plain}"
        else
            echo -e "${red}已取消,所有设置项均为默认设置,请及时修改${plain}"
            return 0
        fi
    fi

    echo -e "${yellow}确认设定,设定中${plain}"
    /usr/local/x-ui/x-ui setting -username "${config_account}" -password "${config_password}"
    echo -e "${yellow}账户密码设定完成${plain}"
    /usr/local/x-ui/x-ui setting -port "${config_port}"
    echo -e "${yellow}面板端口设定完成${plain}"
}

create_vmess(){
echo "正在创建 VMess 节点..."
XUI_WEB_PORT="${XUI_PORT:-54321}"
XUI_API_USER="${XUI_USERNAME:-admin}"
XUI_API_PASS="${XUI_PASSWORD:-admin}"
VMESS_PORT="${XUI_VMESS_PORT:-10086}"

BASE="http://127.0.0.1:${XUI_WEB_PORT}"
pub_ip=$(get_public_ip)
now_time=$(date +"%Y%m%d_%H%M%S")
remark_name="${pub_ip}_${now_time}"

# 获取cookie
echo -e "\n===== 登录请求 ====="
COOKIE_RAW=$(curl -i -s \
-X POST \
"$BASE/login" \
-H "Content-Type: application/json" \
-d "{
\"username\":\"${XUI_API_USER}\",
\"password\":\"${XUI_API_PASS}\"
}")
echo "$COOKIE_RAW"
COOKIE=$(echo "$COOKIE_RAW" | grep -i "set-cookie" | awk '{print $2}')

if [[ -z "$COOKIE" ]];then
    echo -e "${red}获取Cookie失败！面板可能未就绪，或者账号密码错误${plain}"
    return 1
fi

UUID=$(cat /proc/sys/kernel/random/uuid)
echo -e "\n===== 添加Inbound请求 ====="
RESPONSE_FILE=$(mktemp)
HTTP_CODE=$(curl -s -o "$RESPONSE_FILE" -w "%{http_code}" \
-X POST \
"${BASE}/xui/inbound/add" \
-H "Cookie:$COOKIE" \
-H "Content-Type: application/json" \
-d "
{
\"remark\":\"${remark_name}\",
\"enable\":true,
\"port\":${VMESS_PORT},
\"protocol\":\"vmess\",
\"settings\":\"{\\\"clients\\\":[{\\\"id\\\":\\\"$UUID\\\",\\\"alterId\\\":0}]}\",
\"streamSettings\":\"{\\\"network\\\":\\\"tcp\\\"}\"
}
")
RESPONSE_BODY=$(cat "$RESPONSE_FILE")
rm -f "$RESPONSE_FILE"

echo "HTTP状态码: $HTTP_CODE"
echo "返回结果: $RESPONSE_BODY"

# 组装vmess json并生成vmess://链接
vmess_json=$(jq -n \
--arg v "2" \
--arg ps "${remark_name}" \
--arg add "${pub_ip}" \
--arg port "${VMESS_PORT}" \
--arg id "${UUID}" \
--arg aid "0" \
--arg scy "auto" \
--arg net "tcp" \
--arg type "none" \
--arg host "" \
--arg path "" \
'{v:$v,ps:$ps,add:$add,port:$port,id:$id,aid:$aid,scy:$scy,net:$net,type:$type,host:$host,path:$path}')

# base64编码
b64_str=$(echo -n "${vmess_json}" | base64 -w0)
vmess_link="vmess://${b64_str}"

echo ""
echo "=========================="
echo "VMess创建完成"
echo "备注名称: ${remark_name}"
echo "端口: ${VMESS_PORT}"
echo "UUID: ${UUID}"
echo "VMess链接: ${vmess_link}"
echo "=========================="
}

install_x-ui() {
    systemctl stop x-ui
    cd /usr/local/
    if [ $# == 0 ]; then
        last_version=$(curl -Ls "https://api.github.com/repos/vaxilu/x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$last_version" ]]; then
            echo -e "${red}检测 x-ui 版本失败，可能是超出 Github API 限制，请稍后再试，或手动指定 x-ui 版本安装${plain}"
            exit 1
        fi
        echo -e "检测到 x-ui 最新版本：${last_version}，开始安装"
        wget -N --no-check-certificate -O /usr/local/x-ui-linux-${arch}.tar.gz https://github.com/vaxilu/x-ui/releases/download/${last_version}/x-ui-linux-${arch}.tar.gz
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 x-ui 失败，请确保你的服务器能够下载 Github 的文件${plain}"
            exit 1
        fi
    else
        last_version=$1
        url="https://github.com/vaxilu/x-ui/releases/download/${last_version}/x-ui-linux-${arch}.tar.gz"
        echo -e "开始安装 x-ui v$1"
        wget -N --no-check-certificate -O /usr/local/x-ui-linux-${arch}.tar.gz ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 x-ui v$1 失败，请确保此版本存在${plain}"
            exit 1
        fi
    fi
    if [[ -e /usr/local/x-ui/ ]]; then
        rm /usr/local/x-ui/ -rf
    fi
    tar zxvf x-ui-linux-${arch}.tar.gz
    rm x-ui-linux-${arch}.tar.gz -f
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
    echo -e "${green}x-ui v${last_version}${plain} 安装完成，面板已启动，"
    echo -e ""
    echo -e "x-ui 管理脚本使用方法: "
    echo -e "----------------------------------------------"
    echo -e "x-ui              - 显示管理菜单 (功能更多)"
    echo -e "x-ui start        - 启动 x-ui 面板"
    echo -e "x-ui stop         - 停止 x-ui 面板"
    echo -e "x-ui restart      - 重启 x-ui 面板"
    echo -e "x-ui status       - 查看 x-ui 状态"
    echo -e "x-ui enable       - 设置 x-ui 开机自启"
    echo -e "x-ui disable      - 取消 x-ui 开机自启"
    echo -e "x-ui log          - 查看 x-ui 日志"
    echo -e "x-ui v2-ui        - 迁移本机器的 v2-ui 账号数据至 x-ui"
    echo -e "x-ui update       - 更新 x-ui 面板"
    echo -e "x-ui install      - 安装 x-ui 面板"
    echo -e "x-ui uninstall    - 卸载 x-ui 面板"
    echo -e "----------------------------------------------"

    echo -e "\n${yellow}等待面板服务就绪 5秒...${plain}"
    sleep 5
    create_vmess
}

echo -e "${green}开始安装${plain}"
install_base
install_x-ui $1
