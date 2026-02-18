#!/bin/bash

# ==============================================================================
# 🏴‍☠️ ALCHEMIST NETPLAN CONFIGURATOR v7.1 (Robust Edition)
# ==============================================================================

# --- Safety Checks ---
if [[ $EUID -ne 0 ]]; then
   echo "🚫 Ошибка: Запускай из-под root (sudo)."
   exit 1
fi

BACKUP_FILE="/etc/netplan/01-netcfg.yaml.bak.$(date +%s)"
CONFIG_FILE="/etc/netplan/01-netcfg.yaml"

# Функция аварийного выхода
restore_and_exit() {
    echo -e "\n💥 ОБНАРУЖЕНА ОШИБКА ГЕНЕРАЦИИ!"
    echo "🔄 Восстанавливаю предыдущую конфигурацию..."
    if [[ -f "$BACKUP_FILE" ]]; then
        cp "$BACKUP_FILE" "$CONFIG_FILE"
        echo "✅ Конфиг восстановлен. Сеть в безопасности."
    else
        echo "⚠️ Бэкап не найден (возможно, это первый запуск). Проверь файл вручную."
    fi
    exit 1
}

clear
echo "⚔️  Настройка сети: PBR & Dual IP (v7.1 Robust)"
echo "---------------------------------------------------------------------"

# --- 1. Сбор разведданных ---
mapfile -t current_ips < <(ip -4 addr show ens3 | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1')
current_ipv6=$(ip -6 addr show ens3 | grep -oP 'inet6 \K[0-9a-fA-F:\/]+' | grep -v '^fe80' | head -n 1)
ens6_ip=$(ip -4 addr show ens6 | grep -oP 'inet \K[\d.\/]+' | head -n 1)

# Ротация
def_main=""
def_sec=""
if [ ${#current_ips[@]} -ge 2 ]; then
    def_main="${current_ips[1]}"
    def_sec="${current_ips[0]}"
elif [ ${#current_ips[@]} -eq 1 ]; then
    def_sec="${current_ips[0]}"
fi

calc_gw() { echo "$1" | awk -F. '{print $1"."$2"."$3".1"}'; }

# --- 2. Интервью ---

# MAIN IP
echo -e "\n🔵 [ГЛАВНЫЙ IP] (Приоритет 50)"
read -e -p "   IP адрес: " -i "$def_main" ip_main_input
[[ "$ip_main_input" != *"/"* && -n "$ip_main_input" ]] && ip_main_input="${ip_main_input}/24"
ip_main_pure=$(echo "$ip_main_input" | cut -d'/' -f1)
gw_main_def=$(calc_gw "$ip_main_pure")
read -e -p "   Шлюз: " -i "$gw_main_def" gw_main

# SECONDARY IP
echo -e "\n🟠 [ВТОРОЙ IP] (Приоритет 200)"
read -e -p "   IP адрес (Enter, если нет): " -i "$def_sec" ip_sec_input
if [[ -n "$ip_sec_input" ]]; then
    [[ "$ip_sec_input" != *"/"* ]] && ip_sec_input="${ip_sec_input}/24"
    ip_sec_pure=$(echo "$ip_sec_input" | cut -d'/' -f1)
    gw_sec_def=$(calc_gw "$ip_sec_pure")
    read -e -p "   Шлюз: " -i "$gw_sec_def" gw_sec
fi

# IPv6 & Local
echo -e "\n⚪ [ПРОЧЕЕ]"
read -e -p "   IPv6 (ens3): " -i "$current_ipv6" ipv6_input
[[ -n "$ipv6_input" && "$ipv6_input" != *"/"* ]] && ipv6_input="${ipv6_input}/64"
read -e -p "   IPv4 Local (ens6): " -i "$ens6_ip" ens6_input
[[ -n "$ens6_input" && "$ens6_input" != *"/"* ]] && ens6_input="${ens6_input}/16"

# --- 3. Генерация (Безопасный метод) ---

# Бэкапим текущий конфиг
[[ -f "$CONFIG_FILE" ]] && cp "$CONFIG_FILE" "$BACKUP_FILE"

# 3.1 Начало файла
cat > "$CONFIG_FILE" << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ens3:
      addresses:
        - $ip_main_input
EOF

# 3.2 Дописываем адреса (избегаем ошибок с \n)
if [[ -n "$ip_sec_input" ]]; then
    echo "        - $ip_sec_input" >> "$CONFIG_FILE"
fi
if [[ -n "$ipv6_input" ]]; then
    echo "        - \"$ipv6_input\"" >> "$CONFIG_FILE"
fi

# 3.3 DNS (Статичный блок, так надежнее)
cat >> "$CONFIG_FILE" << EOF
      nameservers:
        addresses:
          - 1.1.1.1
          - 8.8.8.8
          - 9.9.9.9
          - 1.0.0.1
          - 8.8.4.4
          - 149.112.112.112
          - "2606:4700:4700::1111"
          - "2001:4860:4860::8888"
          - "2620:fe::fe"
EOF

# 3.4 Маршруты (Routes)
# Собираем блок маршрутов в переменную, тут newlines можно делать echo
{
    echo "      routes:"
    # Main Route
    echo "        - to: 0.0.0.0/0"
    echo "          via: $gw_main"
    echo "          metric: 50"
    echo "          table: 100"
    echo "        - to: 0.0.0.0/0"
    echo "          via: $gw_main"
    echo "          metric: 50"
    
    # Secondary Route
    if [[ -n "$ip_sec_input" ]]; then
        echo "        - to: 0.0.0.0/0"
        echo "          via: $gw_sec"
        echo "          metric: 200"
        echo "          table: 101"
        echo "        - to: 0.0.0.0/0"
        echo "          via: $gw_sec"
        echo "          metric: 200"
    fi

    # IPv6 Route
    if [[ -n "$ipv6_input" ]]; then
        echo "        - to: default"
        echo "          via: \"fe80::1\""
        echo "          on-link: true"
    fi
} >> "$CONFIG_FILE"

# 3.5 Политики (Policies)
{
    echo "      routing-policy:"
    echo "        - from: $ip_main_pure"
    echo "          table: 100"
    if [[ -n "$ip_sec_input" ]]; then
        echo "        - from: $ip_sec_pure"
        echo "          table: 101"
    fi
} >> "$CONFIG_FILE"

# 3.6 Local Interface (ens6)
if [[ -n "$ens6_input" ]]; then
cat >> "$CONFIG_FILE" << EOF
    ens6:
      addresses:
        - "$ens6_input"
EOF
fi

chmod 600 "$CONFIG_FILE"

# --- 4. Финал и Проверка ---
echo -e "\n📄 Генерирую конфигурацию..."

# Пробуем сгенерировать. Если ошибка -> вызываем restore_and_exit
netplan generate || restore_and_exit

echo -e "\n✅ Конфигурация валидна!"
echo "--------------------------------------------------------"
echo "Главный IP: $ip_main_pure"
[[ -n "$ip_sec_input" ]] && echo "Второй IP:  $ip_sec_pure"
echo "--------------------------------------------------------"

# Удаляем бэкап, если всё прошло успешно (опционально, можно оставить)
# rm "$BACKUP_FILE"

netplan try
