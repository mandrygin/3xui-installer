#!/usr/bin/env bash
set -euo pipefail

# ---------- разбор аргументов user= pass= port= webBasePath= ----------
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

log(){ echo -e "$@"; }
die(){ echo -e "❌ $@" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "Запусти от root (sudo -i)."; }

pkg_install(){
  DEBIAN_FRONTEND=noninteractive apt update -y
  DEBIAN_FRONTEND=noninteractive apt upgrade -y
  DEBIAN_FRONTEND=noninteractive apt install -y curl wget sudo ufw unzip git jq || true
}

install_3xui(){
  log "🔹 Устанавливаем 3X-UI…"
  tmp="$(mktemp)"
  curl -fsSL https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o "$tmp" || die "Не скачался установщик 3X-UI."
  bash "$tmp"
  rm -f "$tmp"
}

set_panel(){
  log "🔹 Настраиваем панель (логин/пароль/порт/webBasePath)…"
  # после инсталлятора ещё раз задаём, т.к. он генерит случайные:
  if x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$PANEL_PORT" -webBasePath "$WEB_BASEPATH" >/dev/null 2>&1; then
    :
  else
    x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$PANEL_PORT"
  fi
  systemctl daemon-reload || true
  x-ui enable || true
  x-ui restart || x-ui start
}

ensure_listen(){
  log "🔹 Проверяем, что панель слушает порт $PANEL_PORT…"
  for _ in {1..25}; do
    if ss -lntp 2>/dev/null | grep -q ":$PANEL_PORT .*x-ui"; then return 0; fi
    sleep 1
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

patch_xray_config(){
  log "🔹 Применяем Xray-маршрутизацию (RU → direct, Google/OpenAI/Meta → WARP, блок BitTorrent + private IP)…"

  cfg="/usr/local/x-ui/bin/config.json"
  mkdir -p /usr/local/x-ui/bin

  # Если файла нет — создадим скелет
  if [[ ! -s "$cfg" ]]; then
    cat >"$cfg" <<'JSON'
{
  "log": {"loglevel":"warning"},
  "dns": null,
  "inbounds": [],
  "outbounds": [],
  "routing": { "domainStrategy":"IPIfNonMatch", "rules": [] }
}
JSON
  fi

  # Текущий JSON -> jq, добавляем/обновляем секции
  tmpcfg="$(mktemp)"
  jq '
    .dns = {"servers":["1.1.1.1","8.8.8.8"]} |

    # гарантируем outbounds: direct, blackhole
    .outbounds = (
      ([.outbounds[]? | select(.protocol=="freedom")] + [{"protocol":"freedom","tag":"direct"}]) | unique_by(.protocol)
      + ([.outbounds[]? | select(.protocol=="blackhole")] + [{"protocol":"blackhole","tag":"block"}]) | unique_by(.protocol)
    ) |

    # добавляем/обновляем WARP (WireGuard outbound)
    .outbounds = (
      .outbounds
      | map(select(.tag!="warp"))
      + [{
          "protocol":"wireguard",
          "tag":"warp",
          "settings":{
            "address":["172.16.0.2/32"],
            "peers":[{"publicKey":"bmXOC+F1FxEMF9dyiK2H5Fz3x3o6r8fVq5u4i+L5rHI=","endpoint":"162.159.193.10:2408"}],
            "mtu":1280
          }
        }]
    ) |

    # правила маршрутизации
    .routing.domainStrategy = "IPIfNonMatch" |
    .routing.rules = (
      # уберём старые похожие, добавим нужные
      [.routing.rules[]? |
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
  ' "$cfg" > "$tmpcfg"

  mv "$tmpcfg" "$cfg"
  chmod 644 "$cfg"

  # перезапуск Xray через панель
  systemctl restart x-ui || true
  sleep 1
}

print_access(){
  local LAN_IP PUB_IP
  LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
  PUB_IP="$(curl -fsS ipv4.icanhazip.com 2>/dev/null || true)"
  echo
  echo "=========================================="
  echo "✅ 3X-UI установлена. Доступ к панели:"
  [[ -n "$LAN_IP" ]] && echo "🌐 http://$LAN_IP:$PANEL_PORT$WEB_BASEPATH"
  [[ -n "$PUB_IP" ]] && echo "🌐 http://$PUB_IP:$PANEL_PORT$WEB_BASEPATH"
  echo "👤 Логин:  $PANEL_USER"
  echo "🔑 Пароль: $PANEL_PASS"
  echo "------------------------------------------"
  echo "Xray-конфиг патчен: /usr/local/x-ui/bin/config.json"
  echo "Меню управления: x-ui"
  echo "=========================================="
}

### MAIN
need_root
pkg_install
install_3xui
set_panel
ensure_listen
open_firewall
patch_xray_config
print_access
