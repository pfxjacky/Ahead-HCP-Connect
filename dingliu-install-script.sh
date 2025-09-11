#!/bin/bash

# 顶流服务一键部署脚本
# Enhanced DL HEAD Server Deployment Script

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 配置文件路径
CONFIG_DIR="/etc/dingliu"
CONFIG_FILE="$CONFIG_DIR/config.conf"
SERVICE_NAME="dingliu-server"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
BINARY_PATH="/usr/local/bin/dingliu_head_server"
LOG_FILE="/var/log/dingliu-server.log"
PID_FILE="/var/run/dingliu-server.pid"

# 默认配置
DEFAULT_PORT="8443"
DEFAULT_DOMAIN=""
DEFAULT_PSK=""
DEFAULT_MAX_CONNECTIONS="10000"
DEFAULT_TIMEOUT="60"

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 此脚本必须以root权限运行${NC}"
        exit 1
    fi
}

# 打印标题
print_header() {
    clear
    echo -e "${CYAN}================================================${NC}"
    echo -e "${CYAN}      顶流服务 (HEAD DINGLIU) 一键部署脚本      ${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo
}

# 检查系统架构
check_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64)
            echo -e "${GREEN}✓ 系统架构: x86_64${NC}"
            ;;
        aarch64|arm64)
            echo -e "${GREEN}✓ 系统架构: ARM64${NC}"
            ;;
        *)
            echo -e "${RED}✗ 不支持的系统架构: $ARCH${NC}"
            exit 1
            ;;
    esac
}

# 检查libssl1.1依赖
check_libssl() {
    echo -e "${YELLOW}检查 libssl1.1 依赖...${NC}"
    
    if ldconfig -p | grep -q "libssl.so.1.1"; then
        echo -e "${GREEN}✓ libssl1.1 已安装${NC}"
    else
        echo -e "${YELLOW}! libssl1.1 未安装，正在安装...${NC}"
        
        # 检测系统类型
        if [ -f /etc/debian_version ]; then
            # Debian/Ubuntu
            apt-get update >/dev/null 2>&1
            apt-get install -y libssl1.1 >/dev/null 2>&1 || {
                # 如果默认源没有，尝试添加旧版本源
                echo -e "${YELLOW}尝试从备用源安装...${NC}"
                wget -q http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2_amd64.deb
                dpkg -i libssl1.1_1.1.1f-1ubuntu2_amd64.deb >/dev/null 2>&1
                rm -f libssl1.1_1.1.1f-1ubuntu2_amd64.deb
            }
        elif [ -f /etc/redhat-release ]; then
            # RHEL/CentOS/Fedora
            yum install -y openssl11-libs >/dev/null 2>&1 || \
            dnf install -y openssl11-libs >/dev/null 2>&1
        else
            echo -e "${RED}✗ 无法自动安装 libssl1.1，请手动安装${NC}"
            return 1
        fi
        
        # 再次检查
        if ldconfig -p | grep -q "libssl.so.1.1"; then
            echo -e "${GREEN}✓ libssl1.1 安装成功${NC}"
        else
            echo -e "${RED}✗ libssl1.1 安装失败，请手动安装${NC}"
            return 1
        fi
    fi
}

# 检测IP地址
detect_ip() {
    echo -e "${YELLOW}检测服务器IP地址...${NC}"
    
    # 检测IPv4
    IPV4=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    
    # 检测IPv6
    IPV6=$(ip -6 addr show | grep -oP '(?<=inet6\s)[0-9a-fA-F:]+' | grep -v '::1' | grep -v '^fe80' | head -n 1)
    
    # 显示检测结果
    if [ -n "$IPV4" ] && [ -n "$IPV6" ]; then
        echo -e "${GREEN}✓ 检测到双栈环境${NC}"
        echo -e "  IPv4: ${CYAN}$IPV4${NC}"
        echo -e "  IPv6: ${CYAN}$IPV6${NC}"
        LISTEN_ADDR="[::]"
    elif [ -n "$IPV4" ]; then
        echo -e "${GREEN}✓ 仅检测到IPv4${NC}"
        echo -e "  IPv4: ${CYAN}$IPV4${NC}"
        LISTEN_ADDR="0.0.0.0"
    elif [ -n "$IPV6" ]; then
        echo -e "${GREEN}✓ 仅检测到IPv6${NC}"
        echo -e "  IPv6: ${CYAN}$IPV6${NC}"
        LISTEN_ADDR="[::]"
    else
        echo -e "${RED}✗ 未检测到有效的IP地址${NC}"
        LISTEN_ADDR="0.0.0.0"
    fi
}

