#!/bin/bash

# ==============================================================================
# 🏴‍☠️ ALCHEMIST NETPLAN CONFIGURATOR v7.3 (Smart PBR Edition)
# ==============================================================================

# --- Safety Checks ---
if [[ $EUID -ne 0 ]]; then
   echo "🚫 Ошибка: Запускай из-под root (sudo)."
   exit 1
fi

BACKUP_FILE="/etc/netplan/01-netcfg.yaml.bak.$(date +%s)"
CONFIG_FILE="/etc/netplan/01-netcfg.yaml"

restore_and_exit() {
    echo -e "\n💥 ОБНАРУЖЕНА ОШИБКА ГЕНЕРАЦИИ!"
    echo "🔄 Восстанавливаю предыдущую конфигурацию..."
    if [[ -f "$BACKUP_FILE" ]]; then
        cp "$BACKUP_FILE" "$CONFIG_FILE"
        echo "✅ Конфиг восстановлен. Сеть в безопасности."
    else
        echo "⚠️ Бэкап не найден. Проверь файл вручную."
    fi
    exit 1
}

clear
echo "⚔️  Настройка сети: Smart PBR & Multi IP (v7.3)"
echo "---------------------------------------------------------------------"

# --- 1. Сбор разведданных ---
mapfile -t current_ips < <(ip -4 addr show ens3 | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1')
current_ipv6=$(ip -6 addr show ens3 | grep -oP 'inet6 \K[0-9a-fA-F:\/]+' | grep -v '^fe80' | head -n 1)
ens6_ip=$(ip -4 addr show ens6 | grep -oP 'inet \K[\d.\/]+' | head -n 1)

def_main=""
def_sec=""
if [ ${#current_ips[@]} -ge 2 ]; then
    def_main="${current_ips[1]}"
    def_sec="${current_ips[0]}"
elif [ ${#current_ips[@]} -eq 1 ]; then
    def_main="${current_ips[0]}"
fi

calc_gw() { echo "$1" | awk -F. '{print $1"."$2"."$3".1"}'; }

# --- 2. Интервью ---

# MAIN IP
echo -e "\n🔵 [ГЛАВНЫЙ IP] (Приоритет 50)"
read -e -p "   IP адрес (Enter, если пропустить): " -i "$def_main" ip_main_input
if [[ -n "$ip_main_input" ]]; then
    [[ "$ip_main_input" != *"/"* ]] && ip_main_input="${ip_main_input}/24"
    ip_main_pure=$(echo "$ip_main_input" | cut -d'/' -f1)
    gw_main_def=$(calc_gw "$ip_main_pure")
    read -e -p "   Шлюз: " -i "$gw_main_def" gw_main
fi

# SECONDARY IP
echo -e "\n🟠 [ВТОРОЙ IP] (Приоритет 200)"
read -e -p "   IP адрес (Enter, если пропустить): " -i "$def_sec" ip_sec_input
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

# Подсчет количества активных IPv4 для логики PBR
ipv4_count=0
[[ -n "$ip_main_input" ]] && ((ipv4_count++))
[[ -n "$ip_sec_input" ]]  && ((ipv4_count++))

# --- 3. Генерация ---

[[ -f "$CONFIG_FILE" ]] && cp "$CONFIG_FILE" "$BACKUP_FILE"

{
    echo "network:"
    echo "  version: 2"
    echo "  renderer: networkd"
    echo "  ethernets:"
    echo "    ens3:"

    # 3.1 Адреса
    if [[ $ipv4_count -gt 0 || -n "$ipv6_input" ]]; then
        echo "      addresses:"
        [[ -n "$ip_main_input" ]] && echo "        - $ip_main_input"
        [[ -n "$ip_sec_input" ]]  && echo "        - $ip_sec_input"
        [[ -n "$ipv6_input" ]]    && echo "        - \"$ipv6_input\""
    fi

    # 3.2 DNS
    echo "      nameservers:"
    echo "        addresses:"
    echo "          - 1.1.1.1"
    echo "          - 8.8.8.8"
    echo "          - 9.9.9.9"
    echo "          - 149.112.112.112"
    echo "          - \"2606:4700:4700::1111\""
    echo "          - \"2001:4860:4860::8888\""

    # 3.3 Маршруты (SMART ROUTING)
    if [[ $ipv4_count -gt 0 || -n "$ipv6_input" ]]; then
        echo "      routes:"
        
        if [[ -n "$ip_main_input" ]]; then
            # Главный системный маршрут (нужен всегда)
            echo "        - to: 0.0.0.0/0"
            echo "          via: $gw_main"
            echo "          metric: 50"
            
            # Маршрут PBR (только если есть второй IP)
            if [[ $ipv4_count -eq 2 ]]; then
                echo "        - to: 0.0.0.0/0"
                echo "          via: $gw_main"
                echo "          metric: 50"
                echo "          table: 100"
            fi
        fi

        if [[ -n "$ip_sec_input" ]]; then
            if [[ $ipv4_count -eq 2 ]]; then
                # PBR маршрут для второго IP
                echo "        - to: 0.0.0.0/0"
                echo "          via: $gw_sec"
                echo "          metric: 200"
                echo "          table: 101"
            else
                # Если главный IP был пропущен, делаем второй IP главным системным шлюзом
                echo "        - to: 0.0.0.0/0"
                echo "          via: $gw_sec"
                echo "          metric: 200"
            fi
        fi

        if [[ -n "$ipv6_input" ]]; then
            echo "        - to: default"
            echo "          via: \"fe80::1\""
            echo "          on-link: true"
        fi
    fi

    # 3.4 Политики PBR (ТОЛЬКО ДЛЯ DUAL-IP)
    if [[ $ipv4_count -eq 2 ]]; then
        echo "      routing-policy:"
        echo "        - from: $ip_main_pure"
        echo "          table: 100"
        echo "        - from: $ip_sec_pure"
        echo "          table: 101"
    fi

    # 3.5 Local Interface (ens6)
    if [[ -n "$ens6_input" ]]; then
        echo "    ens6:"
        echo "      addresses:"
        echo "        - \"$ens6_input\""
    fi

} > "$CONFIG_FILE"

chmod 600 "$CONFIG_FILE"

# --- 4. Финал и Проверка ---
echo -e "\n📄 Генерирую конфигурацию..."

netplan generate || restore_and_exit

echo -e "\n✅ Конфигурация валидна!"
echo "--------------------------------------------------------"
[[ -n "$ip_main_input" ]] && echo "Главный IP: $ip_main_pure" || echo "Главный IP: ПРОПУЩЕН"
[[ -n "$ip_sec_input" ]]  && echo "Второй IP:  $ip_sec_pure" || echo "Второй IP:  ПРОПУЩЕН"
echo "Режим PBR:  $( [[ $ipv4_count -eq 2 ]] && echo 'АКТИВЕН (Dual-IP)' || echo 'ВЫКЛЮЧЕН (Single-IP)' )"
echo "--------------------------------------------------------"

netplan try
