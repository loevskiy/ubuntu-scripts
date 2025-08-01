#!/bin/bash

# ==============================================================================
# Скрипт для быстрой настройки сети с помощью Netplan в Ubuntu (v4)
# - Авто-определение текущих IP в качестве значений по умолчанию
# - Авто-подстановка масок (/24, /64, /16)
# - Расширенный список DNS-серверов
# - Актуальный синтаксис 'routes' и безопасные права доступа 600
# ==============================================================================

# --- Проверка на запуск через pipe
if ! [ -t 0 ]; then
    echo "🚫 Ошибка: Этот скрипт является интерактивным и не может быть запущен через pipe."
    echo "Пожалуйста, используйте команду: sudo bash -c \"\$(curl -sSL [URL])\""
    exit 1
fi

# --- Проверка прав суперпользователя
if [[ $EUID -ne 0 ]]; then
   echo "🚫 Ошибка: Этот скрипт необходимо запускать с правами суперпользователя (sudo)."
   exit 1
fi

# --- Функции валидации
validate_ip() {
    local ip=$1
    # Простая проверка, что это похоже на IP
    if [[ $ip =~ ^[0-9]{1,3}\. ]]; then return 0; else return 1; fi
}

validate_ipv6() {
    local ip=$1
    if [[ $ip == *":"* ]]; then return 0; else return 1; fi
}

clear
echo "🚀 Запускаем умную настройку сети Netplan (v4)..."
echo "--------------------------------------------------------"
echo "💡 Совет: Нажмите Enter, чтобы принять предложенное значение по умолчанию."

# --- Авто-определение текущих настроек ---
current_ipv4_ens3=$(ip -4 addr show ens3 | grep -oP 'inet \K[\d.\/]+' | head -n 1)
current_ipv6_ens3=$(ip -6 addr show ens3 | grep -oP 'inet6 \K[0-9a-fA-F:\/]+' | grep -v '^fe80' | head -n 1)
current_ipv4_ens6=$(ip -4 addr show ens6 | grep -oP 'inet \K[\d.\/]+' | head -n 1)

# --- Блок ввода данных ---

# 1. IPv4 для ens3
read -e -p "1️⃣  Введите основной IPv4 для ens3: " -i "$current_ipv4_ens3" ipv4_ens3
if [[ -n "$ipv4_ens3" && ! "$ipv4_ens3" == *"/"* ]]; then
    ipv4_ens3="$ipv4_ens3/24"
    echo "   -- Маска не указана, добавлена /24 --> $ipv4_ens3"
fi

# 2. Шлюз для IPv4
ip_part=$(echo $ipv4_ens3 | cut -d'/' -f1)
suggested_gateway=$(echo $ip_part | awk -F. '{print $1"."$2"."$3".1"}')
read -e -p "2️⃣  Введите IPv4 шлюз: " -i "$suggested_gateway" gateway4

# 3. IPv6 для ens3 (опционально)
read -e -p "3️⃣  Введите IPv6 для ens3 (Enter для пропуска): " -i "$current_ipv6_ens3" ipv6_ens3
if [[ -n "$ipv6_ens3" && ! "$ipv6_ens3" == *"/"* ]]; then
    ipv6_ens3="$ipv6_ens3/64"
    echo "   -- Маска не указана, добавлена /64 --> $ipv6_ens3"
fi
gateway6="fe80::1" # Шлюз для IPv6 почти всегда link-local

# 4. Локальный IP для ens6
read -e -p "4️⃣  Введите локальный IP для ens6: " -i "$current_ipv4_ens6" ipv4_ens6
if [[ -n "$ipv4_ens6" && ! "$ipv4_ens6" == *"/"* ]]; then
    ipv4_ens6="$ipv4_ens6/16"
    echo "   -- Маска не указана, добавлена /16 --> $ipv4_ens6"
fi

echo "--------------------------------------------------------"
echo "✅ Данные приняты. Генерируем файл конфигурации..."

# --- Создание конфигурационного файла Netplan ---
cat > /etc/netplan/01-netcfg.yaml << EOF
# Этот файл был сгенерирован автоматически скриптом
network:
  version: 2
  renderer: networkd
  ethernets:
    ens3:
      addresses:
        - "$ipv4_ens3"
$( [ -n "$ipv6_ens3" ] && echo "        - \"$ipv6_ens3\"" )
      routes:
        - to: default
          via: $gateway4
$( [ -n "$ipv6_ens3" ] && echo "        - to: default
          via: $gateway6" )
      nameservers:
          addresses:
              - "8.8.8.8"
              - "1.1.1.1"
              - "8.8.4.4"
              - "1.0.0.1"
              - "2001:4860:4860::8888"
              - "2001:4860:4860::8844"
              - "2606:4700:4700::1111"
              - "2606:4700:4700::1001"
$( [ -n "$ipv4_ens6" ] && cat << EOL
    ens6:
      addresses:
        - "$ipv4_ens6"
EOL
)
EOF

# --- Установка правильных прав доступа ---
chmod 600 /etc/netplan/01-netcfg.yaml

echo "📄 Файл /etc/netplan/01-netcfg.yaml успешно создан."
echo "🔐 Установлены безопасные права доступа (600)."
echo "--------------------------------------------------------"
cat /etc/netplan/01-netcfg.yaml
echo "--------------------------------------------------------"

# --- Проверка и применение конфигурации ---
echo "⚙️ Проверяем синтаксис командой 'netplan generate'..."
netplan generate

if [ $? -ne 0 ]; then
    echo "🚫 Обнаружена ошибка в синтаксисе. Выход."
    exit 1
fi

echo "✅ Синтаксис верный."
echo "⏳ Сейчас будет запущена команда 'netplan try' для безопасного тестирования."
sleep 2

netplan try

echo "--------------------------------------------------------"
read -p "🎉 Настройка завершена. Нажмите Enter для выхода."

exit 0