# 生成随机PSK
generate_psk() {
    openssl rand -base64 32
}

# 下载服务端二进制文件
download_binary() {
    echo -e "${YELLOW}正在下载服务端程序...${NC}"
    
    # 创建临时目录
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    
    # 下载文件
    wget -q --show-progress "https://raw.githubusercontent.com/pfxjacky/Ahead-HCP-Connect/refs/heads/main/dingliu_head_server" -O dingliu_head_server
    
    if [ $? -eq 0 ]; then
        chmod +x dingliu_head_server
        mv dingliu_head_server "$BINARY_PATH"
        echo -e "${GREEN}✓ 服务端程序下载成功${NC}"
    else
        echo -e "${RED}✗ 服务端程序下载失败${NC}"
        rm -rf "$TMP_DIR"
        return 1
    fi
    
    # 清理临时目录
    cd - >/dev/null
    rm -rf "$TMP_DIR"
}

# 读取配置
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
}

# 保存配置
save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << EOF
# 顶流服务配置文件
DOMAIN="$DOMAIN"
PORT="$PORT"
PSK_B64="$PSK_B64"
LISTEN_ADDR="$LISTEN_ADDR"
MAX_CONNECTIONS="$MAX_CONNECTIONS"
TIMEOUT="$TIMEOUT"
TOKENS="$TOKENS"
EOF
    chmod 600 "$CONFIG_FILE"
    echo -e "${GREEN}✓ 配置已保存${NC}"
}

# 配置域名
configure_domain() {
    print_header
    echo -e "${CYAN}配置自定义域名${NC}"
    echo -e "${YELLOW}----------------------------------------${NC}"
    
    load_config
    
    echo -e "当前域名: ${CYAN}${DOMAIN:-未设置}${NC}"
    echo
    read -p "请输入新的域名 (留空保持不变): " new_domain
    
    if [ -n "$new_domain" ]; then
        DOMAIN="$new_domain"
        save_config
        echo -e "${GREEN}✓ 域名已更新为: $DOMAIN${NC}"
    else
        echo -e "${YELLOW}! 域名未修改${NC}"
    fi
    
    read -p "按回车键返回主菜单..."
}

# 配置端口
configure_port() {
    print_header
    echo -e "${CYAN}配置访问端口${NC}"
    echo -e "${YELLOW}----------------------------------------${NC}"
    
    load_config
    
    echo -e "当前端口: ${CYAN}${PORT:-$DEFAULT_PORT}${NC}"
    echo
    read -p "请输入新的端口号 (1-65535，留空保持不变): " new_port
    
    if [ -n "$new_port" ]; then
        if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
            PORT="$new_port"
            save_config
            echo -e "${GREEN}✓ 端口已更新为: $PORT${NC}"
        else
            echo -e "${RED}✗ 无效的端口号${NC}"
        fi
    else
        echo -e "${YELLOW}! 端口未修改${NC}"
    fi
    
    read -p "按回车键返回主菜单..."
}

