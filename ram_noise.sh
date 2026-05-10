#!/bin/bash
# ram_noise.sh — заполняет RAM с базовой целью ~20% и периодическими спайками.
# Базовая цель: BASE_MIN_PCT..BASE_MAX_PCT (по умолчанию 15..25 = ~20%).
# Спайки: SPIKE_MIN_PCT..SPIKE_MAX_PCT длительностью SPIKE_DURATION_*
# с вероятностью SPIKE_CHANCE_PCT при каждом ретаргете.
# Жесткий потолок: SAFETY_PCT (по умолчанию 85%).

set -u

BASE_MIN_PCT="${BASE_MIN_PCT:-15}"
BASE_MAX_PCT="${BASE_MAX_PCT:-25}"
SPIKE_MIN_PCT="${SPIKE_MIN_PCT:-35}"
SPIKE_MAX_PCT="${SPIKE_MAX_PCT:-55}"
SPIKE_CHANCE_PCT="${SPIKE_CHANCE_PCT:-15}"
SPIKE_DURATION_MIN="${SPIKE_DURATION_MIN:-20}"
SPIKE_DURATION_MAX="${SPIKE_DURATION_MAX:-60}"
SAFETY_PCT="${SAFETY_PCT:-85}"
STEP_MB="${STEP_MB:-50}"
TICK="${TICK:-3}"
RETARGET_MIN="${RETARGET_MIN:-30}"
RETARGET_MAX="${RETARGET_MAX:-120}"
VERBOSE="${VERBOSE:-0}"

TMPFS_DIR="/run/ram_noise.$$"
BALLAST="$TMPFS_DIR/ballast"

mkdir -p "$TMPFS_DIR"
mount -t tmpfs -o size=95% tmpfs "$TMPFS_DIR" 2>/dev/null || {
  echo "Не могу примонтировать tmpfs в $TMPFS_DIR" >&2
  exit 1
}

cleanup() {
  rm -f "$BALLAST" 2>/dev/null
  umount "$TMPFS_DIR" 2>/dev/null
  rmdir "$TMPFS_DIR" 2>/dev/null
  exit 0
}
trap cleanup SIGINT SIGTERM EXIT

mem_total_mb() {
  awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo
}

mem_available_mb() {
  awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo
}

mem_used_pct() {
  awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END{printf "%.0f", (t-a)*100/t}' /proc/meminfo
}

ballast_mb() {
  if [[ -f "$BALLAST" ]]; then
    stat -c '%s' "$BALLAST" | awk '{printf "%d", $1/1048576}'
  else
    echo 0
  fi
}

TOTAL_MB=$(mem_total_mb)
SAFETY_MB=$(( TOTAL_MB * SAFETY_PCT / 100 ))

echo "Старт. total=${TOTAL_MB}MB safety=${SAFETY_PCT}% (${SAFETY_MB}MB) base=${BASE_MIN_PCT}..${BASE_MAX_PCT}% spike=${SPIKE_MIN_PCT}..${SPIKE_MAX_PCT}% (${SPIKE_CHANCE_PCT}% chance)"

pick_base_target() {
  local span=$(( BASE_MAX_PCT - BASE_MIN_PCT ))
  local pct=$(( BASE_MIN_PCT + RANDOM % (span + 1) ))
  echo $(( TOTAL_MB * pct / 100 ))
}

pick_spike_target() {
  local span=$(( SPIKE_MAX_PCT - SPIKE_MIN_PCT ))
  local pct=$(( SPIKE_MIN_PCT + RANDOM % (span + 1) ))
  echo $(( TOTAL_MB * pct / 100 ))
}

# IS_SPIKE=1 — сейчас спайк, после SPIKE_END возвращаемся к базе
IS_SPIKE=0
SPIKE_END=0
TARGET_MB=$(pick_base_target)
NEXT_RETARGET=$(( $(date +%s) + RETARGET_MIN + RANDOM % (RETARGET_MAX - RETARGET_MIN + 1) ))

if [[ "$VERBOSE" == "1" ]]; then
  echo "[$(date '+%H:%M:%S')] начальная цель: ${TARGET_MB}MB"
fi

LAST_LOG=$(date +%s)

