#!/bin/sh

# Логирование
LOG_PREFIX="strongswan-setup: "
log() {
    echo "${LOG_PREFIX}$1"
    #logger "${LOG_PREFIX}$1"  # Раскомментируй для логирования в syslog
}

# Функция для проверки и установки пакетов
install_package() {
    local package="$1"
    if ! opkg find "$package" > /dev/null 2>&1; then
        log "Пакет '$package' не найден, устанавливаю..."
        opkg update
        opkg install "$package" || { log "Ошибка: не удалось установить пакет '$package'."; exit 1; }
    else
        log "Пакет '$package' уже установлен."
    fi
}

# Установка необходимых пакетов
install_package dos2unix
install_package wget

# Определяем WAN интерфейс и IP (альтернативный способ)
WAN_IF=$(uci get network.wan.device)
WAN_IP=$(ip addr show "$WAN_IF" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)

if [ -z "$WAN_IF" ] || [ -z "$WAN_IP" ]; then
    WAN_IF=$(uci get network.Wanusb.device)
    WAN_IP=$(ip addr show "$WAN_IF" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
fi

if [ -z "$WAN_IF" ] || [ -z "$WAN_IP" ]; then
    log "Ошибка: не удалось определить WAN интерфейс или IP адрес. Проверьте конфигурацию сети."
    exit 1
fi

log "WAN интерфейс: $WAN_IF"
log "WAN IP адрес: $WAN_IP"

# Определяем LAN интерфейс и подсеть
LAN_IF="br-lan"
LAN_SUBNET=$(ip route show dev $LAN_IF | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+/[0-9]\+' | head -1)

if [ -z "$LAN_SUBNET" ]; then
    log "Ошибка: не удалось определить LAN подсеть. Проверьте конфигурацию сети."
    exit 1
fi

log "LAN интерфейс: $LAN_IF"
log "LAN подсеть: $LAN_SUBNET"

# Устанавливаем StrongSwan и необходимые пакеты
log "Устанавливаю StrongSwan и необходимые пакеты..."
opkg update
opkg install strongswan strongswan-default strongswan-mod-openssl strongswan-charon strongswan-swanctl || { log "Ошибка при установке StrongSwan пакетов."; exit 1; }

# Генерируем случайный PSK
PSK=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9+/=')
log "Сгенерирован PSK: $PSK"

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

log "Выбран режим: $CHOICE"
log "LEFT_SUBNET: $LEFT_SUBNET"

# Создаем файл конфигурации /etc/swanctl/swanctl.conf
log "Создаю файл конфигурации /etc/swanctl/swanctl.conf..."
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
log "Настраиваю брандмауэр..."

uci add firewall rule 2>/dev/null
uci set firewall.@rule[-1].name='Allow-IPsec-500'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].dest_port='500'
uci set firewall.@rule[-1].target='ACCEPT'
uci commit firewall || { log "Ошибка при настройке firewall"; exit 1; }

uci add firewall rule 2>/dev/null
uci set firewall.@rule[-1].name='Allow-IPsec-4500'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].dest_port='4500'
uci set firewall.@rule[-1].target='ACCEPT'
uci commit firewall || { log "Ошибка при настройке firewall"; exit 1; }


# Разрешаем трафик от VPN к LAN, если выбран доступ к локальным ресурсам
if [ "$CHOICE" = "1" ]; then
    uci add firewall rule 2>/dev/null
    uci set firewall.@rule[-1].name='Allow-VPN-to-LAN'
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].dest='lan'
    uci set firewall.@rule[-1].target='ACCEPT'
    uci commit firewall || { log "Ошибка при настройке firewall"; exit 1; }
fi

# Настройка NAT через зону wan (без нового интерфейса)
uci set firewall.@zone[$(uci show firewall | grep -m 1 ".name='wan'" | cut -d'.' -f1-2)].masq='1'
uci commit firewall || { log "Ошибка при настройке firewall"; exit 1; }

uci add firewall masquerade 2>/dev/null
uci set firewall.@masquerade[-1].name='Masquerade-VPN'
uci set firewall.@masquerade[-1].target='MASQUERADE'
uci set firewall.@masquerade[-1].src_ip='10.10.10.0/24'
uci set firewall.@masquerade[-1].enabled='1'
uci commit firewall || { log "Ошибка при настройке firewall"; exit 1; }

log "Перезапускаю firewall..."
/etc/init.d/firewall restart || { log "Ошибка при перезапуске firewall"; exit 1; }

# Перезапускаем StrongSwan
log "Перезапускаю StrongSwan..."
if [ -f /etc/init.d/strongswan ]; then
    /etc/init.d/strongswan restart || { log "Ошибка при перезапуске StrongSwan"; exit 1; }
    sleep 5 # Увеличиваем время ожидания
    swanctl --load-all || { log "Ошибка при загрузке конфигурации swanctl"; exit 1; }
else
    log "Ошибка: сервис StrongSwan не найден. Убедитесь, что установка прошла успешно."
    exit 1
fi

# Выводим данные для клиента
echo "Сервер VPN успешно настроен."
echo "Данные для подключения клиента:"
echo "- Адрес сервера: $WAN_IP"
echo "- Идентификатор сервера: $WAN_IP"
echo "- PSK: $PSK"
echo "- Идентификатор клиента: используйте любое имя (например, 'myphone')"
echo "$ACCESS_MESSAGE"

log "Настройка StrongSwan завершена."
echo "- Идентификатор клиента: используйте любое имя (например, 'myphone')"
echo "$ACCESS_MESSAGE"
