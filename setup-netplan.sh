#!/bin/bash

# ==============================================================================
# 🏴‍☠️ ALCHEMIST NETPLAN CONFIGURATOR v11.0 MASTER
# Smart PBR, Entry/Exit IP Split, Clean IPv6/LAN Control & Backup Manager
# Target OS: Ubuntu 22.04 / 24.04 LTS (systemd-networkd)
# ==============================================================================

set -u

# Гарантируем интерактивный ввод с терминала даже при запуске через curl | bash
if [[ ! -t 0 ]] && [[ -e /dev/tty ]]; then
    exec < /dev/tty
fi

# --- Константы и пути ---
SCRIPT_VERSION="11.0"
SCRIPT_URL="https://raw.githubusercontent.com/loevskiy/ubuntu-scripts/refs/heads/main/setup-netplan.sh"
INSTALL_PATH="/usr/local/bin/netcfg"
BACKUP_ROOT="/etc/netplan/backups"
MAX_BACKUPS=15
CONFIG_FILE="/etc/netplan/01-netcfg.yaml"
SYSCTL_FILE="/etc/sysctl.d/99-alchemist-pbr.conf"
CLOUD_INIT_DISABLE="/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"
GAI_CONF="/etc/gai.conf"

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
    echo -e "${C_RED}🚫 Ошибка: Запускай скрипт строго из-под root (sudo netcfg).${C_RESET}"
    exit 1
fi

# ==============================================================================
# БАЗОВЫЕ УТИЛИТЫ И ВАЛИДАТОРЫ
# ==============================================================================

# Очистка строки от пробелов, табуляций и символов \r (защита от вставки через VNC)
sanitize_input() {
    echo "${1:-}" | tr -d '[:space:]\r'
}

calc_gw() {
    echo "$1" | awk -F. '{print $1"."$2"."$3".1"}'
}

strip_mask() {
    echo "$1" | cut -d'/' -f1
}

ensure_mask() {
    local ip
    ip=$(sanitize_input "$1")
    local def_mask="${2:-24}"
    if [[ -n "$ip" && "$ip" != *"/"* ]]; then
        echo "${ip}/${def_mask}"
    else
        echo "$ip"
    fi
}

