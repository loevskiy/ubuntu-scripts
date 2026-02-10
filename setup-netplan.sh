#!/bin/bash

# ==============================================================================
# Скрипт для настройки сети Netplan (v5) - Поддержка Dual IP & PBR
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
echo "🚀 Умная настройка Netplan v5 (Dual IP & Routing Policies)"
echo "--------------------------------------------------------"

# --- Авто-определение ---
current_ipv4_ens3=$(ip -4 addr show ens3 | grep -oP 'inet \K[\d.\/]+' | head -n 1)
current_ipv6_ens3=$(ip -6 addr show ens3 | grep -oP 'inet6 \K[0-9a-fA-F:\/]+' | grep -v '^fe80' | head -n 1)
current_ipv4_ens6=$(ip -4 addr show ens6 | grep -oP 'inet \K[\d.\/]+' | head -n 1)

# --- Блок ввода: Первый IP ---
read -e -p "1️⃣  Основной IPv4 для ens3: " -i "$current_ipv4_ens3" ipv4_1
[[ -n "$ipv4_1" && ! "$ipv4_1" == *"/"* ]] && ipv4_1="$ipv4_1/24"

ip_part1=$(echo $ipv4_1 | cut -d'/' -f1)
suggested_gw1=$(echo $ip_part1 | awk -F. '{print $1"."$2"."$3".1"}')
read -e -p "   Шлюз для первого IP: " -i "$suggested_gw1" gateway4_1

# --- Блок ввода: Второй IP (Опционально) ---
echo "--------------------------------------------------------"
read -e -p "2️⃣  Второй IPv4 для ens3 (Enter для пропуска): " ipv4_2
if [[ -n "$ipv4_2" ]]; then
    [[ ! "$ipv4_2" == *"/"* ]] && ipv4_2="$ipv4_2/24"
    ip_part2=$(echo $ipv4_2 | cut -d'/' -f1)
    suggested_gw2=$(echo $ip_part2 | awk -F. '{print $1"."$2"."$3".1"}')
    read -e -p "   Шлюз для второго IP: " -i "$suggested_gw2" gateway4_2
fi

# --- Блок ввода: IPv6 и ens6 ---
echo "--------------------------------------------------------"
read -e -p "3️⃣  IPv6 для ens3 (Enter для пропуска): " -i "$current_ipv6_ens3" ipv6_ens3
[[ -n "$ipv6_ens3" && ! "$ipv6_ens3" == *"/"* ]] && ipv6_ens3="$ipv6_ens3/64"

read -e -p "4️⃣  Локальный IP для ens6: " -i "$current_ipv4_ens6" ipv4_ens6
[[ -n "$ipv4_ens6" && ! "$ipv4_ens6" == *"/"* ]] && ipv4_ens6="$ipv4_ens6/16"

echo "--------------------------------------------------------"
echo "✅ Генерация конфигурации..."

# --- Формирование YAML ---
# Собираем блоки во временные переменные для чистоты шаблона
ADDRESSES="- \"$ipv4_1\""
[[ -n "$ipv4_2" ]] && ADDRESSES="$ADDRESSES
        - \"$ipv4_2\""
[[ -n "$ipv6_ens3" ]] && ADDRESSES="$ADDRESSES
        - \"$ipv6_ens3\""

ROUTES="- to: default
          via: $gateway4_1
          on-link: true"
[[ -n "$ipv6_ens3" ]] && ROUTES="$ROUTES
        - to: default
          via: \"fe80::1\"
          on-link: true"
[[ -n "$ipv4_2" ]] && ROUTES="$ROUTES
        - to: 0.0.0.0/0
          via: $gateway4_2
          table: 100"

POLICY=""
[[ -n "$ipv4_2" ]] && POLICY="      routing-policy:
        - from: $(echo $ipv4_2 | cut -d'/' -f1)
          table: 100"

cat > /etc/netplan/01-netcfg.yaml << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ens3:
      addresses:
        $ADDRESSES
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1, 8.8.4.4, 1.0.0.1]
      routes:
        $ROUTES
$POLICY
EOF

if [[ -n "$ipv4_ens6" ]]; then
cat >> /etc/netplan/01-netcfg.yaml << EOF
    ens6:
      addresses:
        - "$ipv4_ens6"
EOF
fi

chmod 600 /etc/netplan/01-netcfg.yaml
echo "📄 Конфигурация записана."
echo "--------------------------------------------------------"
cat /etc/netplan/01-netcfg.yaml
echo "--------------------------------------------------------"

netplan generate || { echo "🚫 Ошибка синтаксиса!"; exit 1; }
echo "⚙️ Запуск netplan try..."
sleep 1
netplan try
