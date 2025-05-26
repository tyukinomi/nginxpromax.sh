#!/bin/bash

# 显示选择菜单
show_selection_menu() {
    clear
    echo "========================================="
    echo "请选择要使用的 Web 服务器："
    echo "========================================="
    echo "1. Nginx"
    echo "2. Caddy"
    echo "3. 退出"
    echo "========================================="
    read -p "请选择操作： " server_choice

    case $server_choice in
        1)
            # 继续执行 Nginx 相关功能
            return 0
            ;;
        2)
            # 执行 Caddy 相关功能
            manage_caddy
            return 1
            ;;
        3)
            echo "退出脚本"
            exit 0
            ;;
        *)
            echo "无效的选择，请重新选择。"
            read -p "按回车键继续..."
            return 1
            ;;
    esac
}

# Caddy 相关变量
CADDYFILE="/etc/caddy/Caddyfile"
CADDY_CONFIG_DIR="/etc/caddy"
BACKUP_CADDYFILE="${CADDYFILE}.bak"
PROXY_CONFIG_FILE="/root/caddy_reverse_proxies.txt"

# 显示 Caddy 图标
show_caddy_logo() {
  echo -e "\033[32m"
  cat << "EOF"

   ██████╗  █████╗ ██████╗ ██████╗ ██╗   ██╗
  ██╔════╝ ██╔══██╗██╔══██╗██╔══██╗╚██╗ ██╔╝
  ██║  ███╗███████║██║  ██║██║  ██║ ╚████╔╝ 
  ██║   ██║██╔══██║██║  ██║██║  ██║  ╚██╔╝  
  ╚██████╔╝██║  ██║██████╔╝██████╔╝   ██║   
   ╚═════╝ ╚═╝  ╚═╝╚═════╝ ╚═════╝    ╚═╝   

        Modern, HTTP/2-first web server
EOF
  echo -e "\033[0m"
}

# 检查 Caddy 是否已安装
check_caddy_installed() {
    if command -v caddy >/dev/null 2>&1; then
        return 0  # 已安装
    else
        return 1  # 未安装
    fi
}

# 安装 Caddy
install_caddy() {
    echo "开始安装 Caddy..."
    # 检测系统类型
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID
    else
        OS_ID=$(uname -s)
    fi

    case "$OS_ID" in
        ubuntu|debian|kali)
            apt-get update
            apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
                | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
                | tee /etc/apt/sources.list.d/caddy-stable.list
            apt-get update
            apt-get install -y caddy
            ;;
        centos|rhel|almalinux|rocky|fedora)
            if command -v dnf &> /dev/null; then
                dnf install -y 'dnf-command(copr)' || true
                dnf copr enable @caddy/caddy -y
                dnf install -y caddy
            else
                yum install -y yum-plugin-copr || true
                yum copr enable @caddy/caddy -y
                yum install -y caddy
            fi
            ;;
        opensuse*|suse|opensuse-tumbleweed)
            zypper refresh
            zypper install -y caddy
            ;;
        arch|manjaro)
            pacman -Sy --noconfirm caddy
            ;;
        alpine)
            apk update
            apk add caddy
            ;;
        *)
            echo "未检测到已知的Linux发行版，尝试使用通用安装方式。"
            if command -v curl &>/dev/null; then
                curl -fsSL https://get.caddyserver.com | bash -s personal
            elif command -v wget &>/dev/null; then
                wget -O - https://get.caddyserver.com | bash -s personal
            else
                echo "请先安装curl或wget后重试。"
                exit 1
            fi
            ;;
    esac

    if check_caddy_installed; then
        echo "Caddy 安装成功！"
    else
        echo "Caddy 安装失败，请检查日志。"
        exit 1
    fi
}

# 检查指定端口服务是否在运行
check_port_running() {
    local port=$1
    if timeout 1 bash -c "echo > /dev/tcp/127.0.0.1/$port" 2>/dev/null; then
        echo "运行中"
    else
        echo "未运行"
    fi
}

# 配置 Caddy 反向代理
setup_caddy_reverse_proxy() {
    echo "请输入域名（例如 example.com）："
    read domain
    if [ -z "$domain" ]; then
        echo "域名输入不能为空。"
        return
    fi

    echo "请选择上游服务类型："
    echo "1) 本地服务（127.0.0.1）"
    echo "2) 公网 IP 地址"
    echo "3) 其他域名"
    read -p "请选择（1-3）：" upstream_type

    case $upstream_type in
        1)
            echo "请输入本地服务端口（例如 8080）："
            read port
            if [ -z "$port" ]; then
                echo "端口输入不能为空。"
                return
            fi
            upstream="http://127.0.0.1:${port}"
            ;;
        2)
            echo "请输入公网 IP 地址（例如 1.2.3.4）："
            read ip
            if [ -z "$ip" ]; then
                echo "IP 地址不能为空。"
                return
            fi
            echo "请输入端口（留空则使用 80）："
            read port
            port=${port:-80}
            upstream="http://${ip}:${port}"
            ;;
        3)
            echo "请输入目标域名（例如 target.com）："
            read target_domain
            if [ -z "$target_domain" ]; then
                echo "目标域名不能为空。"
                return
            fi
            echo "请输入端口（留空则使用 80）："
            read port
            if [ -z "$port" ]; then
                upstream="http://${target_domain}"
            else
                upstream="http://${target_domain}:${port}"
            fi
            ;;
        *)
            echo "无效的选择。"
            return
            ;;
    esac

    # 检查 Caddyfile 是否备份过，没有则备份一下
    if [ ! -f "$BACKUP_CADDYFILE" ]; then
        cp "$CADDYFILE" "$BACKUP_CADDYFILE"
    fi

    # 添加新的反向代理配置到 Caddyfile
    echo "配置反向代理：${domain} -> ${upstream}"
    echo "${domain} {
    reverse_proxy ${upstream} {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
    }
}" | tee -a "$CADDYFILE" >/dev/null

    # 将配置信息保存到代理配置列表文件
    echo "${domain} -> ${upstream}" >> "$PROXY_CONFIG_FILE"

    # 重启 Caddy 以应用配置
    echo "正在重启 Caddy 服务以应用新配置..."
    systemctl restart caddy

    # 检查上游服务状态
    if [ "$upstream_type" = "1" ]; then
        status=$(check_port_running "$port")
        echo "上游服务（127.0.0.1:${port}）状态：$status"
    fi
    echo "Caddy 服务状态："
    systemctl status caddy --no-pager
}

# 查看 Caddy 服务状态
show_caddy_status() {
    if check_caddy_installed; then
        echo "Caddy 服务状态："
        systemctl status caddy --no-pager
    else
        echo "系统中未安装 Caddy。"
    fi
}

# 查看 Caddy 反向代理配置
show_caddy_reverse_proxies() {
    if [ -f "$PROXY_CONFIG_FILE" ]; then
        echo "当前反向代理配置："
        lineno=0
        while IFS= read -r line; do
            lineno=$((lineno+1))
            port=$(echo "$line" | grep -oE '[0-9]{2,5}$')
            status=$(check_port_running "$port")
            echo "${lineno}) ${line} [上游服务状态：$status]"
        done < "$PROXY_CONFIG_FILE"
    else
        echo "没有配置任何反向代理。"
    fi
}

# 删除 Caddy 反向代理
delete_caddy_reverse_proxy() {
    show_caddy_reverse_proxies
    echo "请输入要删除的反向代理配置编号："
    read proxy_number
    if [ -z "$proxy_number" ]; then
        echo "无效的输入。"
        return
    fi

    # 删除对应行
    sed -i "${proxy_number}d" "$PROXY_CONFIG_FILE"

    # 重新生成 Caddyfile 配置（恢复为备份版本）
    echo "重新生成 Caddyfile 配置..."
    cp "$BACKUP_CADDYFILE" "$CADDYFILE"

    # 根据代理配置列表重新添加剩余配置
    if [ -f "$PROXY_CONFIG_FILE" ]; then
        while IFS= read -r line; do
            domain=$(echo "$line" | awk -F' -> ' '{print $1}')
            upstream=$(echo "$line" | awk -F' -> ' '{print $2}')
            echo "${domain} {
    reverse_proxy ${upstream} {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
    }
}" | tee -a "$CADDYFILE" >/dev/null
        done < "$PROXY_CONFIG_FILE"
    fi

    # 重启 Caddy 服务
    echo "重启 Caddy 服务..."
    systemctl restart caddy
    echo "反向代理删除成功！"
}

# 重启 Caddy 服务
restart_caddy() {
    echo "正在重启 Caddy 服务..."
    systemctl restart caddy
    echo "Caddy 服务已重启。"
    systemctl status caddy --no-pager
}

# 卸载 Caddy
remove_caddy() {
    echo "确定要卸载 Caddy 并删除配置文件吗？(y/n)"
    read confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 停止并卸载
        systemctl stop caddy
        apt-get remove --purge -y caddy

        # 删除仓库源
        rm -f /etc/apt/sources.list.d/caddy-stable.list
        apt-get update

        # 删除配置文件
        if [ -f "$BACKUP_CADDYFILE" ]; then
            rm -f "$CADDYFILE" "$BACKUP_CADDYFILE"
        else
            rm -f "$CADDYFILE"
        fi

        # 删除反向代理配置文件
        if [ -f "$PROXY_CONFIG_FILE" ]; then
            rm -f "$PROXY_CONFIG_FILE"
        fi

        echo "Caddy 已卸载并删除配置文件。"
    else
        echo "操作已取消。"
    fi
}

# Caddy 管理菜单
manage_caddy() {
    while true; do
        clear
        # 显示 Caddy 图标
        show_caddy_logo
        
        echo "============================================="
        # 显示 Caddy 运行状态
        caddy_status=$(systemctl is-active caddy 2>/dev/null)
        if [ "$caddy_status" == "active" ]; then
            echo "Caddy 状态：运行中"
        else
            echo "Caddy 状态：未运行"
        fi
        echo "           Caddy 一键部署 & 管理脚本          "
        echo "============================================="
        echo " 1) 安装 Caddy（如已安装则跳过）"
        echo " 2) 配置 & 启用反向代理（输入域名及上游端口）"
        echo " 3) 查看 Caddy 服务状态"
        echo " 4) 查看当前反向代理配置（显示上游服务状态）"
        echo " 5) 删除指定的反向代理"
        echo " 6) 重启 Caddy 服务"
        echo " 7) 卸载 Caddy（删除配置）"
        echo " 0) 返回主菜单"
        echo "============================================="
        
        read -p "请输入选项: " opt
        case "$opt" in
            1)
                if check_caddy_installed; then
                    echo "Caddy 已安装，跳过安装。"
                else
                    install_caddy
                fi
                ;;
            2)
                if ! check_caddy_installed; then
                    echo "Caddy 未安装，先执行安装步骤。"
                    install_caddy
                fi
                setup_caddy_reverse_proxy
                ;;
            3)
                show_caddy_status
                ;;
            4)
                show_caddy_reverse_proxies
                ;;
            5)
                delete_caddy_reverse_proxy
                ;;
            6)
                restart_caddy
                ;;
            7)
                remove_caddy
                ;;
            0)
                return
                ;;
            *)
                echo "无效选项，请重新输入。"
                ;;
        esac
        echo
        read -p "按回车键继续..."
    done
}

# 检查是否以 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 用户运行此脚本。"
  exit 1
fi

# 定义日志目录
LOG_DIR="/var/log/nginx"
SITES_DIR="/etc/nginx/sites-available"

# 检测系统类型
detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    VER=$VERSION_ID
  elif type lsb_release >/dev/null 2>&1; then
    OS=$(lsb_release -si)
    VER=$(lsb_release -sr)
  elif [ -f /etc/lsb-release ]; then
    . /etc/lsb-release
    OS=$DISTRIB_ID
    VER=$DISTRIB_RELEASE
  elif [ -f /etc/debian_version ]; then
    OS=Debian
    VER=$(cat /etc/debian_version)
  elif [ -f /etc/SuSe-release ]; then
    OS=SuSE
  elif [ -f /etc/redhat-release ]; then
    OS=RedHat
  else
    OS=$(uname -s)
    VER=$(uname -r)
  fi
  echo "$OS"
}

# 安装 Nginx
install_nginx() {
  echo "正在安装 Nginx..."
  OS=$(detect_os)
  
  case $OS in
    "Ubuntu"|"Debian GNU/Linux"|"Debian")
      apt update && apt install -y nginx
      ;;
    "CentOS Linux"|"Red Hat Enterprise Linux"|"Fedora")
      if command -v dnf &> /dev/null; then
        dnf install -y epel-release
        dnf install -y nginx
      else
        yum install -y epel-release
        yum install -y nginx
      fi
      ;;
    "openSUSE"|"SUSE Linux Enterprise Server")
      zypper install -y nginx
      ;;
    "Arch Linux")
      pacman -S --noconfirm nginx
      ;;
    *)
      echo "不支持的操作系统: $OS"
      exit 1
      ;;
  esac
  
  if [ $? -eq 0 ]; then
    echo "Nginx 安装完成！"
    # 创建自定义配置目录
    mkdir -p /etc/nginx/conf.d/blacklist
    mkdir -p /etc/nginx/conf.d/whitelist
    mkdir -p /etc/nginx/conf.d/auth
    mkdir -p /etc/nginx/conf.d/cache
    mkdir -p /etc/nginx/conf.d/waf
    
    # 创建初始黑白名单文件
    touch /etc/nginx/conf.d/blacklist/ip.conf
    touch /etc/nginx/conf.d/whitelist/ip.conf
    
    # 确保黑名单文件格式正确，避免语法错误
    echo "# 全局黑名单配置" > /etc/nginx/conf.d/blacklist/ip.conf
    echo "# 格式: deny IP;" >> /etc/nginx/conf.d/blacklist/ip.conf
    
    echo "# 全局白名单配置" > /etc/nginx/conf.d/whitelist/ip.conf
    echo "# 格式: allow IP;" >> /etc/nginx/conf.d/whitelist/ip.conf
    
    # 重启 Nginx 使配置生效
    systemctl restart nginx
  else
    echo "Nginx 安装失败，请检查日志。"
    exit 1
  fi
}