# Проверка корректности IPv4 (с маской или без)
is_valid_ipv4() {
    local ip_cidr="$1"
    local ip_part mask_part
    ip_part=$(strip_mask "$ip_cidr")
    if [[ "$ip_cidr" == *"/"* ]]; then
        mask_part="${ip_cidr#*/}"
        [[ "$mask_part" =~ ^[0-9]+$ ]] && (( mask_part >= 1 && mask_part <= 32 )) || return 1
    fi
    if [[ "$ip_part" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        read -r -a octets <<< "$ip_part"
        for o in "${octets[@]}"; do
            (( o >= 0 && o <= 255 )) || return 1
        done
        return 0
    fi
    return 1
}

# Проверка базовой корректности IPv6 (с маской или без)
is_valid_ipv6() {
    local ip6_cidr="$1"
    local ip6_part mask_part
    ip6_part=$(strip_mask "$ip6_cidr")
    if [[ "$ip6_cidr" == *"/"* ]]; then
        mask_part="${ip6_cidr#*/}"
        [[ "$mask_part" =~ ^[0-9]+$ ]] && (( mask_part >= 1 && mask_part <= 128 )) || return 1
    fi
    [[ "$ip6_part" == *":"* ]] && [[ "$ip6_part" =~ ^[0-9a-fA-F:]+$ ]] && return 0
    return 1
}

# --- Автоустановка скрипта в /usr/local/bin/netcfg ---
ensure_local_install() {
    if [[ "$0" != "$INSTALL_PATH" ]]; then
        if [[ -f "$0" && "$0" != *bash* ]]; then
            cp -f "$0" "$INSTALL_PATH" 2>/dev/null && chmod +x "$INSTALL_PATH"
        elif [[ ! -f "$INSTALL_PATH" ]]; then
            if curl -fsSL --connect-timeout 5 "$SCRIPT_URL" -o "${INSTALL_PATH}.tmp" 2>/dev/null; then
                if head -n 1 "${INSTALL_PATH}.tmp" | grep -q "#!/bin/bash"; then
                    mv -f "${INSTALL_PATH}.tmp" "$INSTALL_PATH"
                    chmod +x "$INSTALL_PATH"
                else
                    rm -f "${INSTALL_PATH}.tmp"
                fi
            fi
        fi
    fi
}

# --- Блокировка перезаписи сети со стороны cloud-init при ребуте ---
disable_cloud_init_net() {
    if [[ -d "/etc/cloud/cloud.cfg.d" ]] && [[ ! -f "$CLOUD_INIT_DISABLE" ]]; then
        echo "network: {config: disabled}" > "$CLOUD_INIT_DISABLE"
    fi
}

# --- Проверка и переключение опционального приоритета IPv4 в /etc/gai.conf ---
check_ipv4_priority() {
    if [[ -f "$GAI_CONF" ]] && grep -qE "^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100" "$GAI_CONF"; then
        return 0 # Принудительный IPv4 включен
    else
        return 1 # Нативный Dual-Stack (по умолчанию)
    fi
}

set_ipv4_priority() {
    local mode="$1"
    [[ ! -f "$GAI_CONF" ]] && touch "$GAI_CONF"
    if [[ "$mode" == "enable" ]]; then
        if ! check_ipv4_priority; then
            sed -i '/^[[:space:]]*precedence[[:space:]]\+::ffff:0:0\/96[[:space:]]\+100/d' "$GAI_CONF" 2>/dev/null || true
            echo "precedence ::ffff:0:0/96  100" >> "$GAI_CONF"
        fi
    else
        sed -i '/^[[:space:]]*precedence[[:space:]]\+::ffff:0:0\/96[[:space:]]\+100/d' "$GAI_CONF" 2>/dev/null || true
    fi
}

# --- Очистка таблиц и правил PBR в ядре ---
clean_kernel_pbr_state() {
    while ip -4 rule del priority 100 2>/dev/null; do :; done
    while ip -4 rule del priority 101 2>/dev/null; do :; done
    ip -4 route flush table 100 2>/dev/null || true
    ip -4 route flush table 101 2>/dev/null || true
}

# --- Ротация старых бэкапов (оставляем последние MAX_BACKUPS) ---
prune_old_backups() {
    if [[ -d "$BACKUP_ROOT" ]]; then
        mapfile -t all_baks < <(ls -1dt "${BACKUP_ROOT}"/bak_* 2>/dev/null)
        if (( ${#all_baks[@]} > MAX_BACKUPS )); then
            for (( i=MAX_BACKUPS; i<${#all_baks[@]}; i++ )); do
                rm -rf "${all_baks[$i]}"
            done
        fi
    fi
}

# --- Упорядочивание текущих IP: Слот 1 = всегда Главный (Выход), Слот 2 = Второй (Вход) ---
SLOT1_CIDR=""
SLOT2_CIDR=""
ACTIVE_EXIT_IP=""

get_ordered_slots() {
    local iface="$1"
    SLOT1_CIDR=""
    SLOT2_CIDR=""
    ACTIVE_EXIT_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' || true)

    mapfile -t raw_cidrs < <(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4}')
    if [[ ${#raw_cidrs[@]} -eq 0 ]]; then
        return
    elif [[ ${#raw_cidrs[@]} -eq 1 ]]; then
        SLOT1_CIDR="${raw_cidrs[0]}"
        return
    fi

    local c pure
    for c in "${raw_cidrs[@]}"; do
        pure=$(strip_mask "$c")
        if [[ "$pure" == "$ACTIVE_EXIT_IP" && -z "$SLOT1_CIDR" ]]; then
            SLOT1_CIDR="$c"
        elif [[ -z "$SLOT2_CIDR" ]]; then
            SLOT2_CIDR="$c"
        fi
    done

    if [[ -z "$SLOT1_CIDR" ]]; then
        SLOT1_CIDR="${raw_cidrs[0]}"
        SLOT2_CIDR="${raw_cidrs[1]:-}"
    fi
}

# --- Применение конкретного бэкапа ---
apply_backup_dir() {
    local b_dir="$1"
    if [[ ! -d "$b_dir" ]] || ! compgen -G "$b_dir/*.yaml" > /dev/null; then
        echo -e "${C_RED}⚠️ В папке $b_dir не найдены файлы .yaml!${C_RESET}"
        return 1
    fi

    echo -e "${C_CYAN}🔄 Восстанавливаю конфигурацию из: $(basename "$b_dir")...${C_RESET}"
    rm -f /etc/netplan/*.yaml
    cp -a "$b_dir"/*.yaml /etc/netplan/
    chmod 600 /etc/netplan/*.yaml 2>/dev/null

    if grep -q "routing-policy:" /etc/netplan/*.yaml 2>/dev/null; then
        cat <<EOF > "$SYSCTL_FILE"
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
EOF
    else
        rm -f "$SYSCTL_FILE"
    fi
    sysctl --system >/dev/null 2>&1 || true

    clean_kernel_pbr_state
    if netplan apply 2>/dev/null; then
        if command -v conntrack >/dev/null 2>&1; then
            conntrack -F >/dev/null 2>&1 || true
        fi
        echo -e "${C_GREEN}✅ Конфигурация успешно восстановлена и применена к сети!${C_RESET}"
        echo -e "Текущий активный выход IPv4: $(ip -4 route get 1.1.1.1 2>/dev/null | head -n 1)"
        return 0
    else
        echo -e "${C_RED}❌ Ошибка при выполнении netplan apply! Проверь /etc/netplan/ вручную.${C_RESET}"
        return 1
    fi
}

# --- Аварийный перехватчик (HUP, INT, TERM или сбой netplan try) ---
ACTIVE_BACKUP_DIR=""
restore_and_exit() {
    trap - HUP INT TERM
    echo -e "\n${C_RED}💥 ОБНАРУЖЕНА ОШИБКА ИЛИ ОТМЕНА! Выполняю полный откат сети...${C_RESET}"
    if [[ -n "$ACTIVE_BACKUP_DIR" && -d "$ACTIVE_BACKUP_DIR" ]]; then
        apply_backup_dir "$ACTIVE_BACKUP_DIR"
    else
        echo -e "${C_ORANGE}⚠️ Активный бэкап сессии не найден. Воспользуйся пунктом 2 в меню.${C_RESET}"
    fi
    exit 1
}

# ==============================================================================
# МОДУЛЬ 1: НАСТРОЙКА И РОТАЦИЯ СЕТИ
# ==============================================================================
run_network_configurator() {
    echo -e "\n${C_BOLD}⚙️  МАСТЕР НАСТРОЙКИ И РОТАЦИИ IP${C_RESET}"
    echo "--------------------------------------------------------------------------------"

    # 1. Определение и запрос основного WAN-интерфейса
    local detected_wan
    detected_wan=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [[ -z "$detected_wan" ]] && detected_wan=$(ip -o link show | awk -F': ' '$2 != "lo" && $2 !~ /^(wg|tun|tap|docker|veth|br-)/ {print $2; exit}')
    [[ -z "$detected_wan" ]] && detected_wan="ens3"

    local WAN_IF=""
    while true; do
        read -e -p "🌐 Имя основного WAN-интерфейса: " -i "$detected_wan" WAN_IF
        WAN_IF=$(sanitize_input "$WAN_IF")
        if [[ -z "$WAN_IF" || "$WAN_IF" == "lo" ]]; then
            echo -e "   ${C_RED}⚠️ Некорректное имя интерфейса!${C_RESET}"
            continue
        fi
        if [[ ! -d "/sys/class/net/$WAN_IF" ]]; then
            echo -e "   ${C_ORANGE}⚠️ Интерфейс '$WAN_IF' сейчас не найден в системе.${C_RESET}"
            local confirm_wan=""
            read -e -p "   Все равно использовать '$WAN_IF'? [y/N]: " confirm_wan
            [[ "$confirm_wan" =~ ^[Yy]$ ]] && break
        else
            break
        fi
    done

    # Получаем строго упорядоченные слоты: 1 = Текущий Основной (Выход), 2 = Дополнительный (Вход)
    get_ordered_slots "$WAN_IF"
    local slot1_cidr="$SLOT1_CIDR"
    local slot2_cidr="$SLOT2_CIDR"
    local slot1_pure="" slot2_pure=""
    [[ -n "$slot1_cidr" ]] && slot1_pure=$(strip_mask "$slot1_cidr")
    [[ -n "$slot2_cidr" ]] && slot2_pure=$(strip_mask "$slot2_cidr")

    local detected_gw4
    detected_gw4=$(ip -4 route show default dev "$WAN_IF" | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}')
    if [[ -z "$detected_gw4" ]]; then
        detected_gw4=$(ip -4 route show table all default dev "$WAN_IF" | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}')
    fi

    local current_ipv6 detected_gw6
    current_ipv6=$(ip -6 -o addr show dev "$WAN_IF" scope global 2>/dev/null | awk '{print $4}' | head -n 1)
    detected_gw6=$(ip -6 route show default dev "$WAN_IF" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}')
    [[ -z "$detected_gw6" ]] && detected_gw6="fe80::1"

    # ==========================================================================
    # ШАГ 1: ВЫБОР ГЛАВНОГО IP (ВЫХОД + ВХОД)
    # ==========================================================================
    echo -e "\n🔵 ${C_BLUE}[ШАГ 1/4: ГЛАВНЫЙ IPv4 — Исходящий трафик (Metric 50) + Прием входящих]${C_RESET}"
    echo -e "   Выбери, какой адрес сделать ${C_BOLD}ОСНОВНЫМ (исходящим)${C_RESET}:"
    [[ -n "$slot1_cidr" ]] && echo -e "     ${C_BOLD}1)${C_RESET} Текущий Основной IP:       ${C_GREEN}${slot1_cidr}${C_RESET}"
    [[ -n "$slot2_cidr" ]] && echo -e "     ${C_BOLD}2)${C_RESET} Текущий Дополнительный IP: ${C_ORANGE}${slot2_cidr}${C_RESET} (Выбери 2 для ротации)"
    echo -e "     ${C_BOLD}3)${C_RESET} Указать другой IP вручную"

    local def_main_choice="1"
    [[ -z "$slot1_cidr" ]] && def_main_choice="3"

    local main_choice="" ip_main_input="" ip_main_pure="" gw_main_def="" gw_main=""
    while true; do
        read -e -p "   👉 Твой выбор [1/2/3]: " -i "$def_main_choice" main_choice
        main_choice=$(sanitize_input "$main_choice")
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
                ip_main_input=$(ensure_mask "$ip_main_input" "24")
                if is_valid_ipv4 "$ip_main_input"; then
                    break
                else
                    echo -e "   ${C_RED}⚠️ Некорректный формат IPv4! Попробуй снова.${C_RESET}"
                fi
                ;;
            *)
                echo -e "   ${C_RED}⚠️ Введи цифру 1, 2 или 3.${C_RESET}"
                ;;
        esac
    done

    while true; do
        ip_main_input=$(ensure_mask "$ip_main_input" "24")
        read -e -p "   Подтверди Главный IP/маску: " -i "$ip_main_input" ip_main_input
        ip_main_input=$(ensure_mask "$ip_main_input" "24")
        if is_valid_ipv4 "$ip_main_input"; then
            break
        fi
        echo -e "   ${C_RED}⚠️ Ошибка в записи IP/маски! Формат: X.X.X.X/24${C_RESET}"
    done
    ip_main_pure=$(strip_mask "$ip_main_input")

    gw_main_def="${detected_gw4:-$(calc_gw "$ip_main_pure")}"
    while true; do
        read -e -p "   Шлюз для Главного IP:       " -i "$gw_main_def" gw_main
        gw_main=$(sanitize_input "$gw_main")
        if is_valid_ipv4 "$gw_main" && [[ "$gw_main" != *"/"* ]]; then
            break
        fi
        echo -e "   ${C_RED}⚠️ Некорректный IPv4 адрес шлюза (укажи без маски)!${C_RESET}"
    done

    # ==========================================================================
    # ШАГ 2: ВЫБОР ВТОРОГО IP (С ТРЕХУРОВНЕВОЙ ЗАЩИТОЙ ОТ ДУБЛИКАТА)
    # ==========================================================================
    echo -e "\n🟠 ${C_ORANGE}[ШАГ 2/4: ВТОРОЙ IPv4 — Вход клиентов VPN (Metric 200)]${C_RESET}"
    echo -e "   Выбери, какой адрес сделать ${C_BOLD}ДОПОЛНИТЕЛЬНЫМ (входящим)${C_RESET}:"

    if [[ -n "$slot1_cidr" ]]; then
        if [[ "$slot1_pure" == "$ip_main_pure" ]]; then
            echo -e "     ${C_BOLD}1)${C_RESET} 1-й IP (${slot1_cidr}) — ${C_RED}[УЖЕ ВЫБРАН ГЛАВНЫМ — НЕДОСТУПЕН]${C_RESET}"
        else
            echo -e "     ${C_BOLD}1)${C_RESET} Использовать 1-й IP: ${C_BOLD}${slot1_cidr}${C_RESET}"
        fi
    fi

    if [[ -n "$slot2_cidr" ]]; then
        if [[ "$slot2_pure" == "$ip_main_pure" ]]; then
            echo -e "     ${C_BOLD}2)${C_RESET} 2-й IP (${slot2_cidr}) — ${C_RED}[УЖЕ ВЫБРАН ГЛАВНЫМ — НЕДОСТУПЕН]${C_RESET}"
        else
            echo -e "     ${C_BOLD}2)${C_RESET} Использовать 2-й IP: ${C_BOLD}${slot2_cidr}${C_RESET}"
        fi
    fi

    echo -e "     ${C_BOLD}3)${C_RESET} Указать другой IP вручную"
    echo -e "     ${C_BOLD}0)${C_RESET} ${C_RED}Отказаться от 2-го IP (Режим одного IP / Single-IP)${C_RESET}"

    # Автоматический выбор свободного слота по умолчанию
    local def_sec_choice="0"
    if [[ -n "$slot2_cidr" && "$slot2_pure" != "$ip_main_pure" ]]; then
        def_sec_choice="2"
    elif [[ -n "$slot1_cidr" && "$slot1_pure" != "$ip_main_pure" ]]; then
        def_sec_choice="1"
    fi

    local sec_choice="" ip_sec_input="" ip_sec_pure="" gw_sec="" gw_sec_def=""
    while true; do
        read -e -p "   👉 Твой выбор [1/2/3/0]: " -i "$def_sec_choice" sec_choice
        sec_choice=$(sanitize_input "$sec_choice")
        case "$sec_choice" in
            0|"")
                ip_sec_input=""
                echo -e "   ℹ️  Второй IP отключен. Будет настроен режим ${C_BOLD}Single-IP (только 1 IPv4)${C_RESET}."
                break
                ;;
            1)
                if [[ -z "$slot1_cidr" ]]; then
                    echo -e "   ${C_RED}⚠️ 1-й IP не найден.${C_RESET}"
                    continue
                fi
                ip_sec_input="$slot1_cidr"
                ;;
            2)
                if [[ -z "$slot2_cidr" ]]; then
                    echo -e "   ${C_RED}⚠️ 2-й IP не найден. Выбери 3 для ввода нового или 0 для отказа.${C_RESET}"
                    continue
                fi
                ip_sec_input="$slot2_cidr"
                ;;
            3)
                read -e -p "   Введи Второй IP (например, 1.2.3.5/24, или Enter для отказа): " ip_sec_input
                ip_sec_input=$(sanitize_input "$ip_sec_input")
                if [[ -z "$ip_sec_input" ]]; then
                    echo -e "   ℹ️  Ввод пустой — перехожу в режим Single-IP."
                    break
                fi
                ip_sec_input=$(ensure_mask "$ip_sec_input" "24")
                if ! is_valid_ipv4 "$ip_sec_input"; then
                    echo -e "   ${C_RED}⚠️ Некорректный формат IPv4!${C_RESET}"
                    continue
                fi
                ;;
            *)
                echo -e "   ${C_RED}⚠️ Введи цифру 1, 2, 3 или 0.${C_RESET}"
                continue
                ;;
        esac

        # Жесткая проверка на совпадение с Главным IP на этапе меню
        local candidate_pure
        candidate_pure=$(strip_mask "$ip_sec_input")
        if [[ "$candidate_pure" == "$ip_main_pure" ]]; then
            echo -e "   ${C_RED}🚫 Ошибка: Второй IP ($candidate_pure) совпадает с Главным IP ($ip_main_pure)! Нельзя назначить один и тот же адрес дважды. Выбери другой вариант или 0.${C_RESET}"
        else
            break
        fi
    done

    if [[ -n "$ip_sec_input" ]]; then
        # Жесткая проверка на совпадение с Главным IP И корректность маски на этапе подтверждения
        while true; do
            ip_sec_input=$(ensure_mask "$ip_sec_input" "24")
            read -e -p "   Подтверди Второй IP/маску:  " -i "$ip_sec_input" ip_sec_input
            ip_sec_input=$(ensure_mask "$ip_sec_input" "24")
            if ! is_valid_ipv4 "$ip_sec_input"; then
                echo -e "   ${C_RED}⚠️ Ошибка в записи IP/маски! Формат: X.X.X.X/24${C_RESET}"
                continue
            fi
            ip_sec_pure=$(strip_mask "$ip_sec_input")
            if [[ "$ip_sec_pure" == "$ip_main_pure" ]]; then
                echo -e "   ${C_RED}🚫 Ошибка: Второй IP ($ip_sec_pure) совпадает с Главным IP ($ip_main_pure)! Укажи другой адрес.${C_RESET}"
                continue
            fi
            break
        done

        local main_prefix sec_prefix
        main_prefix=$(echo "$ip_main_pure" | cut -d. -f1-3)
        sec_prefix=$(echo "$ip_sec_pure" | cut -d. -f1-3)
        if [[ "$main_prefix" == "$sec_prefix" ]]; then
            gw_sec_def="$gw_main"
        else
            gw_sec_def=$(calc_gw "$ip_sec_pure")
        fi

        while true; do
            read -e -p "   Шлюз для Второго IP:        " -i "$gw_sec_def" gw_sec
            gw_sec=$(sanitize_input "$gw_sec")
            if is_valid_ipv4 "$gw_sec" && [[ "$gw_sec" != *"/"* ]]; then
                break
            fi
            echo -e "   ${C_RED}⚠️ Некорректный IPv4 адрес шлюза (укажи без маски)!${C_RESET}"
        done
    fi

    # ==========================================================================
    # ШАГ 3: НАСТРОЙКА ИЛИ ОТКЛЮЧЕНИЕ IPv6 (ЯВНОЕ МЕНЮ)
    # ==========================================================================
    echo -e "\n⚪ ${C_BOLD}[ШАГ 3/4: НАСТРОЙКА IPv6 НА ИНТЕРФЕЙСЕ $WAN_IF]${C_RESET}"
    local ipv6_choice="" def_ipv6_choice="0" ipv6_input="" gw_ipv6=""

    if [[ -n "$current_ipv6" ]]; then
        echo -e "   Сейчас обнаружен IPv6: ${C_CYAN}${current_ipv6}${C_RESET}"
        echo -e "     ${C_BOLD}1)${C_RESET} Оставить / Изменить IPv6 адрес"
        echo -e "     ${C_BOLD}0)${C_RESET} ${C_RED}Удалить и не использовать IPv6 (Отключить IPv6)${C_RESET}"
        def_ipv6_choice="1"
    else
        echo -e "   Сейчас активный глобальный IPv6 не обнаружен."
        echo -e "     ${C_BOLD}1)${C_RESET} Добавить и настроить IPv6 вручную"
        echo -e "     ${C_BOLD}0)${C_RESET} ${C_CYAN}Не использовать IPv6 (Оставить отключенным)${C_RESET}"
        def_ipv6_choice="0"
    fi

    while true; do
        read -e -p "   👉 Твой выбор по IPv6 [1/0]: " -i "$def_ipv6_choice" ipv6_choice
        ipv6_choice=$(sanitize_input "$ipv6_choice")
        case "$ipv6_choice" in
            0|"")
                ipv6_input=""
                gw_ipv6=""
                echo -e "   ℹ️  IPv6 будет полностью отключен на интерфейсе $WAN_IF."
                break
                ;;
            1)
                while true; do
                    read -e -p "   Введи IPv6 адрес/маску: " -i "$current_ipv6" ipv6_input
                    ipv6_input=$(ensure_mask "$ipv6_input" "64")
                    if is_valid_ipv6 "$ipv6_input"; then
                        break
                    fi
                    echo -e "   ${C_RED}⚠️ Некорректный формат IPv6 (пример: 2a01:4f8:c0c::2/64)!${C_RESET}"
                done
                while true; do
                    read -e -p "   Введи IPv6 шлюз:        " -i "$detected_gw6" gw_ipv6
                    gw_ipv6=$(sanitize_input "$gw_ipv6")
                    if is_valid_ipv6 "$gw_ipv6" && [[ "$gw_ipv6" != *"/"* ]]; then
                        break
                    fi
                    echo -e "   ${C_RED}⚠️ Некорректный IPv6 шлюз (пример: fe80::1)!${C_RESET}"
                done
                break
                ;;
            *)
                echo -e "   ${C_RED}⚠️ Введи 1 (использовать IPv6) или 0 (отключить IPv6).${C_RESET}"
                ;;
        esac
    done

    # ==========================================================================
    # ШАГ 4: НАСТРОЙКА ИЛИ ОТКЛЮЧЕНИЕ ЛОКАЛЬНОЙ СЕТИ (С ЗАПРОСОМ ИМЕНИ ИНТЕРФЕЙСА)
    # ==========================================================================
    echo -e "\n🏠 ${C_BOLD}[ШАГ 4/4: ЛОКАЛЬНАЯ СЕТЬ (LAN / ВНУТРЕННИЙ ИНТЕРФЕЙС)]${C_RESET}"

    # Ищем все кандидаты на роль LAN-интерфейса
    local detected_lan="" current_lan_ip="" all_other_ifs=""
    detected_lan=$(ip -o link show | awk -F': ' -v wan="$WAN_IF" '$2 != "lo" && $2 != wan && $2 !~ /^(wg|tun|tap|docker|veth|br-)/ {print $2; exit}')
    all_other_ifs=$(ip -o link show | awk -F': ' -v wan="$WAN_IF" '$2 != "lo" && $2 != wan && $2 !~ /^(wg|tun|tap|docker|veth|br-)/ {print $2}' | tr '\n' ' ')

    if [[ -n "$detected_lan" ]]; then
        current_lan_ip=$(ip -4 -o addr show dev "$detected_lan" scope global 2>/dev/null | awk '{print $4}' | head -n 1)
    fi

    local lan_choice="" def_lan_choice="0" LAN_IF="" lan_ip_input=""
    if [[ -n "$detected_lan" && -n "$current_lan_ip" ]]; then
        echo -e "   Обнаружен локальный интерфейс ${C_CYAN}${detected_lan}${C_RESET} с адресом ${C_CYAN}${current_lan_ip}${C_RESET}"
        def_lan_choice="1"
    elif [[ -n "$all_other_ifs" ]]; then
        echo -e "   Дополнительные интерфейсы в системе: ${C_CYAN}${all_other_ifs}${C_RESET} (IP не назначен)"
        def_lan_choice="0"
    else
        echo -e "   Дополнительных физических интерфейсов сейчас не обнаружено."
        def_lan_choice="0"
    fi

    echo -e "     ${C_BOLD}1)${C_RESET} Настроить / Использовать локальную сеть (LAN)"
    echo -e "     ${C_BOLD}0)${C_RESET} ${C_RED}Не использовать / Удалить локальную сеть (Отключить LAN)${C_RESET}"

    while true; do
        read -e -p "   👉 Твой выбор по LAN [1/0]: " -i "$def_lan_choice" lan_choice
        lan_choice=$(sanitize_input "$lan_choice")
        case "$lan_choice" in
            0|"")
                LAN_IF=""
                lan_ip_input=""
                echo -e "   ℹ️  Локальная сеть (LAN) отключена и не будет добавлена в конфиг."
                break
                ;;
            1)
                # 1. Запрашиваем имя локального интерфейса
                local def_lan_if="${detected_lan:-ens6}"
                while true; do
                    read -e -p "   Имя интерфейса локальной сети (например, ens6, eth1): " -i "$def_lan_if" LAN_IF
                    LAN_IF=$(sanitize_input "$LAN_IF")
                    if [[ -z "$LAN_IF" || "$LAN_IF" == "lo" ]]; then
                        echo -e "   ${C_RED}⚠️ Имя интерфейса не может быть пустым или 'lo'!${C_RESET}"
                        continue
                    fi
                    if [[ "$LAN_IF" == "$WAN_IF" ]]; then
                        echo -e "   ${C_RED}🚫 Ошибка: Интерфейс '$LAN_IF' уже выбран как основной внешний (WAN)! Укажи другой интерфейс.${C_RESET}"
                        continue
                    fi
                    if [[ ! -d "/sys/class/net/$LAN_IF" ]]; then
                        echo -e "   ${C_ORANGE}⚠️ Внимание: интерфейс '$LAN_IF' сейчас не виден в системе.${C_RESET}"
                        local confirm_lan_if=""
                        read -e -p "   Все равно записать '$LAN_IF' в конфиг? [y/N]: " confirm_lan_if
                        [[ "$confirm_lan_if" =~ ^[Yy]$ ]] && break
                    else
                        # Если пользователь сменил имя интерфейса, подтянем текущий IP с выбранного интерфейса
                        current_lan_ip=$(ip -4 -o addr show dev "$LAN_IF" scope global 2>/dev/null | awk '{print $4}' | head -n 1)
                        break
                    fi
                done

                # 2. Запрашиваем локальный IPv4 и маску
                while true; do
                    read -e -p "   IPv4 адрес и маска для $LAN_IF (например, 10.0.0.2/16): " -i "$current_lan_ip" lan_ip_input
                    lan_ip_input=$(ensure_mask "$lan_ip_input" "16")
                    if ! is_valid_ipv4 "$lan_ip_input"; then
                        echo -e "   ${C_RED}⚠️ Некорректный формат IPv4/маски! Пример: 10.10.0.5/16${C_RESET}"
                        continue
                    fi
                    local lan_pure
                    lan_pure=$(strip_mask "$lan_ip_input")
                    if [[ "$lan_pure" == "$ip_main_pure" || ( -n "$ip_sec_pure" && "$lan_pure" == "$ip_sec_pure" ) ]]; then
                        echo -e "   ${C_RED}🚫 Ошибка: Локальный IP ($lan_pure) совпадает с внешним WAN IP!${C_RESET}"
                        continue
                    fi
                    break
                done
                break
                ;;
            *)
                echo -e "   ${C_RED}⚠️ Введи 1 (настроить LAN) или 0 (не использовать LAN).${C_RESET}"
                ;;
        esac
    done

    local ipv4_count=1
    [[ -n "$ip_sec_input" ]] && ipv4_count=2

    # ==========================================================================
    # БЭКАП И ГЕНЕРАЦИЯ НОВОГО ФАЙЛА NETPLAN
    # ==========================================================================
    disable_cloud_init_net
    ACTIVE_BACKUP_DIR="${BACKUP_ROOT}/bak_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$ACTIVE_BACKUP_DIR"
    if compgen -G "/etc/netplan/*.yaml" > /dev/null; then
        cp -a /etc/netplan/*.yaml "$ACTIVE_BACKUP_DIR"/
        rm -f /etc/netplan/*.yaml
    fi
    prune_old_backups

    trap 'restore_and_exit' HUP INT TERM

    {
        echo "network:"
        echo "  version: 2"
        echo "  renderer: networkd"
        echo "  ethernets:"
        echo "    $WAN_IF:"
        if [[ -n "$ipv6_input" ]]; then
            echo "      accept-ra: true"
        else
            echo "      accept-ra: false"
            echo "      link-local: []"
        fi

        echo "      addresses:"
        echo "        - \"$ip_main_input\""
        [[ -n "$ip_sec_input" ]] && echo "        - \"$ip_sec_input\""
        [[ -n "$ipv6_input" ]]   && echo "        - \"$ipv6_input\""

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

        echo "      routes:"
        # Главный исходящий маршрут IPv4 (Metric 50)
        echo "        - to: 0.0.0.0/0"
        echo "          via: $gw_main"
        echo "          from: $ip_main_pure"
        echo "          metric: 50"
        echo "          on-link: true"

        if [[ $ipv4_count -eq 2 ]]; then
            # Вспомогательный маршрут в main (Metric 200)
            echo "        - to: 0.0.0.0/0"
            echo "          via: $gw_sec"
            echo "          from: $ip_sec_pure"
            echo "          metric: 200"
            echo "          on-link: true"

            # Изолированная таблица 100 для симметричного ответа по Главному IP
            echo "        - to: 0.0.0.0/0"
            echo "          via: $gw_main"
            echo "          from: $ip_main_pure"
            echo "          table: 100"
            echo "          on-link: true"

            # Изолированная таблица 101 для симметричного ответа по Второму IP
            echo "        - to: 0.0.0.0/0"
            echo "          via: $gw_sec"
            echo "          from: $ip_sec_pure"
            echo "          table: 101"
            echo "          on-link: true"
        fi

        if [[ -n "$ipv6_input" ]]; then
            echo "        - to: \"::/0\""
            echo "          via: \"$gw_ipv6\""
            echo "          metric: 100"
            echo "          on-link: true"
        fi

        if [[ $ipv4_count -eq 2 ]]; then
            echo "      routing-policy:"
            echo "        - from: $ip_main_pure"
            echo "          table: 100"
            echo "          priority: 100"
            echo "        - from: $ip_sec_pure"
            echo "          table: 101"
            echo "          priority: 101"
        fi

        if [[ -n "$LAN_IF" && -n "$lan_ip_input" ]]; then
            echo "    $LAN_IF:"
            echo "      addresses:"
            echo "        - \"$lan_ip_input\""
        fi
    } > "$CONFIG_FILE"

    chmod 600 "$CONFIG_FILE"

    echo -e "\n📄 Проверяю синтаксис сгенерированного файла..."
    netplan generate || restore_and_exit

    # Настройка rp_filter=2 для корректной работы двух IP
    if [[ $ipv4_count -eq 2 ]]; then
        cat <<EOF > "$SYSCTL_FILE"
# Alchemist Multi-IP PBR Routing Settings
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
    echo -e "Главный IP (Выход+Вход):${C_BLUE} $ip_main_input${C_RESET} (via $gw_main, metric 50)"
    if [[ $ipv4_count -eq 2 ]]; then
        echo -e "Второй IP (Вход VPN):   ${C_ORANGE}$ip_sec_input${C_RESET} (via $gw_sec, metric 200)"
        echo -e "Режим маршрутизации:    ${C_GREEN}АКТИВЕН PBR (Table 100 & 101)${C_RESET}"
    else
        echo -e "Второй IP (Вход VPN):   ${C_RED}ОТКЛЮЧЕН (Режим 1 IPv4)${C_RESET}"
        echo -e "Режим маршрутизации:    ${C_CYAN}СТАНДАРТНЫЙ (Single-IP)${C_RESET}"
    fi
    if [[ -n "$ipv6_input" ]]; then
        echo -e "Статус IPv6 ($WAN_IF):     ${C_GREEN}$ipv6_input${C_RESET} (via $gw_ipv6)"
    else
        echo -e "Статус IPv6 ($WAN_IF):     ${C_RED}ОТКЛЮЧЕН${C_RESET}"
    fi
    if [[ -n "$LAN_IF" && -n "$lan_ip_input" ]]; then
        echo -e "Локальная сеть (LAN):   ${C_GREEN}$LAN_IF -> $lan_ip_input${C_RESET}"
    else
        echo -e "Локальная сеть (LAN):   ${C_RED}ОТКЛЮЧЕНА${C_RESET}"
    fi
    echo -e "Точка отката:           $ACTIVE_BACKUP_DIR"
    echo "--------------------------------------------------------------------------------"
    echo -e "${C_ORANGE}⏳ Запускаю 'netplan try'. Нажми ENTER, чтобы подтвердить настройки!${C_RESET}"

    clean_kernel_pbr_state
    if ! netplan try; then
        restore_and_exit
    fi

    trap - HUP INT TERM

    # Если пользователь отключил IPv6, очищаем старые глобальные IPv6 адреса с интерфейса
    if [[ -z "$ipv6_input" ]]; then
        ip -6 addr flush dev "$WAN_IF" scope global 2>/dev/null || true
    fi

    # Если пользователь отключил LAN, очищаем старый IPv4 на неиспользуемом LAN-интерфейсе
    if [[ -z "$LAN_IF" && -n "$detected_lan" && -n "$current_lan_ip" ]]; then
        ip -4 addr flush dev "$detected_lan" scope global 2>/dev/null || true
    fi

    if command -v conntrack >/dev/null 2>&1; then
        conntrack -F >/dev/null 2>&1 || true
    fi

    echo -e "\n${C_GREEN}🚀 Сеть успешно перестроена! Текущий исходящий IPv4 сервера:${C_RESET}"
    ip -4 route get 1.1.1.1 2>/dev/null | head -n 1
}

# ==============================================================================
# МОДУЛЬ 2: МЕНЕДЖЕР ВОССТАНОВЛЕНИЯ ИЗ БЭКАПОВ
# ==============================================================================
run_backup_restore_menu() {
    echo -e "\n${C_BOLD}⏪ ВОССТАНОВЛЕНИЕ СЕТИ ИЗ БЭКАПА${C_RESET}"
    echo "--------------------------------------------------------------------------------"

    if [[ ! -d "$BACKUP_ROOT" ]]; then
        echo -e "${C_ORANGE}⚠️ Папка с бэкапами ($BACKUP_ROOT) еще не создана.${C_RESET}"
        return
    fi

    mapfile -t backup_dirs < <(ls -1dt "${BACKUP_ROOT}"/bak_* 2>/dev/null | head -n 10)

    if [[ ${#backup_dirs[@]} -eq 0 ]]; then
        echo -e "${C_ORANGE}⚠️ Доступных бэкапов не найдено.${C_RESET}"
        return
    fi

    local i=1
    for b_dir in "${backup_dirs[@]}"; do
        local b_name label ips_inside
        b_name=$(basename "$b_dir")
        label=""
        [[ $i -eq 1 ]] && label=" ${C_GREEN}[ПОСЛЕДНИЙ БЭКАП]${C_RESET}"
        [[ $i -eq 2 ]] && label=" ${C_ORANGE}[ПРЕДПОСЛЕДНИЙ БЭКАП]${C_RESET}"

        ips_inside=$(grep -hE "^[[:space:]]*-[[:space:]]*\"?[0-9a-fA-F:.\/]+" "$b_dir"/*.yaml 2>/dev/null | grep -vE "1\.1\.1\.1|8\.8\.8\.8|9\.9\.9\.9|149\.112|2606:4700|2001:4860" | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/"//g' | tr '\n' ' ')
        [[ -z "$ips_inside" ]] && ips_inside="DHCP / Нет статики"

        echo -e "   ${C_BOLD}${i})${C_RESET} ${b_name}${label}"
        echo -e "      └─ Адреса внутри: ${C_CYAN}${ips_inside}${C_RESET}"
        ((i++))
    done
    echo -e "   ${C_BOLD}0)${C_RESET} Отмена (вернуться в главное меню)"
    echo "--------------------------------------------------------------------------------"

    local b_choice=""
    read -e -p "👉 Выбери номер бэкапа для восстановления [1-${#backup_dirs[@]} или 0]: " -i "1" b_choice
    b_choice=$(sanitize_input "$b_choice")

    if [[ "$b_choice" == "0" || -z "$b_choice" ]]; then
        echo "Отменено."
        return
    fi

    if [[ "$b_choice" =~ ^[0-9]+$ ]] && (( b_choice >= 1 && b_choice <= ${#backup_dirs[@]} )); then
        local selected_dir="${backup_dirs[$((b_choice-1))]}"
        apply_backup_dir "$selected_dir"
    else
        echo -e "${C_RED}⚠️ Неверный номер бэкапа.${C_RESET}"
    fi
}

# ==============================================================================
# МОДУЛЬ 3: САМООБНОВЛЕНИЕ СКРИПТА С GITHUB
# ==============================================================================
run_self_update() {
    echo -e "\n${C_BOLD}🔄 ОБНОВЛЕНИЕ СКРИПТА С GITHUB${C_RESET}"
    echo "--------------------------------------------------------------------------------"
    echo -e "Источник: ${C_CYAN}$SCRIPT_URL${C_RESET}"

    local tmp_file="/tmp/netcfg_update_$$.sh"
    if ! curl -fsSL --connect-timeout 10 "${SCRIPT_URL}?t=$(date +%s)" -o "$tmp_file"; then
        echo -e "${C_RED}❌ Не удалось скачать обновление. Проверь доступ в интернет или ссылку.${C_RESET}"
        rm -f "$tmp_file"
        return 1
    fi

    if ! head -n 1 "$tmp_file" | grep -q "#!/bin/bash" || ! bash -n "$tmp_file" 2>/dev/null; then
        echo -e "${C_RED}❌ Скачанный файл поврежден или содержит ошибки синтаксиса. Обновление отменено.${C_RESET}"
        rm -f "$tmp_file"
        return 1
    fi

    mv -f "$tmp_file" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    echo -e "${C_GREEN}✅ Скрипт успешно обновлен в $INSTALL_PATH! Перезапускаю...${C_RESET}"
    sleep 1
    exec "$INSTALL_PATH"
}

# ==============================================================================
# ГЛАВНЫЙ ЭКРАН И МЕНЮ
# ==============================================================================
ensure_local_install

while true; do
    clear
    echo -e "${C_BOLD}🏴‍☠️  ALCHEMIST NETPLAN CONFIGURATOR v${SCRIPT_VERSION} MASTER${C_RESET}"
    echo "================================================================================"

    WAN_NOW=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [[ -z "$WAN_NOW" ]] && WAN_NOW=$(ip -o link show | awk -F': ' '$2 != "lo" && $2 !~ /^(wg|tun|tap|docker|veth|br-)/ {print $2; exit}')
    [[ -z "$WAN_NOW" ]] && WAN_NOW="ens3"

    get_ordered_slots "$WAN_NOW"
    IPV6_NOW=$(ip -6 -o addr show dev "$WAN_NOW" scope global 2>/dev/null | awk '{print $4}' | head -n 1)
    LAN_IF_NOW=$(ip -o link show | awk -F': ' -v wan="$WAN_NOW" '$2 != "lo" && $2 != wan && $2 !~ /^(wg|tun|tap|docker|veth|br-)/ {print $2; exit}')
    LAN_IP_NOW=""
    [[ -n "$LAN_IF_NOW" ]] && LAN_IP_NOW=$(ip -4 -o addr show dev "$LAN_IF_NOW" scope global 2>/dev/null | awk '{print $4}' | head -n 1)
    BACKUP_COUNT=$(ls -1d "${BACKUP_ROOT}"/bak_* 2>/dev/null | wc -l)

    echo -e " 🌐 Интерфейс WAN:       ${C_BOLD}${WAN_NOW}${C_RESET}   (Быстрый вызов из терминала: ${C_GREEN}netcfg${C_RESET})"
    echo -e " 🔵 1. Основной IPv4:    ${C_BLUE}${SLOT1_CIDR:-[Не назначен]}${C_RESET} ${SLOT1_CIDR:+${C_GREEN}[ВЫХОД ТРАФИКА + ВХОД]${C_RESET}}"
    echo -e " 🟠 2. Дополнительный:   ${C_ORANGE}${SLOT2_CIDR:-[Отключен / Режим 1 IP]}${C_RESET} ${SLOT2_CIDR:+[ВХОД КЛИЕНТОВ]}"
    echo -e " ⚪ Адрес IPv6 ($WAN_NOW):   ${IPV6_NOW:-[Отключен]}"
    if [[ -n "$LAN_IF_NOW" && -n "$LAN_IP_NOW" ]]; then
        echo -e " 🏠 Локальная сеть LAN:  ${C_CYAN}${LAN_IF_NOW} -> ${LAN_IP_NOW}${C_RESET}"
    else
        echo -e " 🏠 Локальная сеть LAN:  [Отключена]"
    fi

    if check_ipv4_priority; then
        echo -e " 🎯 Режим Dual-Stack:    ${C_ORANGE}Приоритет IPv4 (gai.conf изменен — весь выход через IPv4)${C_RESET}"
    else
        echo -e " 🎯 Режим Dual-Stack:    ${C_GREEN}Стандартный (gai.conf не тронут — IPv6-сайты идут по IPv6)${C_RESET}"
    fi
    echo "================================================================================"

    echo -e " ${C_BOLD}1)${C_RESET} ⚙️  Настроить сеть / Поменять IP местами (Ротация)"
    echo -e " ${C_BOLD}2)${C_RESET} ⏪ Восстановить сеть из бэкапа (Доступно точек отката: ${C_BOLD}${BACKUP_COUNT}${C_RESET})"
    echo -e " ${C_BOLD}3)${C_RESET} 🎯 [Опционально] Переключить режим gai.conf (Dual-Stack / Приоритет IPv4)"
    echo -e " ${C_BOLD}4)${C_RESET} 🔄 Обновить скрипт с GitHub до последней версии"
    echo -e " ${C_BOLD}0)${C_RESET} 🚪 Выход"
    echo "--------------------------------------------------------------------------------"

    read -e -p "👉 Выбери действие [1/2/3/4/0]: " -i "1" menu_action
    menu_action=$(sanitize_input "$menu_action")

    case "$menu_action" in
        1)
            run_network_configurator
            read -r -p $'\nНажми ENTER, чтобы вернуться в меню...'
            ;;
        2)
            run_backup_restore_menu
            read -r -p $'\nНажми ENTER, чтобы вернуться в меню...'
            ;;
        3)
            if check_ipv4_priority; then
                set_ipv4_priority "disable"
                echo -e "\n${C_GREEN}✅ Восстановлен стандартный режим Linux (gai.conf очищен): сайты с поддержкой IPv6 открываются через IPv6.${C_RESET}"
            else
                set_ipv4_priority "enable"
                echo -e "\n${C_ORANGE}ℹ️ Включен принудительный приоритет IPv4 в /etc/gai.conf.${C_RESET}"
            fi
            sleep 2
            ;;
        4)
            run_self_update
            read -r -p $'\nНажми ENTER, чтобы вернуться в меню...'
            ;;
        0|"")
            echo -e "${C_GREEN}👋 Выход. Для вызова меню в любой момент введи: netcfg${C_RESET}"
            exit 0
            ;;
        *)
            echo -e "${C_RED}⚠️ Неверный выбор.${C_RESET}"
            sleep 1
            ;;
    esac
done