# 完整安装
full_install() {
    print_header
    echo -e "${CYAN}开始完整安装${NC}"
    echo -e "${YELLOW}----------------------------------------${NC}"
    
    # 1. 检查架构
    check_arch
    
    # 2. 检查依赖
    check_libssl
    
    # 3. 检测IP
    detect_ip
    
    # 4. 下载二进制文件
    if [ ! -f "$BINARY_PATH" ]; then
        download_binary
    else
        echo -e "${YELLOW}! 服务端程序已存在，跳过下载${NC}"
    fi
    
    # 5. 初始化配置
    echo
    echo -e "${CYAN}初始化配置...${NC}"
    
    # 域名配置
    read -p "请输入域名 (用于生成自签名证书): " DOMAIN
    while [ -z "$DOMAIN" ]; do
        echo -e "${RED}域名不能为空！${NC}"
        read -p "请输入域名: " DOMAIN
    done
    
    # 端口配置
    read -p "请输入服务端口 (默认: $DEFAULT_PORT): " PORT
    PORT=${PORT:-$DEFAULT_PORT}
    
    # 生成PSK
    PSK_B64=$(generate_psk)
    echo -e "${GREEN}✓ 已生成PSK密钥${NC}"
    
    # 设置其他默认值
    MAX_CONNECTIONS=$DEFAULT_MAX_CONNECTIONS
    TIMEOUT=$DEFAULT_TIMEOUT
    TOKENS=""
    
    # 保存配置
    save_config
    
    # 6. 创建systemd服务
    create_service
    
    echo
    echo -e "${GREEN}✓ 安装完成！${NC}"
    echo -e "${YELLOW}请使用菜单中的'启动顶流服务'来启动服务${NC}"
    
    read -p "按回车键返回主菜单..."
}

# 创建systemd服务
create_service() {
    echo -e "${YELLOW}创建系统服务...${NC}"
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=DingLiu ANYTLS AEAD Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/bin
ExecStart=$BINARY_PATH \\
    --listen ${LISTEN_ADDR}:${PORT} \\
    --psk-b64 ${PSK_B64} \\
    --domain ${DOMAIN} \\
    --max-connections ${MAX_CONNECTIONS} \\
    --timeout ${TIMEOUT} \\
    --verbose
Restart=always
RestartSec=10
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    echo -e "${GREEN}✓ 系统服务创建成功${NC}"
}

# 显示节点配置
show_config() {
    print_header
    echo -e "${CYAN}节点配置信息${NC}"
    echo -e "${YELLOW}----------------------------------------${NC}"
    
    load_config
    
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${GREEN}基本配置:${NC}"
        echo -e "  域名: ${CYAN}${DOMAIN:-未设置}${NC}"
        echo -e "  端口: ${CYAN}${PORT:-$DEFAULT_PORT}${NC}"
        echo -e "  监听地址: ${CYAN}${LISTEN_ADDR}:${PORT:-$DEFAULT_PORT}${NC}"
        echo -e "  最大连接数: ${CYAN}${MAX_CONNECTIONS:-$DEFAULT_MAX_CONNECTIONS}${NC}"
        echo -e "  超时时间: ${CYAN}${TIMEOUT:-$DEFAULT_TIMEOUT}秒${NC}"
        echo
        echo -e "${GREEN}安全配置:${NC}"
        echo -e "  PSK密钥: ${CYAN}${PSK_B64}${NC}"
        if [ -n "$TOKENS" ]; then
            echo -e "  访问令牌: ${CYAN}${TOKENS}${NC}"
        else
            echo -e "  访问令牌: ${YELLOW}未设置${NC}"
        fi
        echo
        echo -e "${GREEN}网络信息:${NC}"
        if [ -n "$IPV4" ]; then
            echo -e "  IPv4: ${CYAN}$IPV4${NC}"
        fi
        if [ -n "$IPV6" ]; then
            echo -e "  IPv6: ${CYAN}$IPV6${NC}"
        fi
        echo
        echo -e "${GREEN}服务状态:${NC}"
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            echo -e "  状态: ${GREEN}运行中${NC}"
            echo -e "  PID: ${CYAN}$(systemctl show -p MainPID --value $SERVICE_NAME)${NC}"
        else
            echo -e "  状态: ${RED}已停止${NC}"
        fi
    else
        echo -e "${RED}配置文件不存在，请先执行完整安装${NC}"
    fi
    
    read -p "按回车键返回主菜单..."
}

