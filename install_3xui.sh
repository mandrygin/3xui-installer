#!/usr/bin/env bash
set -euo pipefail

# ---- параметры из аргументов вида user=... pass=... port=... ----
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

log(){ echo -e "$@"; }
die(){ echo -e "❌ $@" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "Запусти скрипт от root (sudo -i)."; }

pkg_install(){
  DEBIAN_FRONTEND=noninteractive apt update -y
  DEBIAN_FRONTEND=noninteractive apt upgrade -y
  DEBIAN_FRONTEND=noninteractive apt install -y curl wget sudo ufw unzip git jq || true
}

install_3xui(){
  log "🔹 Устанавливаем 3X-UI…"
  TMP_FILE="$(mktemp)"
  curl -fsSL https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o "$TMP_FILE" \
    || die "Не удалось загрузить install.sh 3X-UI."
  bash "$TMP_FILE"; rm -f "$TMP_FILE"

  # убираем внешнюю web-папку (новые билды несут фронт внутри бинаря)
  [[ -d /usr/local/x-ui/web ]] && rm -rf /usr/local/x-ui/web || true

  systemctl daemon-reload || true
  x-ui enable || true
  x-ui start  || true
}

set_panel_settings(){
  log "🔹 Настраиваем панель…"
  if x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$PANEL_PORT" -webBasePath "$WEB_BASEPATH" >/dev/null 2>&1; then :; else
    x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$PANEL_PORT"
  fi
  systemctl restart x-ui; sleep 1
}

port_in_use(){ ss -lnt "( sport = :$1 )" | grep -q ":$1"; }

ensure_listen(){
  local want_port="$1" tries=20 i=0
  if port_in_use "$want_port"; then
    if ! ss -lntp | grep -q ":$want_port .*x-ui"; then
      local fallback; fallback="$(shuf -i 1025-65535 -n 1)"
      log "⚠️ Порт $want_port уже занят. Ставлю порт панели: $fallback"
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
  echo "👤 $PANEL_USER"
  echo "🔑 $PANEL_PASS"
  echo "=========================================="
}

need_root
pkg_install
install_3xui
set_panel_settings
ensure_listen "$PANEL_PORT"
open_firewall
current_access