# 安装 Certbot
install_certbot() {
  echo "正在安装 Certbot..."
  OS=$(detect_os)
  
  case $OS in
    "Ubuntu"|"Debian GNU/Linux"|"Debian")
      apt update && apt install -y certbot python3-certbot-nginx
      ;;
    "CentOS Linux"|"Red Hat Enterprise Linux"|"Fedora")
      if command -v dnf &> /dev/null; then
        dnf install -y certbot python3-certbot-nginx
      else
        yum install -y certbot python3-certbot-nginx
      fi
      ;;
    "openSUSE"|"SUSE Linux Enterprise Server")
      zypper install -y certbot python3-certbot-nginx
      ;;
    "Arch Linux")
      pacman -S --noconfirm certbot certbot-nginx
      ;;
    *)
      echo "不支持的操作系统: $OS"
      exit 1
      ;;
  esac
  
  if [ $? -eq 0 ]; then
    echo "Certbot 安装完成！"
  else
    echo "Certbot 安装失败，请检查日志。"
    exit 1
  fi
}

# 人类可读的流量格式化函数
format_size() {
  local size=$(printf "%.0f" "$1")
  if (( size < 1024 )); then
    echo "${size} B"
  elif (( size < 1048576 )); then
    echo "$(( size / 1024 )) KB"
  elif (( size < 1073741824 )); then
    echo "$(( size / 1048576 )) MB"
  else
    echo "$(( size / 1073741824 )) GB"
  fi
}

# 配置反向代理
add_proxy() {
  read -p "请输入域名： " domain
  read -p "请输入反向代理的目标地址（支持IP或域名）： " target_host
  read -p "目标是否为域名？(y/n)： " is_domain
  
  if [[ "$is_domain" != "y" && "$is_domain" != "Y" ]]; then
    read -p "请输入反向代理的目标端口： " target_port
    proxy_pass="http://$target_host:$target_port"
  else
    proxy_pass="http://$target_host"
  fi
  
  read -p "是否启用SSL (y/n)： " enable_ssl
  read -p "是否启用IP白名单 (y/n)： " enable_whitelist
  read -p "是否启用IP黑名单 (y/n)： " enable_blacklist
  read -p "是否启用密码保护 (y/n)： " enable_auth
  
  config_file="/etc/nginx/sites-available/$domain"
  echo "正在添加反向代理配置..."

  # 创建基本配置
  cat > "$config_file" <<EOL
server {
    listen 80;
    server_name $domain;
    
    # 日志配置
    access_log /var/log/nginx/${domain}_access.log;
    error_log /var/log/nginx/${domain}_error.log;

EOL

  # 添加IP白名单配置
  if [[ "$enable_whitelist" == "y" || "$enable_whitelist" == "Y" ]]; then
    cat >> "$config_file" <<EOL
    # IP白名单配置
    include /etc/nginx/conf.d/whitelist/${domain}_ip.conf;
    
EOL
    # 创建域名特定的白名单配置
    touch "/etc/nginx/conf.d/whitelist/${domain}_ip.conf"
    echo "    # 默认白名单配置" > "/etc/nginx/conf.d/whitelist/${domain}_ip.conf"
    echo "    # 格式: allow IP;" >> "/etc/nginx/conf.d/whitelist/${domain}_ip.conf"
    echo "    # 例如: allow 192.168.1.1;" >> "/etc/nginx/conf.d/whitelist/${domain}_ip.conf"
    echo "    deny all;" >> "/etc/nginx/conf.d/whitelist/${domain}_ip.conf"
    
    echo "已创建白名单配置文件: /etc/nginx/conf.d/whitelist/${domain}_ip.conf"
    echo "请手动编辑此文件添加允许的IP地址。"
  fi

  # 添加IP黑名单配置
  if [[ "$enable_blacklist" == "y" || "$enable_blacklist" == "Y" ]]; then
    cat >> "$config_file" <<EOL
    # IP黑名单配置
    include /etc/nginx/conf.d/blacklist/${domain}_ip.conf;
    
EOL
    # 创建域名特定的黑名单配置
    touch "/etc/nginx/conf.d/blacklist/${domain}_ip.conf"
    echo "    # 默认黑名单配置" > "/etc/nginx/conf.d/blacklist/${domain}_ip.conf"
    echo "    # 格式: deny IP;" >> "/etc/nginx/conf.d/blacklist/${domain}_ip.conf"
    echo "    # 例如: deny 192.168.1.100;" >> "/etc/nginx/conf.d/blacklist/${domain}_ip.conf"
    
    echo "已创建黑名单配置文件: /etc/nginx/conf.d/blacklist/${domain}_ip.conf"
    echo "请手动编辑此文件添加禁止的IP地址。"
  fi

  # 添加密码保护配置
  if [[ "$enable_auth" == "y" || "$enable_auth" == "Y" ]]; then
    # 创建密码文件
    if [ ! -f "/etc/nginx/conf.d/auth/${domain}.htpasswd" ]; then
      read -p "请输入用户名: " auth_user
      # 安装 apache2-utils 以使用 htpasswd
      OS=$(detect_os)
      case $OS in
        "Ubuntu"|"Debian GNU/Linux"|"Debian")
          apt install -y apache2-utils
          ;;
        "CentOS Linux"|"Red Hat Enterprise Linux"|"Fedora")
          if command -v dnf &> /dev/null; then
            dnf install -y httpd-tools
          else
            yum install -y httpd-tools
          fi
          ;;
        "openSUSE"|"SUSE Linux Enterprise Server")
          zypper install -y apache2-utils
          ;;
        "Arch Linux")
          pacman -S --noconfirm apache
          ;;
      esac
      htpasswd -c "/etc/nginx/conf.d/auth/${domain}.htpasswd" "$auth_user"
    fi
    
    cat >> "$config_file" <<EOL
    # 密码保护配置
    auth_basic "Restricted Area";
    auth_basic_user_file /etc/nginx/conf.d/auth/${domain}.htpasswd;
    
EOL
  fi

  # 添加反向代理配置
  cat >> "$config_file" <<EOL
    location / {
        proxy_pass $proxy_pass;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # 超时设置
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        # 缓冲区设置
        proxy_buffer_size 4k;
        proxy_buffers 4 32k;
        proxy_busy_buffers_size 64k;
        
        # 其他优化设置
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }
}
EOL

  ln -sf "$config_file" "/etc/nginx/sites-enabled/"
  systemctl reload nginx

  echo "反向代理 $domain -> $proxy_pass 配置完成！"

  if [[ "$enable_ssl" == "y" || "$enable_ssl" == "Y" ]]; then
    apply_ssl_cert "$domain"
  fi
}

# 申请 SSL 证书
apply_ssl_cert() {
  local domain=$1
  
  echo "正在为 $domain 申请 Let's Encrypt SSL 证书..."
  
  # 检查 DNS 解析是否正确指向此服务器
  echo "确保域名 $domain 已正确解析到此服务器的IP地址。"
  read -p "按回车键继续..."
  
  # 使用 certbot 申请证书
  certbot --nginx -d "$domain" --non-interactive --agree-tos --redirect --hsts --staple-ocsp --email "admin@$domain"
  
  if [ $? -eq 0 ]; then
    echo "SSL 证书申请成功！已自动配置 Nginx 使用 HTTPS。"
    echo "证书将自动续签。"
  else
    echo "SSL 证书申请失败，请检查日志和域名解析。"
  fi
}

# 为现有域名申请 SSL 证书
apply_ssl_to_existing() {
  list_proxies
  read -p "请输入要申请 SSL 证书的域名： " domain
  config_file="/etc/nginx/sites-available/$domain"

  if [ -f "$config_file" ]; then
    apply_ssl_cert "$domain"
  else
    echo "未找到配置文件：$domain"
  fi
}

# 手动续签所有 SSL 证书
renew_ssl_certs() {
  echo "正在续签所有 SSL 证书..."
  certbot renew
  if [ $? -eq 0 ]; then
    echo "所有证书已尝试续签。"
  else
    echo "证书续签过程中出现错误，请检查日志。"
  fi
}

# 设置 SSL 证书自动续签（添加到 crontab）
setup_auto_renew() {
  echo "正在配置 SSL 证书自动续签..."
  
  # 检查 crontab 中是否已存在续签任务
  crontab -l | grep -q "certbot renew"
  if [ $? -eq 0 ]; then
    echo "自动续签任务已经存在。"
  else
    # 添加每天两次检查的 crontab 条目
    (crontab -l 2>/dev/null || echo "") | grep -v "certbot renew" | { cat; echo "0 0,12 * * * /usr/bin/certbot renew --quiet --post-hook \"systemctl reload nginx\""; } | crontab -
    if [ $? -eq 0 ]; then
      echo "已添加自动续签任务到 crontab，每天 0:00 和 12:00 自动检查并续签。"
    else
      echo "添加自动续签任务失败。"
    fi
  fi
}

# 删除反向代理配置
delete_proxy() {
  read -p "请输入要删除的域名： " domain
  config_file="/etc/nginx/sites-available/$domain"

  if [ -f "$config_file" ]; then
    # 询问是否同时撤销 SSL 证书
    read -p "是否同时撤销该域名的 SSL 证书? (y/n): " revoke_ssl
    
    if [[ "$revoke_ssl" == "y" || "$revoke_ssl" == "Y" ]]; then
      echo "正在撤销 $domain 的 SSL 证书..."
      certbot revoke --cert-name "$domain" --delete-after-revoke
    fi
    
    # 删除相关配置文件
    rm -f "$config_file"
    rm -f "/etc/nginx/sites-enabled/$domain"
    rm -f "/etc/nginx/conf.d/whitelist/${domain}_ip.conf"
    rm -f "/etc/nginx/conf.d/blacklist/${domain}_ip.conf"
    rm -f "/etc/nginx/conf.d/auth/${domain}.htpasswd"
    
    systemctl reload nginx
    echo "$domain 配置已删除！"
  else
    echo "未找到配置文件：$domain"
  fi
}

# 查看所有反向代理配置
list_proxies() {
  echo "当前所有反向代理配置："
  ls -la /etc/nginx/sites-available/
}

# 查看 SSL 证书状态
list_ssl_certs() {
  echo "当前所有 SSL 证书状态："
  certbot certificates
}

# 检查 Nginx 是否正在运行
nginx_status() {
  systemctl is-active --quiet nginx
  if [ $? -eq 0 ]; then
    echo -e "\033[32mNginx 正在运行。\033[0m"  # Green color for running
  else
    echo -e "\033[31mNginx 未运行。\033[0m"  # Red color for not running
  fi
}

# 重启 Nginx
restart_nginx() {
  echo "正在重启 Nginx..."
  systemctl restart nginx
  if [ $? -eq 0 ]; then
    echo "Nginx 重启成功！"
  else
    echo "Nginx 重启失败，请检查日志。"
  fi
}

# 修改反向代理配置
modify_proxy() {
  list_proxies
  read -p "请输入要修改的域名： " domain
  config_file="/etc/nginx/sites-available/$domain"

  if [ -f "$config_file" ]; then
    echo "当前配置如下："
    cat "$config_file"
    read -p "请输入新的反向代理目标地址（支持IP或域名）： " target_host
    read -p "目标是否为域名？(y/n)： " is_domain
    
    if [[ "$is_domain" != "y" && "$is_domain" != "Y" ]]; then
      read -p "请输入新的反向代理目标端口： " target_port
      proxy_pass="http://$target_host:$target_port"
    else
      proxy_pass="http://$target_host"
    fi

    # 备份原始配置
    cp "$config_file" "${config_file}.bak"
    
    # 更新配置文件
    sed -i "s|proxy_pass http://[^;]*;|proxy_pass $proxy_pass;|" "$config_file"

    # 重载 Nginx 配置
    systemctl reload nginx
    echo "$domain 的反向代理目标已更新为 $proxy_pass。"
    
    # 询问是否需要 SSL
    if ! grep -q "ssl_certificate" "$config_file"; then
      read -p "是否为此域名启用 SSL? (y/n): " enable_ssl
      if [[ "$enable_ssl" == "y" || "$enable_ssl" == "Y" ]]; then
        apply_ssl_cert "$domain"
      fi
    fi
  else
    echo "未找到配置文件：$domain"
  fi
}

