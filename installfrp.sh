#!/bin/sh

#========================================
# FRP 一键安装管理脚本 (单目录版)
# 兼容: Systemd (默认) 与 Alpine 3.21 的 OpenRC
# 所有文件统一存放于 /opt/frp
# 支持: frps (服务端) / frpc (客户端)
#========================================

FRP_VERSION="0.61.0" # 已更新为较新版本
BASE_DIR="/opt/frp"
CONFIG_DIR="$BASE_DIR"
LOG_DIR="$BASE_DIR"
ERROR_PAGE_DIR="/usr/frps"
ERROR_PAGE_FILE="$ERROR_PAGE_DIR/index.html"

# 颜色定义（兼容大多数终端）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PLAIN='\033[0m'

# 检测是否为 root 用户
if [ "$(id -u)" != "0" ]; then
    printf "%b\n" "${RED}错误: 请使用 root 用户运行此脚本.${PLAIN}"
    exit 1
fi

# 检测是否为 Alpine
IS_ALPINE=0
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "x$ID" = "xalpine" ]; then
        IS_ALPINE=1
    fi
fi

# 自动检测系统架构
get_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        i386|i686) ARCH="386" ;;
        armv7l) ARCH="arm" ;;
        *) printf "%b\n" "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac
    printf "%b\n" "${GREEN}检测到系统架构: $ARCH${PLAIN}"
}

# 创建404维护页面
create_error_page() {
    mkdir -p "$ERROR_PAGE_DIR"
    cat > "$ERROR_PAGE_FILE" << 'EOF'
<!doctype html>
<html>
<head>
    <meta charset="utf-8">
    <title>网站维护中</title>
    <style>
        .container {
            width: 60%;
            margin: 10% auto 0;
            background-color: #f0f0f0;
            padding: 2% 5%;
            border-radius: 10px
        }

        ul {
            padding-left: 20px;
        }

        ul li {
            line-height: 2.3;
            list-style: none;
        }

        a {
            color: #20a53a;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>抱歉，您访问的网址可能正在维护</h1>
        <h3>请耐心等待维护完成即可正常访问</h3>
        <ul>
            <li>或者联系网站管理员</li>
            <li>如长期显示本页面，请尝试清空浏览器缓存</li>
        </ul>
    </div>
</body>
</html>
EOF
    printf "%b\n" "${GREEN}已生成404维护页面: $ERROR_PAGE_FILE${PLAIN}"
}

# 下载 FRP 文件（支持 wget 和 curl）
download_frp() {
  FRP_FILE="frp_${FRP_VERSION}_linux_${ARCH}.tar.gz"
  DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_FILE}"

  printf "是否需要国内加速链接下载？(y/n, 默认 n): "
  read useMirror
  if [ "x$useMirror" = "xy" ] || [ "x$useMirror" = "xY" ]; then
    DOWNLOAD_URL="https://ghproxy.net/$DOWNLOAD_URL"
    printf "%b\n" "${GREEN}已启用国内加速链接下载.${PLAIN}"
  fi

  printf "%b\n" "${GREEN}正在下载 FRP ${FRP_VERSION}...${PLAIN}"
  cd /tmp || exit
  if command -v wget >/dev/null 2>&1; then
    if ! wget -O "$FRP_FILE" "$DOWNLOAD_URL"; then
      printf "%b\n" "${RED}wget 下载失败，请检查网络或版本号是否正确.${PLAIN}"
      exit 1
    fi
  elif command -v curl >/dev/null 2>&1; then
    if ! curl -L -o "$FRP_FILE" "$DOWNLOAD_URL"; then
      printf "%b\n" "${RED}curl 下载失败，请检查网络或版本号是否正确.${PLAIN}"
      exit 1
    fi
  else
    printf "%b\n" "${RED}系统中未找到 wget 或 curl，请先安装其中一个工具.${PLAIN}"
    if [ "$IS_ALPINE" -eq 1 ]; then
      printf "%b\n" "${YELLOW}尝试安装 wget 和 ca-certificates: apk add --no-cache wget ca-certificates${PLAIN}"
    fi
    exit 1
  fi

  # 解压
  tar -xzf "$FRP_FILE"
  rm -f "$FRP_FILE"
  TEMP_DIR="frp_${FRP_VERSION}_linux_${ARCH}"

  # 创建基础目录
  mkdir -p "$BASE_DIR"

  # 复制二进制文件（如果存在）
  if [ -f "$TEMP_DIR/frps" ]; then
      cp "$TEMP_DIR/frps" "$BASE_DIR/"
  fi
  if [ -f "$TEMP_DIR/frpc" ]; then
      cp "$TEMP_DIR/frpc" "$BASE_DIR/"
  fi

  # 清理
  rm -rf "$TEMP_DIR"
}

