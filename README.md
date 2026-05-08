# traffic-noise
---

## Быстрый старт

Установка одной командой на Debian/Ubuntu (требуется root):

```bash
curl -fsSL https://raw.githubusercontent.com/strelkatech/traffic-noise/main/install.sh | sudo bash
```

После установки сервис уже запущен и добавлен в автозагрузку. Проверка:

```bash
sudo systemctl status traffic-noise
tail -f /var/log/traffic_noise.log
```

---

## Принцип работы

Скрипт работает в непрерывном режиме без окон и порогов:

1. Каждую секунду читает `/sys/class/net/<iface>/statistics/tx_bytes`
2. Считает мгновенную скорость TX (байт/сек)
3. Запускает `curl --limit-rate` с лимитом `RATIO × TX_rate` КБ/с
4. Curl скачивает чанк 5 МБ, цикл повторяется через секунду

Чем быстрее сервер отдает данные клиентам — тем быстрее скрипт качает. Когда сервер idle — лимит почти ноль, скрипт фактически простаивает. Никакой ручной настройки не требуется.

## Конфигурация (опционально)

По умолчанию все автоматическое. Если нужно — переопредели в `/etc/default/traffic-noise`:

| Переменная | По умолчанию | Назначение |
|---|---:|---|
| `IFACE` | автоопределение | Сетевой интерфейс. Задай вручную (`eth0`, `ens3`), если автоопределение ошиблось |
| `RATIO` | `2.5` | Целевое соотношение `RX:TX`. Для маскировки под мобильного клиента можно поднять до `3.5–4` |

После правки:

```bash
sudo systemctl restart traffic-noise
```

---

## Управление

```bash
# Состояние
sudo systemctl status traffic-noise
sudo journalctl -u traffic-noise -f

# Логи скрипта
tail -f /var/log/traffic_noise.log

# Перезапуск / остановка
sudo systemctl restart traffic-noise
sudo systemctl stop traffic-noise
sudo systemctl disable traffic-noise   # убрать из автозагрузки
```

### Проверка результата

Главная метрика — соотношение `rx`/`tx` в выводе `vnstat`:

```bash
vnstat -d        # по дням
vnstat -h        # по часам
vnstat -l        # live-скорость
```

После суток работы колонка `rx` должна быть в `RATIO` раз больше `tx`. Если соотношение не дотягивает — проверь логи: возможно, какие-то зеркала недоступны или канал упирается в потолок провайдера.

---


## Удаление

```bash
sudo systemctl disable --now traffic-noise
sudo rm /etc/systemd/system/traffic-noise.service
sudo rm /usr/local/bin/traffic_noise.sh
sudo rm /etc/default/traffic-noise
sudo rm /var/log/traffic_noise.log
sudo systemctl daemon-reload
```
