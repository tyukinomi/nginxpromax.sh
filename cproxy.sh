#!/bin/bash

# =============================
#   ______ _                 _  __             _           
#  / ____| |               (_)/ _|           | |          
# | |    | | ___  _   _ ___ _| |_ ___  _ __ __| | ___ _ __ 
# | |    | |/ _ \| | | / __| |  _/ _ \| '__/ _` |/ _ \ '__|
# | |____| | (_) | |_| \__ \ | || (_) | | | (_| |  __/ |   
#  \_____|_|\___/ \__,_|___/_|_| \___/|_|  \__,_|\___|_|   
# =============================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

CLOUDFLARED_BIN="/usr/bin/cloudflared"
CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
SERVICE_PATH="/etc/systemd/system/cloudflared.service"
LOG_PATH="/var/log/cloudflared.log"

# 主菜单
while true; do
    echo -e "${YELLOW}${BOLD}Cloudflare 内网穿透脚本${RESET}"
    echo "请选择操作:"
    echo "1. 临时运行（获取临时公网域名）"
    echo "2. 安装 cloudflared"
    echo "3. 配置隧道（创建/运行/配置）"
    echo "4. 选择性删除隧道"
    echo "5. 完全删除 cloudflared"
    echo "0. 退出"
    read -p "请输入选择的数字: " CHOICE

    case $CHOICE in
    1)
        # 临时运行
        read -p "请输入要穿透的本地地址（如127.0.0.1:8080）: " LOCAL_ADDR
        echo -e "${BLUE}正在前台运行 cloudflared...${RESET}"
        LOGFILE=$(mktemp)
        stdbuf -oL "$CLOUDFLARED_BIN" tunnel --url "$LOCAL_ADDR" 2>&1 | tee "$LOGFILE" &
        PID=$!
        echo -e "${YELLOW}等待 cloudflared 输出访问域名...${RESET}"
        DOMAIN=""
        for i in {1..30}; do
            # 先尝试常规正则
            DOMAIN=$(grep -oP 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$LOGFILE" | head -n1)
            if [[ -z "$DOMAIN" ]]; then
                # 尝试匹配带空格或特殊字符的行
                DOMAIN=$(grep -oP 'https://[a-zA-Z0-9-]+\.trycloudflare\.com[^ ]*' "$LOGFILE" | head -n1 | tr -d ' |')
            fi
            if [[ -n "$DOMAIN" ]]; then
                echo -e "\n${GREEN}成功获取公网临时访问域名：$DOMAIN${RESET}\n"
                wait $PID
                break
            fi
            sleep 1
        done
        if ! ps -p $PID > /dev/null; then
            :
        else
            echo -e "${RED}超时未能获取临时域名，日志保存在：$LOGFILE${RESET}"
            kill $PID 2>/dev/null || true
        fi
        ;;
    2)
        # 安装 cloudflared
        if [[ -f "$CLOUDFLARED_BIN" ]]; then
            echo -e "${GREEN}cloudflared 已安装，跳过下载。${RESET}"
        else
            echo -e "${YELLOW}请选择下载源：${RESET}"
            echo "1. 官方源 (github.com)"
            echo "2. Github 加速源 (ghproxy.com)"
            read -p "请输入 1 或 2: " DL_CHOICE
            if [[ "$DL_CHOICE" == "2" ]]; then
                ACC_URL="https://ghproxy.com/$CLOUDFLARED_URL"
                echo -e "${BLUE}使用 Github 加速源下载 cloudflared...${RESET}"
                curl -L "$ACC_URL" -o "$CLOUDFLARED_BIN"
            else
                echo -e "${BLUE}使用官方源下载 cloudflared...${RESET}"
                curl -L "$CLOUDFLARED_URL" -o "$CLOUDFLARED_BIN"
            fi
            chmod +x "$CLOUDFLARED_BIN"
            echo -e "${GREEN}cloudflared 安装完成。${RESET}"
        fi
        echo -e "${YELLOW}请在浏览器中完成 Cloudflare 授权...${RESET}"
        "$CLOUDFLARED_BIN" tunnel login
        ;;
    3)
        # 配置隧道
        read -p "请输入隧道名称: " TUNNEL_NAME
        read -p "请输入域名 (如: example.com): " DOMAIN_NAME
        read -p "请输入本地服务端口 (默认为80): " LOCAL_PORT
        LOCAL_PORT=${LOCAL_PORT:-80}
        echo -e "${BLUE}创建隧道...${RESET}"
        "$CLOUDFLARED_BIN" tunnel create "$TUNNEL_NAME"
        UUID=$("$CLOUDFLARED_BIN" tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
        echo -e "${BLUE}将域名 $DOMAIN_NAME 指向隧道...${RESET}"
        "$CLOUDFLARED_BIN" tunnel route dns "$TUNNEL_NAME" "$DOMAIN_NAME"
        CONFIG_FILE="/etc/cloudflared/$TUNNEL_NAME.yml"
        mkdir -p /etc/cloudflared
        cat > $CONFIG_FILE << EOL
tunnel: $UUID
credentials-file: /root/.cloudflared/$UUID.json
ingress:
  - hostname: $DOMAIN_NAME
    service: http://localhost:$LOCAL_PORT
  - service: http_status:404
EOL
        echo -e "${BLUE}验证配置文件...${RESET}"
        "$CLOUDFLARED_BIN" tunnel ingress validate "$CONFIG_FILE"
        echo -e "${BLUE}测试隧道运行...${RESET}"
        "$CLOUDFLARED_BIN" --config "$CONFIG_FILE" tunnel run "$UUID" &
        echo -e "${BLUE}创建系统服务...${RESET}"
        cat > "$SERVICE_PATH" << EOL
[Unit]
Description=cloudflared
After=network.target

[Service]
ExecStart=$CLOUDFLARED_BIN --config $CONFIG_FILE tunnel run
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOL
        systemctl daemon-reload
        systemctl enable cloudflared
        systemctl start cloudflared
        systemctl status cloudflared
        echo -e "${GREEN}完成！Cloudflare Tunnel 已成功设置并正在运行。${RESET}"
        ;;
    4)
        # 选择性删除隧道
        echo -e "${BLUE}列出所有现有的隧道...${RESET}"
        TUNNELS=$("$CLOUDFLARED_BIN" tunnel list | awk 'NR>1 {print $1, $2}')
        if [ -z "$TUNNELS" ]; then
            echo "没有发现任何隧道。"
        else
            echo "可用的隧道列表："
            echo "ID      NAME"
            echo "$TUNNELS"
            read -p "请输入要删除的隧道 ID 或名称: " TUNNEL_INPUT
            TUNNEL_ID=$(echo "$TUNNELS" | grep "$TUNNEL_INPUT" | awk '{print $1}')
            TUNNEL_NAME=$(echo "$TUNNELS" | grep "$TUNNEL_INPUT" | awk '{print $2}')
            if [ -z "$TUNNEL_ID" ]; then
                echo "隧道 $TUNNEL_INPUT 不存在。"
            else
                echo "清理隧道 $TUNNEL_ID 的活动连接..."
                "$CLOUDFLARED_BIN" tunnel cleanup "$TUNNEL_ID"
                echo "正在删除隧道 $TUNNEL_ID..."
                "$CLOUDFLARED_BIN" tunnel delete "$TUNNEL_ID"
                echo "隧道 $TUNNEL_ID 已删除。"
                echo -e "${YELLOW}${BOLD}请自行前往 Cloudflare 官网删除与域名 ${TUNNEL_NAME} 相关的 DNS 记录。${RESET}"
            fi
        fi
        ;;
    5)
        # 完全删除 cloudflared
        echo "停止并禁用 Cloudflared 系统服务..."
        systemctl stop cloudflared
        systemctl disable cloudflared
        echo "删除系统服务文件..."
        rm -f "$SERVICE_PATH"
        systemctl daemon-reload
        echo "删除 Cloudflared 可执行文件..."
        rm -f "$CLOUDFLARED_BIN"
        echo "删除配置文件和隧道凭证..."
        rm -rf /etc/cloudflared
        rm -rf /root/.cloudflared
        echo "删除日志文件..."
        rm -rf "$LOG_PATH"
        echo -e "${GREEN}Cloudflared 以及所有相关文件已成功删除。${RESET}"
        ;;
    0)
        exit 0
        ;;
    *)
        echo -e "${RED}无效的选择，请重新输入。${RESET}"
        ;;
    esac
done 