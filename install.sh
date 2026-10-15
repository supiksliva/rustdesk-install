#!/bin/bash
set -e

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo "Пожалуйста, запустите скрипт от имени root (sudo)."
    exit 1
fi

# Меню выбора
if [ -t 0 ] || [ -e /dev/tty ]; then
    echo "Что вы хотите установить?"
    echo "1) RustDesk Server"
    echo "2) 3X-UI (VPN панель)"
    echo "3) Всё вместе (RustDesk + 3X-UI)"
    read -r -p "Выберите вариант [1]: " CHOICE < /dev/tty
    CHOICE="${CHOICE:-1}"
else
    CHOICE="1"
fi

install_rustdesk() {
    echo ""
    echo "--- Установка RustDesk Server ---"
    echo "Определяем внешний IP..."
    IP=$(curl -s4 https://api.ipify.org 2>/dev/null || curl -s4 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

    if [ -n "$1" ]; then
        HOST="$1"
    else
        if [ -t 0 ] || [ -e /dev/tty ]; then
            echo "Ваш текущий IP: $IP"
            read -r -p "Введите домен (или нажмите Enter, чтобы использовать IP $IP): " USER_HOST < /dev/tty
            HOST="${USER_HOST:-$IP}"
        else
            HOST="$IP"
        fi
    fi

    echo "Настраиваем RustDesk для адреса: $HOST"
    echo "Устанавливаем необходимые пакеты..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq curl wget unzip tar ufw qrencode &>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl wget unzip tar qrencode &>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y -q epel-release curl wget unzip tar &>/dev/null || true
        yum install -y -q qrencode &>/dev/null || true
    fi

    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        PACKAGE="rustdesk-server-linux-amd64.zip"
    elif [ "$ARCH" = "aarch64" ]; then
        PACKAGE="rustdesk-server-linux-arm64v8.zip"
    else
        echo "Ошибка: неподдерживаемая архитектура ($ARCH)"
        exit 1
    fi

    INSTALL_DIR="/opt/rustdesk"
    mkdir -p "$INSTALL_DIR"
    cd /tmp

    echo "Скачиваем RustDesk Server..."
    DOWNLOAD_URL="https://github.com/rustdesk/rustdesk-server/releases/latest/download/${PACKAGE}"
    if ! curl -fsSL -o rustdesk.zip "$DOWNLOAD_URL"; then
        curl -fsSL -o rustdesk.zip "https://github.com/rustdesk/rustdesk-server/releases/download/1.1.16/${PACKAGE}"
    fi

    rm -rf /tmp/rustdesk-unpack
    unzip -q -o rustdesk.zip -d /tmp/rustdesk-unpack
    find /tmp/rustdesk-unpack -type f -name hbbs -exec mv {} "$INSTALL_DIR/hbbs" \;
    find /tmp/rustdesk-unpack -type f -name hbbr -exec mv {} "$INSTALL_DIR/hbbr" \;
    chmod +x "$INSTALL_DIR/hbbs" "$INSTALL_DIR/hbbr"
    rm -rf rustdesk.zip /tmp/rustdesk-unpack

    cat << UNIT_HBBS > /etc/systemd/system/rustdesk-hbbs.service
[Unit]
Description=RustDesk ID Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/hbbs -r $HOST:21117 -k _
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT_HBBS

    cat << UNIT_HBBR > /etc/systemd/system/rustdesk-hbbr.service
[Unit]
Description=RustDesk Relay Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/hbbr -k _
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT_HBBR

    systemctl daemon-reload
    systemctl enable --now rustdesk-hbbs &>/dev/null
    systemctl enable --now rustdesk-hbbr &>/dev/null

    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow 21115:21119/tcp &>/dev/null
        ufw allow 21116/udp &>/dev/null
    fi

    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=public --add-port=21115-21119/tcp --permanent &>/dev/null
        firewall-cmd --zone=public --add-port=21116/udp --permanent &>/dev/null
        firewall-cmd --reload &>/dev/null
    fi

    for i in {1..10}; do
        [ -f "$INSTALL_DIR/id_ed25519.pub" ] && break
        sleep 1
    done

    KEY=$(cat "$INSTALL_DIR/id_ed25519.pub" 2>/dev/null || echo "Генерируется... выполните позже: cat $INSTALL_DIR/id_ed25519.pub")

    # Генерация официальной строки конфигурации RustDesk (Base64 JSON в обратном порядке)
    JSON_CFG="{\"host\":\"$HOST\",\"relay\":\"$HOST\",\"api\":\"\",\"key\":\"$KEY\"}"
    if command -v rev &>/dev/null; then
        CONFIG_STRING=$(printf '%s' "$JSON_CFG" | base64 | tr -d '\n\r=' | rev)
    else
        CONFIG_STRING=$(printf '%s' "$JSON_CFG" | base64 | tr -d '\n\r=' | awk '{ for(i=length;i>0;i--) printf "%s",substr($0,i,1); print "" }')
    fi

    echo ""
    echo "Готово! RustDesk Server установлен и запущен."
    echo ""
    echo "Адрес сервера (ID/Relay): $HOST"
    echo "Ключ (Key):               $KEY"
    echo ""
    echo "Строка конфигурации (для импорта в один клик):"
    echo "$CONFIG_STRING"
    echo ""
    echo "QR-код для подключения (отсканируйте сканером в RustDesk):"
    echo ""

    if command -v qrencode &>/dev/null; then
        qrencode -t ANSIUTF8 "$CONFIG_STRING"
    else
        curl -s "https://qrenco.de/$CONFIG_STRING" || true
    fi

    echo ""
    echo "Как применить:"
    echo "• На телефоне: откройте RustDesk -> Настройки -> Сеть -> значок QR вверху."
    echo "• На ПК: откройте RustDesk -> Настройки -> Сеть -> вставьте строку конфигурации."
}

install_3xui() {
    echo ""
    echo "--- Установка последней версии 3X-UI ---"
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
}

case "$CHOICE" in
    1)
        install_rustdesk "$1"
        ;;
    2)
        install_3xui
        ;;
    3)
        install_rustdesk "$1"
        install_3xui
        ;;
    *)
        echo "Неверный выбор. Запуск установки RustDesk по умолчанию."
        install_rustdesk "$1"
        ;;
esac