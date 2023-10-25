#!/bin/bash
# by https://github.com/spiritLHLS/lxd
# 2023.10.25

# ./build_ipv6_network.sh LXC容器名称

set -e

# 字体颜色
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "utf8|UTF-8")
if [[ -z "$utf8_locale" ]]; then
    _yellow "No UTF-8 locale found"
else
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
    _green "Locale set to $utf8_locale"
fi

# 检查所需模块是否存在，如果不存在则安装
install_required_modules() {
    modules=("sudo" "lshw" "jq" "net-tools" "netfilter-persistent" "ipcalc" "sipcalc")
    for module in "${modules[@]}"; do
        if command -v $module >/dev/null 2>&1; then
            _green "$module is installed!"
            _green "$module 已经安装！"
        else
            apt-get install -y $module
            _green "$module has been successfully installed!"
            _green "$module 已成功安装！"
        fi
    done
}
install_required_modules

is_private_ipv6() {
    local address=$1
    # 输入不含:符号
    if [[ $ip_address != *":"* ]]; then
        return 0
    fi
    # 输入为空
    if [[ -z $ip_address ]]; then
        return 0
    fi
    # 检查IPv6地址是否以fe80开头（链接本地地址）
    if [[ $address == fe80:* ]]; then
        return 0
    fi
    # 检查IPv6地址是否以fc00或fd00开头（唯一本地地址）
    if [[ $address == fc00:* || $address == fd00:* ]]; then
        return 0
    fi
    # 检查IPv6地址是否以2001:db8开头（文档前缀）
    if [[ $address == 2001:db8* ]]; then
        return 0
    fi
    # 检查IPv6地址是否以::1开头（环回地址）
    if [[ $address == ::1 ]]; then
        return 0
    fi
    # 检查IPv6地址是否以::ffff:开头（IPv4映射地址）
    if [[ $address == ::ffff:* ]]; then
        return 0
    fi
    # 检查IPv6地址是否以2002:开头（6to4隧道地址）
    if [[ $address == 2002:* ]]; then
        return 0
    fi
    # 检查IPv6地址是否以2001:开头（Teredo隧道地址）
    if [[ $address == 2001:* ]]; then
        return 0
    fi
    # 其他情况为公网地址
    return 1
}

check_ipv6() {
    IPV6=$(ip -6 addr show | grep global | awk '{print $2}' | cut -d '/' -f1 | head -n 1)
    if is_private_ipv6 "$IPV6"; then # 由于是内网IPV6地址，需要通过API获取外网地址
        IPV6=""
        API_NET=("ipv6.ip.sb" "https://ipget.net" "ipv6.ping0.cc" "https://api.my-ip.io/ip" "https://ipv6.icanhazip.com")
        for p in "${API_NET[@]}"; do
            response=$(curl -sLk6m8 "$p" | tr -d '[:space:]')
            if [ $? -eq 0 ] && ! (echo "$response" | grep -q "error"); then
                IPV6="$response"
                break
            fi
            sleep 1
        done
    fi
}

# 查询网卡
interface=$(lshw -C network | awk '/logical name:/{print $3}' | head -1)
_yellow "NIC $interface"
_yellow "网卡 $interface"

