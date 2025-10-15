#!/usr/bin/env bash
set -euo pipefail
trap 'echo "❌ Ошибка на строке $LINENO: $BASH_COMMAND" >&2' ERR

# ---------- аргументы ----------
user="${user:-}"; pass="${pass:-}"; port="${port:-}"; WEB_BASEPATH="${webBasePath:-/}"
for kv in "$@"; do
  case "$kv" in
    user=*) user="${kv#*=}" ;;
    pass=*) pass="${kv#*=}" ;;
    port=*) port="${kv#*=}" ;;
    webBasePath=*) WEB_BASEPATH="${kv#*=}" ;;
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
  DEBIAN_FRONTEND=noninteractive apt install -y curl wget sudo ufw unzip git jq sqlite3 ca-certificates || true
}

install_3xui(){
  log "🔹 Установка 3X-UI…"
  tmp="$(mktemp)"
  curl -fsSL --retry 3 --connect-timeout 20 https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o "$tmp"
  bash "$tmp"
  rm -f "$tmp"

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

port_taken_by_other(){
  ss -lntp 2>/dev/null | awk -v p=":$1" '$4 ~ p {print $0}' | grep -qv x-ui || return 1
}

pick_free_port(){
  for i in {1..50}; do
    p="$(shuf -i 1025-65535 -n 1)"
    ss -lnt 2>/dev/null | grep -q ":$p " || { echo "$p"; return 0; }
  done
  echo 2053
}

apply_panel_settings(){
  log "🔹 Применяю логин/пароль/порт…"
  if port_taken_by_other "$PANEL_PORT"; then
    newp="$(pick_free_port)"
    log "⚠️ Порт $PANEL_PORT занят другим процессом. Ставлю $newp"
    PANEL_PORT="$newp"
  fi

  # ВАЖНО: ключи через '=' и только бинарь
  "$UI" setting -username="$PANEL_USER" -password="$PANEL_PASS" -port="$PANEL_PORT" -webBasePath="$WEB_BASEPATH" >/dev/null 2>&1 || true

  # Валидация по выводу, а не по коду возврата
  show="$("$UI" setting -show 2>&1 || true)"
  echo "$show"
  echo "$show" | grep -q "port: $PANEL_PORT" || die "Панель не приняла порт ($PANEL_PORT)."
  echo "$show" | grep -q "hasDefaultCredential: false" || true

  systemctl restart x-ui
  sleep 2
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
  ufw --force enable >/dev/null 2>&1 || true
}

patch_xray_routing(){
  log "🔹 Патчу Xray (BT/private → block; RU → direct; Google/OpenAI/Meta → WARP)…"
  mkdir -p "$(dirname "$CFG")"
  [[ -s "$CFG" ]] || cat >"$CFG" <<'JSON'
{ "log":{"loglevel":"warning"}, "dns":null, "inbounds":[], "outbounds":[], "routing":{"domainStrategy":"IPIfNonMatch","rules":[]} }
JSON

  tmpcfg="$(mktemp)"
  jq '
    .dns = {"servers":["1.1.1.1","8.8.8.8"]} |
    .outbounds = (
      ( [.outbounds[]? | select(.protocol=="freedom")] + [{"protocol":"freedom","tag":"direct"}] ) | unique_by(.protocol)
      + ( [.outbounds[]? | select(.protocol=="blackhole")] + [{"protocol":"blackhole","tag":"block"}] ) | unique_by(.protocol)
    ) |
    .outbounds = ( [.outbounds[]? | select(.tag!="warp")] + [{
      "protocol":"wireguard","tag":"warp",
      "settings":{"address":["172.16.0.2/32"],
                  "peers":[{"publicKey":"bmXOC+F1FxEMF9dyiK2H5Fz3x3o6r8fVq5u4i+L5rHI=","endpoint":"162.159.193.10:2408"}],
                  "mtu":1280}
    }] ) |
    .routing.domainStrategy = "IPIfNonMatch" |
    .routing.rules = (
      [
        .routing.rules[]? |
        select(
          (.protocol? // [] | index("bittorrent") | not)
          and (.ip? // [] | index("geoip:private") | not)
          and (.ip? // [] | index("geoip:ru") | not)
          and (.domain? // [] | index("geosite:ru") | not)
          and (.domain? // [] | (index("geosite:google") or index("geosite:openai") or index("geosite:meta")) | not)
        )
      ]
      + [
        {"type":"field","protocol":["bittorrent"],"outboundTag":"block"},
        {"type":"field","ip":["geoip:private"],"outboundTag":"block"},
        {"type":"field","ip":["geoip:ru"],"outboundTag":"direct"},
        {"type":"field","domain":["geosite:ru"],"outboundTag":"direct"},
        {"type":"field","domain":["geosite:google","geosite:openai","geosite:meta"],"outboundTag":"warp"}
      ]
    )
  ' "$CFG" > "$tmpcfg"
  mv "$tmpcfg" "$CFG"
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
  echo "Текущие настройки панели:"
  "$UI" setting -show 2>&1 || true
  echo "=========================================="
}

# ---------- MAIN ----------
need_root
pkg_install
install_3xui
wait_ready
apply_panel_settings
ensure_listen
open_firewall
patch_xray_routing
print_access
