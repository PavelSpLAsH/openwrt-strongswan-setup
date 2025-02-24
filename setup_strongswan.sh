#!/bin/sh

# Проверка и установка wget, если он не установлен
if ! command -v wget > /dev/null 2>&1; then
    echo "wget не найден, устанавливаю..."
    opkg update
    opkg install wget
    if [ $? -ne 0 ]; then
        echo "Ошибка: не удалось установить wget. Проверьте интернет-соединение и попробуйте снова."
        exit 1
    fi
else
    echo "wget уже установлен, продолжаю..."
fi

# Определяем WAN интерфейс и IP
WAN_IF=$(ip route show default | grep 'dev ' | awk '{print $5}')
WAN_IP=$(ip addr show $WAN_IF | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)

# Определяем LAN интерфейс и подсеть
LAN_IF="br-lan"
LAN_SUBNET=$(ip route show dev $LAN_IF | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+/[0-9]\+' | head -1)

# Устанавливаем StrongSwan и необходимые пакеты
opkg update
opkg install strongswan strongswan-default strongswan-mod-openssl strongswan-charon strongswan-swanctl

# Генерируем случайный PSK
PSK=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9+/=')

# Запрашиваем у пользователя выбор через /dev/tty
echo "Настроить VPN для выхода в интернет через роутер:"
echo "1 — С доступом к локальным ресурсам ($LAN_SUBNET) и интернетом"
echo "2 — Только интернет, без доступа к локальным ресурсам"
read -p "Введите 1 или 2: " CHOICE < /dev/tty

# Устанавливаем leftsubnet в зависимости от выбора
if [ "$CHOICE" = "1" ]; then
    LEFT_SUBNET="$LAN_SUBNET,0.0.0.0/0"
    ACCESS_MESSAGE="VPN-клиенты имеют доступ к локальной сети ($LAN_SUBNET) и интернету через роутер ($WAN_IP)"
elif [ "$CHOICE" = "2" ]; then
    LEFT_SUBNET="0.0.0.0/0"
    ACCESS_MESSAGE="VPN-клиенты имеют доступ только к интернету через роутер ($WAN_IP)"
else
    echo "Неверный выбор, используется значение по умолчанию: только интернет"
    LEFT_SUBNET="0.0.0.0/0"
    ACCESS_MESSAGE="VPN-клиенты имеют доступ только к интернету через роутер ($WAN_IP)"
fi

# Создаем файл конфигурации /etc/swanctl/swanctl.conf
cat > /etc/swanctl/swanctl.conf << EOF
connections {
    ikev2-psk {
        local_addrs = $WAN_IP
        local {
            auth = psk
            id = $WAN_IP
        }
        remote {
            auth = psk
        }
        children {
            ikev2-psk {
                local_ts = $LEFT_SUBNET
                remote_ts = 0.0.0.0/0
                updown = "/usr/libexec/ipsec/_updown iptables"
                esp_proposals = aes128-sha256
                start_action = trap
            }
        }
        version = 2
        proposals = aes128-sha256-modp3072
        pools = vpn_pool
    }
}

pools {
    vpn_pool {
        addrs = 10.10.10.0/24
    }
}

secrets {
    ike-psk {
        secret = "$PSK"
    }
}
EOF

# Настраиваем брандмауэр
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-IPsec-500'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].dest_port='500'
uci set firewall.@rule[-1].target='ACCEPT'

uci add firewall rule
uci set firewall.@rule[-1].name='Allow-IPsec-4500'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].dest_port='4500'
uci set firewall.@rule[-1].target='ACCEPT'

# Разрешаем трафик от VPN к LAN, если выбран доступ к локальным ресурсам
if [ "$CHOICE" = "1" ]; then
    uci add firewall rule
    uci set firewall.@rule[-1].name='Allow-VPN-to-LAN'
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].dest='lan'
    uci set firewall.@rule[-1].target='ACCEPT'
fi

# Настройка NAT для VPN-клиентов через зону wan
uci set firewall.@zone[$(uci show firewall | grep -m 1 ".name='wan'" | cut -d'.' -f1-2)].masq='1'
uci add firewall masquerade
uci set firewall.@masquerade[-1].name='Masquerade-VPN'
uci set firewall.@masquerade[-1].target='MASQUERADE'
uci set firewall.@masquerade[-1].src='wan'
uci set firewall.@masquerade[-1].src_ip='10.10.10.0/24'
uci set firewall.@masquerade[-1].enabled='1'

uci commit firewall
/etc/init.d/firewall restart

# Перезапускаем StrongSwan через swanctl
killall charon 2>/dev/null || true
/usr/libexec/ipsec/charon &
sleep 2
swanctl --load-all

# Выводим данные для клиента
echo "Сервер VPN успешно настроен."
echo "Данные для подключения клиента:"
echo "- Адрес сервера: $WAN_IP"
echo "- Идентификатор сервера: $WAN_IP"
echo "- PSK: $PSK"
echo "- Идентификатор клиента: используйте любое имя (например, 'myphone')"
echo "$ACCESS_MESSAGE"
