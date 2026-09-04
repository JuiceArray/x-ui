```bash
#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# y-install.sh
#
# 完全调用上游 vaxilu/x-ui install.sh
#
# 自动输入：
#   1. y       确认继续
#   2. 用户名
#   3. 密码
#   4. 面板端口
#
# 用法：
#   bash y-install.sh <用户名> <密码> <面板端口>
#
# 示例：
#   bash y-install.sh admin 'MyPassword123!' 54321
# ============================================================

INSTALL_URL="https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh"

USERNAME="${1:-}"
PASSWORD="${2:-}"
PANEL_PORT="${3:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PLAIN='\033[0m'

die() {
    echo -e "${RED}[ERROR]${PLAIN} $*" >&2
    exit 1
}

# ------------------------------------------------------------
# 参数
# ------------------------------------------------------------

if [[ $# -ne 3 ]]; then
    echo
    echo "用法："
    echo "  bash y-install.sh <用户名> <密码> <面板端口>"
    echo
    echo "示例："
    echo "  bash y-install.sh admin 'MyPassword123!' 54321"
    echo
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    die "请使用 root 用户运行。"
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
    die "端口必须在 1-65535 范围内。"
fi

echo
echo "========================================"
echo "          x-ui y-install"
echo "========================================"
echo
echo "安装来源 : vaxilu/x-ui"
echo "用户名   : ${USERNAME}"
echo "面板端口 : ${PANEL_PORT}"
echo
echo -e "${YELLOW}自动确认安装：y${PLAIN}"
echo

# ------------------------------------------------------------
# 获取上游 install.sh
# ------------------------------------------------------------

TMP_SCRIPT="$(mktemp)"

cleanup() {
    rm -f "$TMP_SCRIPT"
}

trap cleanup EXIT

curl -fsSL "$INSTALL_URL" -o "$TMP_SCRIPT" ||
    die "无法下载上游 install.sh"

chmod +x "$TMP_SCRIPT"

# ------------------------------------------------------------
# 自动回答
#
# 顺序：
#   y
#   username
#   password
#   port
# ------------------------------------------------------------

printf '%s\n%s\n%s\n%s\n' \
    "y" \
    "$USERNAME" \
    "$PASSWORD" \
    "$PANEL_PORT" |
    bash "$TMP_SCRIPT"

echo
echo "========================================"
echo -e "${GREEN}安装流程结束${PLAIN}"
echo "========================================"
echo
```