while true; do
  NOW=$(date +%s)

  # Конец активного спайка — возвращаемся к базе
  if (( IS_SPIKE == 1 )) && (( NOW >= SPIKE_END )); then
    IS_SPIKE=0
    TARGET_MB=$(pick_base_target)
    [[ "$VERBOSE" == "1" ]] && echo "[$(date '+%H:%M:%S')] spike закончился, base target=${TARGET_MB}MB"
    NEXT_RETARGET=$(( NOW + RETARGET_MIN + RANDOM % (RETARGET_MAX - RETARGET_MIN + 1) ))
  fi

  # Плановая смена цели (только если не в активном спайке)
  if (( IS_SPIKE == 0 )) && (( NOW >= NEXT_RETARGET )); then
    if (( RANDOM % 100 < SPIKE_CHANCE_PCT )); then
      IS_SPIKE=1
      TARGET_MB=$(pick_spike_target)
      SPIKE_DUR=$(( SPIKE_DURATION_MIN + RANDOM % (SPIKE_DURATION_MAX - SPIKE_DURATION_MIN + 1) ))
      SPIKE_END=$(( NOW + SPIKE_DUR ))
      [[ "$VERBOSE" == "1" ]] && echo "[$(date '+%H:%M:%S')] SPIKE на ${SPIKE_DUR}s до ${TARGET_MB}MB"
    else
      TARGET_MB=$(pick_base_target)
      [[ "$VERBOSE" == "1" ]] && echo "[$(date '+%H:%M:%S')] base target=${TARGET_MB}MB"
    fi
    NEXT_RETARGET=$(( NOW + RETARGET_MIN + RANDOM % (RETARGET_MAX - RETARGET_MIN + 1) ))
  fi

  CUR=$(ballast_mb)
  USED_PCT=$(mem_used_pct)
  AVAIL_MB=$(mem_available_mb)

  # Жесткая защита: если общее использование >SAFETY_PCT — режем балласт
  if (( USED_PCT > SAFETY_PCT )); then
    NEW=$(( CUR - STEP_MB * 2 ))
    (( NEW < 0 )) && NEW=0
    truncate -s "${NEW}M" "$BALLAST" 2>/dev/null || :
    if [[ "$VERBOSE" == "1" ]]; then
      echo "[$(date '+%H:%M:%S')] OVER_SAFETY used=${USED_PCT}% — урезал до ${NEW}MB"
    fi
  elif (( CUR < TARGET_MB )); then
    # Растем к цели, но только если хватает свободной памяти с запасом
    HEADROOM_MB=$(( SAFETY_MB - (TOTAL_MB - AVAIL_MB) ))
    if (( HEADROOM_MB > STEP_MB * 2 )); then
      ADD=$STEP_MB
      (( CUR + ADD > TARGET_MB )) && ADD=$(( TARGET_MB - CUR ))
      NEW=$(( CUR + ADD ))
      # Заполняем реальными байтами через dd, чтобы tmpfs реально занял RAM
      dd if=/dev/urandom of="$BALLAST" bs=1M count="$ADD" \
         oflag=append conv=notrunc seek="$CUR" status=none 2>/dev/null || :
      truncate -s "${NEW}M" "$BALLAST" 2>/dev/null || :
    fi
  elif (( CUR > TARGET_MB + STEP_MB )); then
    # Превышаем цель — освобождаем
    NEW=$(( CUR - STEP_MB ))
    (( NEW < TARGET_MB )) && NEW=$TARGET_MB
    truncate -s "${NEW}M" "$BALLAST" 2>/dev/null || :
  fi

  # Лог раз в 60 сек в тихом режиме
  STATE="base"
  (( IS_SPIKE == 1 )) && STATE="SPIKE"
  if [[ "$VERBOSE" != "1" ]] && (( NOW - LAST_LOG >= 60 )); then
    BAL=$(ballast_mb)
    BAL_PCT=$(( BAL * 100 / TOTAL_MB ))
    echo "[$(date '+%F %H:%M:%S')] ballast=${BAL}MB (${BAL_PCT}%) target=${TARGET_MB}MB state=${STATE} total_used=${USED_PCT}% avail=${AVAIL_MB}MB"
    LAST_LOG=$NOW
  elif [[ "$VERBOSE" == "1" ]]; then
    BAL=$(ballast_mb)
    echo "[$(date '+%H:%M:%S')] ${STATE} ballast=${BAL}MB → ${TARGET_MB}MB used=${USED_PCT}% avail=${AVAIL_MB}MB"
  fi

  sleep "$TICK"
done