# 生成自定义配置文件
create_config() {
    MODE="$1"
    if [ "x$MODE" = "xserver" ]; then
        cat > "$BASE_DIR/frps.ini" << EOF
[common]
#客户端链接端口
bind_port = 6900
#KCP端口 和 bind_port 保持一致
kcp_bind_port = 6900
#UDP端口
bind_udp_port = 6901

#http port and https
#http/https隧道的默认端口
vhost_http_port = 80
vhost_https_port = 443

#认证方式 默认token
authentication_method = token
#auth token 自定义的认证密码
token = frp0440linuxamd64

#MAX Coon Pool 最大连接池
max_pool_count = 1521

#404page
custom_404_page = $ERROR_PAGE_FILE

#WEB监测面板
#dashboard_port = 7900
#监测面板账户密码
#dashboard_user = admin
#dashboard_pwd = admin

#泛解析域
#subdomain_host = frps.com
EOF
        printf "%b\n" "${GREEN}已生成服务端配置: $BASE_DIR/frps.ini${PLAIN}"
    else
        cat > "$BASE_DIR/frpc.ini" << EOF
[common]
# FRP 服务端 (frps) 的公网 IP 地址
# ⚠️ 请务必修改为你自己的服务器IP！
server_addr = 123.123.123.123

# 与 frps.ini 中 bind_port 保持一致
server_port = 6900

# 认证方式，必须与服务端一致
authentication_method = token

# 认证令牌，必须与 frps.ini 中的 token 完全相同
token = frp0440linuxamd64

# 连接池大小，可选，不填则使用服务端默认值
# pool_count = 5

# 心跳超时时间（秒），可选
# heartbeat_timeout = 90


# ================================
# 以下为穿透规则示例，请按需启用
# ================================

# -------------------------------
# 示例1: TCP 内网 Web 服务穿透 (如本地8080端口)
# -------------------------------
#[web]
#type = tcp
#local_ip = 127.0.0.1
#local_port = 8080
## 远端监听端口 (在frps服务器上开放此端口)
#remote_port = 6000

# -------------------------------
# 示例2: HTTP 网站穿透 (支持自定义域名)
# -------------------------------
#[web_http]
#type = http
#local_port = 8080
## 自定义你的访问域名 (需将 *.yourdomain.com 解析到frps服务器IP)
#custom_domains = web.yourdomain.com

# -------------------------------
# 示例3: HTTPS 网站穿透
# -------------------------------
#[web_https]
#type = https
#local_port = 8443
#custom_domains = secure.yourdomain.com

# -------------------------------
# 示例4: SSH 穿透 (远程登录内网机器)
# -------------------------------
#[ssh]
#type = tcp
#local_ip = 127.0.0.1
#local_port = 22
#remote_port = 6001

# -------------------------------
# 示例5: UDP 穿透 (如内网DNS服务)
# -------------------------------
#[dns]
#type = udp
#local_ip = 127.0.0.1
#local_port = 53
#remote_port = 6002

# -------------------------------
# 示例6: STCP (点对点安全传输，需配合另一个frpc)
# -------------------------------
#[secret_ssh]
#type = stcp
#sk = your_secret_key
#local_ip = 127.0.0.1
#local_port = 22

EOF
        printf "%b\n" "${GREEN}已生成客户端配置: $BASE_DIR/frpc.ini${PLAIN}"
    fi
}

