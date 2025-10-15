#!/usr/bin/env bash
set -euo pipefail
trap 'echo "❌ Ошибка на строке $LINENO: $BASH_COMMAND" >&2' ERR

# --- чтение аргументов ---
user="${user:-}"; pass="${pass:-}"; port="${port:-}"; WEB_BASEPATH="/"
webpath_set=0
for kv in "$@"; do
  case "$kv" in
    user=*) user="${kv#*=}" ;;
    pass=*) pass="${kv#*=}" ;;
    port=*) port="${kv#*=}" ;;
    webBasePath=*) WEB_BASEPATH="${kv#*=}"; webpath_set=1 ;;
  esac
done
PANEL_USER="${user:-admin}"
PANEL_PASS="${pass:-$(tr -dc 'A-Za-z0-9!@#$%_' </dev/urandom | head -c 14)}"
PANEL_PORT="${port:-2053}"

UI="/usr/local/x-ui/x-ui"

log(){ echo -e "$@"; }
die(){ echo -e "❌ $@" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "Запусти скрипт от root (sudo -i)."; }

pkg_install(){
  log "🔹 Обновляем систему и ставим зависимости…"
  DEBIAN_FRONTEND=noninteractive apt update -y
  DEBIAN_FRONTEND=noninteractive apt upgrade -y
  DEBIAN_FRONTEND=noninteractive apt install -y curl wget sudo ufw unzip git jq sqlite3 || true
}

install_3xui(){
  log "🔹 Устанавливаем 3X-UI…"
  tmp="$(mktemp)"
  curl -fsSL --retry 3 --connect-timeout 15 https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o "$tmp" \
    || die "Не удалось скачать install.sh 3X-UI"
  bash "$tmp"; rm -f "$tmp"

  command -v "$UI" >/dev/null 2>&1 || die "Не найден $UI после установки"
  [[ -d /usr/local/x-ui/web ]] && rm -rf /usr/local/x-ui/web || true
  systemctl daemon-reload || true
  "$UI" enable || true
  "$UI" start  || true
}

set_panel(){
  log "🔹 Применяем логин/пароль/порт панели…"
  if (( webpath_set )); then
    "$UI" setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$PANEL_PORT" -webBasePath "$WEB_BASEPATH"
  else
    "$UI" setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$PANEL_PORT"
  fi
  systemctl restart x-ui; sleep 2
}

port_in_use(){ ss -lnt "( sport = :$1 )" | grep -q ":$1"; }
ensure_listen(){
  local want="$1" tries=20 i=0
  if port_in_use "$want"; then
    if ! ss -lntp | grep -q ":$want .*x-ui"; then
      local fb; fb="$(shuf -i 1025-65535 -n 1)"
      log "⚠️ Порт $want занят. Ставлю порт панели: $fb"
      PANEL_PORT="$fb"
      "$UI" setting -port "$PANEL_PORT" >/dev/null 2>&1 || true
      systemctl restart x-ui
    fi
  fi
  while (( i < tries )); do
    ss -lntp 2>/dev/null | grep -q ":$PANEL_PORT .*x-ui" && return 0
    sleep 1; ((i++))
  done
  die "Панель не поднялась на порту $PANEL_PORT"
}

apply_xray_config(){
  log "🔹 Применяем Xray-маршрутизацию (BT block, RU → direct, WARP для Google/OpenAI/Meta)…"
  local cfg="/usr/local/x-ui/bin/config.json"
  local uuid; uuid="$(cat /proc/sys/kernel/random/uuid)"
  cat >"$cfg" <<JSON
{
  "inbounds":[{"port":443,"protocol":"vless","settings":{"clients":[{"id":"$uuid","level":0,"email":"auto@x-ui.local"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"none"}}],
  "outbounds":[
    {"protocol":"freedom","tag":"direct"},
    {"protocol":"blackhole","tag":"block"},
    {"protocol":"wireguard","settings":{"address":["172.16.0.2/32"],"peers":[{"publicKey":"bmXOC+F1FxEMF9dyiK2H5Fz3x3o6r8fVq5u4i+L5rHI=","endpoint":"162.159.193.10:2408"}],"mtu":1280},"tag":"warp"}
  ],
  "routing":{"domainStrategy":"IPIfNonMatch","rules":[
    {"type":"field","protocol":["bittorrent"],"outboundTag":"block"},
    {"type":"field","ip":["geoip:private"],"outboundTag":"block"},
    {"type":"field","ip":["geoip:ru"],"outboundTag":"direct"},
    {"type":"field","domain":["geosite:ru"],"outboundTag":"direct"},
    {"type":"field","domain":["geosite:google","geosite:openai","geosite:meta"],"outboundTag":"warp"}
  ]},
  "dns":{"servers":["1.1.1.1","8.8.8.8"]}
}
JSON
  chmod 644 "$cfg"
  systemctl restart x-ui; sleep 2
}

apply_xray_in_ui(){
  # Попробуем отразить то же в БД, чтобы было видно в UI (если есть такие ключи)
  local DBS=("/usr/local/x-ui/db/x-ui.db" "/etc/x-ui/x-ui.db")
  for DB in "${DBS[@]}"; do
    [[ -f "$DB" ]] || continue
    log "🔹 Обновляю настройки в БД UI: $DB"
    sqlite3 "$DB" "
      UPDATE settings SET value='1'                         WHERE key IN ('block_bittorrent','blockBitTorrent');
      UPDATE settings SET value='[\"geoip:private\"]'      WHERE key IN ('blocked_ips','blockedIps');
      UPDATE settings SET value='[\"geoip:ru\"]'           WHERE key IN ('direct_ips','directIps');
      UPDATE settings SET value='[\"geosite:ru\"]'         WHERE key IN ('direct_domains','directDomains');
      UPDATE settings SET value='[\"geosite:google\",\"geosite:openai\",\"geosite:meta\"]'
                                                           WHERE key IN ('warp_domains','warpDomains','ipv4_domains','ipv4Domains');
    " >/dev/null 2>&1 || true
  done
  systemctl restart x-ui || true
}

open_firewall(){
  log "🔹 Открываю порты UFW…"
  ufw allow 22/tcp  >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw allow 2096/tcp >/dev/null 2>&1 || true
  ufw allow "$PANEL_PORT"/tcp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
}

print_access(){
  local LAN PUB; LAN="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  PUB="$(curl -fsS ipv4.icanhazip.com 2>/dev/null || true)"
  echo "=========================================="
  echo "✅ 3X-UI установлена и настроена"
  [[ -n "$LAN" ]] && echo "🌐 Локально: http://$LAN:$PANEL_PORT${webpath_set:+$WEB_BASEPATH}"
  [[ -n "$PUB" ]] && echo "🌐 Снаружи:  http://$PUB:$PANEL_PORT${webpath_set:+$WEB_BASEPATH}"
  echo "👤 Логин: $PANEL_USER"
  echo "🔑 Пароль: $PANEL_PASS"
  echo "=========================================="
}

need_root
pkg_install
install_3xui
set_panel
ensure_listen "$PANEL_PORT"
apply_xray_config
apply_xray_in_ui
open_firewall
print_access
