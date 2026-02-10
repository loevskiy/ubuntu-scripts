#!/bin/bash

# ==============================================================================
# Скрипт для настройки сети Netplan (v6) - Priority & Dual IP PBR
# ==============================================================================

if ! [ -t 0 ]; then
    echo "🚫 Ошибка: Запускайте через: sudo bash -c \"\$(curl -sSL [URL])\""
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
   echo "🚫 Ошибка: Требуются права sudo."
   exit 1
fi

clear
echo "🚀 Настройка Netplan v6 (Выход через второй IP: Priority 100)"
echo "--------------------------------------------------------"

# --- Авто-определение ---
current_ipv4_ens3=$(ip -4 addr show ens3 | grep -oP 'inet \K[\d.\/]+' | head -n 1)
current_ipv6_ens3=$(ip -6 addr show ens3 | grep -oP 'inet6 \K[0-9a-fA-F:\/]+' | grep -v '^fe80' | head -n 1)
current_ipv4_ens6=$(ip -4 addr show ens6 | grep -oP 'inet \K[\d.\/]+' | head -n 1)

# --- Ввод данных ---
read -e -p "1️⃣  Основной IPv4 (Priority 200): " -i "$current_ipv4_ens3" ipv4_1
[[ -n "$ipv4_1" && ! "$ipv4_1" == *"/"* ]] && ipv4_1="$ipv4_1/24"
ip_only1=$(echo $ipv4_1 | cut -d'/' -f1)
suggested_gw1=$(echo $ip_only1 | awk -F. '{print $1"."$2"."$3".1"}')
read -e -p "   Шлюз для первого IP: " -i "$suggested_gw1" gateway4_1

echo "--------------------------------------------------------"
read -e -p "2️⃣  Второй IPv4 (Priority 100 - EXIT IP): " ipv4_2
if [[ -n "$ipv4_2" ]]; then
    [[ ! "$ipv4_2" == *"/"* ]] && ipv4_2="$ipv4_2/24"
    ip_only2=$(echo $ipv4_2 | cut -d'/' -f1)
    suggested_gw2=$(echo $ip_only2 | awk -F. '{print $1"."$2"."$3".1"}')
    read -e -p "   Шлюз для второго IP: " -i "$suggested_gw2" gateway4_2
fi

echo "--------------------------------------------------------"
read -e -p "3️⃣  IPv6 для ens3: " -i "$current_ipv6_ens3" ipv6_ens3
[[ -n "$ipv6_ens3" && ! "$ipv6_ens3" == *"/"* ]] && ipv6_ens3="$ipv6_ens3/64"

read -e -p "4️⃣  Локальный IP для ens6: " -i "$current_ipv4_ens6" ipv4_ens6
[[ -n "$ipv4_ens6" && ! "$ipv4_ens6" == *"/"* ]] && ipv4_ens6="$ipv4_ens6/16"

# --- Логика формирования блоков ---

# 1. Список адресов
ADDR_LIST="- \"$ipv4_1\""
[[ -n "$ipv4_2" ]] && ADDR_LIST="$ADDR_LIST
        - \"$ipv4_2\""
[[ -n "$ipv6_ens3" ]] && ADDR_LIST="$ADDR_LIST
        - \"$ipv6_ens3\""

# 2. Маршруты и Политики
if [[ -n "$ipv4_2" ]]; then
    # Если два IP: настраиваем приоритеты и PBR для обоих, чтобы не было конфликтов
    ROUTES="- to: default
          via: $gateway4_1
          metric: 200
          on-link: true
        - to: default
          via: $gateway4_2
          metric: 100
          on-link: true
        - to: 0.0.0.0/0
          via: $gateway4_1
          table: 101
        - to: 0.0.0.0/0
          via: $gateway4_2
          table: 102"
    
    POLICIES="      routing-policy:
        - from: $ip_only1
          table: 101
        - from: $ip_only2
          table: 102"
else
    # Если один IP: просто стандартный шлюз
    ROUTES="- to: default
          via: $gateway4_1
          metric: 100
          on-link: true"
    POLICIES=""
fi

# Добавляем IPv6 маршрут если он есть
[[ -n "$ipv6_ens3" ]] && ROUTES="$ROUTES
        - to: default
          via: \"fe80::1\"
          on-link: true"

# --- Сборка файла ---
cat > /etc/netplan/01-netcfg.yaml << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ens3:
      addresses:
        $ADDR_LIST
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
      routes:
        $ROUTES
$POLICIES
EOF

if [[ -n "$ipv4_ens6" ]]; then
cat >> /etc/netplan/01-netcfg.yaml << EOF
    ens6:
      addresses:
        - "$ipv4_ens6"
EOF
fi

chmod 600 /etc/netplan/01-netcfg.yaml
echo "--------------------------------------------------------"
cat /etc/netplan/01-netcfg.yaml
echo "--------------------------------------------------------"

netplan generate && sleep 1 && netplan try
