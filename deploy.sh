#!/bin/bash

# HTTPS CONNECT AEAD 代理服务器管理脚本 v4.1
# 添加详细的客户端配置信息显示

set -e

# ===================== 配置变量 =====================
SERVICE_NAME="https-proxy"
SERVICE_USER="https-proxy"
BINARY_NAME="https_connect_aead_proxy"
BINARY_URL="https://raw.githubusercontent.com/pfxjacky/Ahead-HCP-Connect/refs/heads/main/https_connect_aead_proxy"
INSTALL_DIR="/opt/https-proxy"
CONFIG_DIR="/etc/https-proxy"
LOG_DIR="/var/log/https-proxy"

# 默认配置
DEFAULT_LISTEN_V4="0.0.0.0:8443"
DEFAULT_LISTEN_V6="[::]:8444"
DEFAULT_PFX_PASS="changeit"

# 全局变量
HAS_IPV4=false
HAS_IPV6=false
LOCAL_IPV4=""
LOCAL_IPV6=""
CUSTOM_DOMAIN=""
INSTALL_MODE=""
ADMIN_TOKEN=""

# ===================== 工具函数 =====================
log() {
    echo -e "\033[32m[$(date '+%H:%M:%S')]\033[0m $1"
}

error() {
    echo -e "\033[31m[错误]\033[0m $1"
    exit 1
}

warn() {
    echo -e "\033[33m[警告]\033[0m $1"
}

info() {
    echo -e "\033[36m[信息]\033[0m $1"
}

success() {
    echo -e "\033[32m[成功]\033[0m $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要 root 权限运行，请使用: sudo $0"
    fi
}

# ===================== 步骤1: 网络环境检测 =====================
step1_detect_network() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║                  步骤 1/6: 网络检测               ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    
    log "正在检测网络环境..."
    
    # 检测IPv4
    if ip route get 8.8.8.8 >/dev/null 2>&1; then
        LOCAL_IPV4=$(ip route get 8.8.8.8 | grep -oP 'src \K\S+' 2>/dev/null)
        if [[ -n "$LOCAL_IPV4" && "$LOCAL_IPV4" != "127.0.0.1" ]]; then
            HAS_IPV4=true
            success "检测到 IPv4 地址: $LOCAL_IPV4"
        fi
    fi
    
    # 检测IPv6
    if [[ -f /proc/net/if_inet6 ]] && ip -6 route get 2001:4860:4860::8888 >/dev/null 2>&1; then
        LOCAL_IPV6=$(ip -6 addr show | grep 'inet6.*global' | head -1 | awk '{print $2}' | cut -d'/' -f1 2>/dev/null)
        if [[ -n "$LOCAL_IPV6" ]]; then
            HAS_IPV6=true
            success "检测到 IPv6 地址: $LOCAL_IPV6"
        fi
    fi
    
    # 确定安装模式
    if [[ "$HAS_IPV4" == true && "$HAS_IPV6" == true ]]; then
        INSTALL_MODE="dual"
        info "推荐安装模式: 双栈 (IPv4 + IPv6)"
    elif [[ "$HAS_IPV4" == true ]]; then
        INSTALL_MODE="ipv4"
        info "推荐安装模式: 仅 IPv4"
    elif [[ "$HAS_IPV6" == true ]]; then
        INSTALL_MODE="ipv6"
        info "推荐安装模式: 仅 IPv6"
    else
        error "未检测到可用的网络连接"
    fi
    
    echo ""
    read -p "按回车键继续..." -r
}

