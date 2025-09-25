#!/bin/bash
set -e

SERVER_IP=""
SERVER_NET_IF=""
CLIENT_NAME="client1"

# 参数解析
while [[ $# -gt 0 ]]; do
  case $1 in
    --server-ip)
      SERVER_IP="$2"
      shift 2
      ;;
    --net-if)
      SERVER_NET_IF="$2"
      shift 2
      ;;
    --client-name)
      CLIENT_NAME="$2"
      shift 2
      ;;
    *)
      echo "未知参数: $1"
      echo "用法: $0 --server-ip <公网IP> --net-if <网卡名> [--client-name <客户端名字>]"
      exit 1
      ;;
  esac
done

if [[ -z "$SERVER_IP" || -z "$SERVER_NET_IF" ]]; then
  echo "错误: 必须指定 --server-ip 和 --net-if"
  exit 1
fi

EASYRSA_DIR="/etc/openvpn/easy-rsa"

apt update
apt install -y openvpn easy-rsa iptables-persistent curl

# 初始化 easy-rsa
make-cadir $EASYRSA_DIR
cd $EASYRSA_DIR
./easyrsa init-pki
echo -ne '\n' | ./easyrsa build-ca nopass
./easyrsa gen-dh
openvpn --genkey --secret $EASYRSA_DIR/ta.key
./easyrsa build-server-full server nopass
./easyrsa build-client-full $CLIENT_NAME nopass

# 拷贝服务端文件
cp pki/ca.crt pki/dh.pem pki/private/server.key pki/issued/server.crt ta.key /etc/openvpn/

# 写 server.conf
cat > /etc/openvpn/server.conf <<EOF
port 1194
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
tls-auth ta.key 0
topology subnet
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
keepalive 10 120
cipher AES-256-CBC
user nobody
group nogroup
persist-key
persist-tun
status /var/log/openvpn-status.log
log /var/log/openvpn.log
verb 3
EOF

# 开启转发
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl -p

# NAT
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $SERVER_NET_IF -j MASQUERADE
netfilter-persistent save

# 启动 OpenVPN
systemctl enable openvpn@server
systemctl restart openvpn@server

# 生成客户端配置
CLIENT_DIR="/root/${CLIENT_NAME}"
mkdir -p $CLIENT_DIR

CA=$(cat pki/ca.crt)
CERT=$(cat pki/issued/${CLIENT_NAME}.crt)
KEY=$(cat pki/private/${CLIENT_NAME}.key)
TA=$(cat ta.key)

cat > $CLIENT_DIR/${CLIENT_NAME}.ovpn <<EOF
client
dev tun
proto udp
remote $SERVER_IP 1194
resolv-retry infinite
nobind
persist-key
persist-tun
cipher AES-256-CBC
remote-cert-tls server
auth-nocache
verb 3

<ca>
$CA
</ca>

<cert>
$CERT
</cert>

<key>
$KEY
</key>

<tls-auth>
$TA
</tls-auth>
key-direction 1
EOF

echo "=================================================="
echo "OpenVPN 服务端已配置完成！"
echo "客户端配置文件位置: $CLIENT_DIR/${CLIENT_NAME}.ovpn"
echo "复制这个文件到客户端服务器 A，然后执行："
echo "   apt install -y openvpn"
echo "   openvpn --config ${CLIENT_NAME}.ovpn"
echo "即可。"
echo "=================================================="
