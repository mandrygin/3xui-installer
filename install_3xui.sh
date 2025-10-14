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

# Проверяем, установлен ли бинарь x-ui
if ! command -v x-ui &> /dev/null; then
  echo "❌ Ошибка: x-ui не установился. Прерывание."
  exit 1
fi

# Проверяем наличие web-фронтенда
if [ ! -d "/usr/local/x-ui/web" ] || [ -z "$(ls -A /usr/local/x-ui/web 2>/dev/null)" ]; then
  echo "⚙️ Web-панель отсутствует — скачиваем вручную..."
  mkdir -p /usr/local/x-ui/web
  cd /usr/local/x-ui/web
  wget -q --show-progress https://github.com/MHSanaei/3x-ui-frontend/releases/latest/download/dist.zip
  unzip -oq dist.zip
  rm -f dist.zip
  echo "✅ Веб-файлы фронтенда успешно установлены."
fi

echo ""
read -p "Введите порт панели (по умолчанию 2053): " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-2053}

echo "🔹 Настраиваем брандмауэр..."
ufw allow 22/tcp
ufw allow 443/tcp
ufw allow $PANEL_PORT/tcp
ufw --force enable

echo ""
echo "🔹 Запускаем и настраиваем X-UI..."
x-ui restart
x-ui enable

read -p "Введите логин для панели: " PANEL_USER
read -sp "Введите пароль для панели: " PANEL_PASS
echo ""

x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$PANEL_PORT"

# Определяем IP (локальный, если есть)
LOCAL_IP=$(hostname -I | awk '{print $1}')
IP=${LOCAL_IP:-$(curl -s ipv4.icanhazip.com)}

# Узнаём путь к панели
WEB_PATH=$(grep -oP '(?<=WebBasePath": ")[^"]+' /usr/local/x-ui/bin/config.json || echo "")

x-ui restart
sleep 3

echo ""
echo "=========================================="
echo "✅ 3X-UI успешно установлена и готова!"
echo "------------------------------------------"
echo "🌐 Веб-панель: http://$IP:$PANEL_PORT$WEB_PATH"
echo "👤 Логин: $PANEL_USER"
echo "🔑 Пароль: $PANEL_PASS"
echo "------------------------------------------"
echo "Чтобы открыть меню x-ui вручную: x-ui"
echo "=========================================="