# ===================== 步骤2: 域名配置 =====================
step2_configure_domain() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║                  步骤 2/6: 域名配置               ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    
    echo "本机IP地址:"
    [[ "$HAS_IPV4" == true ]] && echo "  IPv4: $LOCAL_IPV4"
    [[ "$HAS_IPV6" == true ]] && echo "  IPv6: $LOCAL_IPV6"
    echo ""
    
    while true; do
        read -p "请输入您的域名 (例如: proxy.example.com): " input_domain
        
        if [[ -z "$input_domain" ]]; then
            warn "域名不能为空，请重新输入"
            continue
        fi
        
        # 清理输入
        input_domain=$(echo "$input_domain" | sed 's|^https\?://||' | sed 's|/.*$||')
        
        # 基本格式检查
        if [[ ! "$input_domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
            warn "域名格式不正确，请输入有效的域名"
            continue
        fi
        
        CUSTOM_DOMAIN="$input_domain"
        success "域名设置为: $CUSTOM_DOMAIN"
        break
    done
    
    echo ""
    read -p "按回车键继续..." -r
}

# ===================== 步骤3: DNS验证 =====================
step3_verify_dns() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║                  步骤 3/6: DNS验证               ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    
    log "正在验证域名 DNS 解析: $CUSTOM_DOMAIN"
    echo ""
    
    local dns_ok=false
    
    # 检查IPv4 A记录
    if [[ "$HAS_IPV4" == true ]]; then
        echo -n "检查 IPv4 A记录... "
        local resolved_ipv4=$(dig +short A "$CUSTOM_DOMAIN" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
        
        if [[ -n "$resolved_ipv4" ]]; then
            echo "解析到: $resolved_ipv4"
            if [[ "$resolved_ipv4" == "$LOCAL_IPV4" ]]; then
                success "✅ IPv4 A记录匹配本机IP"
                dns_ok=true
            else
                warn "❌ IPv4 A记录不匹配 (本机: $LOCAL_IPV4, 解析: $resolved_ipv4)"
            fi
        else
            warn "❌ 无法解析IPv4 A记录"
        fi
    fi
    
    # 检查IPv6 AAAA记录
    if [[ "$HAS_IPV6" == true ]]; then
        echo -n "检查 IPv6 AAAA记录... "
        local resolved_ipv6=$(dig +short AAAA "$CUSTOM_DOMAIN" 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' | head -1)
        
        if [[ -n "$resolved_ipv6" ]]; then
            echo "解析到: $resolved_ipv6"
            if [[ "$resolved_ipv6" == "$LOCAL_IPV6" ]]; then
                success "✅ IPv6 AAAA记录匹配本机IP"
                dns_ok=true
            else
                warn "❌ IPv6 AAAA记录不匹配 (本机: $LOCAL_IPV6, 解析: $resolved_ipv6)"
            fi
        else
            warn "❌ 无法解析IPv6 AAAA记录"
        fi
    fi
    
    echo ""
    if [[ "$dns_ok" == true ]]; then
        success "🎉 DNS验证通过！"
    else
        warn "⚠️  DNS验证失败，但将继续安装"
        echo ""
        echo "请确保以下DNS记录正确配置："
        [[ "$HAS_IPV4" == true ]] && echo "  $CUSTOM_DOMAIN A $LOCAL_IPV4"
        [[ "$HAS_IPV6" == true ]] && echo "  $CUSTOM_DOMAIN AAAA $LOCAL_IPV6"
    fi
    
    echo ""
    read -p "按回车键继续..." -r
}

# ===================== 步骤4: 系统准备 =====================
step4_system_preparation() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║                  步骤 4/6: 系统准备               ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    
    # 修复主机名
    log "修复主机名解析..."
    local hostname=$(hostname)
    if ! grep -q "127.0.0.1.*$hostname" /etc/hosts; then
        echo "127.0.0.1 $hostname" >> /etc/hosts
    fi
    
    # 安装依赖
    log "安装系统依赖..."
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y curl openssl systemd cron file dnsutils >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl openssl systemd cronie file bind-utils >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl openssl systemd cronie file bind-utils >/dev/null 2>&1
    fi
    
    # 停止现有服务
    log "停止现有服务..."
    for service in "$SERVICE_NAME" "${SERVICE_NAME}-ipv4" "${SERVICE_NAME}-ipv6"; do
        systemctl stop "$service" 2>/dev/null || true
    done
    
    # 杀死残留进程
    local binary_path="$INSTALL_DIR/bin/$BINARY_NAME"
    if [[ -f "$binary_path" ]]; then
        local pids=$(pgrep -f "$binary_path" 2>/dev/null || true)
        if [[ -n "$pids" ]]; then
            echo "$pids" | xargs kill -TERM 2>/dev/null || true
            sleep 2
            pids=$(pgrep -f "$binary_path" 2>/dev/null || true)
            [[ -n "$pids" ]] && echo "$pids" | xargs kill -KILL 2>/dev/null || true
        fi
    fi
    
    # 检查OpenSSL
    log "检查OpenSSL库..."
    install_openssl_if_needed
    
    success "系统准备完成"
    echo ""
    read -p "按回车键继续..." -r
}

install_openssl_if_needed() {
    # 检查libssl.so.1.1是否存在
    local libssl_paths=(
        "/usr/lib/x86_64-linux-gnu/libssl.so.1.1"
        "/usr/lib64/libssl.so.1.1"
        "/lib/x86_64-linux-gnu/libssl.so.1.1"
    )
    
    local found=false
    for path in "${libssl_paths[@]}"; do
        if [[ -f "$path" ]]; then
            found=true
            break
        fi
    done
    
    if [[ "$found" == false ]]; then
        info "安装 OpenSSL 1.1 库..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -y libssl1.1 2>/dev/null || {
                # 手动安装
                local temp_dir="/tmp/libssl_install"
                mkdir -p "$temp_dir" && cd "$temp_dir"
                curl -fsSL "http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2_amd64.deb" -o "libssl1.1.deb"
                dpkg -i "libssl1.1.deb" 2>/dev/null || {
                    ar x "libssl1.1.deb"
                    tar -xf data.tar.xz
                    cp usr/lib/x86_64-linux-gnu/libssl.so.1.1 /usr/lib/x86_64-linux-gnu/
                    cp usr/lib/x86_64-linux-gnu/libcrypto.so.1.1 /usr/lib/x86_64-linux-gnu/
                    ldconfig
                }
                cd - >/dev/null && rm -rf "$temp_dir"
            }
        fi
    fi
}

