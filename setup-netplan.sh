#!/bin/bash

# ==============================================================================
# 🏴‍☠️ ALCHEMIST NETPLAN CONFIGURATOR v8.1 (Seamless DNS Rotation & PBR Edition)
# Target OS: Ubuntu 22.04 / 24.04 LTS (systemd-networkd)
# ==============================================================================

set -u

# --- Цветовая палитра ---
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_BLUE='\033[1;34m'
C_ORANGE='\033[1;33m'
C_GREEN='\033[1;32m'
C_RED='\033[1;31m'
C_CYAN='\033[1;36m'

# --- Проверка прав root ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${C_RED}🚫 Ошибка: Запускай скрипт строго из-под root (sudo).${C_RESET}"
    exit 1
fi

BACKUP_DIR="/etc/netplan/backups/bak_$(date +%Y%m%d_%H%M%S)"
CONFIG_FILE="/etc/netplan/01-netcfg.yaml"
SYSCTL_FILE="/etc/sysctl.d/99-alchemist-pbr.conf"

# --- Функция аварийного отката ---
restore_and_exit() {
    echo -e "\n${C_RED}💥 ОБНАРУЖЕНА ОШИБКА ИЛИ ОТМЕНА! Выполняю откат конфигурации...${C_RESET}"
    if [[ -d "$BACKUP_DIR" ]] && [[ -n "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
        rm -f /etc/netplan/*.yaml
        cp -a "$BACKUP_DIR"/*.yaml /etc/netplan/
        chmod 600 /etc/netplan/*.yaml 2>/dev/null
        netplan generate 2>/dev/null
        echo -e "${C_GREEN}✅ Предыдущие файлы конфигурации полностью восстановлены из $BACKUP_DIR.${C_RESET}"
    else
        echo -e "${C_ORANGE}⚠️ Архив бэкапа пуст или не найден. Проверь /etc/netplan/ вручную.${C_RESET}"
    fi
    exit 1
}

calc_gw() {
    echo "$1" | awk -F. '{print $1"."$2"."$3".1"}'
}

strip_mask() {
    echo "$1" | cut -d'/' -f1
}

ensure_mask() {
    local ip="$1"
    local def_mask="${2:-24}"
    if [[ -n "$ip" && "$ip" != *"/"* ]]; then
        echo "${ip}/${def_mask}"
    else
        echo "$ip"
    fi
}

clear
echo -e "${C_BOLD}⚔️  ALCHEMIST NETPLAN CONFIGURATOR v8.1 (Smart PBR & Seamless DNS Rotation)${C_RESET}"
echo "--------------------------------------------------------------------------------"

# ==============================================================================
# 1. СБОР РАЗВЕДДАННЫХ
# ==============================================================================

# 1.1 Определяем основной WAN-интерфейс
detected_wan=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
[[ -z "$detected_wan" ]] && detected_wan=$(ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}')
[[ -z "$detected_wan" ]] && detected_wan="ens3"

read -e -p "🌐 Основной WAN-интерфейс: " -i "$detected_wan" WAN_IF

# 1.2 Определяем второй (локальный) интерфейс, если он есть
detected_lan=$(ip -o link show | awk -F': ' -v wan="$WAN_IF" '$2 != "lo" && $2 != wan && $2 !~ /^(wg|tun|tap|docker|veth|br-)/ {print $2; exit}')

# 1.3 Собираем текущие IPv4 (ВМЕСТЕ С МАСКОЙ!) на WAN-интерфейсе
mapfile -t current_cidrs < <(ip -4 -o addr show dev "$WAN_IF" scope global | awk '{print $4}')

# Определяем реальный текущий исходящий IP (по маршруту до 1.1.1.1)
active_exit_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' || true)

# Определяем текущий IPv4 шлюз по умолчанию
detected_gw4=$(ip -4 route show default dev "$WAN_IF" | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}')
if [[ -z "$detected_gw4" ]]; then
    detected_gw4=$(ip -4 route show table all default dev "$WAN_IF" | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}')
fi

# Определяем IPv6 адрес и шлюз
current_ipv6=$(ip -6 -o addr show dev "$WAN_IF" scope global | awk '{print $4}' | head -n 1)
detected_gw6=$(ip -6 route show default dev "$WAN_IF" | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}')
[[ -z "$detected_gw6" ]] && detected_gw6="fe80::1"

# 1.4 Формируем слоты для меню (1 - Основной, 2 - Дополнительный)
slot1_cidr="${current_cidrs[0]:-}"
slot2_cidr="${current_cidrs[1]:-}"

echo -e "\n📊 ${C_CYAN}Текущая картина на интерфейсе ${C_BOLD}${WAN_IF}${C_RESET}${C_CYAN}:${C_RESET}"
if [[ -n "$slot1_cidr" ]]; then
    s1_pure=$(strip_mask "$slot1_cidr")
    s1_tag=""
    [[ "$s1_pure" == "$active_exit_ip" ]] && s1_tag=" ${C_GREEN}[АКТИВНЫЙ ВЫХОД / ОСНОВНОЙ]${C_RESET}"
    echo -e "   ${C_BOLD}1)${C_RESET} $slot1_cidr$s1_tag"
else
    echo -e "   ${C_BOLD}1)${C_RESET} [Не обнаружен]"
fi

if [[ -n "$slot2_cidr" ]]; then
    s2_pure=$(strip_mask "$slot2_cidr")
    s2_tag=" ${C_ORANGE}[ДОПОЛНИТЕЛЬНЫЙ / ВХОД]${C_RESET}"
    [[ "$s2_pure" == "$active_exit_ip" ]] && s2_tag=" ${C_GREEN}[АКТИВНЫЙ ВЫХОД / ОСНОВНОЙ]${C_RESET}"
    echo -e "   ${C_BOLD}2)${C_RESET} $slot2_cidr$s2_tag"
else
    echo -e "   ${C_BOLD}2)${C_RESET} [Не задан — сейчас режим 1 IP]"
fi
echo "--------------------------------------------------------------------------------"

# ==============================================================================
# 2. ИНТЕРВЬЮ И ВЫБОР РОЛЕЙ IP
# ==============================================================================

# --- 2.1 ВЫБОР ГЛАВНОГО IP (ВЫХОД ТРАФИКА + ВХОД ПО СТАРОМУ DNS) ---
echo -e "\n🔵 ${C_BLUE}[ГЛАВНЫЙ IP — Выход трафика (Metric 50) + Прием входящих]${C_RESET}"
echo -e "   Выбери, какой адрес сделать ${C_BOLD}ОСНОВНЫМ (исходящим)${C_RESET}:"
[[ -n "$slot1_cidr" ]] && echo -e "     ${C_BOLD}1)${C_RESET} Оставить 1-й IP: ${C_BOLD}${slot1_cidr}${C_RESET}"
[[ -n "$slot2_cidr" ]] && echo -e "     ${C_BOLD}2)${C_RESET} Сделать основным 2-й IP (Ротация): ${C_BOLD}${slot2_cidr}${C_RESET}"
echo -e "     ${C_BOLD}3)${C_RESET} Указать другой IP вручную"

def_main_choice="1"
[[ -z "$slot1_cidr" ]] && def_main_choice="3"

while true; do
    read -e -p "   👉 Твой выбор [1/2/3]: " -i "$def_main_choice" main_choice
    case "$main_choice" in
        1)
            if [[ -n "$slot1_cidr" ]]; then
                ip_main_input="$slot1_cidr"
                break
            else
                echo -e "   ${C_RED}⚠️ 1-й IP не найден. Выбери 3 для ручного ввода.${C_RESET}"
            fi
            ;;
        2)
            if [[ -n "$slot2_cidr" ]]; then
                ip_main_input="$slot2_cidr"
                break
            else
                echo -e "   ${C_RED}⚠️ 2-й IP сейчас не настроен. Выбери 1 или 3.${C_RESET}"
            fi
            ;;
        3)
            read -e -p "   Введи новый Главный IP (например, 1.2.3.4/24): " ip_main_input
            [[ -n "$ip_main_input" ]] && break
            echo -e "   ${C_RED}⚠️ Главный IP не может быть пустым!${C_RESET}"
            ;;
        *)
            echo -e "   ${C_RED}⚠️ Введи цифру 1, 2 или 3.${C_RESET}"
            ;;
    esac
done

ip_main_input=$(ensure_mask "$ip_main_input" "24")
read -e -p "   Проверь Главный IP/маску: " -i "$ip_main_input" ip_main_input
ip_main_input=$(ensure_mask "$ip_main_input" "24")
ip_main_pure=$(strip_mask "$ip_main_input")

gw_main_def="${detected_gw4:-$(calc_gw "$ip_main_pure")}"
read -e -p "   Шлюз для Главного IP:     " -i "$gw_main_def" gw_main


# --- 2.2 ВЫБОР ВТОРОГО IP (ОСНОВНОЙ ВХОД КЛИЕНТОВ VPN) ---
echo -e "\n🟠 ${C_ORANGE}[ВТОРОЙ IP — Вход клиентов VPN (Metric 200)]${C_RESET}"
echo -e "   Выбери, какой адрес сделать ${C_BOLD}ДОПОЛНИТЕЛЬНЫМ (входящим)${C_RESET}:"
[[ -n "$slot1_cidr" ]] && echo -e "     ${C_BOLD}1)${C_RESET} Использовать 1-й IP: ${C_BOLD}${slot1_cidr}${C_RESET}"
[[ -n "$slot2_cidr" ]] && echo -e "     ${C_BOLD}2)${C_RESET} Использовать 2-й IP: ${C_BOLD}${slot2_cidr}${C_RESET}"
echo -e "     ${C_BOLD}3)${C_RESET} Указать другой IP вручную"
echo -e "     ${C_BOLD}0)${C_RESET} ${C_RED}Отказаться от 2-го IP (Режим одного IP / Single-IP)${C_RESET}"

if [[ "$main_choice" == "1" && -n "$slot2_cidr" ]]; then
    def_sec_choice="2"
elif [[ "$main_choice" == "2" && -n "$slot1_cidr" ]]; then
    def_sec_choice="1"
else
    def_sec_choice="0"
fi

ip_sec_input=""
ip_sec_pure=""
gw_sec=""

while true; do
    read -e -p "   👉 Твой выбор [1/2/3/0]: " -i "$def_sec_choice" sec_choice
    case "$sec_choice" in
        0|"")
            ip_sec_input=""
            echo -e "   ℹ️  Второй IP отключен. Будет настроен режим ${C_BOLD}Single-IP${C_RESET}."
            break
            ;;
        1)
            if [[ -n "$slot1_cidr" ]]; then
                ip_sec_input="$slot1_cidr"
            else
                echo -e "   ${C_RED}⚠️ 1-й IP не найден.${C_RESET}"
                continue
            fi
            ;;
        2)
            if [[ -n "$slot2_cidr" ]]; then
                ip_sec_input="$slot2_cidr"
            else
                echo -e "   ${C_RED}⚠️ 2-й IP не найден. Выбери 3 для ввода нового или 0 для отказа.${C_RESET}"
                continue
            fi
            ;;
        3)
            read -e -p "   Введи Второй IP (например, 1.2.3.5/24): " ip_sec_input
            if [[ -z "$ip_sec_input" ]]; then
                echo -e "   ℹ️  Ввод пустой — перехожу в режим Single-IP."
                break
            fi
            ;;
        *)
            echo -e "   ${C_RED}⚠️ Введи цифру 1, 2, 3 или 0.${C_RESET}"
            continue
            ;;
    esac

    candidate_pure=$(strip_mask "$ip_sec_input")
    if [[ "$candidate_pure" == "$ip_main_pure" ]]; then
        echo -e "   ${C_RED}🚫 Ошибка: Второй IP ($candidate_pure) совпадает с Главным IP! Выбери другой вариант или 0.${C_RESET}"
    else
        break
    fi
done

if [[ -n "$ip_sec_input" ]]; then
    ip_sec_input=$(ensure_mask "$ip_sec_input" "24")
    read -e -p "   Проверь Второй IP/маску:  " -i "$ip_sec_input" ip_sec_input
    ip_sec_input=$(ensure_mask "$ip_sec_input" "24")
    ip_sec_pure=$(strip_mask "$ip_sec_input")

    main_prefix=$(echo "$ip_main_pure" | cut -d. -f1-3)
    sec_prefix=$(echo "$ip_sec_pure" | cut -d. -f1-3)
    if [[ "$main_prefix" == "$sec_prefix" ]]; then
        gw_sec_def="$gw_main"
    else
        gw_sec_def=$(calc_gw "$ip_sec_pure")
    fi
    read -e -p "   Шлюз для Второго IP:      " -i "$gw_sec_def" gw_sec
fi


# --- 2.3 ПРОЧИЕ НАСТРОЙКИ (IPv6 & LAN) ---
echo -e "\n⚪ ${C_BOLD}[ДОПОЛНИТЕЛЬНЫЕ ИНТЕРФЕЙСЫ И IPv6]${C_RESET}"
read -e -p "   IPv6 адрес ($WAN_IF, Enter чтобы отключить): " -i "$current_ipv6" ipv6_input
if [[ -n "$ipv6_input" ]]; then
    ipv6_input=$(ensure_mask "$ipv6_input" "64")
    read -e -p "   IPv6 шлюз ($WAN_IF):                         " -i "$detected_gw6" gw_ipv6
fi

lan_ip_input=""
LAN_IF=""
if [[ -n "$detected_lan" ]]; then
    current_lan_ip=$(ip -4 -o addr show dev "$detected_lan" scope global | awk '{print $4}' | head -n 1)
    read -e -p "   Локальный интерфейс ($detected_lan) IPv4 (Enter — пропустить): " -i "$current_lan_ip" lan_ip_input
    if [[ -n "$lan_ip_input" ]]; then
        LAN_IF="$detected_lan"
        lan_ip_input=$(ensure_mask "$lan_ip_input" "16")
    fi
fi

ipv4_count=1
[[ -n "$ip_sec_input" ]] && ipv4_count=2

# ==============================================================================
# 3. БЭКАП И ГЕНЕРАЦИЯ КОНФИГУРАЦИИ
# ==============================================================================

mkdir -p "$BACKUP_DIR"
if compgen -G "/etc/netplan/*.yaml" > /dev/null; then
    cp -a /etc/netplan/*.yaml "$BACKUP_DIR"/
    rm -f /etc/netplan/*.yaml
fi

{
    echo "network:"
    echo "  version: 2"
    echo "  renderer: networkd"
    echo "  ethernets:"
    echo "    $WAN_IF:"

    # 3.1 Адреса
    echo "      addresses:"
    echo "        - \"$ip_main_input\""
    [[ -n "$ip_sec_input" ]] && echo "        - \"$ip_sec_input\""
    [[ -n "$ipv6_input" ]]   && echo "        - \"$ipv6_input\""

    # 3.2 DNS
    echo "      nameservers:"
    echo "        addresses:"
    echo "          - 1.1.1.1"
    echo "          - 8.8.8.8"
    echo "          - 9.9.9.9"
    echo "          - 149.112.112.112"
    if [[ -n "$ipv6_input" ]]; then
        echo "          - \"2606:4700:4700::1111\""
        echo "          - \"2001:4860:4860::8888\""
    fi

    # 3.3 Маршруты (SMART ROUTING + PREFSRC + SYMMETRIC INPUT)
    echo "      routes:"
    # Главный маршрут (Таблица main, Приоритет 50 — весь исходящий трафик идет отсюда)
    echo "        - to: 0.0.0.0/0"
    echo "          via: $gw_main"
    echo "          from: $ip_main_pure"
    echo "          metric: 50"
    echo "          on-link: true"

    if [[ $ipv4_count -eq 2 ]]; then
        # Второй маршрут в таблице main (Приоритет 200 — для видимости в main и отказоустойчивости)
        echo "        - to: 0.0.0.0/0"
        echo "          via: $gw_sec"
        echo "          from: $ip_sec_pure"
        echo "          metric: 200"
        echo "          on-link: true"

        # Изолированная таблица 100: гарантирует, что клиенты со СТАРЫМ DNS (стучащиеся на Главный IP)
        # получат ответ строго с Главного IP
        echo "        - to: 0.0.0.0/0"
        echo "          via: $gw_main"
        echo "          from: $ip_main_pure"
        echo "          table: 100"
        echo "          on-link: true"

        # Изолированная таблица 101: гарантирует, что клиенты с НОВЫМ DNS (стучащиеся на Второй IP)
        # получат ответ строго со Второго IP
        echo "        - to: 0.0.0.0/0"
        echo "          via: $gw_sec"
        echo "          from: $ip_sec_pure"
        echo "          table: 101"
        echo "          on-link: true"
    fi

    if [[ -n "$ipv6_input" ]]; then
        echo "        - to: \"::/0\""
        echo "          via: \"$gw_ipv6\""
        echo "          on-link: true"
    fi

    # 3.4 Политики PBR (обеспечивают одновременный прием входящих на оба IP)
    if [[ $ipv4_count -eq 2 ]]; then
        echo "      routing-policy:"
        echo "        - from: $ip_main_pure"
        echo "          table: 100"
        echo "          priority: 100"
        echo "        - from: $ip_sec_pure"
        echo "          table: 101"
        echo "          priority: 101"
    fi

    # 3.5 Локальный интерфейс (если задан)
    if [[ -n "$LAN_IF" && -n "$lan_ip_input" ]]; then
        echo "    $LAN_IF:"
        echo "      addresses:"
        echo "        - \"$lan_ip_input\""
    fi

} > "$CONFIG_FILE"

chmod 600 "$CONFIG_FILE"

# ==============================================================================
# 4. ПРОВЕРКА, SYSCTL И ПРИМЕНЕНИЕ
# ==============================================================================

echo -e "\n📄 Проверяю синтаксис сгенерированного файла..."
netplan generate || restore_and_exit

# Постоянная настройка rp_filter=2 (переживает перезагрузку сервера!)
if [[ $ipv4_count -eq 2 ]]; then
    cat <<EOF > "$SYSCTL_FILE"
# Alchemist Multi-IP PBR Routing Settings (Persistent across reboots)
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.${WAN_IF}.rp_filter = 2
EOF
    sysctl --system >/dev/null 2>&1 || true
else
    rm -f "$SYSCTL_FILE"
    sysctl --system >/dev/null 2>&1 || true
fi

echo -e "\n${C_GREEN}✅ Конфигурация валидна! Сводка перед применением:${C_RESET}"
echo "--------------------------------------------------------------------------------"
echo -e "Интерфейс WAN:          ${C_BOLD}$WAN_IF${C_RESET}"
echo -e "Главный IP (Выход+Вход):${C_BLUE} $ip_main_input${C_RESET} (via $gw_main, metric 50, Table 100)"
if [[ $ipv4_count -eq 2 ]]; then
    echo -e "Второй IP (Вход VPN):   ${C_ORANGE}$ip_sec_input${C_RESET} (via $gw_sec, metric 200, Table 101)"
    echo -e "Режим маршрутизации:    ${C_GREEN}АКТИВЕН PBR (Оба IP работают на вход, выход с Главного)${C_RESET}"
else
    echo -e "Второй IP (Вход VPN):   ОТКЛЮЧЕН"
    echo -e "Режим маршрутизации:    ${C_CYAN}СТАНДАРТНЫЙ (Single-IP)${C_RESET}"
fi
echo -e "Бэкап старых конфигов:  $BACKUP_DIR"
echo "--------------------------------------------------------------------------------"
echo -e "${C_ORANGE}⏳ Запускаю 'netplan try'. Нажми ENTER, чтобы подтвердить настройки!${C_RESET}"

if ! netplan try; then
    restore_and_exit
fi

# Сброс старых привязок NAT в conntrack (если установлен conntrack), чтобы трафик сразу пошел с нового IP
if command -v conntrack >/dev/null 2>&1; then
    conntrack -F >/dev/null 2>&1 || true
fi

echo -e "\n${C_GREEN}🚀 Сеть успешно перестроена! Текущий исходящий IP сервера:${C_RESET}"
ip -4 route get 1.1.1.1 | head -n 1
