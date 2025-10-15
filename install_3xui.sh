#!/usr/bin/env bash
set -euo pipefail
trap 'echo "❌ Ошибка на строке $LINENO: $BASH_COMMAND" >&2' ERR

# ---------- чтение аргументов user=... pass=... port=... webBasePath=... ----------
user="${user:-}"; pass="${pass:-}"; port="${port:-}"; WEB_BASEPATH="/"
for kv in "$@"; do
  case "$kv" in
    user=*) user="${kv#*=}" ;;
    pass=*) pass="${kv#*=}" ;;
    port=*) port="${kv#*=}" ;;
    webBasePath=*) WEB_BASEPATH="${kv#*=}" ;;
  esac
done

PANEL_USER="${user:-admin}"
PANEL_PASS="${pass:-$(tr -dc 'A-Za-z0-9!@#$%_' </dev/urandom | head -c 14)}"
PANEL_PORT="${port:-2053}"

# ---------- целевые XRAY-настройки как на скриншоте ----------
BLOCK_BT="1"
BLOCKED_IPS=("geoip:private")
DIRECT_IPS=("geoip:ru")
DIRECT_DOMAINS=("geosite:ru")
WARP_DOMAINS=("geosite:google" "geosite:openai" "geosite:meta")

log(){ echo -e "$@"; }
die(){ echo -e "❌ $@" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "Запусти скрипт от root (sudo -i)."; }

pkg_install(){
  log "🔹 Обновляем систему и ставим зависимости..."
  DEBIAN_FRONTEND=noninteractive apt update -y
  DEBIAN_FRONTEND=noninteractive apt upgrade -y
  DEBIAN_FRONTEND=noninteractive apt install -y curl wget sudo ufw unzip git jq sqlite3 || true
}

install_3xui(){
  log "🔹 Устанавливаем 3X-UI…"
  TMP_FILE="$(mktemp)"
  curl -fsSL --retry 3 --connect-timeout 15 \
    https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh \
    -o "$TMP_FILE" || die "Не удалось загрузить install.sh 3X-UI."
  bash "$TMP_FILE"
  rm -f "$TMP_FILE"

  command -v x-ui >/dev/null 2>&1 || die "x-ui не найден после установки."

  # старый внешний фронт больше не нужен
  [[ -d /usr/local/x-ui/web ]] && rm -rf /usr/local/x-ui/web || true

  systemctl daemon-reload || true
  x-ui enable || true
  x-ui start  || true
}

set_panel_settings(){
  log "🔹 Настраиваем панель (логин/пароль/порт/basePath)…"
  if x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$PANEL_PORT" -webBasePath "$WEB_BASEPATH" >/dev/null 2>&1; then :; else
    x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$PANEL_PORT"
  fi
  systemctl restart x-ui; sleep 2
}

# Применяем рабочий xray config (эффективная маршрутизация)
apply_xray_config_file(){
  log "🔹 Применяем Xray-конфиг (BT block, RU direct, WARP для Google/OpenAI/Meta)…"
  local cfg="/usr/local/x-ui/bin/config.json"
  local uuid; uuid="$(cat /proc/sys/kernel/random/uuid)"

  cat >"$cfg" <<JSON
{
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$uuid", "level": 0, "email": "auto@x-ui.local" }
        ],
        "decryption": "none"
      },
      "streamSettings": { "network": "tcp", "security": "none" }
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
          { "publicKey": "bmXOC+F1FxEMF9dyiK2H5Fz3x3o6r8fVq5u4i+L5rHI=", "endpoint": "162.159.193.10:2408" }
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
      { "type": "field", "domain": ["geosite:google","geosite:openai","geosite:meta"], "outboundTag": "warp" }
    ]
  },
  "dns": { "servers": ["1.1.1.1", "8.8.8.8"] }
}
JSON

  chmod 644 "$cfg"
  systemctl restart x-ui
  sleep 2
  log "✅ Xray-конфиг записан и перезапущен (UUID: $uuid)"
}

# Пытаемся проставить те же значения в БД X-UI, чтобы они отобразились в UI
apply_xray_prefs_in_db(){
  local DB="/usr/local/x-ui/db/x-ui.db"
  if [[ ! -f "$DB" ]]; then
    log "ℹ️ БД X-UI не найдена ($DB). Пропускаю запись в UI."
    return 0
  fi

  log "🔹 Применяем параметры в БД X-UI (если схема совпадает)…"
  # Универсальные попытки для популярных схем (без падения при несовпадении)
  sqlite3 "$DB" "
  -- возможный кей-вэлью
  UPDATE settings SET value='1' WHERE key IN ('block_bittorrent','blockBitTorrent');

  -- прямые/заблокированные ip/домены как JSON-строки
  UPDATE settings SET value='[\"geoip:private\"]' WHERE key IN ('blocked_ips','blockedIps');
  UPDATE settings SET value='[\"geoip:ru\"]'      WHERE key IN ('direct_ips','directIps');
  UPDATE settings SET value='[\"geosite:ru\"]'    WHERE key IN ('direct_domains','directDomains');

  -- домены для WARP/IPv4 (в некоторых сборках это один список маршрутизации)
  UPDATE settings SET value='[\"geosite:google\",\"geosite:openai\",\"geosite:meta\"]'
    WHERE key IN ('warp_domains','warpDomains','ipv4_domains','ipv4Domains');
  " >/dev/null 2>&1 || true

  systemctl restart x-ui || true
  sleep 2
}

port_in_use(){ ss -lnt "( sport = :$1 )" | grep -q ":$1"; }

ensure_listen(){
  local want_port="$1" tries=20 i=0
  if port_in_use "$want_port"; then
    if ! ss -lntp | grep -q ":$want_port .*x-ui"; then
      local fallback; fallback="$(shuf -i 1025-65535 -n 1)"
      log "⚠️ Порт $want_port занят. Новый порт панели: $fallback"
      PANEL_PORT="$fallback"
      x-ui setting -port "$PANEL_PORT" >/dev/null 2>&1 && systemctl restart x-ui
    fi
  fi
  while (( i < tries )); do
    ss -lntp 2>/dev/null | grep -q ":$PANEL_PORT .*x-ui" && return 0
    sleep 1; ((i++))
  done
  die "Панель не поднялась на порту $PANEL_PORT."
}

open_firewall(){
  log "🔹 Открываем порты UFW…"
  ufw allow 22/tcp  >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw allow 2096/tcp >/dev/null 2>&1 || true
  ufw allow "$PANEL_PORT"/tcp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
}

current_access(){
  local LAN_IP PUB_IP
  LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
  PUB_IP="$(curl -fsS ipv4.icanhazip.com 2>/dev/null || true)"
  echo "=========================================="
  echo "✅ 3X-UI установлена и запущена"
  [[ -n "$LAN_IP" ]] && echo "🌐 Локально: http://$LAN_IP:$PANEL_PORT$WEB_BASEPATH"
  [[ -n "$PUB_IP" ]] && echo "🌐 Внешний:  http://$PUB_IP:$PANEL_PORT$WEB_BASEPATH"
  echo "👤 Пользователь: $PANEL_USER"
  echo "🔑 Пароль:      $PANEL_PASS"
  echo "=========================================="
}

# ---------- MAIN ----------
need_root
pkg_install
install_3xui
set_panel_settings
apply_xray_config_file
apply_xray_prefs_in_db
ensure_listen "$PANEL_PORT"
open_firewall
current_access
