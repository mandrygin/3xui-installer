#!/bin/bash
# Автоматическая установка 3X-UI с веб-интерфейсом и автоконфигурацией Xray
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

# Применяем настройки панели
x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$PANEL_PORT"

# Получаем локальный IP
IP=$(hostname -I | awk '{print $1}')

# Проверяем путь панели
WEBPATH=$(x-ui settings | grep -oP 'webBasePath:\s*\K.*' | tr -d '[:space:]')
if [ -z "$WEBPATH" ]; then
    WEBPATH="/"
fi

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

echo ""
echo "🔹 Применяем рекомендуемые настройки XRAY..."

cat >/usr/local/x-ui/bin/config.json <<'EOF'
{
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "REPLACE_UUID",
            "level": 0,
            "email": "auto@x-ui.local"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" },
    {
      "protocol": "wireguard",
      "settings": {
        "address": ["172.16.0.2/32"],
        "peers": [
          {
            "publicKey": "bmXOC+F1FxEMF9dyiK2H5Fz3x3o6r8fVq5u4i+L5rHI=",
            "endpoint": "162.159.193.10:2408"
          }
        ],
        "mtu": 1280
      },
      "tag": "warp"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" },
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "ip": ["geoip:ru"], "outboundTag": "direct" },
      { "type": "field", "domain": ["geosite:ru"], "outboundTag": "direct" },
      { "type": "field", "domain": ["geosite:google", "geosite:openai", "geosite:meta"], "outboundTag": "warp" }
    ]
  },
  "dns": {
    "servers": ["1.1.1.1", "8.8.8.8"]
  }
}
EOF

# Генерация UUID
UUID=$(cat /proc/sys/kernel/random/uuid)
sed -i "s|REPLACE_UUID|$UUID|g" /usr/local/x-ui/bin/config.json

systemctl restart x-ui
echo ""
echo "✅ Настройки XRAY применены!"
echo "🔑 UUID пользователя: $UUID"
