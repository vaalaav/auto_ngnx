# Auto NGINX VPS Setup

<p align="center">

![Shell](https://img.shields.io/badge/Shell-Bash-green?style=for-the-badge&logo=gnu-bash)
![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04_|_24.04-E95420?style=for-the-badge&logo=ubuntu)
![NGINX](https://img.shields.io/badge/NGINX-Stable-009639?style=for-the-badge&logo=nginx)
![CrowdSec](https://img.shields.io/badge/CrowdSec-Supported-00AEEF?style=for-the-badge)
![License](https://img.shields.io/badge/License-MIT-blue?style=for-the-badge)

</p>

<p align="center">

Автоматический скрипт для развёртывания и настройки VPS на Ubuntu.

Позволяет за несколько минут установить и настроить:

<b>NGINX</b> • <b>HTML-сайт из GitHub</b> • <b>SSL Let's Encrypt</b> • <b>CrowdSec</b> • <b>CyberOK Skipa IPs</b> • <b>TCP BBR</b> • <b>myserverinfo</b>

</p>

---

# Возможности

✅ Установка и настройка NGINX

✅ Развёртывание сайта из GitHub

✅ Автоматическое получение SSL сертификата Let's Encrypt

✅ Установка и настройка CrowdSec

✅ Установка CyberOK Skipa IPs

✅ Включение TCP BBR

✅ Установка утилиты `myserverinfo`

✅ Просмотр состояния сервера и сервисов

✅ Интерактивное меню

---

# Скриншоты

## Главное меню

Добавьте сюда скриншот:

```markdown
![Главное меню](images/main-menu.png)
```

Пример:

```text
+--------------------------------+

      AUTO NGINX VPS

+--------------------------------+

1. Установить всё

2. Установить/Обновить сайт

3. Установить/Обновить SSL

4. Установить/Обновить CrowdSec

5. Установить/Обновить CyberOK Skipa IPs

6. Включить BBR

7. Установить/Обновить myserverinfo

8. Показать информацию о сервере

0. Выход
```

---

## myserverinfo

Добавьте сюда скриншот:

```markdown
![myserverinfo](images/myserverinfo.png)
```

Пример:

```text
===================================

Информация о сервере

===================================

ОС: Ubuntu 24.04

Ядро: 6.x

CPU: Intel Xeon

RAM: 2 GB

Диск: 20 GB

IPv4: xxx.xxx.xxx.xxx

-----------------------------------

NGINX: Работает

SSL: Установлен

CrowdSec: Работает

Firewall Bouncer: Работает

CyberOK: Установлен

BBR: Включен

===================================
```

---

# Поддерживаемые ОС

Рекомендуется:

- Ubuntu 24.04 LTS

Также поддерживается:

- Ubuntu 22.04 LTS

---

# Устанавливаемые компоненты

| Компонент | Назначение |
|----------|------------|
| NGINX | Веб-сервер |
| Website | HTML сайт из GitHub |
| SSL | Let's Encrypt + Certbot |
| CrowdSec | Защита от атак |
| Firewall Bouncer | Интеграция CrowdSec с firewall |
| CyberOK | Списки доверенных IP |
| TCP BBR | Современный алгоритм TCP |
| myserverinfo | Мониторинг сервера |

---

# Быстрый старт

Скачайте и запустите скрипт:

```bash
curl -fsSL https://raw.githubusercontent.com/vaalaav/auto_ngnx/main/setup-vps.sh -o setup-vps.sh && sudo bash setup-vps.sh
```

---

# Главное меню

```text
1. Установить всё

2. Установить/Обновить сайт

3. Установить/Обновить SSL

4. Установить/Обновить CrowdSec

5. Установить/Обновить CyberOK Skipa IPs

6. Включить BBR

7. Установить/Обновить myserverinfo

8. Показать информацию о сервере

0. Выход
```

---

# Описание пунктов меню

## 1. Установить всё

Устанавливает:

- NGINX
- Website
- SSL
- CrowdSec
- Firewall Bouncer
- CyberOK
- BBR
- myserverinfo

---

## 2. Установить/Обновить сайт

Позволяет:

- указать GitHub репозиторий;
- скачать HTML шаблон;
- обновить существующий сайт.

---

## 3. Установить/Обновить SSL

Устанавливает:

- Certbot;
- SSL сертификат Let's Encrypt;
- автоматическое продление сертификатов.

---

## 4. Установить/Обновить CrowdSec

Устанавливает:

- CrowdSec Engine;
- Firewall Bouncer;
- коллекцию Linux;
- коллекцию NGINX;
- коллекцию SSH.

Полезные команды:

```bash
sudo cscli metrics
```

```bash
sudo cscli decisions list
```

```bash
sudo cscli collections list
```

---

## 5. Установить/Обновить CyberOK Skipa IPs

Устанавливает и обновляет список доверенных IP адресов.

---

## 6. Включить BBR

Включает:

```text
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
```

Проверить:

```bash
sysctl net.ipv4.tcp_congestion_control
```

Ожидаемый результат:

```text
net.ipv4.tcp_congestion_control = bbr
```

---

## 7. Установить/Обновить myserverinfo

После установки доступна команда:

```bash
myserverinfo
```

Показывает:

- ОС;
- Ядро;
- CPU;
- RAM;
- Диск;
- IP адреса;
- состояние NGINX;
- состояние SSL;
- состояние CrowdSec;
- состояние Firewall Bouncer;
- состояние CyberOK;
- состояние BBR.

---

## 8. Показать информацию о сервере

Доступные разделы:

```text
1. Вся информация

2. Система

3. NGINX

4. Website

5. SSL

6. CrowdSec

7. Firewall Bouncer

8. CyberOK Skipa IPs

9. BBR
```

---

# Требования

- Ubuntu 22.04 или Ubuntu 24.04;
- Root-права;
- Доступ в Интернет;
- Свободные порты:
  - 80/tcp
  - 443/tcp;
- Доменное имя для SSL.

---

# Рекомендации по безопасности

Рекомендуется:

- отключить вход по SSH по паролю;
- использовать SSH ключи;
- регулярно обновлять систему:

```bash
sudo apt update && sudo apt upgrade -y
```

- использовать CrowdSec для защиты SSH и NGINX.

---

# Структура проекта

```text
auto_ngnx/

├── setup-vps.sh

├── README.md

└── LICENSE
```

---

# Планы развития

- [ ] Установка Docker
- [ ] Установка Docker Compose
- [ ] Автоматические резервные копии
- [ ] Поддержка Fail2Ban
- [ ] Telegram уведомления
- [ ] Автоматическое обновление
- [ ] Установка WireGuard
- [ ] Поддержка AmneziaWG
- [ ] Шаблоны Reverse Proxy
- [ ] Поддержка нескольких сайтов

---

# Лицензия

MIT License

---

# Автор

**vaalaav**

GitHub:

https://github.com/vaalaav

Если проект оказался полезен, поставьте ⭐.
