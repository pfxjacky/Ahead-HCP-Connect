#!/bin/bash
# 一键安装/卸载 Ahead‑HCP‑Connect 的脚本
#
# 本脚本提供一个简单的交互式菜单，可以安装或卸载服务端。
# 安装时将根据用户输入自动生成证书、随机 PSK 密钥，并绑定机器的 IPv4 与 IPv6 地址。
#
# 注意：脚本假定目标系统为类 Unix 系统（例如 Ubuntu/Debian/CentOS），并具有 sudo 权限。

set -e

# 安装目录，可根据需要修改
INSTALL_DIR="/opt/head_android_server"
SERVICE_FILE="/etc/systemd/system/head_android_server.service"

# Github 仓库地址（用于备选编译）
REPO_URL="https://github.com/pfxjacky/Ahead-HCP-Connect.git"
# 预编译二进制地址（如果可用）
BIN_URL="https://raw.githubusercontent.com/pfxjacky/Ahead-HCP-Connect/refs/heads/main/head-android-server"

###########################################################################
# 工具函数

# 从当前主机获取首个公共 IPv4 地址
function get_ipv4() {
    ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d'/' -f1 | head -n1
}

# 从当前主机获取首个公共 IPv6 地址
function get_ipv6() {
    ip -6 addr show scope global | awk '/inet6 /{print $2}' | cut -d'/' -f1 | head -n1
}

# 生成随机 PSK 密钥（32 字节，Base64 编码）
function generate_psk() {
    # 如果系统安装了 openssl，使用 openssl 生成
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 32
    else
        # fallback：使用 /dev/urandom
        head -c 32 /dev/urandom | base64
    fi
}

# 生成自签名证书，包含域名和 IP 地址作为 SAN
function generate_cert() {
    local domain="$1"
    local ipv4="$2"
    local ipv6="$3"
    mkdir -p "$INSTALL_DIR"
    local cert="$INSTALL_DIR/server.crt"
    local key="$INSTALL_DIR/server.key"

    # 创建一个临时的 openssl 配置，用于指定 subjectAltName
    local tmpcfg="$(mktemp)"
    cat > "$tmpcfg" <<EOF
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
req_extensions     = req_ext
distinguished_name = dn

[ dn ]
CN = $domain

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1   = $domain
IP.1    = $ipv4
IP.2    = $ipv6
EOF
    # 生成密钥和证书
    if command -v openssl >/dev/null 2>&1; then
        openssl req -x509 -nodes -newkey rsa:2048 \
            -keyout "$key" -out "$cert" -days 3650 \
            -config "$tmpcfg" >/dev/null 2>&1
    else
        echo "未检测到 openssl，无法生成证书。请先安装 openssl。"
        rm -f "$tmpcfg"
        return 1
    fi
    rm -f "$tmpcfg"
    echo "$cert|$key"
}

# 下载或编译服务端程序
function obtain_server_binary() {
    mkdir -p "$INSTALL_DIR"
    local bin_path="$INSTALL_DIR/anytls_aead_server"
    # 尝试下载预编译二进制文件
    if command -v curl >/dev/null 2>&1; then
        echo "尝试下载预编译的服务端二进制..."
        if curl -fsSL "$BIN_URL" -o "$bin_path"; then
            chmod +x "$bin_path"
            echo "$bin_path"
            return 0
        fi
    fi
    # 下载失败则尝试从源码编译
    echo "下载失败，尝试从源码编译。"
    if ! command -v git >/dev/null 2>&1; then
        echo "缺少 git，无法克隆仓库。请安装 git 后重试。"
        return 1
    fi
    if ! command -v cargo >/dev/null 2>&1; then
        echo "缺少 Rust 工具链 (cargo)。正在尝试安装..."
        # 根据系统类型安装 rustup。用户需自行确认.
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    fi
    local workdir="$(mktemp -d)"
    git clone --depth 1 "$REPO_URL" "$workdir"
    pushd "$workdir" >/dev/null
    # 在 Rust 项目根目录运行构建
    if cargo build --release; then
        cp target/release/anytls_aead_server "$bin_path"
        chmod +x "$bin_path"
        popd >/dev/null
        rm -rf "$workdir"
        echo "$bin_path"
        return 0
    else
        popd >/dev/null
        rm -rf "$workdir"
        echo "编译失败。"
        return 1
    fi
}

# 创建 systemd 服务文件
function create_service() {
    local bin="$1"
    local port="$2"
    local psk="$3"
    # 写入 systemd unit
    sudo tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=Ahead-HCP-Connect AEAD Server
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$bin --listen 0.0.0.0:$port --generate-ca --psk $psk --skip-cert-verify
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now $(basename "$SERVICE_FILE" .service)
}

# 安装流程
function install_server() {
    echo "=== 安装 anytls_aead_server ==="
    read -p "请输入证书使用的域名 (默认 example.com): " domain
    domain=${domain:-example.com}
    read -p "请输入监听端口 (默认 8443): " port
    port=${port:-58443}
    # 获取主机 IPv4 和 IPv6
    local ipv4=$(get_ipv4)
    local ipv6=$(get_ipv6)
    echo "检测到 IPv4 地址: $ipv4"
    echo "检测到 IPv6 地址: $ipv6"
    # 生成随机 PSK
    local psk=$(generate_psk)
    echo "已生成随机 PSK: $psk"
    # 生成证书
    echo "正在生成自签名证书..."
    generate_cert "$domain" "$ipv4" "$ipv6" || return 1
    # 获取二进制
    echo "正在获取服务端程序..."
    local bin_path=$(obtain_server_binary) || { echo "获取二进制失败"; return 1; }
    # 创建 systemd 服务
    echo "正在创建 systemd 服务..."
    create_service "$bin_path" "$port" "$psk"
    echo "服务安装完成！"
    echo "监听端口: $port"
    echo "PSK 密钥: $psk"
    echo "证书保存路径: $INSTALL_DIR/server.crt"
    echo "私钥保存路径: $INSTALL_DIR/server.key"
}

# 卸载流程
function uninstall_server() {
    echo "=== 卸载 anytls_aead_server ==="
    if [ -f "$SERVICE_FILE" ]; then
        sudo systemctl disable --now $(basename "$SERVICE_FILE" .service) || true
        sudo rm -f "$SERVICE_FILE"
        sudo systemctl daemon-reload
    fi
    if [ -d "$INSTALL_DIR" ]; then
        sudo rm -rf "$INSTALL_DIR"
    fi
    echo "卸载完成。"
}

# 主菜单
function main_menu() {
    while true; do
        echo "=========================="
        echo "  AnyTLS AEAD 服务管理脚本"
        echo "=========================="
        echo "1) 安装服务端"
        echo "2) 卸载服务端"
        echo "3) 退出"
        read -p "请选择操作 [1-3]: " choice
        case $choice in
            1)
                install_server
                ;;
            2)
                uninstall_server
                ;;
            3)
                exit 0
                ;;
            *)
                echo "无效的选项，请重新选择。"
                ;;
        esac
    done
}

# 脚本入口
main_menu