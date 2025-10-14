#!/bin/bash
# Автоматическая установка 3X-UI с веб-интерфейсом
# Автор: ChatGPT (для nutson.us)
# =======================================

set -e

echo "🔹 Обновляем систему..."
apt update -y && apt upgrade -y

echo "🔹 Устанавливаем зависимости..."
apt install -y curl wget unzip sudo git ufw

echo "🔹 Устанавливаем 3X-UI..."
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

echo ""
echo "🔹 Проверяем, установлен ли frontend..."
if [ ! -d "/usr/local/x-ui/web" ]; then
    echo "⚙️  Веб-панель отсутствует — скачиваем..."
    mkdir -p /usr/local/x-ui/web
    cd /usr/local/x-ui/web

    # Попробуем стабильный источник FranzKafkaYu (активный форк)
    wget -q --show-progress https://github.com/FranzKafkaYu/x-ui-frontend/archive/refs/heads/master.zip -O frontend.zip || \
    wget -q --show-progress https://github.com/MHSanaei/3x-ui-frontend/archive/refs/heads/master.zip -O frontend.zip

    unzip -oq frontend.zip
    mv x-ui-frontend-*/* /usr/local/x-ui/web/ || true
    rm -f frontend.zip
    cd /usr/local/x-ui
else
    echo "✅ Веб-панель уже установлена."
fi

echo ""
echo "🔹 Открываем порты..."
ufw allow 22/tcp
ufw allow 443/tcp
ufw allow 2053/tcp
ufw allow 2096/tcp
ufw --force enable

echo ""
echo "🔹 Запускаем и включаем x-ui..."
x-ui restart || x-ui start
x-ui enable

echo ""
read -p "Введите логин для панели: " PANEL_USER
read -sp "Введите пароль для панели: " PANEL_PASS
echo ""

# Настраиваем порт панели
PANEL_PORT=2053

# Применяем настройки
x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$PANEL_PORT"

# Получаем локальный IP
IP=$(hostname -I | awk '{print $1}')

# Проверяем WebBasePath
WEBPATH=$(x-ui settings | grep -oP 'webBasePath:\s*\K.*' | tr -d '[:space:]')

echo ""
echo "=========================================="
echo "✅ 3X-UI успешно установлена и запущена!"
echo "------------------------------------------"
echo "🌐 Веб-панель: http://$IP:$PANEL_PORT$WEBPATH"
echo "👤 Логин: $PANEL_USER"
echo "🔑 Пароль: $PANEL_PASS"
echo "------------------------------------------"
echo "Чтобы открыть меню вручную: x-ui"
echo "=========================================="