# ===================== 步骤5: 服务安装 =====================
step5_install_service() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║                  步骤 5/6: 服务安装               ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    
    # 生成管理令牌
    ADMIN_TOKEN="$(openssl rand -hex 16)"
    
    # 下载二进制文件
    log "下载代理程序..."
    local temp_file="/tmp/https_connect_aead_proxy.$$"
    
    if ! curl -fL --progress-bar --max-time 120 "$BINARY_URL" -o "$temp_file"; then
        error "下载失败，请检查网络连接"
    fi
    
    local file_size=$(stat -c%s "$temp_file" 2>/dev/null || echo "0")
    if [[ $file_size -lt 1000000 ]]; then
        rm -f "$temp_file"
        error "下载的文件太小，可能下载失败"
    fi
    
    success "下载完成 ($(numfmt --to=iec $file_size))"
    
    # 创建用户和目录
    log "创建系统用户和目录..."
    if ! id "$SERVICE_USER" &>/dev/null; then
        useradd -r -s /bin/false -d "$INSTALL_DIR" -c "HTTPS Proxy" "$SERVICE_USER"
    fi
    
    mkdir -p "$INSTALL_DIR/bin" "$CONFIG_DIR" "$LOG_DIR"
    
    # 安装二进制文件
    log "安装二进制文件..."
    cp "$temp_file" "$INSTALL_DIR/bin/$BINARY_NAME"
    chmod +x "$INSTALL_DIR/bin/$BINARY_NAME"
    chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"
    rm -f "$temp_file"
    
    # 验证二进制文件
    if ! timeout 10 "$INSTALL_DIR/bin/$BINARY_NAME" --help >/dev/null 2>&1; then
        error "二进制文件验证失败"
    fi
    
    # 生成PSK
    log "生成PSK密钥..."
    openssl rand -out "$CONFIG_DIR/psk.bin" 32
    chown "$SERVICE_USER:$SERVICE_USER" "$CONFIG_DIR/psk.bin"
    chmod 600 "$CONFIG_DIR/psk.bin"
    
    # 生成SSL证书
    log "生成SSL证书..."
    generate_ssl_certificate
    
    # 创建服务文件
    log "创建systemd服务..."
    create_systemd_services
    
    # 保存配置信息
    save_configuration
    
    success "服务安装完成"
    echo ""
    read -p "按回车键继续..." -r
}

