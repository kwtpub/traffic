#!/bin/bash
# install.sh — автоматическая установка traffic_noise (непрерывный режим)
# как systemd-сервиса. Скачивает в RATIO раз быстрее, чем сервер отдает (TX),
# подстраивая скорость в реальном времени без окон и порогов.
#
# Использование на сервере (Debian/Ubuntu, от root):
#   curl -fsSL https://raw.githubusercontent.com/strelkatech/traffic-noise/main/install.sh | sudo bash

set -euo pipefail

SCRIPT_PATH="/usr/local/bin/traffic_noise.sh"
SERVICE_PATH="/etc/systemd/system/traffic-noise.service"
ENV_PATH="/etc/default/traffic-noise"
LOG_PATH="/var/log/traffic_noise.log"
SERVICE_NAME="traffic-noise"

if [[ $EUID -ne 0 ]]; then
  echo "Ошибка: запускай через sudo или от root." >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "Ошибка: systemd не найден. Скрипт рассчитан на Debian/Ubuntu." >&2
  exit 1
fi

echo "[1/5] Устанавливаю зависимости..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates gawk iproute2 vnstat >/dev/null
systemctl enable --now vnstat >/dev/null 2>&1 || true

echo "[2/5] Записываю traffic_noise.sh в $SCRIPT_PATH..."
cat > "$SCRIPT_PATH" <<'NOISE_EOF'
#!/bin/bash
# Непрерывный адаптивный шум: RX_rate = RATIO * TX_rate, обновление 1 раз/сек.

set -u

RATIO="${RATIO:-2.5}"
IFACE="${IFACE:-$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')}"

FILES=(
  "https://speed.hetzner.de/10GB.bin"
  "https://speed.hetzner.de/1GB.bin"
  "http://speedtest.tele2.net/10GB.zip"
  "http://speedtest.tele2.net/1GB.zip"
  "https://proof.ovh.net/files/10Gb.dat"
  "https://proof.ovh.net/files/1Gb.dat"
  "https://releases.ubuntu.com/jammy/ubuntu-22.04.4-live-server-amd64.iso"
  "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.5.0-amd64-netinst.iso"
)

if [[ -z "$IFACE" ]]; then
  echo "Не удалось определить интерфейс. Задай IFACE=eth0 в /etc/default/traffic-noise" >&2
  exit 1
fi

TX_FILE="/sys/class/net/$IFACE/statistics/tx_bytes"
if [[ ! -r "$TX_FILE" ]]; then
  echo "Нет доступа к $TX_FILE" >&2
  exit 1
fi

cleanup() { exit 0; }
trap cleanup SIGINT SIGTERM EXIT

echo "Старт. Интерфейс=$IFACE RATIO=$RATIO (непрерывный режим)"

TX_PREV=$(<"$TX_FILE")
T_PREV=$(date +%s.%N)

while true; do
  sleep 1

  TX_NOW=$(<"$TX_FILE")
  T_NOW=$(date +%s.%N)

  TX_RATE_BPS=$(awk -v a="$TX_PREV" -v b="$TX_NOW" -v t1="$T_PREV" -v t2="$T_NOW" \
    'BEGIN{dt=t2-t1; if(dt<=0)dt=1; d=b-a; if(d<0)d=0; printf "%.0f", d/dt}')

  TX_PREV="$TX_NOW"
  T_PREV="$T_NOW"

  TARGET_KBPS=$(awk -v r="$TX_RATE_BPS" -v k="$RATIO" 'BEGIN{v=(r*k)/1024; if(v<1)v=1; printf "%.0f", v}')

  URL=${FILES[$RANDOM % ${#FILES[@]}]}
  HOST=$(echo "$URL" | awk -F/ '{print $3}')

  TX_MB=$(awk -v r="$TX_RATE_BPS" 'BEGIN{printf "%.2f", r/1048576}')
  TGT_MB=$(awk -v k="$TARGET_KBPS" 'BEGIN{printf "%.2f", k/1024}')
  echo "[$(date '+%H:%M:%S')] TX=${TX_MB}MB/s → RX=${TGT_MB}MB/s ← $HOST"

  curl -s --max-time 30 \
    --user-agent "Mozilla/5.0 (X11; Linux x86_64)" \
    --limit-rate "${TARGET_KBPS}k" \
    -r "0-5242879" \
    -o /dev/null \
    "$URL" || true
done
NOISE_EOF
chmod +x "$SCRIPT_PATH"

echo "[3/5] Создаю systemd unit $SERVICE_PATH..."
cat > "$SERVICE_PATH" <<UNIT_EOF
[Unit]
Description=Adaptive Traffic Noise (continuous, RX_rate = RATIO * TX_rate)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-$ENV_PATH
ExecStart=$SCRIPT_PATH
Restart=always
RestartSec=10
User=root
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
ENV_EOF
fi

touch "$LOG_PATH"
chmod 644 "$LOG_PATH"

echo "[4/5] Перезагружаю systemd, включаю автозапуск..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1

echo "[5/5] Запускаю сервис..."
systemctl restart "$SERVICE_NAME"

sleep 1
systemctl status "$SERVICE_NAME" --no-pager -l || true

echo
echo "Готово."
echo "Логи:     tail -f $LOG_PATH"
echo "Журнал:   journalctl -u $SERVICE_NAME -f"
echo "Трафик:   vnstat -l    (live)   |   vnstat -d    (по дням, проверить RX:TX)"
echo "Стоп:     systemctl stop $SERVICE_NAME"