# 启动服务
start_service() {
    print_header
    echo -e "${CYAN}启动顶流服务${NC}"
    echo -e "${YELLOW}----------------------------------------${NC}"
    
    load_config
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}✗ 配置文件不存在，请先执行完整安装${NC}"
        read -p "按回车键返回主菜单..."
        return
    fi
    
    if [ ! -f "$BINARY_PATH" ]; then
        echo -e "${RED}✗ 服务程序不存在，请先执行完整安装${NC}"
        read -p "按回车键返回主菜单..."
        return
    fi
    
    # 更新服务文件
    create_service
    
    echo -e "${YELLOW}正在启动服务...${NC}"
    systemctl start "$SERVICE_NAME"
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    
    sleep 2
    
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}✓ 服务启动成功${NC}"
        echo
        echo -e "${GREEN}服务信息:${NC}"
        echo -e "  访问地址: ${CYAN}${DOMAIN}:${PORT}${NC}"
        echo -e "  PSK密钥: ${CYAN}${PSK_B64}${NC}"
        echo
        echo -e "${YELLOW}查看日志: tail -f $LOG_FILE${NC}"
    else
        echo -e "${RED}✗ 服务启动失败${NC}"
        echo -e "${YELLOW}查看错误信息:${NC}"
        journalctl -u "$SERVICE_NAME" -n 10 --no-pager
    fi
    
    read -p "按回车键返回主菜单..."
}

# 停止服务
stop_service() {
    print_header
    echo -e "${CYAN}停止顶流服务${NC}"
    echo -e "${YELLOW}----------------------------------------${NC}"
    
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${YELLOW}正在停止服务...${NC}"
        systemctl stop "$SERVICE_NAME"
        echo -e "${GREEN}✓ 服务已停止${NC}"
    else
        echo -e "${YELLOW}! 服务未在运行${NC}"
    fi
    
    read -p "按回车键返回主菜单..."
}

# 重启服务
restart_service() {
    print_header
    echo -e "${CYAN}重启顶流服务${NC}"
    echo -e "${YELLOW}----------------------------------------${NC}"
    
    load_config
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}✗ 配置文件不存在，请先执行完整安装${NC}"
        read -p "按回车键返回主菜单..."
        return
    fi
    
    # 更新服务文件
    create_service
    
    echo -e "${YELLOW}正在重启服务...${NC}"
    systemctl restart "$SERVICE_NAME"
    
    sleep 2
    
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}✓ 服务重启成功${NC}"
    else
        echo -e "${RED}✗ 服务重启失败${NC}"
        echo -e "${YELLOW}查看错误信息:${NC}"
        journalctl -u "$SERVICE_NAME" -n 10 --no-pager
    fi
    
    read -p "按回车键返回主菜单..."
}

# 查看日志
view_logs() {
    print_header
    echo -e "${CYAN}查看服务日志${NC}"
    echo -e "${YELLOW}----------------------------------------${NC}"
    
    if [ -f "$LOG_FILE" ]; then
        echo -e "${GREEN}最近50行日志:${NC}"
        tail -n 50 "$LOG_FILE"
    else
        echo -e "${YELLOW}日志文件不存在${NC}"
    fi
    
    echo
    echo -e "${YELLOW}提示: 使用 'tail -f $LOG_FILE' 实时查看日志${NC}"
    
    read -p "按回车键返回主菜单..."
}

# 完整卸载
full_uninstall() {
    print_header
    echo -e "${CYAN}完整卸载${NC}"
    echo -e "${YELLOW}----------------------------------------${NC}"
    
    echo -e "${RED}警告: 此操作将删除所有相关文件和配置！${NC}"
    read -p "确定要继续吗？(y/N): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo
        echo -e "${YELLOW}正在卸载...${NC}"
        
        # 停止并禁用服务
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            systemctl stop "$SERVICE_NAME"
        fi
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
        
        # 删除文件
        rm -f "$SERVICE_FILE"
        rm -f "$BINARY_PATH"
        rm -rf "$CONFIG_DIR"
        rm -f "$LOG_FILE"
        rm -f "$PID_FILE"
        
        # 重载systemd
        systemctl daemon-reload
        
        echo -e "${GREEN}✓ 卸载完成${NC}"
    else
        echo -e "${YELLOW}! 卸载已取消${NC}"
    fi
    
    read -p "按回车键返回主菜单..."
}

