#!/usr/bin/env bash
# 本机台架凭据的统一入口。**不存放任何真实值**，只负责按优先级查找：
#
#   1. 调用者已设的同名环境变量（优先级最高，适合一次性覆盖）
#   2. 仓库根的 .local-creds（gitignore 排除，本机私有）
#
# 用法：
#   . "$(dirname "$0")/lib-creds.sh"
#   cred DEV root@example          # 取 DEV；没有就报错退出
#   cred SUDO_PW ''                # 取 SUDO_PW，允许为空（不报错）
#
# 设计意图：仓库里不出现任何真实口令/SSID/内网地址，但脚本在本机仍能直接跑。

_LIB_CREDS_BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$_LIB_CREDS_BASE/.local-creds" ]; then
    # shellcheck disable=SC1091
    . "$_LIB_CREDS_BASE/.local-creds"
fi

# cred <变量名> [用于报错的说明]
cred() {
    local name="$1" hint="${2-}"
    local value
    eval "value=\${$name-}"
    if [ -z "$value" ]; then
        {
            echo "错误：未提供 $name${hint:+（$hint）}。" >&2
            echo "  请在仓库根创建 .local-creds（已被 .gitignore 排除），例如：" >&2
            echo "      $name=<value>" >&2
            echo "  或直接用环境变量覆盖：$name=... $0 ..." >&2
        } >&2
        exit 1
    fi
    printf '%s' "$value"
}

# cred_opt <变量名>：允许为空，返回原值（可能为空串）。
cred_opt() {
    local name="$1" value
    eval "value=\${$name-}"
    printf '%s' "$value"
}