# 一键删除并卸载 Nginx 和 Certbot
uninstall_all() {
  echo "正在删除所有反向代理配置和 SSL 证书..."
  
  # 撤销所有证书
  echo "正在尝试撤销所有 SSL 证书..."
  certbot revoke --non-interactive --delete-after-revoke
  
  # 删除配置
  rm -rf /etc/nginx/sites-available/*
  rm -rf /etc/nginx/sites-enabled/*
  rm -rf /etc/nginx/conf.d/blacklist/*
  rm -rf /etc/nginx/conf.d/whitelist/*
  rm -rf /etc/nginx/conf.d/auth/*
  
  # 停止服务
  systemctl stop nginx
  systemctl disable nginx
  
  # 卸载软件
  apt remove --purge -y nginx nginx-common nginx-full certbot python3-certbot-nginx apache2-utils
  apt autoremove -y
  
  # 删除 crontab 中的自动续签
  (crontab -l 2>/dev/null | grep -v "certbot renew") | crontab -
  
  echo "Nginx 和 Certbot 已卸载，所有反向代理配置和 SSL 证书已删除！"
}

# 显示 Nginx 日志
view_nginx_logs() {
  echo "显示最近的 Nginx 错误日志："
  tail -n 50 /var/log/nginx/error.log
  
  echo -e "\n显示最近的 Nginx 访问日志："
  tail -n 20 /var/log/nginx/access.log
}

# 网站流量统计
site_traffic_stats() {
  echo "网站流量统计"
  echo "1. 查看所有站点流量概览"
  echo "2. 查看特定站点详细流量"
  echo "3. 查看特定 IP 的访问日志"
  echo "4. 返回主菜单"
  
  read -p "请选择操作： " stats_choice
  
  case $stats_choice in
    1)
      # 列出所有站点并统计汇总数据
      local total_requests=0
      local total_traffic=0
      declare -A site_requests
      declare -A site_traffic
      
      echo "📌 站点列表:"
      for site in "/etc/nginx/sites-available"/*; do
        [[ -f "$site" ]] || continue
        site_name=$(basename "$site")
        log_path="/var/log/nginx/${site_name}_access.log"
        
        if [[ ! -f "$log_path" ]]; then
          echo "  ❌ $site_name (无日志)"
          continue
        fi
        
        # 统计该站点请求数 & 总流量
        requests=$(wc -l < "$log_path" 2>/dev/null || echo 0)
        traffic=$(awk '{size=$10} size ~ /^[0-9]+$/ {sum += size} END {printf "%.0f", sum}' "$log_path" 2>/dev/null || echo 0)
        traffic=${traffic:-0}
        
        site_requests["$site_name"]=$requests
        site_traffic["$site_name"]=$traffic
        total_requests=$((total_requests + requests))
        total_traffic=$((total_traffic + traffic))
        
        echo "  ✅ $site_name - 请求数: $requests, 流量: $(format_size "$traffic")"
      done
      
      # 汇总数据
      echo -e "\n📊 站点总览"
      echo "  🌐 站点总数: ${#site_requests[@]}"
      echo "  📥 总请求数: $total_requests"
      echo "  📊 总流量: $(format_size "$total_traffic")"
      
      # 按请求数排序站点
      echo -e "\n📈 Top 5 站点 (按请求数)"
      for site in "${!site_requests[@]}"; do
        echo "${site_requests[$site]} $site"
      done | sort -nr | head -n 5 | awk '{printf "  %-15s 请求数: %s\n", $2, $1}'
      
      # 按流量排序站点
      echo -e "\n💾 Top 5 站点 (按流量)"
      for site in "${!site_traffic[@]}"; do
        echo "${site_traffic[$site]} $site"
      done | sort -nr | head -n 5 | while read -r size site; do
        echo "  $site 流量: $(format_size "$size")"
      done
      ;;
    2)
      read -p "请输入站点名称： " site_name
      log_path="/var/log/nginx/${site_name}_access.log"
      
      if [[ ! -f "$log_path" ]]; then
        echo "错误: 访问日志 $log_path 不存在！"
        return
      fi
      
      echo "日志文件: $log_path"
      
      # 统计请求最多的 10 个 IP
      echo -e "\n📊 请求数最多的 IP:"
      awk '{print $1}' "$log_path" | sort | uniq -c | sort -nr | head -n 10 | awk '{printf "  %-15s 请求数: %s\n", $2, $1}'
      
      # 统计流量最多的 10 个 IP
      echo -e "\n📊 消耗带宽最多的 IP:"
      awk '{ip=$1; size=$10} size ~ /^[0-9]+$/ {traffic[ip] += size} END {for (ip in traffic) printf "%.0f %s\n", traffic[ip], ip}' "$log_path" \
        | sort -nr | head -n 10 | while read -r size ip; do
        echo "  $ip 流量: $(format_size "$size")"
      done
      
      # 统计访问最多的 10 个 URL
      echo -e "\n📊 访问最多的 URL:"
      awk '{print $7}' "$log_path" | sort | uniq -c | sort -nr | head -n 10 | awk '{printf "  %-30s 请求数: %s\n", $2, $1}'
      
      # 统计状态码分布
      echo -e "\n📊 HTTP 状态码分布:"
      awk '{print $9}' "$log_path" | sort | uniq -c | sort -nr | awk '{printf "  HTTP %s: %s 次\n", $2, $1}'
      ;;
    3)
      read -p "请输入要查询的 IP 地址： " ip_addr
      read -p "请输入保存日志的文件路径 (默认: /tmp/ip_logs.txt)： " output_file
      output_file=${output_file:-/tmp/ip_logs.txt}
      
      echo "📂 正在搜索与 IP $ip_addr 相关的日志..."
      > "$output_file"  # 清空输出文件
      
      found=0
      for log_file in /var/log/nginx/*_access.log; do
        if [[ -f "$log_file" ]]; then
          if grep -q "$ip_addr" "$log_file"; then
            grep "$ip_addr" "$log_file" >> "$output_file"
            found=1
          fi
        fi
      done
      
      if [[ $found -eq 1 ]]; then
        echo "✅ 日志已保存到: $output_file"
        echo "前 10 行日志预览:"
        head -n 10 "$output_file"
      else
        echo "❌ 没有找到与 $ip_addr 相关的日志！"
      fi
      ;;
    4)
      return
      ;;
    *)
      echo "无效的选择，请重新选择。"
      ;;
  esac
}

# 管理 IP 黑名单
manage_blacklist() {
  echo "IP 黑名单管理"
  echo "1. 查看全局黑名单"
  echo "2. 添加 IP 到全局黑名单"
  echo "3. 从全局黑名单移除 IP"
  echo "4. 查看特定域名黑名单"
  echo "5. 添加 IP 到特定域名黑名单"
  echo "6. 从特定域名黑名单移除 IP"
  echo "7. 返回主菜单"
  
  read -p "请选择操作： " bl_choice
  
  case $bl_choice in
    1)
      if [ -f "/etc/nginx/conf.d/blacklist/ip.conf" ]; then
        echo "全局 IP 黑名单："
        cat /etc/nginx/conf.d/blacklist/ip.conf
      else
        echo "全局黑名单文件不存在，正在创建..."
        mkdir -p /etc/nginx/conf.d/blacklist
        echo "# 全局黑名单配置" > /etc/nginx/conf.d/blacklist/ip.conf
        echo "# 格式: deny IP;" >> /etc/nginx/conf.d/blacklist/ip.conf
        echo "已创建空白全局黑名单文件。"
      fi
      ;;
    2)
      if [ ! -d "/etc/nginx/conf.d/blacklist" ]; then
        mkdir -p /etc/nginx/conf.d/blacklist
      fi
      
      if [ ! -f "/etc/nginx/conf.d/blacklist/ip.conf" ]; then
        echo "# 全局黑名单配置" > /etc/nginx/conf.d/blacklist/ip.conf
        echo "# 格式: deny IP;" >> /etc/nginx/conf.d/blacklist/ip.conf
      fi
      
      read -p "请输入要添加到全局黑名单的 IP： " ip
      # 检查IP格式是否有效
      if [[ ! $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "IP 格式无效，请输入有效的 IPv4 地址。"
        return
      fi
      
      # 检查是否已存在
      if grep -q "deny $ip;" /etc/nginx/conf.d/blacklist/ip.conf; then
        echo "IP $ip 已在黑名单中。"
        return
      fi
      
      echo "deny $ip;" >> /etc/nginx/conf.d/blacklist/ip.conf
      
      # 确保主配置文件包含黑名单
      if ! grep -q "include /etc/nginx/conf.d/blacklist/ip.conf;" /etc/nginx/nginx.conf; then
        # 在 http 块中添加包含语句
        sed -i '/http {/a \    include /etc/nginx/conf.d/blacklist/ip.conf;' /etc/nginx/nginx.conf
      fi
      
      # 测试配置文件语法
      nginx -t
      if [ $? -eq 0 ]; then
        systemctl reload nginx
        echo "IP $ip 已添加到全局黑名单。"
      else
        echo "Nginx 配置测试失败，回滚更改..."
        sed -i "/deny $ip;/d" /etc/nginx/conf.d/blacklist/ip.conf
        echo "操作已取消。"
      fi
      ;;
    3)
      if [ -f "/etc/nginx/conf.d/blacklist/ip.conf" ]; then
        read -p "请输入要从全局黑名单移除的 IP： " ip
        sed -i "/deny $ip;/d" /etc/nginx/conf.d/blacklist/ip.conf
        systemctl reload nginx
        echo "IP $ip 已从全局黑名单移除。"
      else
        echo "全局黑名单文件不存在。"
      fi
      ;;
    4)
      read -p "请输入域名： " domain
      if [ -f "/etc/nginx/conf.d/blacklist/${domain}_ip.conf" ]; then
        echo "$domain 的 IP 黑名单："
        cat "/etc/nginx/conf.d/blacklist/${domain}_ip.conf"
      else
        echo "未找到 $domain 的黑名单配置。"
      fi
      ;;
    5)
      read -p "请输入域名： " domain
      config_file="/etc/nginx/sites-available/$domain"
      
      if [ ! -f "$config_file" ]; then
        echo "未找到 $domain 的配置文件。"
        return
      fi
      
      if [ ! -d "/etc/nginx/conf.d/blacklist" ]; then
        mkdir -p /etc/nginx/conf.d/blacklist
      fi
      
      blacklist_file="/etc/nginx/conf.d/blacklist/${domain}_ip.conf"
      
      if [ ! -f "$blacklist_file" ]; then
        touch "$blacklist_file"
        # 在域名配置文件中添加包含语句
        sed -i '/server {/a \    include /etc/nginx/conf.d/blacklist/'"$domain"'_ip.conf;' "$config_file"
      fi
      
      read -p "请输入要添加到黑名单的 IP： " ip
      echo "deny $ip;" >> "$blacklist_file"
      systemctl reload nginx
      echo "IP $ip 已添加到 $domain 的黑名单。"
      ;;
    6)
      read -p "请输入域名： " domain
      if [ -f "/etc/nginx/conf.d/blacklist/${domain}_ip.conf" ]; then
        read -p "请输入要从黑名单移除的 IP： " ip
        sed -i "/deny $ip;/d" "/etc/nginx/conf.d/blacklist/${domain}_ip.conf"
        systemctl reload nginx
        echo "IP $ip 已从 $domain 的黑名单移除。"
      else
        echo "未找到 $domain 的黑名单配置。"
      fi
      ;;
    7)
      return
      ;;
    *)
      echo "无效的选择，请重新选择。"
      ;;
  esac
}

# 管理 IP 白名单
manage_whitelist() {
  echo "IP 白名单管理"
  echo "1. 查看全局白名单"
  echo "2. 添加 IP 到全局白名单"
  echo "3. 从全局白名单移除 IP"
  echo "4. 查看特定域名白名单"
  echo "5. 添加 IP 到特定域名白名单"
  echo "6. 从特定域名白名单移除 IP"
  echo "7. 启用/禁用特定域名的白名单模式"
  echo "8. 返回主菜单"
  
  read -p "请选择操作： " wl_choice
  
  case $wl_choice in
    1)
      if [ -f "/etc/nginx/conf.d/whitelist/ip.conf" ]; then
        echo "全局 IP 白名单："
        cat /etc/nginx/conf.d/whitelist/ip.conf
      else
        echo "全局白名单文件不存在，正在创建..."
        mkdir -p /etc/nginx/conf.d/whitelist
        touch /etc/nginx/conf.d/whitelist/ip.conf
        echo "已创建空白全局白名单文件。"
      fi
      ;;
    2)
      if [ ! -d "/etc/nginx/conf.d/whitelist" ]; then
        mkdir -p /etc/nginx/conf.d/whitelist
      fi
      
      if [ ! -f "/etc/nginx/conf.d/whitelist/ip.conf" ]; then
        touch /etc/nginx/conf.d/whitelist/ip.conf
      fi
      
      read -p "请输入要添加到全局白名单的 IP： " ip
      echo "allow $ip;" >> /etc/nginx/conf.d/whitelist/ip.conf
      
      # 确保主配置文件包含白名单
      if ! grep -q "include /etc/nginx/conf.d/whitelist/ip.conf;" /etc/nginx/nginx.conf; then
        # 在 http 块中添加包含语句
        sed -i '/http {/a \    include /etc/nginx/conf.d/whitelist/ip.conf;' /etc/nginx/nginx.conf
      fi
      
      systemctl reload nginx
      echo "IP $ip 已添加到全局白名单。"
      ;;
    3)
      if [ -f "/etc/nginx/conf.d/whitelist/ip.conf" ]; then
        read -p "请输入要从全局白名单移除的 IP： " ip
        sed -i "/allow $ip;/d" /etc/nginx/conf.d/whitelist/ip.conf
        systemctl reload nginx
        echo "IP $ip 已从全局白名单移除。"
      else
        echo "全局白名单文件不存在。"
      fi
      ;;
    4)
      read -p "请输入域名： " domain
      if [ -f "/etc/nginx/conf.d/whitelist/${domain}_ip.conf" ]; then
        echo "$domain 的 IP 白名单："
        cat "/etc/nginx/conf.d/whitelist/${domain}_ip.conf"
      else
        echo "未找到 $domain 的白名单配置。"
      fi
      ;;
    5)
      read -p "请输入域名： " domain
      config_file="/etc/nginx/sites-available/$domain"
      
      if [ ! -f "$config_file" ]; then
        echo "未找到 $domain 的配置文件。"
        return
      fi
      
      if [ ! -d "/etc/nginx/conf.d/whitelist" ]; then
        mkdir -p /etc/nginx/conf.d/whitelist
      fi
      
      whitelist_file="/etc/nginx/conf.d/whitelist/${domain}_ip.conf"
      
      if [ ! -f "$whitelist_file" ]; then
        touch "$whitelist_file"
        # 在域名配置文件中添加包含语句
        sed -i '/server {/a \    include /etc/nginx/conf.d/whitelist/'"$domain"'_ip.conf;' "$config_file"
      fi
      
      read -p "请输入要添加到白名单的 IP： " ip
      
      # 检查是否已有 deny all 指令
      if grep -q "deny all;" "$whitelist_file"; then
        # 在 deny all 之前插入新的 allow 指令
        sed -i "/deny all;/i allow $ip;" "$whitelist_file"
      else
        # 如果没有 deny all，则直接添加 allow 指令
        echo "allow $ip;" >> "$whitelist_file"
      fi
      
      systemctl reload nginx
      echo "IP $ip 已添加到 $domain 的白名单。"
      ;;
    6)
      read -p "请输入域名： " domain
      if [ -f "/etc/nginx/conf.d/whitelist/${domain}_ip.conf" ]; then
        read -p "请输入要从白名单移除的 IP： " ip
        sed -i "/allow $ip;/d" "/etc/nginx/conf.d/whitelist/${domain}_ip.conf"
        systemctl reload nginx
        echo "IP $ip 已从 $domain 的白名单移除。"
      else
        echo "未找到 $domain 的白名单配置。"
      fi
      ;;
    7)
      read -p "请输入域名： " domain
      whitelist_file="/etc/nginx/conf.d/whitelist/${domain}_ip.conf"
      
      if [ ! -f "$whitelist_file" ]; then
        echo "未找到 $domain 的白名单配置，正在创建..."
        mkdir -p /etc/nginx/conf.d/whitelist
        touch "$whitelist_file"
        
        # 在域名配置文件中添加包含语句
        config_file="/etc/nginx/sites-available/$domain"
        if [ -f "$config_file" ]; then
          sed -i '/server {/a \    include /etc/nginx/conf.d/whitelist/'"$domain"'_ip.conf;' "$config_file"
        else
          echo "未找到 $domain 的配置文件。"
          return
        fi
      fi
      
      if grep -q "deny all;" "$whitelist_file"; then
        read -p "白名单模式已启用，是否要禁用? (y/n): " disable_whitelist
        if [[ "$disable_whitelist" == "y" || "$disable_whitelist" == "Y" ]]; then
          sed -i "/deny all;/d" "$whitelist_file"
          systemctl reload nginx
          echo "$domain 的白名单模式已禁用。"
        fi
      else
        read -p "白名单模式未启用，是否要启用? (y/n): " enable_whitelist
        if [[ "$enable_whitelist" == "y" || "$enable_whitelist" == "Y" ]]; then
          echo "deny all;" >> "$whitelist_file"
          systemctl reload nginx
          echo "$domain 的白名单模式已启用。"
          echo "注意：请确保已添加允许访问的 IP，否则所有访问将被拒绝。"
        fi
      fi
      ;;
    8)
      return
      ;;
    *)
      echo "无效的选择，请重新选择。"
      ;;
  esac
}

# 管理密码保护
manage_auth() {
  echo "密码保护管理"
  echo "1. 为域名添加密码保护"
  echo "2. 为域名添加新用户"
  echo "3. 修改域名用户密码"
  echo "4. 删除域名用户"
  echo "5. 禁用域名密码保护"
  echo "6. 返回主菜单"
  
  read -p "请选择操作： " auth_choice
  
  case $auth_choice in
    1)
      read -p "请输入域名： " domain
      config_file="/etc/nginx/sites-available/$domain"
      
      if [ ! -f "$config_file" ]; then
        echo "未找到 $domain 的配置文件。"
        return
      fi
      
      # 检查是否已启用密码保护
      if grep -q "auth_basic" "$config_file"; then
        echo "$domain 已启用密码保护。"
        return
      fi
      
      # 创建密码文件目录
      if [ ! -d "/etc/nginx/conf.d/auth" ]; then
        mkdir -p /etc/nginx/conf.d/auth
      fi
      
      # 创建密码文件
      read -p "请输入用户名: " auth_user
      # 安装 apache2-utils 以使用 htpasswd
      OS=$(detect_os)
      case $OS in
        "Ubuntu"|"Debian GNU/Linux"|"Debian")
          apt install -y apache2-utils
          ;;
        "CentOS Linux"|"Red Hat Enterprise Linux"|"Fedora")
          if command -v dnf &> /dev/null; then
            dnf install -y httpd-tools
          else
            yum install -y httpd-tools
          fi
          ;;
        "openSUSE"|"SUSE Linux Enterprise Server")
          zypper install -y apache2-utils
          ;;
        "Arch Linux")
          pacman -S --noconfirm apache
          ;;
      esac
      htpasswd -c "/etc/nginx/conf.d/auth/${domain}.htpasswd" "$auth_user"
      
      # 在配置文件中添加密码保护
      sed -i '/server_name/a \    auth_basic "Restricted Area";\n    auth_basic_user_file /etc/nginx/conf.d/auth/'"$domain"'.htpasswd;' "$config_file"
      
      systemctl reload nginx
      echo "$domain 已启用密码保护。"
      ;;
    2)
      read -p "请输入域名： " domain
      if [ ! -d "/etc/nginx/conf.d/auth" ]; then
        mkdir -p /etc/nginx/conf.d/auth
      fi
      
      if [ -f "/etc/nginx/conf.d/auth/${domain}.htpasswd" ]; then
        read -p "请输入新用户名: " auth_user
        htpasswd "/etc/nginx/conf.d/auth/${domain}.htpasswd" "$auth_user"
        echo "用户 $auth_user 已添加到 $domain 的密码保护。"
      else
        echo "未找到 $domain 的密码文件，正在创建新文件..."
        read -p "请输入用户名: " auth_user
        OS=$(detect_os)
        case $OS in
          "Ubuntu"|"Debian GNU/Linux"|"Debian")
            apt install -y apache2-utils
            ;;
          "CentOS Linux"|"Red Hat Enterprise Linux"|"Fedora")
            if command -v dnf &> /dev/null; then
              dnf install -y httpd-tools
            else
              yum install -y httpd-tools
            fi
            ;;
          "openSUSE"|"SUSE Linux Enterprise Server")
            zypper install -y apache2-utils
            ;;
          "Arch Linux")
            pacman -S --noconfirm apache
            ;;
        esac
        htpasswd -c "/etc/nginx/conf.d/auth/${domain}.htpasswd" "$auth_user"
        
        # 检查配置文件是否已包含密码保护
        config_file="/etc/nginx/sites-available/$domain"
        if [ -f "$config_file" ] && ! grep -q "auth_basic" "$config_file"; then
          sed -i '/server_name/a \    auth_basic "Restricted Area";\n    auth_basic_user_file /etc/nginx/conf.d/auth/'"$domain"'.htpasswd;' "$config_file"
          systemctl reload nginx
        fi
        
        echo "已创建密码文件并添加用户 $auth_user。"
      fi
      ;;
    3)
      read -p "请输入域名： " domain
      if [ -f "/etc/nginx/conf.d/auth/${domain}.htpasswd" ]; then
        read -p "请输入用户名: " auth_user
        htpasswd -D "/etc/nginx/conf.d/auth/${domain}.htpasswd" "$auth_user" 2>/dev/null
        htpasswd "/etc/nginx/conf.d/auth/${domain}.htpasswd" "$auth_user"
        echo "用户 $auth_user 的密码已更新。"
      else
        echo "未找到 $domain 的密码文件。"
      fi
      ;;
    4)
      read -p "请输入域名： " domain
      if [ -f "/etc/nginx/conf.d/auth/${domain}.htpasswd" ]; then
        read -p "请输入要删除的用户名: " auth_user
        htpasswd -D "/etc/nginx/conf.d/auth/${domain}.htpasswd" "$auth_user"
        echo "用户 $auth_user 已从 $domain 的密码保护中删除。"
      else
        echo "未找到 $domain 的密码文件。"
      fi
      ;;
    5)
      read -p "请输入域名： " domain
      config_file="/etc/nginx/sites-available/$domain"
      
      if [ ! -f "$config_file" ]; then
        echo "未找到 $domain 的配置文件。"
        return
      fi
      
      # 删除密码保护配置
      sed -i '/auth_basic/d' "$config_file"
      sed -i '/auth_basic_user_file/d' "$config_file"
      rm -f "/etc/nginx/conf.d/auth/${domain}.htpasswd"
      
      systemctl reload nginx
      echo "$domain 的密码保护已禁用。"
      ;;
    6)
      return
      ;;
    *)
      echo "无效的选择，请重新选择。"
      ;;
  esac
}

# 显示域名状态
show_domain_status() {
  local feature=$1
  echo "现有域名状态："
  echo "----------------------------------------"
  printf "%-30s %-20s\n" "域名" "状态"
  echo "----------------------------------------"
  
  for domain_file in /etc/nginx/sites-available/*; do
    if [ -f "$domain_file" ]; then
      domain=$(basename "$domain_file")
      status="未启用"
      
      case $feature in
        "cache")
          if grep -q "proxy_cache.*_cache;" "$domain_file"; then
            status="已启用"
          fi
          ;;
        "rate_limit")
          if grep -q "limit_req zone=" "$domain_file"; then
            status="已启用"
          fi
          ;;
        "waf")
          if grep -q "include.*waf.*conf;" "$domain_file"; then
            status="已启用"
          fi
          ;;
        "security_headers")
          if grep -q "add_header X-Frame-Options" "$domain_file"; then
            status="已启用"
          fi
          ;;
        "http2")
          if grep -q "listen.*http2" "$domain_file"; then
            status="已启用"
          fi
          ;;
        "gzip")
          if grep -q "gzip on;" "$domain_file"; then
            status="已启用"
          fi
          ;;
      esac
      
      printf "%-30s %-20s\n" "$domain" "$status"
    fi
  done
  echo "----------------------------------------"
}

# 管理缓存设置
manage_cache_settings() {
  echo "缓存配置管理"
  show_domain_status "cache"
  read -p "请输入域名： " domain
  config_file="/etc/nginx/sites-available/$domain"
  
  if [ ! -f "$config_file" ]; then
    echo "未找到 $domain 的配置文件。"
    return
  fi
  
  echo "1. 启用缓存"
  echo "2. 禁用缓存"
  echo "3. 返回上级菜单"
  
  read -p "请选择操作： " cache_choice
  
  case $cache_choice in
    1)
      setup_cache "$domain"
      ;;
    2)
      # 删除缓存配置
      cache_conf="/etc/nginx/conf.d/cache/${domain}_cache.conf"
      if [ -f "$cache_conf" ]; then
        rm -f "$cache_conf"
        sed -i '/proxy_cache '"${domain}"'_cache;/d' "$config_file"
        sed -i '/proxy_cache_bypass/d' "$config_file"
        sed -i '/add_header X-Cache-Status/d' "$config_file"
        sed -i '/include \/etc\/nginx\/conf.d\/cache\/'"${domain}"'_cache.conf;/d' /etc/nginx/nginx.conf
        systemctl reload nginx
        echo "$domain 的缓存配置已禁用。"
      else
        echo "$domain 未启用缓存配置。"
      fi
      ;;
    3)
      return
      ;;
    *)
      echo "无效的选择，请重新选择。"
      ;;
  esac
}

# 管理限速设置
manage_rate_limit_settings() {
  echo "限速配置管理"
  show_domain_status "rate_limit"
  read -p "请输入域名： " domain
  config_file="/etc/nginx/sites-available/$domain"
  
  if [ ! -f "$config_file" ]; then
    echo "未找到 $domain 的配置文件。"
    return
  fi
  
  echo "1. 启用/修改限速"
  echo "2. 禁用限速"
  echo "3. 返回上级菜单"
  
  read -p "请选择操作： " rate_choice
  
  case $rate_choice in
    1)
      setup_rate_limit "$domain"
      ;;
    2)
      if grep -q "limit_req zone=req_limit_per_ip" "$config_file"; then
        sed -i '/limit_req zone=req_limit_per_ip/d' "$config_file"
        sed -i '/limit_conn conn_limit_per_ip/d' "$config_file"
        sed -i '/limit_req_status/d' "$config_file"
        sed -i '/limit_conn_status/d' "$config_file"
        systemctl reload nginx
        echo "$domain 的限速配置已禁用。"
      else
        echo "$domain 未启用限速配置。"
      fi
      ;;
    3)
      return
      ;;
    *)
      echo "无效的选择，请重新选择。"
      ;;
  esac
}

# 管理WAF设置
manage_waf_settings() {
  echo "WAF防护管理"
  show_domain_status "waf"
  read -p "请输入域名： " domain
  config_file="/etc/nginx/sites-available/$domain"
  
  if [ ! -f "$config_file" ]; then
    echo "未找到 $domain 的配置文件。"
    return
  fi
  
  echo "1. 启用WAF"
  echo "2. 禁用WAF"
  echo "3. 返回上级菜单"
  
  read -p "请选择操作： " waf_choice
  
  case $waf_choice in
    1)
      setup_waf "$domain"
      ;;
    2)
      waf_conf="/etc/nginx/conf.d/waf/${domain}_waf.conf"
      if [ -f "$waf_conf" ]; then
        rm -f "$waf_conf"
        sed -i '/include \/etc\/nginx\/conf.d\/waf\/'"${domain}"'_waf.conf;/d' "$config_file"
        systemctl reload nginx
        echo "$domain 的WAF防护已禁用。"
      else
        echo "$domain 未启用WAF防护。"
      fi
      ;;
    3)
      return
      ;;
    *)
      echo "无效的选择，请重新选择。"
      ;;
  esac
}

# 管理安全头设置
manage_security_headers_settings() {
  echo "安全头管理"
  show_domain_status "security_headers"
  read -p "请输入域名： " domain
  config_file="/etc/nginx/sites-available/$domain"
  
  if [ ! -f "$config_file" ]; then
    echo "未找到 $domain 的配置文件。"
    return
  fi
  
  echo "1. 启用安全头"
  echo "2. 禁用安全头"
  echo "3. 返回上级菜单"
  
  read -p "请选择操作： " headers_choice
  
  case $headers_choice in
    1)
      setup_security_headers "$domain"
      ;;
    2)
      if grep -q "# 安全头配置" "$config_file"; then
        sed -i '/# 安全头配置/,/Strict-Transport-Security/d' "$config_file"
        systemctl reload nginx
        echo "$domain 的安全头配置已禁用。"
      else
        echo "$domain 未启用安全头配置。"
      fi
      ;;
    3)
      return
      ;;
    *)
      echo "无效的选择，请重新选择。"
      ;;
  esac
}

# 管理HTTP/2设置
manage_http2_settings() {
  echo "HTTP/2支持管理"
  show_domain_status "http2"
  read -p "请输入域名： " domain
  config_file="/etc/nginx/sites-available/$domain"
  
  if [ ! -f "$config_file" ]; then
    echo "未找到 $domain 的配置文件。"
    return
  fi
  
  echo "1. 启用HTTP/2"
  echo "2. 禁用HTTP/2"
  echo "3. 返回上级菜单"
  
  read -p "请选择操作： " http2_choice
  
  case $http2_choice in
    1)
      setup_http2 "$domain"
      ;;
    2)
      if grep -q "listen 443 ssl http2;" "$config_file"; then
        sed -i 's/listen 443 ssl http2;/listen 443 ssl;/' "$config_file"
        systemctl reload nginx
        echo "$domain 的HTTP/2支持已禁用。"
      else
        echo "$domain 未启用HTTP/2支持。"
      fi
      ;;
    3)
      return
      ;;
    *)
      echo "无效的选择，请重新选择。"
      ;;
  esac
}

# 管理Gzip压缩设置
manage_gzip_settings() {
  echo "Gzip压缩管理"
  show_domain_status "gzip"
  read -p "请输入域名（留空则为全局配置）： " domain
  
  echo "1. 启用Gzip压缩"
  echo "2. 禁用Gzip压缩"
  echo "3. 返回上级菜单"
  
  read -p "请选择操作： " gzip_choice
  
  case $gzip_choice in
    1)
      setup_gzip "$domain"
      ;;
    2)
      if [ -z "$domain" ]; then
        # 禁用全局Gzip配置
        if grep -q "# Gzip 压缩配置" /etc/nginx/nginx.conf; then
          sed -i '/# Gzip 压缩配置/,/gzip_types/d' /etc/nginx/nginx.conf
          systemctl reload nginx
          echo "全局Gzip压缩已禁用。"
        else
          echo "全局Gzip压缩未启用。"
        fi
      else
        # 禁用特定域名的Gzip配置
        config_file="/etc/nginx/sites-available/$domain"
        if [ -f "$config_file" ]; then
          if grep -q "# Gzip 压缩配置" "$config_file"; then
            sed -i '/# Gzip 压缩配置/,/gzip_types/d' "$config_file"
            systemctl reload nginx
            echo "$domain 的Gzip压缩已禁用。"
          else
            echo "$domain 未启用Gzip压缩。"
          fi
        else
          echo "未找到 $domain 的配置文件。"
        fi
      fi
      ;;
    3)
      return
      ;;
    *)
      echo "无效的选择，请重新选择。"
      ;;
  esac
}

# 设置缓存配置
setup_cache() {
  local domain=$1
  local config_file="/etc/nginx/sites-available/$domain"
  
  # 创建缓存目录
  mkdir -p /etc/nginx/conf.d/cache
  mkdir -p /var/cache/nginx/cache
  
  # 创建缓存配置文件
  local cache_conf="/etc/nginx/conf.d/cache/${domain}_cache.conf"
  cat > "$cache_conf" <<EOL
proxy_cache_path /var/cache/nginx/cache/${domain}_cache levels=1:2 keys_zone=${domain}_cache:10m max_size=10g inactive=60m use_temp_path=off;
proxy_cache_key \$scheme\$request_method\$host\$request_uri;
proxy_cache_valid 200 302 10m;
proxy_cache_valid 404 1m;
EOL

  # 在配置文件中添加缓存设置
  sed -i '/location \/ {/a \        proxy_cache '"${domain}"'_cache;\n        proxy_cache_bypass \$http_pragma;\n        add_header X-Cache-Status \$upstream_cache_status;' "$config_file"
  
  # 在主配置文件中包含缓存配置
  if ! grep -q "include /etc/nginx/conf.d/cache/${domain}_cache.conf;" /etc/nginx/nginx.conf; then
    sed -i '/http {/a \    include /etc/nginx/conf.d/cache/'"${domain}"'_cache.conf;' /etc/nginx/nginx.conf
  fi
  
  systemctl reload nginx
  echo "$domain 的缓存配置已启用。"
}

# 设置限速配置
setup_rate_limit() {
  local domain=$1
  local config_file="/etc/nginx/sites-available/$domain"
  
  read -p "请输入每秒请求限制数 (默认: 10): " req_limit
  req_limit=${req_limit:-10}
  
  read -p "请输入每个IP的并发连接数限制 (默认: 5): " conn_limit
  conn_limit=${conn_limit:-5}
  
  # 在 http 块中添加限速区域定义
  if ! grep -q "limit_req_zone" /etc/nginx/nginx.conf; then
    sed -i '/http {/a \    limit_req_zone $binary_remote_addr zone=req_limit_per_ip:10m rate='"$req_limit"'r/s;\n    limit_conn_zone $binary_remote_addr zone=conn_limit_per_ip:10m;' /etc/nginx/nginx.conf
  fi
  
  # 在服务器配置中添加限速规则
  sed -i '/server_name/a \    limit_req zone=req_limit_per_ip burst=20 nodelay;\n    limit_conn conn_limit_per_ip '"$conn_limit"';\n    limit_req_status 429;\n    limit_conn_status 429;' "$config_file"
  
  systemctl reload nginx
  echo "$domain 的限速配置已启用。"
}

# 设置WAF配置
setup_waf() {
  local domain=$1
  local config_file="/etc/nginx/sites-available/$domain"
  
  # 创建WAF配置目录
  mkdir -p /etc/nginx/conf.d/waf
  
  # 创建WAF规则配置文件
  local waf_conf="/etc/nginx/conf.d/waf/${domain}_waf.conf"
  cat > "$waf_conf" <<EOL
# 基本WAF规则
# 阻止常见的SQL注入攻击
if (\$query_string ~* "union.*select.*\(") {
    return 403;
}
if (\$query_string ~* "concat.*\(") {
    return 403;
}

# 阻止常见的XSS攻击
if (\$query_string ~* "<.*script.*>") {
    return 403;
}
if (\$query_string ~* "<.*iframe.*>") {
    return 403;
}

# 阻止目录遍历
if (\$query_string ~* "\.\.\/") {
    return 403;
}

# 阻止敏感文件访问
location ~* \.(git|svn|htaccess|env|config|cfg|ini)$ {
    deny all;
    return 403;
}
EOL

  # 在配置文件中包含WAF规则
  sed -i '/server_name/a \    include /etc/nginx/conf.d/waf/'"${domain}"'_waf.conf;' "$config_file"
  
  systemctl reload nginx
  echo "$domain 的WAF防护已启用。"
}

# 设置安全头
setup_security_headers() {
  local domain=$1
  local config_file="/etc/nginx/sites-available/$domain"
  
  # 添加安全头配置
  cat >> "$config_file" <<EOL
    # 安全头配置
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
EOL

  systemctl reload nginx
  echo "$domain 的安全头配置已启用。"
}

# 设置HTTP/2
setup_http2() {
  local domain=$1
  local config_file="/etc/nginx/sites-available/$domain"
  
  # 检查是否已启用SSL
  if ! grep -q "listen 443 ssl" "$config_file"; then
    echo "请先为 $domain 启用SSL。"
    return 1
  fi
  
  # 启用HTTP/2
  sed -i 's/listen 443 ssl;/listen 443 ssl http2;/' "$config_file"
  
  systemctl reload nginx
  echo "$domain 的HTTP/2支持已启用。"
}

# 设置Gzip压缩
setup_gzip() {
  local domain=$1
  local config_file
  
  if [ -z "$domain" ]; then
    # 全局Gzip配置
    config_file="/etc/nginx/nginx.conf"
    # 检查是否已存在Gzip配置
    if grep -q "gzip on;" "$config_file"; then
      echo "全局Gzip压缩已经启用。"
      return
    fi
    
    # 在http块中添加Gzip配置
    cat > "/etc/nginx/conf.d/gzip.conf" <<EOL
# Gzip 压缩配置
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 6;
gzip_buffers 16 8k;
gzip_http_version 1.1;
gzip_min_length 256;
gzip_types
    text/plain
    text/css
    text/xml
    text/javascript
    application/javascript
    application/x-javascript
    application/xml
    application/json
    application/ld+json
    application/manifest+json
    application/rss+xml
    application/xhtml+xml
    image/svg+xml;
EOL
    
    # 在nginx.conf中包含gzip配置
    if ! grep -q "include /etc/nginx/conf.d/gzip.conf;" "$config_file"; then
      sed -i '/http {/a \    include /etc/nginx/conf.d/gzip.conf;' "$config_file"
    fi
  else
    # 特定域名的Gzip配置
    config_file="/etc/nginx/sites-available/$domain"
    # 检查是否已存在Gzip配置
    if grep -q "gzip on;" "$config_file"; then
      echo "$domain 的Gzip压缩已经启用。"
      return
    fi
    
    # 在server块中添加Gzip配置
    cat > "/etc/nginx/conf.d/gzip_${domain}.conf" <<EOL
# Gzip 压缩配置
gzip on;
gzip_vary on;
gzip_min_length 256;
gzip_proxied any;
gzip_comp_level 6;
gzip_types
    text/plain
    text/css
    text/xml
    text/javascript
    application/javascript
    application/x-javascript
    application/xml
    application/json;
EOL
    
    # 在域名配置文件中包含gzip配置
    if ! grep -q "include /etc/nginx/conf.d/gzip_${domain}.conf;" "$config_file"; then
      sed -i '/server {/a \    include /etc/nginx/conf.d/gzip_'"${domain}"'.conf;' "$config_file"
    fi
  fi
  
  # 测试配置
  nginx -t
  if [ $? -eq 0 ]; then
    systemctl reload nginx
    echo "Gzip压缩已启用。"
  else
    echo "Nginx配置测试失败，回滚更改..."
    if [ -z "$domain" ]; then
      rm -f "/etc/nginx/conf.d/gzip.conf"
      sed -i '/include \/etc\/nginx\/conf.d\/gzip.conf;/d' "$config_file"
    else
      rm -f "/etc/nginx/conf.d/gzip_${domain}.conf"
      sed -i '/include \/etc\/nginx\/conf.d\/gzip_'"${domain}"'.conf;/d' "$config_file"
    fi
    echo "已回滚更改。"
  fi
}

# 显示所有域名详细信息
show_domains_info() {
  echo "域名详细信息："
  echo "=================================================================="
  printf "%-30s %-10s %-15s %-25s\n" "域名" "端口" "SSL状态" "功能状态"
  echo "=================================================================="
  
  for domain_file in /etc/nginx/sites-available/*; do
    if [ -f "$domain_file" ]; then
      domain=$(basename "$domain_file")
      
      # 获取端口信息
      port=$(grep -oP "(?<=proxy_pass http://127.0.0.1:)\d+" "$domain_file" || echo "未设置")
      
      # 检查SSL状态
      if grep -q "ssl_certificate" "$domain_file"; then
        ssl_status="已启用"
      else
        ssl_status="未启用"
      fi
      
      # 检查各项功能状态
      features=""
      if grep -q "proxy_cache.*_cache;" "$domain_file"; then
        features="缓存 "
      fi
      if grep -q "limit_req zone=" "$domain_file"; then
        features="${features}限速 "
      fi
      if grep -q "include.*waf.*conf;" "$domain_file"; then
        features="${features}WAF "
      fi
      if grep -q "add_header X-Frame-Options" "$domain_file"; then
        features="${features}安全头 "
      fi
      if grep -q "listen.*http2" "$domain_file"; then
        features="${features}HTTP2 "
      fi
      if grep -q "gzip on;" "$domain_file"; then
        features="${features}Gzip "
      fi
      
      if [ -z "$features" ]; then
        features="无特殊功能"
      fi
      
      printf "%-30s %-10s %-15s %-25s\n" "$domain" "$port" "$ssl_status" "$features"
      echo "配置文件: $domain_file"
      if [ -d "/etc/nginx/conf.d/cache/${domain}_cache" ]; then
        echo "缓存目录: /etc/nginx/conf.d/cache/${domain}_cache"
      fi
      if [ -f "/etc/nginx/conf.d/waf/${domain}_waf.conf" ]; then
        echo "WAF配置: /etc/nginx/conf.d/waf/${domain}_waf.conf"
      fi
      echo "------------------------------------------------------------------"
    fi
  done
}

# 备份功能
backup_nginx_config() {
  local backup_dir="/etc/nginx/backups"
  local timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_file="$backup_dir/nginx_backup_$timestamp.tar.gz"
  
  # 创建备份目录
  mkdir -p "$backup_dir"
  
  # 创建备份
  tar -czf "$backup_file" /etc/nginx/nginx.conf /etc/nginx/sites-available/ /etc/nginx/sites-enabled/ /etc/nginx/conf.d/
  
  if [ $? -eq 0 ]; then
    echo "备份成功创建：$backup_file"
    # 删除30天前的备份
    find "$backup_dir" -name "nginx_backup_*.tar.gz" -mtime +30 -delete
  else
    echo "备份创建失败！"
  fi
}

# 恢复功能
restore_nginx_config() {
  local backup_dir="/etc/nginx/backups"
  
  if [ ! -d "$backup_dir" ]; then
    echo "未找到备份目录！"
    return 1
  fi
  
  echo "可用的备份文件："
  local i=1
  local backup_files=()
  
  while IFS= read -r file; do
    backup_files+=("$file")
    echo "$i) $(basename "$file") ($(date -r "$file" '+%Y-%m-%d %H:%M:%S'))"
    ((i++))
  done < <(find "$backup_dir" -name "nginx_backup_*.tar.gz" -type f | sort -r)
  
  if [ ${#backup_files[@]} -eq 0 ]; then
    echo "没有找到备份文件！"
    return 1
  fi
  
  read -p "请选择要恢复的备份文件编号： " choice
  
  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#backup_files[@]} ]; then
    local selected_backup="${backup_files[$((choice-1))]}"
    
    # 创建临时恢复目录
    local temp_dir=$(mktemp -d)
    
    echo "正在恢复备份..."
    tar -xzf "$selected_backup" -C "$temp_dir"
    
    # 备份当前配置
    backup_nginx_config
    
    # 恢复配置文件
    cp -r "$temp_dir/etc/nginx/nginx.conf" /etc/nginx/
    cp -r "$temp_dir/etc/nginx/sites-available/"* /etc/nginx/sites-available/
    cp -r "$temp_dir/etc/nginx/sites-enabled/"* /etc/nginx/sites-enabled/
    cp -r "$temp_dir/etc/nginx/conf.d/"* /etc/nginx/conf.d/
    
    # 清理临时目录
    rm -rf "$temp_dir"
    
    # 测试配置
    nginx -t
    if [ $? -eq 0 ]; then
      systemctl reload nginx
      echo "配置已成功恢复！"
    else
      echo "恢复的配置存在错误，请检查配置文件。"
    fi
  else
    echo "无效的选择！"
  fi
}

# 修复功能
repair_nginx_config() {
  echo "Nginx配置修复工具"
  echo "1. 检查配置文件语法"
  echo "2. 修复权限"
  echo "3. 重建符号链接"
  echo "4. 重置默认配置"
  echo "5. 返回主菜单"
  
  read -p "请选择修复操作： " repair_choice
  
  case $repair_choice in
    1)
      echo "检查Nginx配置文件语法..."
      nginx -t
      ;;
    2)
      echo "修复Nginx相关目录和文件权限..."
      chown -R root:root /etc/nginx
      chown -R www-data:www-data /var/log/nginx
      chmod -R 644 /etc/nginx/conf.d/*
      chmod -R 644 /etc/nginx/sites-available/*
      chmod -R 644 /etc/nginx/sites-enabled/*
      chmod 755 /etc/nginx/conf.d
      chmod 755 /etc/nginx/sites-available
      chmod 755 /etc/nginx/sites-enabled
      echo "权限修复完成。"
      ;;
    3)
      echo "重建sites-enabled目录的符号链接..."
      rm -f /etc/nginx/sites-enabled/*
      for site in /etc/nginx/sites-available/*; do
        if [ -f "$site" ]; then
          ln -sf "$site" "/etc/nginx/sites-enabled/$(basename "$site")"
        fi
      done
      echo "符号链接重建完成。"
      ;;
    4)
      echo "警告：这将重置Nginx到默认配置！"
      read -p "是否继续？(y/n): " confirm
      if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        # 备份当前配置
        backup_nginx_config
        
        # 重新安装Nginx
        apt-get remove --purge nginx nginx-common nginx-full
        apt-get install -y nginx
        
        echo "Nginx已重置到默认配置。"
      fi
      ;;
    5)
      return
      ;;
    *)
      echo "无效的选择！"
      ;;
  esac
}

# 显示 Nginx 图标
show_nginx_logo() {
  echo -e "\033[32m"
  cat << "EOF"
    
    ███╗   ██╗ ██████╗ ██╗███╗   ██╗██╗  ██╗
    ████╗  ██║██╔════╝ ██║████╗  ██║╚██╗██╔╝
    ██╔██╗ ██║██║  ███╗██║██╔██╗ ██║ ╚███╔╝ 
    ██║╚██╗██║██║   ██║██║██║╚██╗██║ ██╔██╗ 
    ██║ ╚████║╚██████╔╝██║██║ ╚████║██╔╝ ██╗
    ╚═╝  ╚═══╝ ╚═════╝ ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝
                                                     
           High Performance Load Balancer & Web Server
EOF
  echo -e "\033[0m"
}

# 添加高级功能管理
manage_advanced_features() {
  echo "高级功能设置:"
  echo "1. 缓存配置管理"
  echo "2. 限速配置管理"
  echo "3. WAF 防护管理"
  echo "4. 安全头管理"
  echo "5. HTTP/2 支持管理"
  echo "6. 负载均衡配置"
  echo "7. URL重写规则"
  echo "8. 错误页面自定义"
  echo "9. 流媒体服务配置"
  echo "10. 反向代理高级设置"
  echo "11. 性能优化配置"
  echo "12. 防盗链配置"
  echo "13. CORS跨域配置"
  echo "14. SSL优化配置"
  echo "15. 日志格式定制"
  echo "16. 返回主菜单"
  
  read -p "请选择操作： " adv_choice
  
  case $adv_choice in
    1)
      manage_cache_settings
      ;;
    2)
      manage_rate_limit_settings
      ;;
    3)
      manage_waf_settings
      ;;
    4)
      manage_security_headers_settings
      ;;
    5)
      manage_http2_settings
      ;;
    6)
      manage_load_balance
      ;;
    7)
      manage_url_rewrite
      ;;
    8)
      manage_error_pages
      ;;
    9)
      manage_media_stream
      ;;
    10)
      manage_proxy_advanced
      ;;
    11)
      manage_performance
      ;;
    12)
      manage_hotlink_protection
      ;;
    13)
      manage_cors
      ;;
    14)
      manage_ssl_optimization
      ;;
    15)
      manage_log_format
      ;;
    16)
      return
      ;;
    *)
      echo "无效的选择，请重新选择。"
      ;;
  esac
}

# 负载均衡配置管理
manage_load_balance() {
  echo "负载均衡配置管理"
  show_domain_status "load_balance"
  read -p "请输入域名： " domain
  config_file="/etc/nginx/sites-available/$domain"
  
  if [ ! -f "$config_file" ]; then
    echo "未找到 $domain 的配置文件。"
    return
  fi
  
  echo "1. 添加后端服务器"
  echo "2. 移除后端服务器"
  echo "3. 修改负载均衡算法"
  echo "4. 配置健康检查"
  echo "5. 返回上级菜单"
  
  read -p "请选择操作： " lb_choice
  
  case $lb_choice in
    1)
      read -p "请输入后端服务器地址和端口(例如: 192.168.1.10:8080): " backend
      if [ ! -f "/etc/nginx/conf.d/upstream/${domain}.conf" ]; then
        mkdir -p /etc/nginx/conf.d/upstream
        cat > "/etc/nginx/conf.d/upstream/${domain}.conf" <<EOL
upstream ${domain}_backend {
    server $backend;
}
EOL
        sed -i "s|proxy_pass http://127.0.0.1:[0-9]*;|proxy_pass http://${domain}_backend;|" "$config_file"
      else
        sed -i "/upstream ${domain}_backend {/a \    server $backend;" "/etc/nginx/conf.d/upstream/${domain}.conf"
      fi
      ;;
    2)
      if [ -f "/etc/nginx/conf.d/upstream/${domain}.conf" ]; then
        echo "当前后端服务器列表："
        grep "server" "/etc/nginx/conf.d/upstream/${domain}.conf"
        read -p "请输入要移除的服务器地址和端口: " backend
        sed -i "/server $backend;/d" "/etc/nginx/conf.d/upstream/${domain}.conf"
      else
        echo "未找到负载均衡配置。"
      fi
      ;;
    3)
      echo "可用的负载均衡算法："
      echo "1. 轮询(默认)"
      echo "2. 加权轮询"
      echo "3. IP哈希"
      echo "4. 最少连接"
      read -p "请选择算法: " algo_choice
      case $algo_choice in
        1)
          sed -i "/upstream ${domain}_backend {/a \    # 轮询算法" "/etc/nginx/conf.d/upstream/${domain}.conf"
          ;;
        2)
          echo "为每个后端服务器设置权重"
          while read -p "输入服务器地址和权重(例如: 192.168.1.10:8080 weight=3),输入q退出: " backend; do
            [ "$backend" = "q" ] && break
            sed -i "s/server \([0-9.:]*\);/server \1 $backend;/" "/etc/nginx/conf.d/upstream/${domain}.conf"
          done
          ;;
        3)
          sed -i "/upstream ${domain}_backend {/a \    ip_hash;" "/etc/nginx/conf.d/upstream/${domain}.conf"
          ;;
        4)
          sed -i "/upstream ${domain}_backend {/a \    least_conn;" "/etc/nginx/conf.d/upstream/${domain}.conf"
          ;;
      esac
      ;;
    4)
      read -p "设置健康检查间隔(秒): " interval
      read -p "设置超时时间(秒): " timeout
      read -p "设置最大失败次数: " max_fails
      cat >> "/etc/nginx/conf.d/upstream/${domain}.conf" <<EOL
    check interval=$interval timeout=$timeout rise=2 fall=$max_fails type=http;
    check_http_send "HEAD / HTTP/1.0\r\n\r\n";
    check_http_expect_alive http_2xx http_3xx;
EOL
      ;;
    5)
      return
      ;;
  esac
  
  nginx -t && systemctl reload nginx
}

# URL重写规则管理
manage_url_rewrite() {
  echo "URL重写规则管理"
  show_domain_status "rewrite"
  read -p "请输入域名： " domain
  config_file="/etc/nginx/sites-available/$domain"
  
  if [ ! -f "$config_file" ]; then
    echo "未找到 $domain 的配置文件。"
    return
  fi
  
  echo "1. 添加重写规则"
  echo "2. 删除重写规则"
  echo "3. 查看现有规则"
  echo "4. 返回上级菜单"
  
  read -p "请选择操作： " rewrite_choice
  
  case $rewrite_choice in
    1)
      echo "重写规则类型："
      echo "1. 永久重定向(301)"
      echo "2. 临时重定向(302)"
      echo "3. 内部重写"
      read -p "请选择重写类型: " type_choice
      read -p "请输入源URL模式(例如: /old/.*): " source
      read -p "请输入目标URL(例如: /new/\$1): " target
      
      case $type_choice in
        1)
          echo "    rewrite ^$source$ $target permanent;" >> "$config_file"
          ;;
        2)
          echo "    rewrite ^$source$ $target redirect;" >> "$config_file"
          ;;
        3)
          echo "    rewrite ^$source$ $target last;" >> "$config_file"
          ;;
      esac
      ;;
    2)
      if grep -q "rewrite" "$config_file"; then
        echo "现有重写规则："
        grep -n "rewrite" "$config_file"
        read -p "请输入要删除的规则行号: " line_number
        sed -i "${line_number}d" "$config_file"
      else
        echo "未找到重写规则。"
      fi
      ;;
    3)
      if grep -q "rewrite" "$config_file"; then
        echo "现有重写规则："
        grep -n "rewrite" "$config_file"
      else
        echo "未找到重写规则。"
      fi
      ;;
    4)
      return
      ;;
  esac
  
  nginx -t && systemctl reload nginx
}

# 错误页面自定义管理
manage_error_pages() {
  echo "错误页面自定义管理"
  show_domain_status "error_page"
  read -p "请输入域名： " domain
  config_file="/etc/nginx/sites-available/$domain"
  
  if [ ! -f "$config_file" ]; then
    echo "未找到 $domain 的配置文件。"
    return
  fi
  
  echo "1. 添加自定义错误页面"
  echo "2. 删除自定义错误页面"
  echo "3. 查看现有错误页面配置"
  echo "4. 返回上级菜单"
  
  read -p "请选择操作： " error_choice
  
  case $error_choice in
    1)
      echo "常见错误代码："
      echo "404 - 页面未找到"
      echo "403 - 禁止访问"
      echo "500 - 服务器错误"
      echo "502 - 网关错误"
      echo "503 - 服务不可用"
      read -p "请输入错误代码: " error_code
      read -p "请输入错误页面路径(例如: /usr/share/nginx/html/404.html): " error_page
      
      # 确保错误页面目录存在
      mkdir -p "$(dirname "$error_page")"
      
      # 创建默认错误页面模板
      cat > "$error_page" <<EOL
<!DOCTYPE html>
<html>
<head>
    <title>Error $error_code</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            text-align: center;
            padding: 50px;
        }
        h1 { color: #444; }
        .error-code { font-size: 72px; color: #666; }
    </style>
</head>
<body>
    <div class="error-code">$error_code</div>
    <h1>抱歉，出现了一些问题</h1>
    <p>我们正在努力修复这个问题。</p>
</body>
</html>
EOL
      
      echo "    error_page $error_code $error_page;" >> "$config_file"
      ;;
    2)
      if grep -q "error_page" "$config_file"; then
        echo "现有错误页面配置："
        grep -n "error_page" "$config_file"
        read -p "请输入要删除的配置行号: " line_number
        sed -i "${line_number}d" "$config_file"
      else
        echo "未找到错误页面配置。"
      fi
      ;;
    3)
      if grep -q "error_page" "$config_file"; then
        echo "现有错误页面配置："
        grep -n "error_page" "$config_file"
      else
        echo "未找到错误页面配置。"
      fi
      ;;
    4)
      return
      ;;
  esac
  
  nginx -t && systemctl reload nginx
}

# 流媒体服务配置管理
manage_media_stream() {
  echo "流媒体服务配置管理"
  show_domain_status "media_stream"
  read -p "请输入域名： " domain
  config_file="/etc/nginx/sites-available/$domain"
  
  if [ ! -f "$config_file" ]; then
    echo "未找到 $domain 的配置文件。"
    return
  fi
  
  echo "1. 配置HLS流媒体"
  echo "2. 配置DASH流媒体"
  echo "3. 配置MP4点播"
  echo "4. 配置RTMP推流"
  echo "5. 返回上级菜单"
  
  read -p "请选择操作： " media_choice
  
  case $media_choice in
    1)
      # 配置HLS流媒体
      mkdir -p /var/www/hls/$domain
      cat >> "$config_file" <<EOL
    location /hls {
        types {
            application/vnd.apple.mpegurl m3u8;
            video/mp2t ts;
        }
        root /var/www;
        add_header Cache-Control no-cache;
        add_header Access-Control-Allow-Origin *;
    }
EOL
      ;;
    2)
      # 配置DASH流媒体
      mkdir -p /var/www/dash/$domain
      cat >> "$config_file" <<EOL
    location /dash {
        types {
            application/dash+xml mpd;
        }
        root /var/www;
        add_header Cache-Control no-cache;
        add_header Access-Control-Allow-Origin *;
    }
EOL
      ;;
    3)
      # 配置MP4点播
      mkdir -p /var/www/videos/$domain
      cat >> "$config_file" <<EOL
    location /videos {
        mp4;
        mp4_buffer_size 1m;
        mp4_max_buffer_size 5m;
        root /var/www;
        add_header Cache-Control no-cache;
    }
EOL
      ;;
    4)
      # 配置RTMP推流（需要额外安装nginx-rtmp-module）
      apt-get install -y libnginx-mod-rtmp
      cat > "/etc/nginx/conf.d/rtmp.conf" <<EOL
rtmp {
    server {
        listen 1935;
        chunk_size 4096;
        
        application live {
            live on;
            record off;
            hls on;
            hls_path /var/www/hls/$domain;
            hls_fragment 3;
            hls_playlist_length 60;
            
            dash on;
            dash_path /var/www/dash/$domain;
        }
    }
}
EOL
      ;;
    5)
      return
      ;;
  esac
  
  nginx -t && systemctl reload nginx
}

# 反向代理高级设置
manage_proxy_advanced() {
  echo "反向代理高级设置"
  show_domain_status "proxy_advanced"
  read -p "请输入域名： " domain
  config_file="/etc/nginx/sites-available/$domain"
  
  if [ ! -f "$config_file" ]; then
    echo "未找到 $domain 的配置文件。"
    return
  fi
  
  echo "1. 配置WebSocket支持"
  echo "2. 配置SSL会话复用"
  echo "3. 配置代理缓冲区"
  echo "4. 配置超时设置"
  echo "5. 配置请求体大小限制"
  echo "6. 返回上级菜单"
  
  read -p "请选择操作： " proxy_choice
  
  case $proxy_choice in
    1)
      # 配置WebSocket支持
      cat >> "$config_file" <<EOL
    # WebSocket支持
    location /websocket {
        proxy_pass http://backend_websocket;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
EOL
      ;;
    2)
      # 配置SSL会话复用
      cat >> "$config_file" <<EOL
    # SSL会话复用
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets on;
EOL
      ;;
    3)
      # 配置代理缓冲区
      read -p "请输入代理缓冲区大小(默认4k): " buffer_size
      buffer_size=${buffer_size:-4k}
      cat >> "$config_file" <<EOL
    # 代理缓冲区设置
    proxy_buffer_size $buffer_size;
    proxy_buffers 8 $buffer_size;
    proxy_busy_buffers_size $(( ${buffer_size%k} * 2 ))k;
EOL
      ;;
    4)
      # 配置超时设置
      read -p "请输入连接超时时间(秒): " connect_timeout
      read -p "请输入读取超时时间(秒): " read_timeout
      read -p "请输入发送超时时间(秒): " send_timeout
      cat >> "$config_file" <<EOL
    # 超时设置
    proxy_connect_timeout ${connect_timeout}s;
    proxy_read_timeout ${read_timeout}s;
    proxy_send_timeout ${send_timeout}s;
EOL
      ;;
    5)
      # 配置请求体大小限制
      read -p "请输入最大请求体大小(例如: 10m): " max_body_size
      cat >> "$config_file" <<EOL
    # 请求体大小限制
    client_max_body_size $max_body_size;
EOL
      ;;
    6)
      return
      ;;
  esac
  
  nginx -t && systemctl reload nginx
}

# 性能优化配置
manage_performance() {
  echo "性能优化配置"
  show_domain_status "performance"
  read -p "请输入域名： " domain
  config_file="/etc/nginx/sites-available/$domain"
  
  if [ ! -f "$config_file" ]; then
    echo "未找到 $domain 的配置文件。"
    return
  fi
  
  echo "1. 配置工作进程和连接数"
  echo "2. 配置keepalive设置"
  echo "3. 配置文件句柄限制"
  echo "4. 配置静态文件缓存"
  echo "5. 配置压缩设置"
  echo "6. 返回上级菜单"
  
  read -p "请选择操作： " perf_choice
  
  case $perf_choice in
    1)
      # 获取CPU核心数
      cpu_cores=$(nproc)
      # 配置工作进程和连接数
      cat > "/etc/nginx/conf.d/performance.conf" <<EOL
# 性能优化配置
worker_processes auto;
worker_cpu_affinity auto;
worker_rlimit_nofile 65535;

events {
    worker_connections 65535;
    multi_accept on;
    use epoll;
}

http {
    open_file_cache max=1000 inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;
}
EOL
      ;;
    2)
      # 配置keepalive设置
      cat >> "$config_file" <<EOL
    # Keepalive设置
    keepalive_timeout 65;
    keepalive_requests 100;
    
    # 上游keepalive
    upstream_keepalive 32;
    upstream_keepalive_timeout 60;
    upstream_keepalive_requests 1000;
EOL
      ;;
    3)
      # 配置文件句柄限制
      echo "* soft nofile 65535" >> /etc/security/limits.conf
      echo "* hard nofile 65535" >> /etc/security/limits.conf
      echo "session required pam_limits.so" >> /etc/pam.d/common-session
      ;;
    4)
      # 配置静态文件缓存
      cat >> "$config_file" <<EOL
    # 静态文件缓存
    location ~* \.(jpg|jpeg|png|gif|ico|css|js)$ {
        expires 7d;
        add_header Cache-Control "public, no-transform";
    }
EOL
      ;;
    5)
      # 配置压缩设置（使用Brotli替代Gzip）
      apt-get install -y nginx-module-brotli
      cat > "/etc/nginx/conf.d/compression.conf" <<EOL
# Brotli压缩设置
brotli on;
brotli_comp_level 6;
brotli_types text/plain text/css application/javascript application/json application/x-javascript text/xml application/xml application/xml+rss text/javascript;
EOL
      ;;
    6)
      return
      ;;
  esac
  
  nginx -t && systemctl reload nginx
}

# 防盗链配置
manage_hotlink_protection() {
  echo "防盗链配置"
  show_domain_status "hotlink"
  read -p "请输入域名： " domain
  config_file="/etc/nginx/sites-available/$domain"
  
  if [ ! -f "$config_file" ]; then
    echo "未找到 $domain 的配置文件。"
    return
  fi
  
  echo "1. 启用基础防盗链"
  echo "2. 启用高级防盗链（带白名单）"
  echo "3. 禁用防盗链"
  echo "4. 返回上级菜单"
  
  read -p "请选择操作： " hotlink_choice
  
  case $hotlink_choice in
    1)
      cat >> "$config_file" <<EOL
    # 基础防盗链配置
    location ~* \.(gif|jpg|jpeg|png|bmp|swf|flv|mp4|ico)$ {
        valid_referers none blocked server_names;
        if (\$invalid_referer) {
            return 403;
        }
    }
EOL
      ;;
    2)
      read -p "请输入允许的域名（用空格分隔）： " allowed_domains
      cat >> "$config_file" <<EOL
    # 高级防盗链配置
    location ~* \.(gif|jpg|jpeg|png|bmp|swf|flv|mp4|ico)$ {
        valid_referers none blocked server_names $allowed_domains;
        if (\$invalid_referer) {
            return 403;
        }
    }
EOL
      ;;
    3)
      sed -i '/# 基础防盗链配置/,/}/d' "$config_file"
      sed -i '/# 高级防盗链配置/,/}/d' "$config_file"
      ;;
    4)
      return
      ;;
  esac
  
  nginx -t && systemctl reload nginx
}

# CORS跨域配置
manage_cors() {
  echo "CORS跨域配置"
  show_domain_status "cors"
  read -p "请输入域名： " domain
  config_file="/etc/nginx/sites-available/$domain"
  
  if [ ! -f "$config_file" ]; then
    echo "未找到 $domain 的配置文件。"
    return
  fi
  
  echo "1. 启用简单跨域"
  echo "2. 启用完整跨域配置"
  echo "3. 禁用跨域"
  echo "4. 返回上级菜单"
  
  read -p "请选择操作： " cors_choice
  
  case $cors_choice in
    1)
      cat >> "$config_file" <<EOL
    # 简单跨域配置
    add_header 'Access-Control-Allow-Origin' '*';
    add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
EOL
      ;;
    2)
      read -p "请输入允许的域名（用空格分隔，* 表示允许所有）： " allowed_origins
      cat >> "$config_file" <<EOL
    # 完整跨域配置
    add_header 'Access-Control-Allow-Origin' '$allowed_origins';
    add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, PUT, DELETE';
    add_header 'Access-Control-Allow-Headers' 'DNT,X-CustomHeader,Keep-Alive,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Authorization';
    add_header 'Access-Control-Allow-Credentials' 'true';
    
    if (\$request_method = 'OPTIONS') {
        add_header 'Access-Control-Max-Age' 1728000;
        add_header 'Content-Type' 'text/plain charset=UTF-8';
        add_header 'Content-Length' 0;
        return 204;
    }
EOL
      ;;
    3)
      sed -i '/# 简单跨域配置/,/^$/d' "$config_file"
      sed -i '/# 完整跨域配置/,/^$/d' "$config_file"
      ;;
    4)
      return
      ;;
  esac
  
  nginx -t && systemctl reload nginx
}

# SSL优化配置
manage_ssl_optimization() {
  echo "SSL优化配置"
  show_domain_status "ssl_optimization"
  read -p "请输入域名： " domain
  config_file="/etc/nginx/sites-available/$domain"
  
  if [ ! -f "$config_file" ]; then
    echo "未找到 $domain 的配置文件。"
    return
  fi
  
  echo "1. 配置SSL协议和加密套件"
  echo "2. 配置OCSP Stapling"
  echo "3. 配置SSL会话缓存"
  echo "4. 配置HSTS"
  echo "5. 返回上级菜单"
  
  read -p "请选择操作： " ssl_choice
  
  case $ssl_choice in
    1)
      cat >> "$config_file" <<EOL
    # SSL协议和加密套件配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
EOL
      ;;
    2)
      cat >> "$config_file" <<EOL
    # OCSP Stapling配置
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;
EOL
      ;;
    3)
      cat >> "$config_file" <<EOL
    # SSL会话缓存配置
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;
EOL
      ;;
    4)
      cat >> "$config_file" <<EOL
    # HSTS配置
    add_header Strict-Transport-Security "max-age=63072000" always;
EOL
      ;;
    5)
      return
      ;;
  esac
  
  nginx -t && systemctl reload nginx
}

# 日志格式定制
manage_log_format() {
  echo "日志格式定制"
  show_domain_status "log_format"
  read -p "请输入域名： " domain
  config_file="/etc/nginx/sites-available/$domain"
  
  if [ ! -f "$config_file" ]; then
    echo "未找到 $domain 的配置文件。"
    return
  fi
  
  echo "1. 配置详细访问日志"
  echo "2. 配置JSON格式日志"
  echo "3. 配置条件日志"
  echo "4. 返回上级菜单"
  
  read -p "请选择操作： " log_choice
  
  case $log_choice in
    1)
      cat > "/etc/nginx/conf.d/log_format.conf" <<EOL
# 详细访问日志格式
log_format detailed '\$remote_addr - \$remote_user [\$time_local] '
                    '"\$request" \$status \$body_bytes_sent '
                    '"\$http_referer" "\$http_user_agent" '
                    '\$request_time \$upstream_response_time \$pipe '
                    '\$upstream_cache_status \$gzip_ratio';

access_log /var/log/nginx/${domain}_access.log detailed buffer=32k flush=5s;
EOL
      ;;
    2)
      cat > "/etc/nginx/conf.d/log_format.conf" <<EOL
# JSON格式日志
log_format json_combined escape=json '{ '
    '"time_local": "\$time_local", '
    '"remote_addr": "\$remote_addr", '
    '"remote_user": "\$remote_user", '
    '"request": "\$request", '
    '"status": "\$status", '
    '"body_bytes_sent": "\$body_bytes_sent", '
    '"request_time": "\$request_time", '
    '"http_referrer": "\$http_referer", '
    '"http_user_agent": "\$http_user_agent" }';

access_log /var/log/nginx/${domain}_access.log json_combined buffer=32k flush=5s;
EOL
      ;;
    3)
      cat >> "$config_file" <<EOL
    # 条件日志配置
    map \$status \$loggable {
        ~^[23] 0;
        default 1;
    }
    
    access_log /var/log/nginx/${domain}_error_access.log combined if=\$loggable;
EOL
      ;;
    4)
      return
      ;;
  esac
  
  nginx -t && systemctl reload nginx
}

# 删除备份功能
delete_backup() {
  local backup_dir="/etc/nginx/backups"
  
  if [ ! -d "$backup_dir" ]; then
    echo "未找到备份目录！"
    return 1
  fi
  
  echo "可用的备份文件："
  local i=1
  local backup_files=()
  
  while IFS= read -r file; do
    backup_files+=("$file")
    echo "$i) $(basename "$file") ($(date -r "$file" '+%Y-%m-%d %H:%M:%S'))"
    ((i++))
  done < <(find "$backup_dir" -name "nginx_backup_*.tar.gz" -type f | sort -r)
  
  if [ ${#backup_files[@]} -eq 0 ]; then
    echo "没有找到备份文件！"
    return 1
  fi
  
  echo "输入要删除的备份文件编号（多个文件用空格分隔，输入 'all' 删除所有）："
  read -r selection
  
  if [ "$selection" = "all" ]; then
    rm -f "$backup_dir"/nginx_backup_*.tar.gz
    echo "已删除所有备份文件。"
  else
    for num in $selection; do
      if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le ${#backup_files[@]} ]; then
        rm -f "${backup_files[$((num-1))]}"
        echo "已删除备份文件: $(basename "${backup_files[$((num-1))]}")"
      else
        echo "无效的选择: $num"
      fi
    done
  fi
}

# 修改主循环，添加服务器选择
while true; do
    if show_selection_menu; then
        # 如果选择了 Nginx，继续执行原有的 Nginx 管理菜单
        clear
        # 显示 Nginx 图标
        show_nginx_logo
        
        # 显示 Nginx 状态
        nginx_status
        
        echo "========================================="
        echo "Nginx 管理脚本"
        echo "========================================="
        echo "1. 安装 Nginx"
        echo "2. 安装 Certbot (Let's Encrypt 客户端)"
        echo "3. 查看域名详细信息"
        echo "4. 添加反向代理 (可选 SSL)"
        echo "5. 为现有域名申请 SSL 证书"
        echo "6. 手动续签所有 SSL 证书"
        echo "7. 设置 SSL 证书自动续签"
        echo "8. 删除反向代理"
        echo "9. 查看所有反向代理配置"
        echo "10. 查看所有 SSL 证书状态"
        echo "11. 修改反向代理配置"
        echo "12. 重启 Nginx"
        echo "13. 查看 Nginx 日志"
        echo "14. 管理 IP 黑名单"
        echo "15. 管理 IP 白名单"
        echo "16. 管理网站密码保护"
        echo "17. 网站流量统计"
        echo "18. 备份/恢复配置"
        echo "19. 修复工具"
        echo "20. 一键删除并卸载 Nginx 和 Certbot"
        echo "21. 返回服务器选择"
        read -p "请选择操作： " choice
        
        case $choice in
            1)
                install_nginx
                ;;
            2)
                install_certbot
                ;;
            3)
                show_domains_info
                ;;
            4)
                add_proxy
                ;;
            5)
                apply_ssl_to_existing
                ;;
            6)
                renew_ssl_certs
                ;;
            7)
                setup_auto_renew
                ;;
            8)
                delete_proxy
                ;;
            9)
                list_proxies
                ;;
            10)
                list_ssl_certs
                ;;
            11)
                modify_proxy
                ;;
            12)
                restart_nginx
                ;;
            13)
                view_nginx_logs
                ;;
            14)
                manage_blacklist
                ;;
            15)
                manage_whitelist
                ;;
            16)
                manage_auth
                ;;
            17)
                site_traffic_stats
                ;;
            18)
                echo "1. 备份配置"
                echo "2. 恢复配置"
                echo "3. 删除备份"
                read -p "请选择操作： " backup_choice
                case $backup_choice in
                    1)
                        backup_nginx_config
                        ;;
                    2)
                        restore_nginx_config
                        ;;
                    3)
                        delete_backup
                        ;;
                    *)
                        echo "无效的选择。"
                        ;;
                esac
                ;;
            19)
                repair_nginx_config
                ;;
            20)
                uninstall_all
                exit 0
                ;;
            21)
                continue
                ;;
            *)
                echo "无效的选择，请重新选择。"
                ;;
        esac
        
        echo ""
        read -p "按回车键继续..."
    fi
done

# 修改 Caddy 反向代理配置
modify_caddy_proxy() {
    if [ ! -f "$PROXY_CONFIG_FILE" ]; then
        echo "没有找到任何反向代理配置。"
        return
    fi

    # 显示当前配置
    echo "当前反向代理配置："
    lineno=0
    while IFS= read -r line; do
        lineno=$((lineno+1))
        echo "${lineno}) ${line}"
    done < "$PROXY_CONFIG_FILE"

    # 选择要修改的配置
    echo "请输入要修改的配置编号："
    read proxy_number
    if [ -z "$proxy_number" ] || ! [[ "$proxy_number" =~ ^[0-9]+$ ]]; then
        echo "无效的输入。"
        return
    fi

    # 获取选中的配置
    selected_config=$(sed -n "${proxy_number}p" "$PROXY_CONFIG_FILE")
    if [ -z "$selected_config" ]; then
        echo "未找到指定的配置。"
        return
    fi

    # 解析当前配置
    current_domain=$(echo "$selected_config" | awk -F' -> ' '{print $1}')
    current_upstream=$(echo "$selected_config" | awk -F' -> ' '{print $2}')

    # 输入新的配置
    echo "当前域名: $current_domain"
    echo "请输入新的域名（留空则保持不变）："
    read new_domain
    new_domain=${new_domain:-$current_domain}

    echo "当前上游服务: $current_upstream"
    echo "请选择新的上游服务类型："
    echo "1) 本地服务（127.0.0.1）"
    echo "2) 公网 IP 地址"
    echo "3) 其他域名"
    echo "4) 保持不变"
    read -p "请选择（1-4）：" upstream_type

    case $upstream_type in
        1)
            echo "请输入本地服务端口（例如 8080）："
            read port
            if [ -z "$port" ]; then
                echo "端口输入不能为空。"
                return
            fi
            new_upstream="http://127.0.0.1:${port}"
            ;;
        2)
            echo "请输入公网 IP 地址（例如 1.2.3.4）："
            read ip
            if [ -z "$ip" ]; then
                echo "IP 地址不能为空。"
                return
            fi
            echo "请输入端口（留空则使用 80）："
            read port
            port=${port:-80}
            new_upstream="http://${ip}:${port}"
            ;;
        3)
            echo "请输入目标域名（例如 target.com）："
            read target_domain
            if [ -z "$target_domain" ]; then
                echo "目标域名不能为空。"
                return
            fi
            echo "请输入端口（留空则使用 80）："
            read port
            if [ -z "$port" ]; then
                new_upstream="http://${target_domain}"
            else
                new_upstream="http://${target_domain}:${port}"
            fi
            ;;
        4)
            new_upstream=$current_upstream
            ;;
        *)
            echo "无效的选择。"
            return
            ;;
    esac

    # 更新配置文件
    sed -i "${proxy_number}c\\${new_domain} -> ${new_upstream}" "$PROXY_CONFIG_FILE"

    # 重新生成 Caddyfile
    echo "重新生成 Caddyfile 配置..."
    cp "$BACKUP_CADDYFILE" "$CADDYFILE"

    # 根据更新后的代理配置列表重新生成配置
    while IFS= read -r line; do
        domain=$(echo "$line" | awk -F' -> ' '{print $1}')
        upstream=$(echo "$line" | awk -F' -> ' '{print $2}')
        echo "${domain} {
    reverse_proxy ${upstream} {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
    }
}" | tee -a "$CADDYFILE" >/dev/null
    done < "$PROXY_CONFIG_FILE"

    # 重启 Caddy 服务
    echo "正在重启 Caddy 服务以应用新配置..."
    systemctl restart caddy
    echo "配置已更新！"
}

# Caddy 黑白名单管理
manage_caddy_access() {
    echo "Caddy 访问控制管理"
    echo "1. 添加 IP 白名单"
    echo "2. 添加 IP 黑名单"
    echo "3. 查看当前访问控制规则"
    echo "4. 删除访问控制规则"
    echo "5. 返回上级菜单"
    read -p "请选择操作： " access_choice
    case $access_choice in
        1)
            read -p "请输入域名： " domain
            read -p "请输入要添加的 IP 地址： " ip
            mkdir -p /etc/caddy/access
            echo "$ip" >> "/etc/caddy/access/${domain}_whitelist.txt"
            if ! grep -q "import /etc/caddy/access/${domain}_whitelist.txt" "$CADDYFILE"; then
                sed -i "/^${domain} {/a \\    import /etc/caddy/access/${domain}_whitelist.txt" "$CADDYFILE"
            fi
            ;;
        2)
            read -p "请输入域名： " domain
            read -p "请输入要添加的 IP 地址： " ip
            mkdir -p /etc/caddy/access
            echo "$ip" >> "/etc/caddy/access/${domain}_blacklist.txt"
            if ! grep -q "import /etc/caddy/access/${domain}_blacklist.txt" "$CADDYFILE"; then
                sed -i "/^${domain} {/a \\    import /etc/caddy/access/${domain}_blacklist.txt" "$CADDYFILE"
            fi
            ;;
        3)
            read -p "请输入域名： " domain
            echo "白名单规则："
            cat "/etc/caddy/access/${domain}_whitelist.txt" 2>/dev/null || echo "无白名单规则"
            echo "黑名单规则："
            cat "/etc/caddy/access/${domain}_blacklist.txt" 2>/dev/null || echo "无黑名单规则"
            ;;
        4)
            read -p "请输入域名： " domain
            read -p "要删除白名单还是黑名单？(w/b)： " list_type
            if [ "$list_type" = "w" ]; then
                rm -f "/etc/caddy/access/${domain}_whitelist.txt"
                sed -i "/import \/etc\/caddy\/access\/${domain}_whitelist.txt/d" "$CADDYFILE"
            elif [ "$list_type" = "b" ]; then
                rm -f "/etc/caddy/access/${domain}_blacklist.txt"
                sed -i "/import \/etc\/caddy\/access\/${domain}_blacklist.txt/d" "$CADDYFILE"
            fi
            ;;
        5)
            return
            ;;
    esac
    systemctl restart caddy
}

# Caddy 流量统计
show_caddy_traffic() {
    echo "Caddy 流量统计"
    echo "1. 查看所有站点流量"
    echo "2. 查看特定站点流量"
    echo "3. 查看特定 IP 访问记录"
    echo "4. 返回上级菜单"
    read -p "请选择操作： " traffic_choice
    case $traffic_choice in
        1)
            for log_file in /var/log/caddy/*.log; do
                [ -f "$log_file" ] || continue
                domain=$(basename "$log_file" .log)
                echo "站点：$domain"
                echo "总请求数：$(wc -l < \"$log_file\")"
                echo "总流量：$(awk '{sum+=$10} END {print sum}' \"$log_file\" | numfmt --to=iec)"
                echo "------------------------"
            done
            ;;
        2)
            read -p "请输入域名： " domain
            log_file="/var/log/caddy/${domain}.log"
            if [ -f "$log_file" ]; then
                echo "站点：$domain"
                echo "总请求数：$(wc -l < \"$log_file\")"
                echo "总流量：$(awk '{sum+=$10} END {print sum}' \"$log_file\" | numfmt --to=iec)"
                echo "最近访问的 IP："
                tail -n 100 "$log_file" | awk '{print $1}' | sort | uniq -c | sort -nr | head -n 10
            else
                echo "未找到该站点的日志文件"
            fi
            ;;
        3)
            read -p "请输入要查询的 IP 地址： " ip
            for log_file in /var/log/caddy/*.log; do
                [ -f "$log_file" ] || continue
                domain=$(basename "$log_file" .log)
                echo "站点：$domain"
                grep "$ip" "$log_file" | tail -n 10
                echo "------------------------"
            done
            ;;
        4)
            return
            ;;
    esac
}

# Caddy 密码保护管理
manage_caddy_auth() {
    echo "Caddy 密码保护管理"
    echo "1. 添加密码保护"
    echo "2. 修改密码"
    echo "3. 删除密码保护"
    echo "4. 返回上级菜单"
    read -p "请选择操作： " auth_choice
    case $auth_choice in
        1)
            read -p "请输入域名： " domain
            read -p "请输入用户名： " username
            read -s -p "请输入密码： " password
            echo
            mkdir -p /etc/caddy/auth
            echo "${username}:$(openssl passwd -apr1 ${password})" > "/etc/caddy/auth/${domain}.htpasswd"
            if ! grep -q "basicauth" "$CADDYFILE"; then
                sed -i "/^${domain} {/a \\    basicauth * {\\n        import /etc/caddy/auth/${domain}.htpasswd\\n    }" "$CADDYFILE"
            fi
            ;;
        2)
            read -p "请输入域名： " domain
            read -p "请输入用户名： " username
            read -s -p "请输入新密码： " password
            echo
            if [ -f "/etc/caddy/auth/${domain}.htpasswd" ]; then
                sed -i "/^${username}:/d" "/etc/caddy/auth/${domain}.htpasswd"
                echo "${username}:$(openssl passwd -apr1 ${password})" >> "/etc/caddy/auth/${domain}.htpasswd"
            else
                echo "未找到该域名的密码文件"
            fi
            ;;
        3)
            read -p "请输入域名： " domain
            rm -f "/etc/caddy/auth/${domain}.htpasswd"
            sed -i "/basicauth \\* {\\n        import \/etc\/caddy\/auth\/${domain}.htpasswd\\n    }/d" "$CADDYFILE"
            ;;
        4)
            return
            ;;
    esac
    systemctl restart caddy
}

# Caddy 配置备份管理
manage_caddy_backup() {
    echo "Caddy 配置备份管理"
    echo "1. 创建备份"
    echo "2. 恢复备份"
    echo "3. 删除备份"
    echo "4. 返回上级菜单"
    read -p "请选择操作： " backup_choice

    case $backup_choice in
        1)
            # 创建备份目录
            mkdir -p /etc/caddy/backups
            timestamp=$(date +%Y%m%d_%H%M%S)
            backup_file="/etc/caddy/backups/caddy_backup_${timestamp}.tar.gz"
            
            # 创建备份
            tar -czf "$backup_file" /etc/caddy/Caddyfile /etc/caddy/access /etc/caddy/auth
            
            if [ $? -eq 0 ]; then
                echo "备份成功创建：$backup_file"
                # 删除30天前的备份
                find /etc/caddy/backups -name "caddy_backup_*.tar.gz" -mtime +30 -delete
            else
                echo "备份创建失败！"
            fi
            ;;
        2)
            # 显示可用的备份
            echo "可用的备份文件："
            local i=1
            local backup_files=()
            
            while IFS= read -r file; do
                backup_files+=("$file")
                echo "$i) $(basename "$file") ($(date -r "$file" '+%Y-%m-%d %H:%M:%S'))"
                ((i++))
            done < <(find /etc/caddy/backups -name "caddy_backup_*.tar.gz" -type f | sort -r)
            
            if [ ${#backup_files[@]} -eq 0 ]; then
                echo "没有找到备份文件！"
                return 1
            fi
            
            read -p "请选择要恢复的备份文件编号： " choice
            
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#backup_files[@]} ]; then
                local selected_backup="${backup_files[$((choice-1))]}"
                
                # 创建临时恢复目录
                local temp_dir=$(mktemp -d)
                
                echo "正在恢复备份..."
                tar -xzf "$selected_backup" -C "$temp_dir"
                
                # 备份当前配置
                cp "$CADDYFILE" "${CADDYFILE}.bak"
                
                # 恢复配置文件
                cp -r "$temp_dir/etc/caddy/Caddyfile" /etc/caddy/
                cp -r "$temp_dir/etc/caddy/access" /etc/caddy/ 2>/dev/null
                cp -r "$temp_dir/etc/caddy/auth" /etc/caddy/ 2>/dev/null
                
                # 清理临时目录
                rm -rf "$temp_dir"
                
                # 重启 Caddy
                systemctl restart caddy
                echo "配置已成功恢复！"
            else
                echo "无效的选择！"
            fi
            ;;
        3)
            # 显示可用的备份
            echo "可用的备份文件："
            local i=1
            local backup_files=()
            
            while IFS= read -r file; do
                backup_files+=("$file")
                echo "$i) $(basename "$file") ($(date -r "$file" '+%Y-%m-%d %H:%M:%S'))"
                ((i++))
            done < <(find /etc/caddy/backups -name "caddy_backup_*.tar.gz" -type f | sort -r)
            
            if [ ${#backup_files[@]} -eq 0 ]; then
                echo "没有找到备份文件！"
                return 1
            fi
            
            echo "输入要删除的备份文件编号（多个文件用空格分隔，输入 'all' 删除所有）："
            read -r selection
            
            if [ "$selection" = "all" ]; then
                rm -f /etc/caddy/backups/caddy_backup_*.tar.gz
                echo "已删除所有备份文件。"
            else
                for num in $selection; do
                    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le ${#backup_files[@]} ]; then
                        rm -f "${backup_files[$((num-1))]}"
                        echo "已删除备份文件: $(basename "${backup_files[$((num-1))]}")"
                    else
                        echo "无效的选择: $num"
                    fi
                done
            fi
            ;;
        4)
            return
            ;;
        *)
            echo "无效的选择，请重新选择。"
            ;;
    esac
}
