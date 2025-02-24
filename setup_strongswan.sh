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
WAN_IF=$(ip route show default | grep -oP 'dev \K\S+')
WAN_IP=$(ip addr show $WAN_IF | grep -oP 'inet \K\d+\.\d+\.\d+\.\d+')

# Определяем LAN интерфейс и подсеть
LAN_IF="br-lan"
LAN_SUBNET=$(ip route show dev $LAN_IF | grep -oP '^\K\d+\.\d+\.\d+\.\d+/\d+' | head -1)

# Устанавливаем StrongSwan
opkg update
opkg install strongswan

# Генерируем случайный PSK
PSK=$(openssl rand -base64 48)

# Запрашиваем у пользователя выбор
echo "Настроить VPN для выхода в интернет через роутер:"
echo "1 — С доступом к локальным ресурсам ($LAN_SUBNET) и интернетом"
echo "2 — Только интернет, без доступа к локальным ресурсам"
read -p "Введите 1 или 2: " CHOICE

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

# Создаем файл конфигурации /etc/ipsec.conf
cat > /etc/ipsec.conf << EOF
config setup
    charondebug="ike 2, knl 2, cfg 2"

conn ikev2-psk
    keyexchange=ikev2
    ike=aes128-sha256-modp3072!
    esp=aes128-sha256!
    left=$WAN_IP
    leftid=$WAN_IP
    leftsubnet=$LEFT_SUBNET
    leftfirewall=yes
    right=%any
    rightauth=psk
    rightsourceip=10.10.10.0/24
    auto=add
EOF

# Создаем файл с секретами /etc/ipsec.secrets
echo "%any : PSK \"$PSK\"" > /etc/ipsec.secrets

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
    uci set firewall.@rule[-1].src='ipsec'
    uci set firewall.@rule[-1].dest='lan'
    uci set firewall.@rule[-1].target='ACCEPT'
fi

# Настройка NAT для выхода в интернет
uci set firewall.@zone[$(uci show firewall | grep -m 1 -B 1 ".name='wan'" | grep -o "@zone\[[0-1]\]")].masq='1'
uci add firewall rule
uci set firewall.@rule[-1].name='Masquerade-VPN-to-WAN'
uci set firewall.@rule[-1].src='ipsec'
uci set firewall.@rule[-1].dest='wan'
uci set firewall.@rule[-1].target='MASQUERADE'

uci commit firewall
/etc/init.d/firewall restart

# Перезапускаем StrongSwan
/etc/init.d/ipsec restart

# Выводим данные для клиента
echo "Сервер VPN успешно настроен."
echo "Данные для подключения клиента:"
echo "- Адрес сервера: $WAN_IP"
echo "- Идентификатор сервера: $WAN_IP"
echo "- PSK: $PSK"
echo "- Идентификатор клиента: используйте любое имя (например, 'myphone')"
echo "$ACCESS_MESSAGE"