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

## Конфигурация

Все параметры — в `/etc/default/traffic-noise`. После правки:

```bash
sudo systemctl restart traffic-noise
```

| Переменная | По умолчанию | Назначение |
|---|---:|---|
| `IFACE` | автоопределение | Сетевой интерфейс. Если автоопределение ошибочно — задай вручную (`eth0`, `ens3`, `enp1s0`) |
| `RATIO` | `2.5` | Целевое соотношение `RX:TX`. Для маскировки под мобильного клиента можно поднять до `3.5–4` |
| `WINDOW` | `60` | Окно замера в секундах. Меньше окно — быстрее реакция, но чаще запросы |
| `MAX_DOWNLOAD_MB` | `500` | Потолок скачивания за одно окно. Защита от runaway-нагрузки и лимитов VPS |
| `MIN_TX_BYTES` | `1048576` | Порог idle (в байтах). Ниже — окно пропускается |
| `LIMIT_RATE` | `0` | Лимит скорости curl. `0` = без лимита; `5M` = не быстрее 5 МБ/с — полезно, чтобы не забивать канал клиентов |

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

После суток работы колонка `rx` должна быть в `RATIO` раз больше `tx`. Если соотношение не дотягивает — подними `MAX_DOWNLOAD_MB` или проверь логи (возможно, какие-то зеркала недоступны).

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
