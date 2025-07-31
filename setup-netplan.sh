#!/bin/bash

# ==============================================================================
# Скрипт для быстрой настройки сети с помощью Netplan в Ubuntu (v2)
# ==============================================================================

# --- Проверка на запуск через pipe, который ломает интерактивный ввод ---
if ! [ -t 0 ]; then
    echo "🚫 Ошибка: Этот скрипт является интерактивным и не может быть запущен через pipe."
    echo "Пожалуйста, скачайте его и запустите локально:"
    echo "1. curl -o setup-netplan.sh -L [URL_СКРИПТА]"
    echo "2. chmod +x setup-netplan.sh"
    echo "3. sudo ./setup-netplan.sh"
    exit 1
fi

# --- Проверка прав суперпользователя ---
if [[ $EUID -ne 0 ]]; then
   echo "🚫 Ошибка: Этот скрипт необходимо запускать с правами суперпользователя (sudo)." 
   exit 1
fi

# --- Функции валидации (остаются без изменений) ---
validate_ip_cidr() {
    local ip=$1
    local regex="^([0-9]{1,3}\.){3}[0-9]{1,3}\/[0-9]{1,2}$"
    if [[ $ip =~ $regex ]]; then
        return 0
    else
        return 1
    fi
}

validate_ipv6_cidr() {
    local ip=$1
    if [[ "$ip" == *"/"* && "$ip" == *":"* ]]; then
        return 0
    else
        return 1
    fi
}

clear
echo "🚀 Запускаем настройку сети Netplan..."
echo "-------------------------------------------"

# --- Блок ввода данных (остается без изменений) ---
while true; do
    read -p "1️⃣  Введите основной IPv4 адрес для ens3 (формат: АДРЕС/МАСКА, например, 212.34.153.253/24): " ipv4_ens3
    if validate_ip_cidr "$ipv4_ens3"; then
        break
    else
        echo "❌ Неверный формат. Пожалуйста, введите адрес в формате IP/CIDR (например, 192.168.1.10/24)."
    fi
done

ip_part=$(echo $ipv4_ens3 | cut -d'/' -f1)
suggested_gateway=$(echo $ip_part | awk -F. '{print $1"."$2"."$3".1"}')

read -p "2️⃣  Предлагаемый шлюз: $suggested_gateway. Нажмите Enter для подтверждения или введите свой: " gateway4
if [ -z "$gateway4" ]; then
    gateway4=$suggested_gateway
fi

read -p "3️⃣  Введите IPv6 адрес для ens3 (или Enter, чтобы пропустить): " ipv6_ens3
if [ -n "$ipv6_ens3" ]; then
    while ! validate_ipv6_cidr "$ipv6_ens3"; do
        echo "❌ Неверный формат IPv6. Попробуйте еще раз (например, 2a03:4000:...::1/64) или оставьте поле пустым."
        read -p "3️⃣  Введите IPv6 адрес для ens3 (или Enter, чтобы пропустить): " ipv6_ens3
        [ -z "$ipv6_ens3" ] && break
    done
fi

while true; do
    read -p "4️⃣  Введите локальный IP адрес для ens6 (формат: АДРЕС/МАСКА, например, 10.13.3.237/16): " ipv4_ens6
    if validate_ip_cidr "$ipv4_ens6"; then
        break
    else
        echo "❌ Неверный формат. Пожалуйста, введите адрес в формате IP/CIDR."
    fi
done

echo "-------------------------------------------"
echo "✅ Данные приняты. Генерируем файл конфигурации..."

# --- Блок генерации файла и применения настроек (остается без изменений) ---
TMP_FILE=$(mktemp)

cat > $TMP_FILE << EOF
# Этот файл был сгенерирован автоматически
network:
  version: 2
  renderer: networkd
  ethernets:
    ens3:
      addresses:
        - "$ipv4_ens3"
$( [ -n "$ipv6_ens3" ] && echo "        - \"$ipv6_ens3\"" )
      gateway4: $gateway4
$( [ -n "$ipv6_ens3" ] && echo "      gateway6: fe80::1" )
      nameservers:
          addresses:
              - "8.8.8.8"
              - "1.1.1.1"

    ens6:
      addresses:
        - "$ipv4_ens6"
EOF

mv $TMP_FILE /etc/netplan/01-netcfg.yaml
chmod 644 /etc/netplan/01-netcfg.yaml

echo "📄 Файл /etc/netplan/01-netcfg.yaml успешно создан."
cat /etc/netplan/01-netcfg.yaml
echo "-------------------------------------------"

echo "⚙️ Проверяем синтаксис командой 'netplan generate'..."
netplan generate

if [ $? -ne 0 ]; then
    echo "🚫 Обнаружена ошибка в синтаксисе. Пожалуйста, проверьте введенные данные и файл."
    exit 1
fi

echo "✅ Синтаксис верный."
echo "⏳ Сейчас будет запущена команда 'netplan try' для безопасного тестирования."
sleep 3
netplan try

echo "-------------------------------------------"
read -p "🎉 Настройка завершена. Нажмите Enter для выхода."

exit 0
