#!/bin/bash
# install.sh — автоматическая установка traffic_noise (адаптивный шум
# с развязкой формы графика) как systemd-сервиса.
#
# Использование на сервере (Debian/Ubuntu, от root):
#   curl -fsSL https://raw.githubusercontent.com/strelkatech/traffic-noise/main/install.sh | sudo bash

set -euo pipefail

SCRIPT_PATH="/usr/local/bin/traffic_noise.sh"
SERVICE_PATH="/etc/systemd/system/traffic-noise.service"
ENV_PATH="/etc/default/traffic-noise"
LOG_PATH="/var/log/traffic_noise.log"
LOGROTATE_PATH="/etc/logrotate.d/traffic-noise"
SERVICE_NAME="traffic-noise"

RAM_SCRIPT_PATH="/usr/local/bin/ram_noise.sh"
RAM_SERVICE_PATH="/etc/systemd/system/ram-noise.service"
RAM_ENV_PATH="/etc/default/ram-noise"
RAM_LOG_PATH="/var/log/ram_noise.log"
RAM_LOGROTATE_PATH="/etc/logrotate.d/ram-noise"
RAM_SERVICE_NAME="ram-noise"

if [[ $EUID -ne 0 ]]; then
  echo "Ошибка: запускай через sudo или от root." >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "Ошибка: systemd не найден. Скрипт рассчитан на Debian/Ubuntu." >&2
  exit 1
fi

echo "[1/9] Устанавливаю зависимости..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates gawk iproute2 procps vnstat logrotate >/dev/null
systemctl enable --now vnstat >/dev/null 2>&1 || true

echo "[2/9] Записываю traffic_noise.sh в $SCRIPT_PATH..."
cat > "$SCRIPT_PATH" <<'NOISE_EOF'
# traffic_noise.sh — адаптивный шум с развязкой формы графика.
# Накапливает "долг" RX = RATIO * (TX_total - стартовый), а тратит долг
# плавно через скользящее окно SMOOTH_WINDOW секунд + базовый шум BASE_MBIT.
# В результате график RX визуально не коррелирует с графиком TX.

set -u

RATIO="${RATIO:-2.5}"
IFACE="${IFACE:-$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')}"
MIN_WORKERS="${MIN_WORKERS:-1}"
MAX_WORKERS="${MAX_WORKERS:-32}"
CHUNK_MB="${CHUNK_MB:-200}"
SMOOTH_WINDOW="${SMOOTH_WINDOW:-300}"   # окно сглаживания, секунды
BASE_MBIT="${BASE_MBIT:-10}"            # базовый шум при idle, Mbit/s
MAX_NOISE_MBIT="${MAX_NOISE_MBIT:-400}" # максимальная прибавка RX над TX, Mbit/s
JITTER="${JITTER:-0.30}"                # рандом-разброс ±30% от целевой скорости
# Защита от перегрузки сервера:
CPU_SOFT_PCT="${CPU_SOFT_PCT:-70}"      # выше этого CPU используем — начинаем душить шум
CPU_HARD_PCT="${CPU_HARD_PCT:-90}"      # выше этого — шум = 0
LINK_MBIT="${LINK_MBIT:-1000}"          # потолок канала, Mbit/s (для авто-душения)
LINK_SOFT_PCT="${LINK_SOFT_PCT:-70}"    # выше этого% от LINK_MBIT по TX+RX — душим
LINK_HARD_PCT="${LINK_HARD_PCT:-90}"    # выше этого — шум = 0
VERBOSE="${VERBOSE:-0}"

FILES=(
  "https://speed.hetzner.de/10GB.bin"
  "https://speed.hetzner.de/1GB.bin"
  "http://speedtest.tele2.net/10GB.zip"
  "http://speedtest.tele2.net/1GB.zip"
  "https://proof.ovh.net/files/10Gb.dat"
  "https://proof.ovh.net/files/1Gb.dat"
  "http://ipv4.download.thinkbroadband.com/1GB.zip"
  "http://ipv4.download.thinkbroadband.com/512MB.zip"
  "https://releases.ubuntu.com/jammy/ubuntu-22.04.4-live-server-amd64.iso"
  "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.5.0-amd64-netinst.iso"
)