# 安装 OpenRC 服务脚本 (Alpine)
create_openrc_service() {
    SERVICE_NAME="$1" # frps or frpc
    BIN_NAME="$2"     # frps or frpc
    CONFIG_NAME="$3"  # frps.ini or frpc.ini

    SERVICE_PATH="/etc/init.d/${SERVICE_NAME}"

    cat > "${SERVICE_PATH}" << EOF
#!/sbin/openrc-run
name="${SERVICE_NAME}"
description="Frp ${SERVICE_NAME} Service"
command="${BASE_DIR}/${BIN_NAME}"
command_args="-c ${BASE_DIR}/${CONFIG_NAME}"
command_user="root"
pidfile="/var/run/\${RC_SVCNAME}.pid"
depend() {
    need net
}
EOF

    chmod +x "${SERVICE_PATH}"
    # 添加到默认运行级别
    rc-update add "${SERVICE_NAME}" default >/dev/null 2>&1 || true
    printf "%b\n" "${GREEN}已创建 OpenRC 服务并加入默认 runlevel: ${SERVICE_NAME}${PLAIN}"
}

# 安装 systemd 服务（保留原方法以兼容 systemd 系统）
create_systemd_service() {
    SERVICE_NAME="$1" # frps or frpc
    BIN_NAME="$2"
    CONFIG_NAME="$3"

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Frp ${SERVICE_NAME} Service
After=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
ExecStart=${BASE_DIR}/${BIN_NAME} -c ${BASE_DIR}/${CONFIG_NAME}
ExecReload=/bin/kill -HUP \$MAINPID
WorkingDirectory=${BASE_DIR}
StandardOutput=append:${LOG_DIR}/${SERVICE_NAME}.log
StandardError=append:${LOG_DIR}/${SERVICE_NAME}.log

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    printf "%b\n" "${GREEN}已注册 systemd 服务: ${SERVICE_NAME}${PLAIN}"
}

# 安装服务 (选择 OpenRC 或 systemd)
install_service() {
    SERVICE_TYPE="$1" # "frps" or "frpc"
    if [ "x$SERVICE_TYPE" = "xfrpc" ] || [ "x$SERVICE_TYPE" = "xclient" ]; then
        SERVICE_NAME="frpc"
        BIN_NAME="frpc"
        CONFIG_NAME="frpc.ini"
    else
        SERVICE_NAME="frps"
        BIN_NAME="frps"
        CONFIG_NAME="frps.ini"
    fi

    if [ "$IS_ALPINE" -eq 1 ]; then
        create_openrc_service "${SERVICE_NAME}" "${BIN_NAME}" "${CONFIG_NAME}"
    else
        create_systemd_service "${SERVICE_NAME}" "${BIN_NAME}" "${CONFIG_NAME}"
    fi
}

# 卸载 FRP
uninstall_frp() {
    MODE="$1"
    SERVICE_NAME="frps"
    if [ "x$MODE" = "xclient" ] || [ "x$MODE" = "xfrpc" ]; then
        SERVICE_NAME="frpc"
    fi

    printf "%b\n" "${YELLOW}正在卸载 ${SERVICE_NAME} ...${PLAIN}"

    if [ "$IS_ALPINE" -eq 1 ]; then
        # 停止并移除 OpenRC 服务
        rc-service "${SERVICE_NAME}" stop >/dev/null 2>&1 || true
        rc-update del "${SERVICE_NAME}" default >/dev/null 2>&1 || true
        rm -f "/etc/init.d/${SERVICE_NAME}"
    else
        systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
        systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    # 删除目录
    rm -rf "$BASE_DIR"
    # 删除404页面目录
    rm -rf "$ERROR_PAGE_DIR"

    printf "%b\n" "${GREEN}卸载完成.${PLAIN}"
}

# 控制服务
control_service() {
    ACTION="$1" # start/stop/restart/status
    MODE="$2"   # server/client
    SERVICE_NAME="frps"
    if [ "x$MODE" = "xclient" ] || [ "x$MODE" = "xfrpc" ]; then
        SERVICE_NAME="frpc"
    fi

    # 检查是否已安装服务脚本
    if [ "$IS_ALPINE" -eq 1 ]; then
        if [ ! -f "/etc/init.d/${SERVICE_NAME}" ]; then
            printf "%b\n" "${RED}服务未安装，请先运行 install.${PLAIN}"
            exit 1
        fi
        rc-service "${SERVICE_NAME}" "${ACTION}"
    else
        if ! systemctl list-unit-files | grep -q "${SERVICE_NAME}.service"; then
            printf "%b\n" "${RED}服务未安装，请先运行 install.${PLAIN}"
            exit 1
        fi
        systemctl "${ACTION}" "${SERVICE_NAME}"
    fi
}

