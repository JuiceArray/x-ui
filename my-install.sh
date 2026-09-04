```bash
#!/usr/bin/env bash
set -e

# ===== 自定义这里 =====
PANEL_USER="你的账号"
PANEL_PASS="你的密码"
PANEL_PORT="你的面板端口"
# ======================

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 用户运行"
    exit 1
fi

echo "开始安装 x-ui..."

bash <(curl -Ls https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh) &
PID=$!

# 等待安装脚本启动
wait $PID

# 安装完成后设置面板账号、密码和端口
/usr/local/x-ui/x-ui setting \
    -username "$PANEL_USER" \
    -password "$PANEL_PASS"

/usr/local/x-ui/x-ui setting \
    -port "$PANEL_PORT"

systemctl daemon-reload
systemctl enable x-ui
systemctl restart x-ui

echo
echo "================================"
echo "x-ui 安装/配置完成"
echo "账号: $PANEL_USER"
echo "面板端口: $PANEL_PORT"
echo "================================"
```
