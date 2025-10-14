#!/bin/bash
# =======================================
# Автоматическая установка 3X-UI на Ubuntu/Debian
# Автор: ChatGPT (для nutson.us)
# =======================================

set -e
export DEBIAN_FRONTEND=noninteractive

# Проверка root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Пожалуйста, запустите скрипт с правами root (sudo)"
  exit 1
fi

echo "🔹 Обновляем систему..."
apt update -y && apt upgrade -yq

echo "🔹 Устанавливаем зависимости..."
apt install -y curl wget unzip sudo ufw

echo "🔹 Устанавливаем 3X-UI..."
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

# Проверка наличия веб-панели
if [ ! -d "/usr/local/x-ui/web" ] || [ -z "$(ls -A /usr/local/x-ui/web)" ]; then
  echo "⚠️ Web-панель не найдена — выполняем reinstall..."
  x-ui reinstall
fi

echo "✅ Установка 3X-UI завершена."

echo ""
read -p "Введите порт панели (по умолчанию 2053): " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-2053}

echo "🔹 Открываем порты..."
ufw allow 22/tcp
ufw allow 443/tcp
ufw allow $PANEL_PORT/tcp
ufw --force enable

echo ""
echo "🔹 Создаём первого пользователя панели..."
x-ui start
sleep 3
x-ui enable

read -p "Введите логин для панели: " PANEL_USER
read -sp "Введите пароль для панели: " PANEL_PASS
echo ""

x-ui setting -username $PANEL_USER -password $PANEL_PASS -port $PANEL_PORT

# Определяем IP (локальный, если есть)
LOCAL_IP=$(hostname -I | awk '{print $1}')
IP=${LOCAL_IP:-$(curl -s ipv4.icanhazip.com)}

x-ui restart
sleep 2

echo ""
echo "=========================================="
echo "✅ 3X-UI успешно установлена!"
echo "------------------------------------------"
echo "🌐 Веб-панель: http://$IP:$PANEL_PORT/panel"
echo "👤 Логин: $PANEL_USER"
echo "🔑 Пароль: $PANEL_PASS"
echo "------------------------------------------"
echo "Чтобы открыть меню x-ui, введите: x-ui"
echo "=========================================="