save_configuration() {
    # 保存配置信息到文件，供后续查看
    cat > "$CONFIG_DIR/client-config.txt" << EOF
# HTTPS 代理客户端配置信息
# 生成时间: $(date)

域名: $CUSTOM_DOMAIN
安装模式: $INSTALL_MODE
管理令牌: $ADMIN_TOKEN
PSK Base64: $(base64 -w0 "$CONFIG_DIR/psk.bin")

EOF

    if [[ "$INSTALL_MODE" == "ipv4" || "$INSTALL_MODE" == "dual" ]]; then
        cat >> "$CONFIG_DIR/client-config.txt" << EOF
# IPv4 配置
Name: $CUSTOM_DOMAIN-IPv4
Host: $CUSTOM_DOMAIN
Port: 8443
SNI: $CUSTOM_DOMAIN
Admin Token: $ADMIN_TOKEN
PSK: $(base64 -w0 "$CONFIG_DIR/psk.bin")
Insecure TLS: ✓ (必须勾选)

EOF
    fi

    if [[ "$INSTALL_MODE" == "ipv6" || "$INSTALL_MODE" == "dual" ]]; then
        cat >> "$CONFIG_DIR/client-config.txt" << EOF
# IPv6 配置  
Name: $CUSTOM_DOMAIN-IPv6
Host: $CUSTOM_DOMAIN
Port: 8444
SNI: $CUSTOM_DOMAIN
Admin Token: $ADMIN_TOKEN
PSK: $(base64 -w0 "$CONFIG_DIR/psk.bin")
Insecure TLS: ✓ (必须勾选)

EOF
    fi
}

generate_ssl_certificate() {
    local ssl_conf="/tmp/ssl.conf"
    cat > "$ssl_conf" << EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C=US
ST=State
L=City
O=Organization
CN=$CUSTOM_DOMAIN

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $CUSTOM_DOMAIN
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

    # 添加本机IP到证书
    local alt_count=2
    if [[ "$HAS_IPV4" == true ]]; then
        ((alt_count++))
        echo "IP.$alt_count = $LOCAL_IPV4" >> "$ssl_conf"
    fi
    if [[ "$HAS_IPV6" == true ]]; then
        ((alt_count++))
        echo "IP.$alt_count = $LOCAL_IPV6" >> "$ssl_conf"
    fi
    
    local temp_key="/tmp/server.key"
    local temp_cert="/tmp/server.crt"
    
    openssl genrsa -out "$temp_key" 2048 2>/dev/null
    openssl req -new -x509 -key "$temp_key" -out "$temp_cert" -days 3650 \
        -config "$ssl_conf" -extensions v3_req 2>/dev/null
    openssl pkcs12 -export -out "$CONFIG_DIR/cert.p12" \
        -inkey "$temp_key" -in "$temp_cert" \
        -password "pass:$DEFAULT_PFX_PASS" 2>/dev/null
    
    rm -f "$ssl_conf" "$temp_key" "$temp_cert"
    chown "$SERVICE_USER:$SERVICE_USER" "$CONFIG_DIR/cert.p12"
    chmod 644 "$CONFIG_DIR/cert.p12"
}

create_systemd_services() {
    case "$INSTALL_MODE" in
        ipv4)
            create_service_file "ipv4" "$DEFAULT_LISTEN_V4"
            systemctl enable "${SERVICE_NAME}-ipv4"
            ;;
        ipv6)
            create_service_file "ipv6" "$DEFAULT_LISTEN_V6"
            systemctl enable "${SERVICE_NAME}-ipv6"
            ;;
        dual)
            create_service_file "ipv4" "$DEFAULT_LISTEN_V4"
            create_service_file "ipv6" "$DEFAULT_LISTEN_V6"
            systemctl enable "${SERVICE_NAME}-ipv4" "${SERVICE_NAME}-ipv6"
            ;;
    esac
    
    systemctl daemon-reload
}

create_service_file() {
    local ip_version="$1"
    local listen_addr="$2"
    local service_file="/etc/systemd/system/${SERVICE_NAME}-${ip_version}.service"
    
    cat > "$service_file" << EOF
[Unit]
Description=HTTPS CONNECT AEAD Proxy Server ($ip_version)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR

ExecStart=$INSTALL_DIR/bin/$BINARY_NAME \\
    --listen $listen_addr \\
    --pfx $CONFIG_DIR/cert.p12 \\
    --pfx-pass $DEFAULT_PFX_PASS \\
    --psk-file $CONFIG_DIR/psk.bin \\
    --admin-token $ADMIN_TOKEN

Restart=always
RestartSec=5
StartLimitBurst=5
LimitNOFILE=65535

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

# ===================== 步骤6: 启动和验证 =====================
step6_start_and_verify() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║                  步骤 6/6: 启动验证               ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    
    # 启动服务
    log "启动代理服务..."
    
    local services_started=0
    case "$INSTALL_MODE" in
        ipv4)
            if systemctl start "${SERVICE_NAME}-ipv4"; then
                success "IPv4 服务启动成功"
                ((services_started++))
            fi
            ;;
        ipv6)
            if systemctl start "${SERVICE_NAME}-ipv6"; then
                success "IPv6 服务启动成功"
                ((services_started++))
            fi
            ;;
        dual)
            if systemctl start "${SERVICE_NAME}-ipv4"; then
                success "IPv4 服务启动成功"
                ((services_started++))
            fi
            if systemctl start "${SERVICE_NAME}-ipv6"; then
                success "IPv6 服务启动成功"
                ((services_started++))
            fi
            ;;
    esac
    
    if [[ $services_started -eq 0 ]]; then
        error "所有服务启动失败"
    fi
    
    # 等待服务稳定
    log "等待服务稳定..."
    sleep 5
    
    # 运行完整状态检测
    run_health_check
    
    # 显示安装结果
    show_installation_summary
}

