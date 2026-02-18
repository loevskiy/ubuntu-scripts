#!/bin/bash

# ==============================================================================
# 🏴‍☠️ ALCHEMIST NETPLAN CONFIGURATOR v7 (Dual IP + PBR + Auto-Rotation)
# ==============================================================================

if [[ $EUID -ne 0 ]]; then
   echo "🚫 Ошибка: Запускай из-под root (sudo)."
   exit 1
fi

clear
echo "⚔️  Настройка сети: PBR (Policy Based Routing) & Ротация IP"
echo "⚠️  Внимание: Скрипт полностью перезапишет /etc/netplan/01-netcfg.yaml"
echo "---------------------------------------------------------------------"

# --- 1. Сбор разведданных (текущие IP) ---
# Получаем список всех IPv4 на ens3 в массив
mapfile -t current_ips < <(ip -4 addr show ens3 | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1')
current_ipv6=$(ip -6 addr show ens3 | grep -oP 'inet6 \K[0-9a-fA-F:\/]+' | grep -v '^fe80' | head -n 1)
ens6_ip=$(ip -4 addr show ens6 | grep -oP 'inet \K[\d.\/]+' | head -n 1)

# Логика авто-предложения (Ротация)
# Если есть 2 IP, то по умолчанию предлагаем:
#   Main (New) = Второй найденный (бывший доп)
#   Secondary (Old) = Первый найденный (бывший main)
def_main=""
def_sec=""

if [ ${#current_ips[@]} -ge 2 ]; then
    def_main="${current_ips[1]}" # Второй становится главным
    def_sec="${current_ips[0]}"  # Первый уходит во вторичные
elif [ ${#current_ips[@]} -eq 1 ]; then
    def_sec="${current_ips[0]}"  # Единственный уходит во вторичные (освобождая место под новый)
    def_main=""                  # Ждем ввода нового
fi

# Ф-ция вычисления шлюза (грубая, .1 на конце)
calc_gw() {
    echo "$1" | awk -F. '{print $1"."$2"."$3".1"}'
}

# --- 2. Интервью ---

# --- ГЛАВНЫЙ IP (NEW) ---
echo -e "\n🔵 [ГЛАВНЫЙ IP] Будет использоваться по умолчанию для выхода."
read -e -p "   IP адрес: " -i "$def_main" ip_main_input
[[ "$ip_main_input" != *"/"* && -n "$ip_main_input" ]] && ip_main_input="${ip_main_input}/24"
ip_main_pure=$(echo "$ip_main_input" | cut -d'/' -f1)
gw_main_def=$(calc_gw "$ip_main_pure")

read -e -p "   Шлюз: " -i "$gw_main_def" gw_main
echo "   -> Метрика: 50 (Высший приоритет)"

# --- ВТОРОСТЕПЕННЫЙ IP (OLD/LEGACY) ---
echo -e "\n🟠 [ВТОРОЙ IP] Для доживания/ротации. Входящие работают корректно."
read -e -p "   IP адрес (Enter, если нет): " -i "$def_sec" ip_sec_input
if [[ -n "$ip_sec_input" ]]; then
    [[ "$ip_sec_input" != *"/"* ]] && ip_sec_input="${ip_sec_input}/24"
    ip_sec_pure=$(echo "$ip_sec_input" | cut -d'/' -f1)
    gw_sec_def=$(calc_gw "$ip_sec_pure")
    read -e -p "   Шлюз: " -i "$gw_sec_def" gw_sec
    echo "   -> Метрика: 200 (Низкий приоритет)"
fi

# --- IPv6 и Local ---
echo -e "\n⚪ [ПРОЧЕЕ]"
read -e -p "   IPv6 (ens3): " -i "$current_ipv6" ipv6_input
[[ -n "$ipv6_input" && "$ipv6_input" != *"/"* ]] && ipv6_input="${ipv6_input}/64"

read -e -p "   IPv4 Local (ens6): " -i "$ens6_ip" ens6_input
[[ -n "$ens6_input" && "$ens6_input" != *"/"* ]] && ens6_input="${ens6_input}/16"

# --- 3. Генерация конфига ---

# Формируем список адресов
ADDRESSES="        - $ip_main_input"
[[ -n "$ip_sec_input" ]] && ADDRESSES="${ADDRESSES}\n        - $ip_sec_input"
[[ -n "$ipv6_input" ]] && ADDRESSES="${ADDRESSES}\n        - \"$ipv6_input\""

# Формируем маршруты (Routes)
# Main IP route (table 100)
ROUTES="        # --- Routes for Main IP ---
        - to: 0.0.0.0/0
          via: $gw_main
          metric: 50
          table: 100
        - to: 0.0.0.0/0
          via: $gw_main
          metric: 50"

# Secondary IP route (table 101)
if [[ -n "$ip_sec_input" ]]; then
ROUTES="$ROUTES
        # --- Routes for Secondary IP ---
        - to: 0.0.0.0/0
          via: $gw_sec
          metric: 200
          table: 101
        - to: 0.0.0.0/0
          via: $gw_sec
          metric: 200"
fi

# IPv6 Route
if [[ -n "$ipv6_input" ]]; then
ROUTES="$ROUTES
        - to: default
          via: \"fe80::1\"
          on-link: true"
fi

# Формируем политики (Routing Policy)
# Суть: "Если пакет пришел ОТ этого IP, используй таблицу этого IP"
POLICIES="      routing-policy:
        - from: $ip_main_pure
          table: 100"

if [[ -n "$ip_sec_input" ]]; then
POLICIES="$POLICIES
        - from: $ip_sec_pure
          table: 101"
fi

# Сборка файла
cat > /etc/netplan/01-netcfg.yaml << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ens3:
      addresses:
$ADDRESSES
      nameservers:
        addresses:
          # IPv4
          - 1.1.1.1        # Cloudflare (Скорость + Приватность)
          - 8.8.8.8        # Google (Стабильность)
          - 9.9.9.9        # Quad9 (Безопасность: блокирует вредоносные домены)
          - 1.0.0.1        # Cloudflare Secondary
          - 8.8.4.4        # Google Secondary
          - 149.112.112.112 # Quad9 Secondary
          # IPv6 (рекомендуется для полноты стека)
          - "2606:4700:4700::1111"
          - "2001:4860:4860::8888"
          - "2620:fe::fe"
      routes:
$ROUTES
$POLICIES
EOF

# Добавляем ens6 если есть
if [[ -n "$ens6_input" ]]; then
cat >> /etc/netplan/01-netcfg.yaml << EOF
    ens6:
      addresses:
        - "$ens6_input"
EOF
fi

# --- 4. Финал ---
chmod 600 /etc/netplan/01-netcfg.yaml
echo -e "\n📄 Генерирую конфигурацию..."
netplan generate

echo -e "\n✅ Конфигурация готова к применению!"
echo "--------------------------------------------------------"
echo "Главный IP: $ip_main_pure (Table 100, Metric 50)"
[[ -n "$ip_sec_input" ]] && echo "Второй IP:  $ip_sec_pure (Table 101, Metric 200)"
echo "--------------------------------------------------------"

read -p "Нажми Enter чтобы применить (netplan try)..."
netplan try
