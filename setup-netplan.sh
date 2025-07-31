#!/bin/bash

# ==============================================================================
# Скрипт для быстрой настройки сети с помощью Netplan в Ubuntu (v3)
# - Использует актуальный синтаксис 'routes' вместо 'gateway4'
# - Устанавливает безопасные права доступа 600 на файл конфигурации
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
validate_ip_cidr() {
    local ip=$1
    local regex="^([0-9]{1,3}\.){3}[0-9]{1,3}\/[0-9]{1,2}$"
    if [[ $ip =~ $regex ]]; then return 0; else return 1; fi
}

validate_ipv6_cidr() {
    local ip=$1
    if [[ "$ip" == *"/"* && "$ip" == *":"* ]]; then return 0; else return 1; fi
}

clear
echo "🚀 Запускаем настройку сети Netplan (синтаксис 2024+)..."
echo "--------------------------------------------------------"

# --- Блок ввода данных
while true; do
    read -p "1️⃣  Введите основной IPv4 адрес для ens3 (формат: АДРЕС/МАСКА): " ipv4_ens3
    if validate_ip_cidr "$ipv4_ens3"; then break; else echo "❌ Неверный формат."; fi
done

ip_part=$(echo $ipv4_ens3 | cut -d'/' -f1)
suggested_gateway=$(echo $ip_part | awk -F. '{print $1"."$2"."$3".1"}')

read -p "2️⃣  Предлагаемый IPv4 шлюз: $suggested_gateway. Enter для подтверждения или введите свой: " gateway4
if [ -z "$gateway4" ]; then gateway4=$suggested_gateway; fi

read -p "3️⃣  Введите IPv6 адрес для ens3 (или Enter, чтобы пропустить): " ipv6_ens3
if [ -n "$ipv6_ens3" ]; then
    while ! validate_ipv6_cidr "$ipv6_ens3"; do
        echo "❌ Неверный формат IPv6."
        read -p "3️⃣  Введите IPv6 адрес для ens3 (или Enter, чтобы пропустить): " ipv6_ens3
        [ -z "$ipv6_ens3" ] && break
    done
fi
# Для IPv6 шлюз почти всегда link-local fe80::1
gateway6="fe80::1"

while true; do
    read -p "4️⃣  Введите локальный IP адрес для ens6 (формат: АДРЕС/МАСКА): " ipv4_ens6
    if validate_ip_cidr "$ipv4_ens6"; then break; else echo "❌ Неверный формат."; fi
done

echo "--------------------------------------------------------"
echo "✅ Данные приняты. Генерируем файл конфигурации..."

# --- Создание конфигурационного файла Netplan с актуальным синтаксисом
cat > /etc/netplan/01-netcfg.yaml << EOF
# Этот файл был сгенерирован автоматически
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

    ens6:
      addresses:
        - "$ipv4_ens6"
EOF

# --- Установка правильных прав доступа ---
chmod 600 /etc/netplan/01-netcfg.yaml

echo "📄 Файл /etc/netplan/01-netcfg.yaml успешно создан."
echo "🔐 Установлены безопасные права доступа (600)."
echo "--------------------------------------------------------"

# --- Проверка и применение конфигурации
echo "⚙️ Проверяем синтаксис командой 'netplan generate'..."
netplan generate

if [ $? -ne 0 ]; then
    echo "🚫 Обнаружена ошибка в синтаксисе. Пожалуйста, проверьте введенные данные и файл."
    exit 1
fi

echo "✅ Синтаксис верный. Предупреждения должны исчезнуть."
echo "⏳ Сейчас будет запущена команда 'netplan try' для безопасного тестирования."
sleep 2

netplan try

echo "--------------------------------------------------------"
read -p "🎉 Настройка завершена. Нажмите Enter для выхода."

exit 0
