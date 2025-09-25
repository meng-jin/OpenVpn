#!/bin/bash

#================================================================
# WireGuard 一键安装脚本
#
#   - 支持 Debian, Ubuntu, CentOS/RHEL 系统
#   - 自动配置服务端 (NAT 转发) 和 客户端 (全局流量)
#   - 提供清晰的操作指引
#
#================================================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# --- 脚本变量 ---
WG_CONF="/etc/wireguard/wg0.conf"

# --- 函数定义 ---

# 检查是否为 root 用户
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 请以 root 用户身份运行此脚本。${NC}"
        exit 1
    fi
}

# 检查并安装 WireGuard
install_wireguard() {
    if ! command -v wg &> /dev/null; then
        echo -e "${YELLOW}正在检测并安装 WireGuard...${NC}"
        if [ -f /etc/debian_version ]; then
            apt-get update
            apt-get install -y wireguard
        elif [ -f /etc/redhat-release ]; then
            yum install -y epel-release
            yum install -y wireguard-tools
        else
            echo -e "${RED}错误: 无法识别的操作系统。仅支持 Debian/Ubuntu/CentOS。${NC}"
            exit 1
        fi
        echo -e "${GREEN}WireGuard 安装完成。${NC}"
    else
        echo -e "${GREEN}WireGuard 已安装。${NC}"
    fi
}

# 配置服务端 (VPS-B)
setup_server() {
    echo "--- 开始配置 WireGuard 服务端 (VPS-B) ---"
    
    # 检查配置文件是否存在
    if [ -f "$WG_CONF" ]; then
        read -p "配置文件 wg0.conf 已存在。要覆盖吗? (y/n): " overwrite
        if [ "$overwrite" != "y" ]; then
            echo "操作已取消。"
            exit 0
        fi
    fi

    # 生成密钥
    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard
    wg genkey | tee /etc/wireguard/server_privatekey | wg pubkey > /etc/wireguard/server_publickey
    
    SERVER_PRIV_KEY=$(cat /etc/wireguard/server_privatekey)
    SERVER_PUB_KEY=$(cat /etc/wireguard/server_publickey)

    # 获取公网 IP 和 网卡
    PUBLIC_IP=$(curl -s ip.sb)
    INTERFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

    read -p "请输入 WireGuard 监听端口 (默认 51820): " LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-51820}

    # 创建服务端配置
    cat > "$WG_CONF" <<EOF
[Interface]
Address = 10.0.0.1/24
SaveConfig = true
ListenPort = $LISTEN_PORT
PrivateKey = $SERVER_PRIV_KEY
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $INTERFACE -j MASQUERADE

[Peer]
# 客户端 (VPS-A) 配置
# 请在客户端配置完成后，将客户端的公钥填入下方
PublicKey = 
AllowedIPs = 10.0.0.2/32
EOF

    # 开启 IP 转发
    sed -i '/net.ipv4.ip_forward=1/s/^#//' /etc/sysctl.conf
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    sysctl -p

    # 启动并设置开机自启
    wg-quick up wg0
    systemctl enable wg-quick@wg0

    echo -e "=============================================================="
    echo -e "${GREEN}服务端配置完成!${NC}"
    echo -e "请在防火墙中开放 UDP 端口: ${YELLOW}$LISTEN_PORT${NC}"
    echo -e "--------------------------------------------------------------"
    echo -e "请记录以下信息，在配置客户端时需要使用:"
    echo -e "  - ${YELLOW}服务端公钥: $SERVER_PUB_KEY${NC}"
    echo -e "  - ${YELLOW}服务端Endpoint: $PUBLIC_IP:$LISTEN_PORT${NC}"
    echo -e "--------------------------------------------------------------"
    echo -e "下一步: 请在客户端配置完成后，将其公钥手动添加到 ${YELLOW}$WG_CONF${NC} 文件的 [Peer] 部分。"
    echo -e "=============================================================="
}

# 配置客户端 (VPS-A)
setup_client() {
    echo "--- 开始配置 WireGuard 客户端 (VPS-A) ---"
    
    if [ -f "$WG_CONF" ]; then
        read -p "配置文件 wg0.conf 已存在。要覆盖吗? (y/n): " overwrite
        if [ "$overwrite" != "y" ]; then
            echo "操作已取消。"
            exit 0
        fi
    fi

    # 生成密钥
    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard
    wg genkey | tee /etc/wireguard/client_privatekey | wg pubkey > /etc/wireguard/client_publickey
    
    CLIENT_PRIV_KEY=$(cat /etc/wireguard/client_privatekey)
    CLIENT_PUB_KEY=$(cat /etc/wireguard/client_publickey)

    # 获取用户输入
    read -p "请输入服务端(VPS-B)的公钥: " SERVER_PUB_KEY_INPUT
    read -p "请输入服务端(VPS-B)的Endpoint (格式 IP:端口): " SERVER_ENDPOINT_INPUT

    # 创建客户端配置
    cat > "$WG_CONF" <<EOF
[Interface]
Address = 10.0.0.2/24
PrivateKey = $CLIENT_PRIV_KEY
DNS = 8.8.8.8

[Peer]
PublicKey = $SERVER_PUB_KEY_INPUT
Endpoint = $SERVER_ENDPOINT_INPUT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    # 启动并设置开机自启
    wg-quick up wg0
    systemctl enable wg-quick@wg0

    echo -e "=============================================================="
    echo -e "${GREEN}客户端配置完成!${NC}"
    echo -e "--------------------------------------------------------------"
    echo -e "请将以下 ${YELLOW}客户端公钥${NC} 添加到服务端的配置文件中:"
    echo -e "${YELLOW}$CLIENT_PUB_KEY${NC}"
    echo -e "--------------------------------------------------------------"
    echo -e "添加后，请在服务端执行 ${YELLOW}sudo wg-quick down wg0 && sudo wg-quick up wg0${NC} 来使配置生效。"
    echo -e "=============================================================="
}

# --- 主逻辑 ---
main() {
    check_root
    install_wireguard

    echo "请选择要执行的操作:"
    echo "  1) 设置为 服务端 (VPS-B, 流量出口)"
    echo "  2) 设置为 客户端 (VPS-A, 流量来源)"
    read -p "请输入选项 [1-2]: " choice

    case $choice in
        1) setup_server ;;
        2) setup_client ;;
        *) echo -e "${RED}无效选项。${NC}"; exit 1 ;;
    esac
}

main