# ===================== 完整状态检测 =====================
run_health_check() {
    echo ""
    echo "🔍 运行完整状态检测..."
    echo "====================="
    
    local all_good=true
    
    # 1. 检查服务状态
    echo ""
    echo "📊 服务状态检查:"
    for service in "${SERVICE_NAME}-ipv4" "${SERVICE_NAME}-ipv6"; do
        if [[ -f "/etc/systemd/system/${service}.service" ]]; then
            if systemctl is-active --quiet "$service"; then
                success "✅ $service: 运行中"
            else
                warn "❌ $service: 已停止"
                all_good=false
            fi
        fi
    done
    
    # 2. 检查端口监听
    echo ""
    echo "🌐 端口监听检查:"
    if [[ "$INSTALL_MODE" == "ipv4" || "$INSTALL_MODE" == "dual" ]]; then
        if ss -tlnp | grep -q ":8443 "; then
            success "✅ IPv4 端口 8443: 正在监听"
        else
            warn "❌ IPv4 端口 8443: 未监听"
            all_good=false
        fi
    fi
    
    if [[ "$INSTALL_MODE" == "ipv6" || "$INSTALL_MODE" == "dual" ]]; then
        if ss -tlnp | grep -q ":8444 "; then
            success "✅ IPv6 端口 8444: 正在监听"
        else
            warn "❌ IPv6 端口 8444: 未监听"
            all_good=false
        fi
    fi
    
    # 3. 检查配置文件
    echo ""
    echo "📁 配置文件检查:"
    if [[ -f "$CONFIG_DIR/psk.bin" ]]; then
        success "✅ PSK文件: 存在"
    else
        warn "❌ PSK文件: 不存在"
        all_good=false
    fi
    
    if [[ -f "$CONFIG_DIR/cert.p12" ]]; then
        success "✅ SSL证书: 存在"
    else
        warn "❌ SSL证书: 不存在"
        all_good=false
    fi
    
    if [[ -n "$ADMIN_TOKEN" ]]; then
        success "✅ 管理令牌: 已设置"
    else
        warn "❌ 管理令牌: 未设置"
        all_good=false
    fi
    
    # 4. 网络连通性测试
    echo ""
    echo "🔗 网络连通性测试:"
    if [[ "$INSTALL_MODE" == "ipv4" || "$INSTALL_MODE" == "dual" ]]; then
        if timeout 5 curl -k -s "https://127.0.0.1:8443" >/dev/null 2>&1; then
            success "✅ IPv4 HTTPS (127.0.0.1:8443): 可访问"
        else
            warn "❌ IPv4 HTTPS (127.0.0.1:8443): 不可访问"
            all_good=false
        fi
        
        if timeout 5 curl -k -s "https://$LOCAL_IPV4:8443" >/dev/null 2>&1; then
            success "✅ IPv4 HTTPS ($LOCAL_IPV4:8443): 可访问"
        else
            warn "❌ IPv4 HTTPS ($LOCAL_IPV4:8443): 不可访问"
            all_good=false
        fi
    fi
    
    if [[ "$INSTALL_MODE" == "ipv6" || "$INSTALL_MODE" == "dual" ]]; then
        if timeout 5 curl -k -s "https://[::1]:8444" >/dev/null 2>&1; then
            success "✅ IPv6 HTTPS ([::1]:8444): 可访问"
        else
            warn "❌ IPv6 HTTPS ([::1]:8444): 不可访问"
            all_good=false
        fi
        
        if [[ -n "$LOCAL_IPV6" ]] && timeout 5 curl -k -s "https://[$LOCAL_IPV6]:8444" >/dev/null 2>&1; then
            success "✅ IPv6 HTTPS ([$LOCAL_IPV6]:8444): 可访问"
        else
            warn "❌ IPv6 HTTPS ([$LOCAL_IPV6]:8444): 不可访问"
            all_good=false
        fi
    fi
    
    # 5. 域名HTTPS测试
    echo ""
    echo "🌐 域名HTTPS测试:"
    local domain_ports=()
    [[ "$INSTALL_MODE" == "ipv4" || "$INSTALL_MODE" == "dual" ]] && domain_ports+=("8443")
    [[ "$INSTALL_MODE" == "ipv6" || "$INSTALL_MODE" == "dual" ]] && domain_ports+=("8444")
    
    for port in "${domain_ports[@]}"; do
        if timeout 5 curl -k -s "https://$CUSTOM_DOMAIN:$port" >/dev/null 2>&1; then
            success "✅ 域名 HTTPS ($CUSTOM_DOMAIN:$port): 可访问"
        else
            warn "❌ 域名 HTTPS ($CUSTOM_DOMAIN:$port): 不可访问"
        fi
    done
    
    # 总结
    echo ""
    if [[ "$all_good" == true ]]; then
        success "🎉 所有检查项目都通过！代理服务运行正常"
    else
        warn "⚠️  部分检查项目失败，请检查相关配置"
    fi
}

