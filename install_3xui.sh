# Автоматическая установка 3X-UI на Ubuntu/Debian
# Автор: ChatGPT (для nutson.us)
# =======================================

set -e

echo "🔹 Обновляем систему..."
apt update -y && apt upgrade -y

echo "🔹 Устанавливаем зависимости..."
apt install -y curl wget unzip sudo ufw

echo "🔹 Устанавливаем 3X-UI..."
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

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

IP=$(curl -s ipv4.icanhazip.com)

echo ""
echo "=========================================="
echo "✅ 3X-UI успешно установлена!"
echo "------------------------------------------"
echo "🌐 Веб-панель: http://$IP:$PANEL_PORT"
echo "👤 Логин: $PANEL_USER"
echo "🔑 Пароль: $PANEL_PASS"
echo "------------------------------------------"
echo "Чтобы открыть меню x-ui, введите: x-ui"
echo "=========================================="