# 获取指定LXC容器的内网IPV6
CONTAINER_NAME="$1"
CONTAINER_IPV6=$(lxc list $CONTAINER_NAME --format=json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet6") | select(.scope=="global") | .address')
if [ -z "$CONTAINER_IPV6" ]; then
    _red "Container has no intranet IPV6 address, no auto-mapping"
    _red "容器无内网IPV6地址，不进行自动映射"
    exit 1
fi
_blue "The container with the name $CONTAINER_NAME has an intranet IPV6 address of $CONTAINER_IPV6"
_blue "$CONTAINER_NAME 容器的内网IPV6地址为 $CONTAINER_IPV6"

# 获取宿主机子网前缀
SUBNET_PREFIX=$(ip -6 addr show | grep -E 'inet6.*global' | awk '{print $2}' | awk -F'/' '{print $1}' | head -n 1 | cut -d ':' -f1-5):

# 获取宿主机的IPV6地址
ipv6_address=$(ip addr show | awk '/inet6.*scope global/ { print $2 }' | head -n 1)
if [[ $ipv6_address == */* ]]; then
    ipv6_length=$(echo "$ipv6_address" | awk -F '/' '{ print $2 }')
    _green "subnet size: $ipv6_length"
    _green "子网大小: $ipv6_length"
else
    _green "Subnet size for IPV6 not queried"
    _green "查询不到IPV6的子网大小"
    exit 1
fi

# 检查是否存在 IPV6
if [ -z "$SUBNET_PREFIX" ]; then
    _red "No IPV6 subnet, no automatic mapping"
    _red "无 IPV6 子网，不进行自动映射"
    exit 1
fi
_blue "The IPV6 subnet prefix is $SUBNET_PREFIX"
_blue "宿主机的IPV6子网前缀为 $SUBNET_PREFIX"

# 用 iptables 映射的IPV6网络

# # 寻找未使用的子网内的一个IPV6地址
# for i in $(seq 1 65535); do
#     IPV6="${SUBNET_PREFIX}$i"
#     if [[ $IPV6 == $CONTAINER_IPV6 ]]; then
#         continue
#     fi
#     if ip -6 addr show dev "$interface" | grep -q $IPV6; then
#         continue
#     fi
#     if ! ping6 -c1 -w1 -q $IPV6 &>/dev/null; then
#         if ! ip6tables -t nat -C PREROUTING -d $IPV6 -j DNAT --to-destination $CONTAINER_IPV6 &>/dev/null; then
#             _green "$IPV6"
#             break
#         fi
#     fi
#     _yellow "$IPV6"
# done

# # 检查是否找到未使用的 IPV6 地址
# if [ -z "$IPV6" ]; then
#     _red "No IPV6 address available, no auto mapping"
#     _red "无可用 IPV6 地址，不进行自动映射"
#     exit 1
# fi

# # 映射 IPV6 地址到容器的私有 IPV6 地址
# ip addr add "$IPV6"/"$ipv6_length" dev "$interface"
# ip6tables -t nat -A PREROUTING -d $IPV6 -j DNAT --to-destination $CONTAINER_IPV6
# # 创建守护进程，避免重启服务器后绑定的IPV6地址丢失
# if [ ! -f /usr/local/bin/add-ipv6.sh ]; then
#     wget ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/lxd/main/scripts/add-ipv6.sh -O /usr/local/bin/add-ipv6.sh
#     chmod +x /usr/local/bin/add-ipv6.sh
# else
#     echo "Script already exists. Skipping installation."
# fi
# if [ ! -f /etc/systemd/system/add-ipv6.service ]; then
#     wget ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/lxd/main/scripts/add-ipv6.service -O /etc/systemd/system/add-ipv6.service
#     chmod +x /etc/systemd/system/add-ipv6.service
#     systemctl daemon-reload
#     systemctl enable add-ipv6.service
#     systemctl start add-ipv6.service
# else
#     echo "Service already exists. Skipping installation."
# fi

# if [ ! -f "/etc/iptables/rules.v6" ]; then
#     touch /etc/iptables/rules.v6
# fi
# ip6tables-save >/etc/iptables/rules.v6
# netfilter-persistent save
# netfilter-persistent reload
# service netfilter-persistent restart

check_ipv6
ipv6_name=${IPV6}
# ifconfig ${ipv6_network_name} | awk '/inet6/{print $2}'
if grep -q "auto he-ipv6" /etc/network/interfaces; then
    ipv6_network_name="he-ipv6"
    ip_network_gam=$(ip -6 addr show ${ipv6_network_name} | grep -E "${ipv6_name}/48|${ipv6_name}/64|${ipv6_name}/80|${ipv6_name}/96|${ipv6_name}/112" | grep global | awk '{print $2}' 2> /dev/null)
else
    ipv6_network_name=$(ls /sys/class/net/ | grep -v "`ls /sys/devices/virtual/net/`")
    ip_network_gam=$(ip -6 addr show ${ipv6_network_name} | grep -E "${ipv6_name}/48|${ipv6_name}/64|${ipv6_name}/80|${ipv6_name}/96|${ipv6_name}/112" | grep global | awk '{print $2}' 2> /dev/null)
fi
echo "$ip_network_gam"
if [ -n "$ip_network_gam" ];
    then
    if ! grep "net.ipv6.conf.${ipv6_network_name}.proxy_ndp = 1" /etc/sysctl.conf  >/dev/null
    then
        echo "net.ipv6.conf.${ipv6_network_name}.proxy_ndp = 1">>/etc/sysctl.conf
        sysctl -p
    fi
    if ! grep "net.ipv6.conf.all.forwarding = 1" /etc/sysctl.conf  >/dev/null
    then
        echo "net.ipv6.conf.all.forwarding = 1">>/etc/sysctl.conf
        sysctl -p
    fi
    if ! grep "net.ipv6.conf.all.proxy_ndp=1" /etc/sysctl.conf  >/dev/null
    then
        echo "net.ipv6.conf.all.proxy_ndp=1">>/etc/sysctl.conf
        sysctl -p
    fi
    ipv6_lala=$(sipcalc "$ip_network_gam" | grep "Compressed address" | awk '{print $4}' | awk -F: '{NF--; print}' OFS=:):
    randbits=$(od -An -N2 -t x1 /dev/urandom | tr -d ' ')
    lxc_ipv6="${ipv6_lala%/*}${randbits}"
    echo "$lxc_ipv6"
    lxc config device add "$CONTAINER_NAME" eth1 nic nictype=routed parent=${ipv6_network_name} ipv6.address=${lxc_ipv6}
    # # 打印信息并测试是否通畅
    # if ping6 -c 3 $IPV6 &>/dev/null; then
    #     _green "$CONTAINER_NAME The external IPV6 address of the container is $IPV6"
    #     _green "$CONTAINER_NAME 容器的外网IPV6地址为 $IPV6"
    # else
    #     _red "Mapping failure"
    #     _red "映射失败"
    #     exit 1
    # fi
    # 写入信息
    echo "$lxc_ipv6" >>"$CONTAINER_NAME"_v6
fi