# 高级配置
advanced_config() {
    print_header
    echo -e "${CYAN}高级配置${NC}"
    echo -e "${YELLOW}----------------------------------------${NC}"
    
    load_config
    
    echo "1) 配置访问令牌"
    echo "2) 配置最大连接数"
    echo "3) 配置超时时间"
    echo "4) 重新生成PSK密钥"
    echo "0) 返回主菜单"
    echo
    read -p "请选择操作 [0-4]: " choice
    
    case $choice in
        1)
            echo
            echo -e "当前令牌: ${CYAN}${TOKENS:-未设置}${NC}"
            read -p "请输入访问令牌 (多个用逗号分隔，留空清除): " new_tokens
            TOKENS="$new_tokens"
            save_config
            echo -e "${GREEN}✓ 访问令牌已更新${NC}"
            ;;
        2)
            echo
            echo -e "当前最大连接数: ${CYAN}${MAX_CONNECTIONS:-$DEFAULT_MAX_CONNECTIONS}${NC}"
            read -p "请输入新的最大连接数 (1-100000): " new_max
            if [[ "$new_max" =~ ^[0-9]+$ ]] && [ "$new_max" -ge 1 ] && [ "$new_max" -le 100000 ]; then
                MAX_CONNECTIONS="$new_max"
                save_config
                echo -e "${GREEN}✓ 最大连接数已更新${NC}"
            else
                echo -e "${RED}✗ 无效的数值${NC}"
            fi
            ;;
        3)
            echo
            echo -e "当前超时时间: ${CYAN}${TIMEOUT:-$DEFAULT_TIMEOUT}秒${NC}"
            read -p "请输入新的超时时间 (秒): " new_timeout
            if [[ "$new_timeout" =~ ^[0-9]+$ ]] && [ "$new_timeout" -ge 1 ]; then
                TIMEOUT="$new_timeout"
                save_config
                echo -e "${GREEN}✓ 超时时间已更新${NC}"
            else
                echo -e "${RED}✗ 无效的数值${NC}"
            fi
            ;;
        4)
            echo
            echo -e "${YELLOW}警告: 重新生成PSK密钥后，所有客户端需要更新配置${NC}"
            read -p "确定要继续吗？(y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                PSK_B64=$(generate_psk)
                save_config
                echo -e "${GREEN}✓ 新的PSK密钥: ${CYAN}$PSK_B64${NC}"
            fi
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}无效的选择${NC}"
            ;;
    esac
    
    read -p "按回车键继续..."
    advanced_config
}

# 主菜单
main_menu() {
    while true; do
        print_header
        detect_ip
        echo
        echo -e "${CYAN}主菜单${NC}"
        echo -e "${YELLOW}----------------------------------------${NC}"
        echo "1) 完整安装"
        echo "2) 配置自定义域名"
        echo "3) 配置访问端口"
        echo "4) 显示节点配置"
        echo "5) 启动顶流服务"
        echo "6) 停止顶流服务"
        echo "7) 重启顶流服务"
        echo "8) 查看服务日志"
        echo "9) 高级配置"
        echo "10) 完整卸载"
        echo "0) 退出"
        echo -e "${YELLOW}----------------------------------------${NC}"
        
        # 显示服务状态
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            echo -e "服务状态: ${GREEN}● 运行中${NC}"
        else
            echo -e "服务状态: ${RED}● 已停止${NC}"
        fi
        echo
        
        read -p "请选择操作 [0-10]: " choice
        
        case $choice in
            1) full_install ;;
            2) configure_domain ;;
            3) configure_port ;;
            4) show_config ;;
            5) start_service ;;
            6) stop_service ;;
            7) restart_service ;;
            8) view_logs ;;
            9) advanced_config ;;
            10) full_uninstall ;;
            0)
                echo
                echo -e "${GREEN}感谢使用！再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选择，请重试${NC}"
                sleep 2
                ;;
        esac
    done
}

# 主程序入口
main() {
    check_root
    main_menu
}

# 运行主程序
main