# ===================== 安装结果显示 =====================
show_installation_summary() {
    echo ""
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║                🎉 安装完成！                     ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    
    echo "📋 服务器信息"
    echo "============"
    echo "安装模式: $INSTALL_MODE"
    echo "域名: $CUSTOM_DOMAIN"
    echo "管理令牌: $ADMIN_TOKEN"
    echo "PSK Base64: $(base64 -w0 "$CONFIG_DIR/psk.bin")"
    echo ""
    
    echo "╔══════════════════════════════════════════════════╗"
    echo "║               📱 客户端配置信息                   ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    
    if [[ "$INSTALL_MODE" == "ipv4" || "$INSTALL_MODE" == "dual" ]]; then
        echo "┌──────────────── IPv4 配置 ────────────────┐"
        echo "│ Name: $CUSTOM_DOMAIN-IPv4"
        echo "│ Host: $CUSTOM_DOMAIN"
        echo "│ Port: 8443"
        echo "│ SNI: $CUSTOM_DOMAIN"
        echo "│ Admin Token: $ADMIN_TOKEN"
        echo "│ PSK: $(base64 -w0 "$CONFIG_DIR/psk.bin")"
        echo "│ Insecure TLS: ✓ (必须勾选)"
        echo "└────────────────────────────────────────────┘"
        echo ""
    fi
    
    if [[ "$INSTALL_MODE" == "ipv6" || "$INSTALL_MODE" == "dual" ]]; then
        echo "┌──────────────── IPv6 配置 ────────────────┐"
        echo "│ Name: $CUSTOM_DOMAIN-IPv6"
        echo "│ Host: $CUSTOM_DOMAIN"
        echo "│ Port: 8444"
        echo "│ SNI: $CUSTOM_DOMAIN"
        echo "│ Admin Token: $ADMIN_TOKEN"
        echo "│ PSK: $(base64 -w0 "$CONFIG_DIR/psk.bin")"
        echo "│ Insecure TLS: ✓ (必须勾选)"
        echo "└────────────────────────────────────────────┘"
        echo ""
    fi
    
    echo "💡 客户端配置说明"
    echo "================"
    echo "1. 在客户端软件中创建新的节点配置"
    echo "2. 按照上述信息逐项填写配置参数"
    echo "3. ⚠️  务必勾选 'Insecure TLS (skip verify)' 选项"
    echo "4. Admin Token 和 PSK 二选一即可 (推荐使用 Admin Token)"
    echo "5. 如果是双栈模式，可以创建两个节点分别使用不同端口"
    echo ""
    
    echo "🌐 服务访问地址"
    echo "=============="
    if [[ "$INSTALL_MODE" == "ipv4" || "$INSTALL_MODE" == "dual" ]]; then
        echo "IPv4 域名: https://$CUSTOM_DOMAIN:8443"
        echo "IPv4 直连: https://$LOCAL_IPV4:8443"
    fi
    if [[ "$INSTALL_MODE" == "ipv6" || "$INSTALL_MODE" == "dual" ]]; then
        echo "IPv6 域名: https://$CUSTOM_DOMAIN:8444"
        echo "IPv6 直连: https://[$LOCAL_IPV6]:8444"
    fi
    echo ""
    
    echo "📄 配置文件位置"
    echo "=============="
    echo "客户端配置: $CONFIG_DIR/client-config.txt"
    echo "PSK文件: $CONFIG_DIR/psk.bin"
    echo "SSL证书: $CONFIG_DIR/cert.p12"
    echo ""
    
    echo "🔧 管理命令"
    echo "==========="
    echo "查看状态: $0 status"
    echo "查看配置: $0 config"
    echo "重启服务: $0 restart"
    echo "停止服务: $0 stop"
    echo "卸载服务: $0 uninstall"
    echo ""
    
    info "配置信息已保存到: $CONFIG_DIR/client-config.txt"
}