if [[ -z "$IFACE" ]]; then
  echo "Не удалось определить интерфейс. Задай IFACE=eth0." >&2
  exit 1
fi

TX_FILE="/sys/class/net/$IFACE/statistics/tx_bytes"
RX_FILE="/sys/class/net/$IFACE/statistics/rx_bytes"
[[ -r "$TX_FILE" && -r "$RX_FILE" ]] || { echo "Нет доступа к $TX_FILE/$RX_FILE" >&2; exit 1; }

WORKER_DIR="/run/traffic_noise.$$"
mkdir -p "$WORKER_DIR"

CHUNK_BYTES=$(( CHUNK_MB * 1024 * 1024 ))
END_OFFSET=$(( CHUNK_BYTES - 1 ))

cleanup() {
  for pidfile in "$WORKER_DIR"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    kill "$(<"$pidfile")" 2>/dev/null || true
  done
  rm -rf "$WORKER_DIR"
  exit 0
}
trap cleanup SIGINT SIGTERM EXIT

spawn_worker() {
  local id=$1
  local pidfile="$WORKER_DIR/$id.pid"
  (
    while true; do
      local url=${FILES[$RANDOM % ${#FILES[@]}]}
      curl -s --max-time 60 \
        --user-agent "Mozilla/5.0 (X11; Linux x86_64)" \
        -r "0-$END_OFFSET" \
        -o /dev/null \
        "$url" || sleep 1
    done
  ) &
  echo $! > "$pidfile"
}

kill_one_worker() {
  for pidfile in "$WORKER_DIR"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    local pid=$(<"$pidfile")
    kill "$pid" 2>/dev/null || true
    pkill -P "$pid" 2>/dev/null || true
    rm -f "$pidfile"
    return 0
  done
}

count_workers() {
  local n=0
  for pidfile in "$WORKER_DIR"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    local pid=$(<"$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      n=$((n+1))
    else
      rm -f "$pidfile"
    fi
  done
  echo "$n"
}

echo "Старт. iface=$IFACE ratio=$RATIO smooth=${SMOOTH_WINDOW}s base=${BASE_MBIT}Mbit/s max_noise=${MAX_NOISE_MBIT}Mbit/s jitter=$JITTER cpu=${CPU_SOFT_PCT}/${CPU_HARD_PCT}% link=${LINK_MBIT}Mbit/s ${LINK_SOFT_PCT}/${LINK_HARD_PCT}%"

# Чтение CPU из /proc/stat: возвращает % использования (1 - idle/total) за интервал.
CPU_PREV_TOTAL=0
CPU_PREV_IDLE=0
read_cpu_pct() {
  # /proc/stat: cpu user nice system idle iowait irq softirq steal guest guest_nice
  read -r _ u n s i io ir sr st _ _ < /proc/stat
  local idle=$(( i + io ))
  local total=$(( u + n + s + i + io + ir + sr + st ))
  local d_total=$(( total - CPU_PREV_TOTAL ))
  local d_idle=$((  idle  - CPU_PREV_IDLE  ))
  CPU_PREV_TOTAL=$total
  CPU_PREV_IDLE=$idle
  if (( d_total <= 0 )); then
    echo 0
    return
  fi
  awk -v dt="$d_total" -v di="$d_idle" 'BEGIN{ printf "%.0f", 100*(dt-di)/dt }'
}
# Прогрев счетчика
read_cpu_pct >/dev/null

# Возвращает множитель [0..1] для душения шума.
# soft/hard в процентах. Ниже soft = 1, выше hard = 0, между — линейно.
soft_hard_multiplier() {
  local val=$1 soft=$2 hard=$3
  awk -v v="$val" -v s="$soft" -v h="$hard" 'BEGIN{
    if (v <= s) { print "1.000"; exit }
    if (v >= h) { print "0.000"; exit }
    printf "%.3f", (h - v) / (h - s);
  }'
}

NEXT_ID=0
for ((i=0; i<MIN_WORKERS; i++)); do
  spawn_worker "$NEXT_ID"; NEXT_ID=$((NEXT_ID+1))
done

# === Состояние интегратора ===
# DEBT — сколько байт мы "должны" скачать сверх уже скачанного
# DEBT растет на (TX_delta * RATIO) каждый тик
# DEBT тратится на target_rate * dt каждый тик
# target_rate движется к (DEBT / SMOOTH_WINDOW) с экспоненциальным сглаживанием

DEBT=0
TARGET_RATE_BPS=$(awk -v m="$BASE_MBIT" 'BEGIN{printf "%.0f", m*1000000/8}')   # старт = базовый шум
EMA_ALPHA="0.05"   # коэффициент сглаживания TARGET_RATE (медленный)
MAX_NOISE_BPS=$(awk -v m="$MAX_NOISE_MBIT" 'BEGIN{printf "%.0f", m*1000000/8}')   # потолок прибавки

TX_PREV=$(<"$TX_FILE")
RX_PREV=$(<"$RX_FILE")
T_PREV=$(date +%s.%N)

SUM_TX=0; SUM_RX=0; SUM_TGT=0; SUM_N=0; SUM_DEBT=0; TICKS=0
LAST_SUMMARY=$(date +%s)

BASE_BPS=$(awk -v m="$BASE_MBIT" 'BEGIN{printf "%.0f", m*1000000/8}')

while true; do
  sleep 2

  TX_NOW=$(<"$TX_FILE")
  RX_NOW=$(<"$RX_FILE")
  T_NOW=$(date +%s.%N)

  read DT TX_DELTA RX_DELTA < <(awk \
    -v ta="$TX_PREV" -v tb="$TX_NOW" \
    -v ra="$RX_PREV" -v rb="$RX_NOW" \
    -v t1="$T_PREV"  -v t2="$T_NOW"  \
    'BEGIN{
       dt=t2-t1; if(dt<=0) dt=1;
       dtx=tb-ta; if(dtx<0) dtx=0;
       drx=rb-ra; if(drx<0) drx=0;
       printf "%.3f %.0f %.0f", dt, dtx, drx;
     }')

  TX_PREV="$TX_NOW"; RX_PREV="$RX_NOW"; T_PREV="$T_NOW"

  TX_RATE=$(awk -v d="$TX_DELTA" -v t="$DT" 'BEGIN{printf "%.0f", d/t}')
  RX_RATE=$(awk -v d="$RX_DELTA" -v t="$DT" 'BEGIN{printf "%.0f", d/t}')

  # 1) Растим долг от свежего TX, но не больше чем (TX + MAX_NOISE) * dt.
  #    То есть прибавка RX над TX за тик ограничена MAX_NOISE_BPS.
  RAW_ADD=$(awk -v tx="$TX_DELTA" -v r="$RATIO" 'BEGIN{printf "%.0f", tx*r}')
  CAP_ADD=$(awk -v tx="$TX_DELTA" -v cap="$MAX_NOISE_BPS" -v dt="$DT" \
    'BEGIN{printf "%.0f", tx + cap*dt}')
  if (( RAW_ADD > CAP_ADD )); then
    ADD_DEBT=$CAP_ADD
  else
    ADD_DEBT=$RAW_ADD
  fi
  DEBT=$(( DEBT + ADD_DEBT ))

  # 2) Списываем то, что уже скачали за этот тик
  DEBT=$(( DEBT - RX_DELTA ))
  (( DEBT < 0 )) && DEBT=0

  # 3) Желаемая скорость = долг / окно сглаживания + базовый шум,
  #    но не больше чем TX_RATE + MAX_NOISE_BPS (страховка)
  WANT_BPS=$(awk -v d="$DEBT" -v w="$SMOOTH_WINDOW" -v b="$BASE_BPS" \
    'BEGIN{printf "%.0f", d/w + b}')
  HARD_CAP=$(( TX_RATE + MAX_NOISE_BPS ))
  (( WANT_BPS > HARD_CAP )) && WANT_BPS=$HARD_CAP

  # 3a) Глушим по нагрузке CPU и по загрузке канала.
  #     Чем выше нагрузка — тем меньше множитель (вплоть до 0).
  CPU_PCT=$(read_cpu_pct)
  LINK_USED_MBIT=$(awk -v tx="$TX_RATE" -v rx="$RX_RATE" \
    'BEGIN{printf "%.0f", (tx+rx)*8/1000000}')
  LINK_PCT=$(awk -v u="$LINK_USED_MBIT" -v c="$LINK_MBIT" \
    'BEGIN{if(c<1) c=1; printf "%.0f", 100*u/c}')

  CPU_MUL=$(soft_hard_multiplier  "$CPU_PCT"  "$CPU_SOFT_PCT"  "$CPU_HARD_PCT")
  LINK_MUL=$(soft_hard_multiplier "$LINK_PCT" "$LINK_SOFT_PCT" "$LINK_HARD_PCT")

  # Берем минимум — самая зажатая ось определяет душение.
  THROTTLE=$(awk -v a="$CPU_MUL" -v b="$LINK_MUL" 'BEGIN{print (a<b)?a:b}')

  # Множим целевую скорость на throttle. При throttle=0 → шум полностью отключен,
  # но долг продолжает копиться и будет отработан позже, когда нагрузка спадет.
  WANT_BPS=$(awk -v w="$WANT_BPS" -v m="$THROTTLE" 'BEGIN{printf "%.0f", w*m}')

  # 4) EMA-сглаживание TARGET_RATE_BPS, чтобы не дергался
  TARGET_RATE_BPS=$(awk -v cur="$TARGET_RATE_BPS" -v want="$WANT_BPS" -v a="$EMA_ALPHA" \
    'BEGIN{printf "%.0f", cur + a*(want-cur)}')

  # 5) Добавляем jitter ±JITTER, чтобы график выглядел как органический шум
  JITTER_RATE=$(awk -v r="$TARGET_RATE_BPS" -v j="$JITTER" -v rnd="$RANDOM" \
    'BEGIN{
       srand(rnd);
       k = 1 + j*(2*rand()-1);   # коэффициент в диапазоне [1-j, 1+j]
       printf "%.0f", r*k;
     }')

  # 6) Регулируем число воркеров под JITTER_RATE.
  #    При сильном throttling (множитель ниже 0.1) — гасим всех воркеров,
  #    игнорируя MIN_WORKERS, чтобы реально отпустить нагрузку.
  N=$(count_workers)
  LOW=$(awk  -v t="$JITTER_RATE" 'BEGIN{printf "%.0f", t*0.85}')
  HIGH=$(awk -v t="$JITTER_RATE" 'BEGIN{printf "%.0f", t*1.15}')

  EFFECTIVE_MIN=$MIN_WORKERS
  THROTTLE_LOW=$(awk -v m="$THROTTLE" 'BEGIN{print (m<0.1)?1:0}')
  (( THROTTLE_LOW == 1 )) && EFFECTIVE_MIN=0

  ACTION=""
  if (( THROTTLE_LOW == 1 )) && (( N > 0 )); then
    # Аварийный сброс: глушим всех, пока нагрузка не спадет.
    kill_one_worker
    ACTION="kill(throttle)"
  elif (( RX_RATE < LOW )) && (( N < MAX_WORKERS )); then
    spawn_worker "$NEXT_ID"; NEXT_ID=$((NEXT_ID+1))
    ACTION="+1"
  elif (( RX_RATE > HIGH )) && (( N > EFFECTIVE_MIN )); then
    kill_one_worker
    ACTION="-1"
  fi

  if [[ "$VERBOSE" == "1" ]]; then
    TX_M=$(awk -v r="$TX_RATE" 'BEGIN{printf "%.1f", r*8/1000000}')
    RX_M=$(awk -v r="$RX_RATE" 'BEGIN{printf "%.1f", r*8/1000000}')
    TGT_M=$(awk -v r="$JITTER_RATE" 'BEGIN{printf "%.1f", r*8/1000000}')
    DEBT_MB=$(awk -v d="$DEBT" 'BEGIN{printf "%.1f", d/1048576}')
    echo "[$(date '+%H:%M:%S')] TX=${TX_M} RX=${RX_M} target=${TGT_M} Mbit/s debt=${DEBT_MB}MB workers=$N cpu=${CPU_PCT}% link=${LINK_PCT}% throttle=${THROTTLE} $ACTION"
  else
    SUM_TX=$(( SUM_TX + TX_RATE ))
    SUM_RX=$(( SUM_RX + RX_RATE ))
    SUM_TGT=$(( SUM_TGT + JITTER_RATE ))
    SUM_N=$(( SUM_N + N ))
    SUM_DEBT=$(( SUM_DEBT + DEBT ))
    TICKS=$(( TICKS + 1 ))

    NOW=$(date +%s)
    if (( NOW - LAST_SUMMARY >= 60 )); then
      AVG_TX=$(( SUM_TX / TICKS ))
      AVG_RX=$(( SUM_RX / TICKS ))
      AVG_TGT=$(( SUM_TGT / TICKS ))
      AVG_DEBT=$(( SUM_DEBT / TICKS ))
      AVG_N=$(awk -v s="$SUM_N" -v t="$TICKS" 'BEGIN{printf "%.1f", s/t}')

      TX_M=$(awk -v r="$AVG_TX"  'BEGIN{printf "%.1f", r*8/1000000}')
      RX_M=$(awk -v r="$AVG_RX"  'BEGIN{printf "%.1f", r*8/1000000}')
      TGT_M=$(awk -v r="$AVG_TGT" 'BEGIN{printf "%.1f", r*8/1000000}')
      DEBT_MB=$(awk -v d="$AVG_DEBT" 'BEGIN{printf "%.1f", d/1048576}')
      RATIO_NOW=$(awk -v t="$AVG_TX" -v r="$AVG_RX" 'BEGIN{if(t<1) t=1; printf "%.2f", r/t}')

      echo "[$(date '+%F %H:%M:%S')] avg/min: TX=${TX_M} RX=${RX_M} target=${TGT_M} Mbit/s | ratio=${RATIO_NOW} | debt=${DEBT_MB}MB workers~${AVG_N} cpu=${CPU_PCT}% link=${LINK_PCT}% throttle=${THROTTLE}"

      SUM_TX=0; SUM_RX=0; SUM_TGT=0; SUM_N=0; SUM_DEBT=0; TICKS=0
      LAST_SUMMARY=$NOW
    fi
  fi
done
NOISE_EOF
chmod +x "$SCRIPT_PATH"

echo "[3/9] Создаю systemd unit $SERVICE_PATH..."
cat > "$SERVICE_PATH" <<UNIT_EOF
[Unit]
Description=Adaptive Traffic Noise (smoothed, decoupled from TX shape)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-$ENV_PATH
ExecStart=$SCRIPT_PATH
Restart=always
RestartSec=10
User=root
LimitNOFILE=65536
StandardOutput=append:$LOG_PATH
StandardError=append:$LOG_PATH

[Install]
WantedBy=multi-user.target
UNIT_EOF

if [[ ! -f "$ENV_PATH" ]]; then
  cat > "$ENV_PATH" <<ENV_EOF
# Конфигурация traffic-noise (опционально). После правки: systemctl restart $SERVICE_NAME
#IFACE=eth0
#RATIO=2.5
#MIN_WORKERS=1
#MAX_WORKERS=32
#CHUNK_MB=200
#SMOOTH_WINDOW=300       # окно сглаживания, сек (300 = долг гасится за 5 минут)
#BASE_MBIT=10            # базовый шум при idle, Mbit/s
#MAX_NOISE_MBIT=400      # потолок прибавки RX над TX (RX <= TX + MAX_NOISE_MBIT)
#JITTER=0.30             # рандом-разброс ±30%
#CPU_SOFT_PCT=70         # выше этого CPU% — плавно душим шум (множитель < 1)
#CPU_HARD_PCT=90         # выше этого CPU% — шум полностью отключен
#LINK_MBIT=1000          # потолок сетевого канала, Mbit/s
#LINK_SOFT_PCT=70        # выше этого% от LINK_MBIT по TX+RX — душим шум
#LINK_HARD_PCT=90        # выше этого% — шум полностью отключен
#VERBOSE=0
ENV_EOF
fi

echo "[4/9] Создаю logrotate-конфиг $LOGROTATE_PATH..."
cat > "$LOGROTATE_PATH" <<LR_EOF
$LOG_PATH {
    daily
    rotate 7
    maxsize 50M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
LR_EOF
chmod 644 "$LOGROTATE_PATH"

touch "$LOG_PATH"
chmod 644 "$LOG_PATH"

echo "[5/9] Записываю ram_noise.sh в $RAM_SCRIPT_PATH..."
cat > "$RAM_SCRIPT_PATH" <<'RAM_EOF'
#!/bin/bash
# ram_noise.sh — RAM-балласт с базовой целью ~20% и периодическими спайками.

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

mem_total_mb() { awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo; }
mem_available_mb() { awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo; }
mem_used_pct() { awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END{printf "%.0f", (t-a)*100/t}' /proc/meminfo; }

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

IS_SPIKE=0
SPIKE_END=0
TARGET_MB=$(pick_base_target)
NEXT_RETARGET=$(( $(date +%s) + RETARGET_MIN + RANDOM % (RETARGET_MAX - RETARGET_MIN + 1) ))
LAST_LOG=$(date +%s)

while true; do
  NOW=$(date +%s)

  if (( IS_SPIKE == 1 )) && (( NOW >= SPIKE_END )); then
    IS_SPIKE=0
    TARGET_MB=$(pick_base_target)
    [[ "$VERBOSE" == "1" ]] && echo "[$(date '+%H:%M:%S')] spike конец, base=${TARGET_MB}MB"
    NEXT_RETARGET=$(( NOW + RETARGET_MIN + RANDOM % (RETARGET_MAX - RETARGET_MIN + 1) ))
  fi

  if (( IS_SPIKE == 0 )) && (( NOW >= NEXT_RETARGET )); then
    if (( RANDOM % 100 < SPIKE_CHANCE_PCT )); then
      IS_SPIKE=1
      TARGET_MB=$(pick_spike_target)
      SPIKE_DUR=$(( SPIKE_DURATION_MIN + RANDOM % (SPIKE_DURATION_MAX - SPIKE_DURATION_MIN + 1) ))
      SPIKE_END=$(( NOW + SPIKE_DUR ))
      [[ "$VERBOSE" == "1" ]] && echo "[$(date '+%H:%M:%S')] SPIKE на ${SPIKE_DUR}s до ${TARGET_MB}MB"
    else
      TARGET_MB=$(pick_base_target)
      [[ "$VERBOSE" == "1" ]] && echo "[$(date '+%H:%M:%S')] base=${TARGET_MB}MB"
    fi
    NEXT_RETARGET=$(( NOW + RETARGET_MIN + RANDOM % (RETARGET_MAX - RETARGET_MIN + 1) ))
  fi

  CUR=$(ballast_mb)
  USED_PCT=$(mem_used_pct)
  AVAIL_MB=$(mem_available_mb)

  if (( USED_PCT > SAFETY_PCT )); then
    NEW=$(( CUR - STEP_MB * 2 ))
    (( NEW < 0 )) && NEW=0
    truncate -s "${NEW}M" "$BALLAST" 2>/dev/null || :
    [[ "$VERBOSE" == "1" ]] && echo "[$(date '+%H:%M:%S')] OVER_SAFETY ${USED_PCT}% — урезал до ${NEW}MB"
  elif (( CUR < TARGET_MB )); then
    HEADROOM_MB=$(( SAFETY_MB - (TOTAL_MB - AVAIL_MB) ))
    if (( HEADROOM_MB > STEP_MB * 2 )); then
      ADD=$STEP_MB
      (( CUR + ADD > TARGET_MB )) && ADD=$(( TARGET_MB - CUR ))
      NEW=$(( CUR + ADD ))
      dd if=/dev/urandom of="$BALLAST" bs=1M count="$ADD" \
         oflag=append conv=notrunc seek="$CUR" status=none 2>/dev/null || :
      truncate -s "${NEW}M" "$BALLAST" 2>/dev/null || :
    fi
  elif (( CUR > TARGET_MB + STEP_MB )); then
    NEW=$(( CUR - STEP_MB ))
    (( NEW < TARGET_MB )) && NEW=$TARGET_MB
    truncate -s "${NEW}M" "$BALLAST" 2>/dev/null || :
  fi

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
RAM_EOF
chmod +x "$RAM_SCRIPT_PATH"

echo "[6/9] Создаю systemd unit $RAM_SERVICE_PATH..."
cat > "$RAM_SERVICE_PATH" <<RAM_UNIT_EOF
[Unit]
Description=RAM Noise (random ballast in tmpfs to mimic loaded server)
After=network-online.target

[Service]
Type=simple
EnvironmentFile=-$RAM_ENV_PATH
ExecStart=$RAM_SCRIPT_PATH
Restart=always
RestartSec=10
User=root
StandardOutput=append:$RAM_LOG_PATH
StandardError=append:$RAM_LOG_PATH

[Install]
WantedBy=multi-user.target
RAM_UNIT_EOF

if [[ ! -f "$RAM_ENV_PATH" ]]; then
  cat > "$RAM_ENV_PATH" <<RAM_ENV_EOF
# Конфигурация ram-noise (опционально). После правки: systemctl restart $RAM_SERVICE_NAME
#BASE_MIN_PCT=15        # базовая цель, нижняя граница (% от total RAM)
#BASE_MAX_PCT=25        # базовая цель, верхняя граница
#SPIKE_MIN_PCT=35       # спайк, нижняя граница
#SPIKE_MAX_PCT=55       # спайк, верхняя граница
#SPIKE_CHANCE_PCT=15    # вероятность спайка при ретаргете (%)
#SPIKE_DURATION_MIN=20  # длительность спайка, мин (сек)
#SPIKE_DURATION_MAX=60  # длительность спайка, макс (сек)
#SAFETY_PCT=85          # жесткий потолок общей загрузки RAM
#STEP_MB=50             # шаг изменения, МБ
#TICK=3                 # частота проверки, сек
#RETARGET_MIN=30        # минимум секунд между ретаргетами
#RETARGET_MAX=120       # максимум секунд между ретаргетами
#VERBOSE=0
RAM_ENV_EOF
fi

cat > "$RAM_LOGROTATE_PATH" <<RAM_LR_EOF
$RAM_LOG_PATH {
    daily
    rotate 7
    maxsize 50M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
RAM_LR_EOF
chmod 644 "$RAM_LOGROTATE_PATH"

touch "$RAM_LOG_PATH"
chmod 644 "$RAM_LOG_PATH"

echo "[7/9] Перезагружаю systemd, включаю автозапуск..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
systemctl enable "$RAM_SERVICE_NAME" >/dev/null 2>&1

echo "[8/9] Запускаю traffic-noise..."
systemctl restart "$SERVICE_NAME"

echo "[9/9] Запускаю ram-noise..."
systemctl restart "$RAM_SERVICE_NAME"

sleep 1
systemctl status "$SERVICE_NAME" --no-pager -l || true
echo
systemctl status "$RAM_SERVICE_NAME" --no-pager -l || true

echo
echo "Готово."
echo "Трафик: tail -f $LOG_PATH"
echo "RAM:    tail -f $RAM_LOG_PATH"
echo "Стоп:   systemctl stop $SERVICE_NAME $RAM_SERVICE_NAME"
echo "Free:   free -h     (увидишь занятую память в used/buff/cache)"
