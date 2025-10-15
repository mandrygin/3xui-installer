#!/usr/bin/env bash
set -euo pipefail
trap 'echo "❌ Ошибка на строке $LINENO: $BASH_COMMAND" >&2' ERR

# ---- аргументы ----
user="${user:-}"; pass="${pass:-}"; port="${port:-}"; WEB_BASEPATH="${webBasePath:-/}"
INBOUND_PORT="${inbound:-443}"   # порт VLESS-инбаунда (можешь переопределить inbound=2096)
for kv in "$@"; do
  case "$kv" in
    user=*) user="${kv#*=}" ;;
    pass=*) pass="${kv#*=}" ;;
    port=*) port="${kv#*=}" ;;
    webBasePath=*) WEB_BASEPATH="${kv#*=}" ;;
    inbound=*) INBOUND_PORT="${kv#*=}" ;;
  esac
done
PANEL_USER="${user:-admin}"
PANEL_PASS="${pass:-$(tr -dc 'A-Za-z0-9!@#\$%_' </dev/urandom | head -c 14)}"
PANEL_PORT="${port:-2053}"

UI="/usr/local/x-ui/x-ui"
CFG="/usr/local/x-ui/bin/config.json"

log(){ echo -e "$@"; }
die(){ echo -e "❌ $@" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "Запусти от root (sudo -i)."; }

pkg_install(){
  log "🔹 Пакеты…"
  DEBIAN_FRONTEND=noninteractive apt update -y
  DEBIAN_FRONTEND=noninteractive apt upgrade -y
  DEBIAN_FRONTEND=noninteractive apt install -y curl wget sudo ufw unzip git ca-certificates || true
}

install_3xui(){
  log "🔹 Установка 3X-UI…"
  tmp="$(mktemp)"
  curl -fsSL --retry 3 --connect-timeout 20 https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o "$tmp"
  bash "$tmp"; rm -f "$tmp"
  [[ -x "$UI" ]] || die "Не найден бинарь $UI после установки."
  [[ -d /usr/local/x-ui/web ]] && rm -rf /usr/local/x-ui/web || true
  systemctl daemon-reload || true
  "$UI" enable || true
  "$UI" start  || true
}

wait_ready(){
  log "🔹 Жду готовности CLI…"
  for i in {1..40}; do
    out="$("$UI" setting -show 2>&1 || true)"
    echo "$out" | grep -q "port:" && return 0
    sleep 1
  done
  die "x-ui не отвечает на CLI."
}

apply_panel_settings(){
  log "🔹 Применяю логин/пароль/порт…"
  # ключи только в виде key=value
  "$UI" setting -username="$PANEL_USER" -password="$PANEL_PASS" -port="$PANEL_PORT" -webBasePath="$WEB_BASEPATH" >/dev/null 2>&1 || true
  # валидация по выводу (код возврата игнорируем)
  show="$("$UI" setting -show 2>&1 || true)"
  echo "$show" | grep -q "port: $PANEL_PORT" || die "Панель не приняла порт ($PANEL_PORT)."
  systemctl restart x-ui; sleep 2
}

ensure_listen(){
  log "🔹 Проверяю, что x-ui слушает $PANEL_PORT…"
  for i in {1..30}; do
    ss -lntp 2>/dev/null | grep -q ":$PANEL_PORT .*x-ui" && return 0
    sleep 1
  done
  die "Панель не слушает порт $PANEL_PORT."
}

open_firewall(){
  log "🔹 Открываю UFW…"
  ufw allow 22/tcp  >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw allow 2096/tcp >/dev/null 2>&1 || true
  ufw allow "$PANEL_PORT"/tcp >/dev/null 2>&1 || true
  ufw allow "$INBOUND_PORT"/tcp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
}

write_xray_config(){
  log "🔹 Переписываю Xray config.json…"
  mkdir -p "$(dirname "$CFG")"
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  cat >"$CFG" <<JSON
{
  "log": { "loglevel": "warning" },
  "dns": { "servers": ["1.1.1.1", "8.8.8.8"] },
  "inbounds": [
    {
      "port": $INBOUND_PORT,
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
    { "protocol": "freedom",  "tag": "direct" },
    { "protocol": "blackhole","tag": "block"  },
    {
      "protocol": "wireguard",
      "tag": "warp",
      "settings": {
        "address": ["172.16.0.2/32"],
        "peers": [
          { "publicKey": "bmXOC+F1FxEMF9dyiK2H5Fz3x3o6r8fVq5u4i+L5rHI=", "endpoint": "162.159.193.10:2408" }
        ],
        "mtu": 1280
      }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" },
      { "type": "field", "ip": ["geoip:private"],     "outboundTag": "block"  },
      { "type": "field", "ip": ["geoip:ru"],          "outboundTag": "direct" },
      { "type": "field", "domain": ["geosite:ru"],    "outboundTag": "direct" },
      { "type": "field", "domain": ["geosite:google","geosite:openai","geosite:meta"], "outboundTag": "warp" }
    ]
  }
}
JSON
  chmod 644 "$CFG"
  systemctl restart x-ui || true
  sleep 1
}

print_access(){
  local LAN PUB; LAN="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  PUB="$(curl -fsS ipv4.icanhazip.com 2>/dev/null || true)"
  echo
  echo "=========================================="
  echo "✅ 3X-UI установлена и настроена"
  [[ -n "$LAN" ]] && echo "🌐 Локально: http://$LAN:$PANEL_PORT$WEB_BASEPATH"
  [[ -n "$PUB" ]] && echo "🌐 Снаружи:  http://$PUB:$PANEL_PORT$WEB_BASEPATH"
  echo "👤 Логин:  $PANEL_USER"
  echo "🔑 Пароль: $PANEL_PASS"
  echo "------------------------------------------"
  echo "Файл Xray-конфига: $CFG"
  echo "UUID VLESS: $uuid"
  echo "Inbound порт: $INBOUND_PORT"
  echo "=========================================="
}

# ---- MAIN ----
need_root
pkg_install
install_3xui
wait_ready
apply_panel_settings
ensure_listen
open_firewall
write_xray_config
print_access