# 查看配置文件
view_config() {
    MODE="$1"
    CONFIG_FILE="$BASE_DIR/frps.ini"
    if [ "x$MODE" = "xclient" ] || [ "x$MODE" = "xfrpc" ]; then
        CONFIG_FILE="$BASE_DIR/frpc.ini"
    fi

    if [ -f "$CONFIG_FILE" ]; then
        printf "%b\n" "${GREEN}================ 配置文件内容: $CONFIG_FILE ================${PLAIN}"
        cat "$CONFIG_FILE"
        printf "%b\n" "${GREEN}========================================================${PLAIN}"
    else
        printf "%b\n" "${RED}配置文件不存在: $CONFIG_FILE${PLAIN}"
    fi
}

# 安装 FRP
install_frp() {
    MODE="$1"
    if [ -z "$MODE" ]; then
        printf "%b\n" "${YELLOW}用法: $0 install [server|client]${PLAIN}"
        exit 1
    fi

    get_arch

    # 下载二进制
    download_frp

    # 赋予执行权限
    if [ -f "$BASE_DIR/frps" ]; then
        chmod +x "$BASE_DIR/frps"
    fi
    if [ -f "$BASE_DIR/frpc" ]; then
        chmod +x "$BASE_DIR/frpc"
    fi

    # 生成配置与页面
    if [ "x$MODE" = "xserver" ]; then
        create_error_page
        create_config "server"
        install_service "frps"
        printf "%b\n" "${GREEN}FRP 服务端 (frps) 安装完成!${PLAIN}"
    else
        create_config "client"
        install_service "frpc"
        printf "%b\n" "${GREEN}FRP 客户端 (frpc) 安装完成!${PLAIN}"
    fi

    printf "%s\n" "=================================="
    printf "%b\n" "${GREEN}程序与配置路径: ${BASE_DIR}${PLAIN}"
    printf "%b\n" "${GREEN}404页面路径: ${ERROR_PAGE_FILE}${PLAIN}"
    printf "%b\n" "${GREEN}日志查看: tail -f ${LOG_DIR}/frp*.log${PLAIN}"
    printf "%s\n" "=================================="
}

# 主菜单
main() {
  if [ $# -eq 0 ]; then
    printf "%b\n" "${GREEN}FRP 一键管理脚本${PLAIN}"
    printf "1. 安装 frps (服务端)\n"
    printf "2. 安装 frpc (客户端)\n"
    printf "3. 启动 frps\n"
    printf "4. 停止 frps\n"
    printf "5. 重启 frps\n"
    printf "6. 查看 frps 状态\n"
    printf "7. 启动 frpc\n"
    printf "8. 停止 frpc\n"
    printf "9. 重启 frpc\n"
    printf "10. 查看 frpc 状态\n"
    printf "11. 卸载 frps\n"
    printf "12. 卸载 frpc\n"
    printf "13. 查看 frps 配置\n"
    printf "14. 查看 frpc 配置\n"
    printf "0. 退出\n"
    printf "请输入数字 [0-14]: "
    read menuChoice
    case "$menuChoice" in
      1)
        install_frp "server"
        ;;
      2)
        install_frp "client"
        ;;
      3)
        control_service "start" "server"
        ;;
      4)
        control_service "stop" "server"
        ;;
      5)
        control_service "restart" "server"
        ;;
      6)
        control_service "status" "server"
        ;;
      7)
        control_service "start" "client"
        ;;
      8)
        control_service "stop" "client"
        ;;
      9)
        control_service "restart" "client"
        ;;
      10)
        control_service "status" "client"
        ;;
      11)
        uninstall_frp "server"
        ;;
      12)
        uninstall_frp "client"
        ;;
      13)
        view_config "server"
        ;;
      14)
        view_config "client"
        ;;
      *)
        exit 0
        ;;
    esac
    exit 0
  fi

    case "$1" in
        install)
            install_frp "$2"
            ;;
        uninstall)
            uninstall_frp "$2"
            ;;
        start|stop|restart|status)
            control_service "$1" "$2"
            ;;
        config)
            view_config "$2"
            ;;
        *)
            printf "未知命令: $1\n"
            main
            ;;
    esac
}

main "$@"
