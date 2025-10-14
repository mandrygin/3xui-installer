#!/usr/bin/env bash
# Автоматическая установка 3X-UI (встроенный фронтенд) + автоконфиг Xray
# Автор: ChatGPT (для nutson.us)

set -euo pipefail

# ---------- ПАРАМЕТРЫ ПО УМОЛЧАНИЮ (можно переопределить аргументами) ----------
PANEL_USER="${user:-admin}"
PANEL_PASS="${pass:-$(tr -dc 'A-Za-z0-9!@#$%_' </dev/urandom | head -c 14)}"
PANEL_PORT="${port:-2053}"
WEB_BASEPATH="/"

# ---------- УТИЛИТЫ ----------
log(){ echo -e "$@"; }
die(){ echo -e "❌ $@" >&2; exit 1; }

need_root(){
  [[ $EUID -eq 0 ]] || die "Запусти скрипт от root (sudo -i)."
}

pkg_install(){
  DEBIAN_FRONTEND=noninteractive apt update -y
  DEBIAN_FRONTEND=noninteractive apt upgrade -y
  DEBIAN_FRONTEND=noninteractive apt install -y curl wget sudo ufw unzip git jq || true
}

install_3xui(){
  log "🔹 Устанавливаем 3X-UI…"
  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

  # Убираем внешнюю web-папку (новые билды несут фронтенд внутри бинаря)
  if [[ -d /usr/local/x-ui/web ]]; then
    rm -rf /usr/local/x-ui/web || true
  fi

  systemctl daemon-reload || true
  x-ui enable || true
  x-ui start  || true
}

set_panel_settings(){
  log "🔹 Настраиваем панель (логин/пароль/порт/webBasePath)…"
  # В некоторых сборках доступен -webBasePath, в некоторых — нет. Сначала пробуем полный набор.
  if x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$PANEL_PORT" -webBasePath "$WEB_BASEPATH" >/dev/null 2>&1; then
    :
  else
    # Резервный вариант без webBasePath
    x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$PANEL_PORT"
  fi

  systemctl restart x-ui
  sleep 1
}

port_in_use(){
  ss -lnt "( sport = :$1 )" | grep -q ":$1"
}

ensure_listen(){
  local want_port="$1"
  local tries=20
  local i=0

  # Если порт занят НЕ x-ui, подберём случайный
  if port_in_use "$want_port"; then
    if ! ss -lntp | grep -q ":$want_port .*x-ui"; then
      local fallback
      fallback="$(shuf -i 1025-65535 -n 1)"
      log "⚠️ Порт $want_port уже занят. Ставлю порт панели: $fallback"
      PANEL_PORT="$fallback"
      if x-ui setting -port "$PANEL_PORT" >/dev/null 2>&1; then
        systemctl restart x-ui
      fi
    fi
  fi

  # Ждём, пока x-ui поднимет HTTP на нужном порту
  while (( i < tries )); do
    if ss -lntp 2>/dev/null | grep -q ":$PANEL_PORT .*x-ui"; then
      return 0
    fi
    sleep 1; ((i++))
  done

  die "Панель не поднялась на порту $PANEL_PORT."
}

current_access(){
  local basePath
  # Покажем актуальные настройки
  x-ui settings || true
  basePath="$(x-ui settings 2>/dev/null | awk -F':' '/webBasePath/{print $2}' | tr -d '[:space:]')"
  [[ -z "${basePath:-}" ]] && basePath="/"

  # IP-адреса
  local LAN_IP PUB_IP
  LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  PUB_IP="$(curl -fsS ipv4.icanhazip.com 2>/dev/null || true)"

  echo
  echo "=========================================="
  echo "✅ 3X-UI установлена и запущена"
  echo "------------------------------------------"
  [[ -n "$LAN_IP" ]] && echo "🌐 Локальная панель:  http://$LAN_IP:$PANEL_PORT$basePath"
  [[ -n "$PUB_IP" ]] && echo "🌐 Внешняя панель:    http://$PUB_IP:$PANEL_PORT$basePath"
  echo "👤 Логин:  $PANEL_USER"
  echo "🔑 Пароль: $PANEL_PASS"
  echo "------------------------------------------"
  echo "Меню управления: x-ui"
  echo "=========================================="
}

open_firewall(){
  log "🔹 Открываем порты UFW…"
  ufw allow 22/tcp  >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw allow 2096/tcp >/dev/null 2>&1 || true
  ufw allow "$PANEL_PORT"/tcp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
}

apply_xray_config(){
  log "🔹 Применяем Xray-конфиг…"
  local cfg="/usr/local/x-ui/bin/config.json"
  local uuid
  uuid="$(cat /proc/sys/kernel/random/uuid)"

  cat >"$cfg" <<'JSON'
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
JSON

  sed -i "s/REPLACE_UUID/${uuid}/g" "$cfg"
  chmod 644 "$cfg"
  systemctl restart x-ui
  sleep 1
  log "✅ Xray применён. UUID: $uuid"
}

### MAIN
need_root
log "🔹 Обновляем систему и ставим зависимости…"
pkg_install
install_3xui
set_panel_settings
ensure_listen "$PANEL_PORT"
open_firewall
apply_xray_config
current_access