# ===================== 其他管理功能 =====================
show_status() {
    echo ""
    echo "📊 代理服务状态"
    echo "==============="
    
    # 尝试加载保存的配置
    if [[ -f "$CONFIG_DIR/client-config.txt" ]]; then
        source "$CONFIG_DIR/client-config.txt" 2>/dev/null || true
    fi
    
    run_health_check
}

show_config() {
    echo ""
    echo "📱 客户端配置信息"
    echo "================="
    
    if [[ -f "$CONFIG_DIR/client-config.txt" ]]; then
        cat "$CONFIG_DIR/client-config.txt"
    else
        warn "配置文件不存在，请重新安装服务"
    fi
}

restart_services() {
    echo ""
    log "重启代理服务..."
    
    for service in "${SERVICE_NAME}-ipv4" "${SERVICE_NAME}-ipv6"; do
        if [[ -f "/etc/systemd/system/${service}.service" ]]; then
            systemctl restart "$service" && success "✓ $service 重启成功"
        fi
    done
    
    sleep 3
    show_status
}

stop_services() {
    echo ""
    log "停止代理服务..."
    
    for service in "${SERVICE_NAME}-ipv4" "${SERVICE_NAME}-ipv6"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            systemctl stop "$service" && success "✓ $service 已停止"
        fi
    done
}

uninstall_services() {
    echo ""
    warn "此操作将完全删除代理服务和配置"
    read -p "确认卸载? [y/N]: " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "卸载代理服务..."
        
        # 停止并禁用服务
        for service in "${SERVICE_NAME}-ipv4" "${SERVICE_NAME}-ipv6"; do
            systemctl stop "$service" 2>/dev/null || true
            systemctl disable "$service" 2>/dev/null || true
            rm -f "/etc/systemd/system/${service}.service"
        done
        
        systemctl daemon-reload
        
        # 删除文件和用户
        rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"
        userdel "$SERVICE_USER" 2>/dev/null || true
        
        success "卸载完成"
    else
        info "取消卸载"
    fi
}

# ===================== 主菜单 =====================
show_main_menu() {
    clear
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║        HTTPS 代理服务器管理脚本 v4.1             ║"
    echo "║           详细客户端配置信息显示                 ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    echo "请选择操作:"
    echo ""
    echo "  1) 🚀 全流程安装服务"
    echo "  2) 📊 查看服务状态"
    echo "  3) 📱 查看客户端配置"
    echo "  4) 🔄 重启服务"
    echo "  5) ⏹️  停止服务"
    echo "  6) 🗑️  卸载服务"
    echo ""
    echo "  0) 退出"
    echo ""
    
    read -p "请输入选择 [0-6]: " choice
    
    case "$choice" in
        1)
            step1_detect_network
            step2_configure_domain
            step3_verify_dns
            step4_system_preparation
            step5_install_service
            step6_start_and_verify
            ;;
        2)
            show_status
            ;;
        3)
            show_config
            ;;
        4)
            restart_services
            ;;
        5)
            stop_services
            ;;
        6)
            uninstall_services
            ;;
        0)
            echo ""
            echo "👋 感谢使用！"
            exit 0
            ;;
        *)
            warn "无效选择，请输入 0-6"
            sleep 2
            ;;
    esac
    
    echo ""
    read -p "按回车键返回主菜单..." -r
}

# ===================== 主程序 =====================
main() {
    check_root
    
    # 命令行参数处理
    case "${1:-}" in
        status)
            show_status
            ;;
        config)
            show_config
            ;;
        restart)
            restart_services
            ;;
        stop)
            stop_services
            ;;
        uninstall)
            uninstall_services
            ;;
        *)
            while true; do
                show_main_menu
            done
            ;;
    esac
}

# 启动程序
main "$@"