#!/bin/bash
###############################################################################
#
#   СКРИПТ АВТОМАТИЧЕСКОЙ УСТАНОВКИ И НАСТРОЙКИ VPS (Ubuntu 24.04 LTS)
#
#   Возможности:
#     - установка и настройка Nginx + сайт из git-репозитория;
#     - получение и автопродление SSL-сертификата Let's Encrypt;
#     - установка CrowdSec + firewall-bouncer (iptables/nftables);
#     - установка блок-листа CyberOK Skipa IPs с автообновлением по таймеру;
#     - включение BBR (congestion control);
#     - команда myserverinfo для просмотра состояния сервера.
#
#   Скрипт диалоговый, запускается от root, безопасен для повторного запуска.
#   Все действия логируются в /var/log/myserver-install.log
#
###############################################################################

# Не используем "set -e", т.к. это диалоговое меню, и после ошибки одного
# пункта меню скрипт должен вернуться в меню, а не завершиться полностью.
# Вместо этого после каждой важной команды проверяем код возврата $?.
set -o pipefail

###############################################################################
#                              ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
###############################################################################

# --- Цвета для красивого вывода в терминал ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'   # сброс цвета (No Color)

# --- Пути и константы ---
LOG_FILE="/var/log/myserver-install.log"          # общий лог установки
CONFIG_DIR="/etc/myserver"                        # каталог для хранения конфигурации скрипта
CONFIG_FILE="${CONFIG_DIR}/config.conf"           # сохранённые домен/репозиторий/email

SITE_PATH="/var/www/site"                         # каталог с сайтом
NGINX_CONF="/etc/nginx/sites-available/site"      # конфиг nginx для сайта
NGINX_ENABLED="/etc/nginx/sites-enabled/site"     # симлинк на конфиг

CYBEROK_DIR="/opt/CyberOK_Skipa_ips"              # каталог с репозиторием блок-листа
CYBEROK_REPO="https://github.com/tread-lightly/CyberOK_Skipa_ips.git"
CYBEROK_UPDATE_SCRIPT="/usr/local/bin/update-cyberok.sh"
CYBEROK_LOG="/var/log/cyberok-update.log"
CYBEROK_IPSET="cyberok_skipa"                     # имя ipset-набора с заблокированными подсетями

MYSERVERINFO_PATH="/usr/local/bin/myserverinfo"   # путь к команде myserverinfo

# --- Переменные, которые сохраняются между запусками скрипта ---
SITE_DOMAIN=""
SITE_REPO=""
CERTBOT_EMAIL=""

# Если конфиг уже существует (повторный запуск скрипта) - подгружаем значения,
# чтобы не спрашивать у пользователя то, что он уже вводил ранее.
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

###############################################################################
#                       ФУНКЦИИ ЛОГИРОВАНИЯ И ВЫВОДА СООБЩЕНИЙ
###############################################################################

# Записывает сообщение в лог-файл с отметкой времени
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Информационное сообщение (синий цвет)
msg_info() {
    echo -e "${BLUE}[ИНФО]${NC} $1"
    log "[INFO] $1"
}

# Сообщение об успешном выполнении (зелёный цвет)
msg_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
    log "[OK] $1"
}

# Предупреждение (жёлтый цвет)
msg_warn() {
    echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $1"
    log "[WARN] $1"
}

# Сообщение об ошибке (красный цвет)
msg_err() {
    echo -e "${RED}[ОШИБКА]${NC} $1"
    log "[ERROR] $1"
}

# Заголовок текущего шага установки (голубой цвет, со стрелкой)
msg_step() {
    echo -e "${CYAN}==> $1${NC}"
    log "==> $1"
}

###############################################################################
#                          СЛУЖЕБНЫЕ (ВСПОМОГАТЕЛЬНЫЕ) ФУНКЦИИ
###############################################################################

# Проверка, что скрипт запущен от root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}Этот скрипт необходимо запускать от пользователя root!${NC}"
        echo -e "Запустите так: ${BOLD}sudo bash $0${NC}"
        exit 1
    fi
}

# Устанавливает пакет $1, если он ещё не установлен (идемпотентность).
# Возвращает 0 при успехе, 1 при ошибке.
ensure_package() {
    local pkg="$1"
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        # пакет уже установлен - ничего не делаем
        return 0
    fi

    msg_step "Установка пакета: $pkg"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        msg_err "Не удалось установить пакет $pkg (см. $LOG_FILE)"
        return 1
    fi
    msg_ok "Пакет $pkg установлен"
    return 0
}

# Сохраняет текущие значения SITE_DOMAIN / SITE_REPO / CERTBOT_EMAIL
# в файл конфигурации, чтобы их можно было использовать при следующих
# запусках скрипта (например, при выборе "Установить/обновить SSL"
# отдельно от установки сайта).
save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << EOF
# Автоматически сгенерированный файл конфигурации.
# Используется скриптом установки и командой myserverinfo.
SITE_DOMAIN="$SITE_DOMAIN"
SITE_REPO="$SITE_REPO"
CERTBOT_EMAIL="$CERTBOT_EMAIL"
EOF
}

# Небольшая пауза с ожиданием Enter - удобно между пунктами меню,
# чтобы пользователь успел прочитать результат выполнения функции.
pause() {
    echo ""
    read -rp "Нажмите Enter, чтобы вернуться в меню..." _unused
}

###############################################################################
#                          1) УСТАНОВКА NGINX И ЗАВИСИМОСТЕЙ
###############################################################################

install_nginx() {
    msg_step "Установка веб-сервера Nginx и необходимых пакетов"

    # Обновляем список пакетов apt перед установкой
    msg_step "Обновление списка пакетов apt"
    apt-get update -y >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        msg_err "Не удалось выполнить apt-get update"
        return 1
    fi
    msg_ok "Список пакетов apt обновлён"

    # Список пакетов, необходимых для работы сайта
    local packages=(nginx git curl unzip certbot python3-certbot-nginx)

    local pkg
    for pkg in "${packages[@]}"; do
        ensure_package "$pkg" || return 1
    done

    # Включаем и запускаем nginx (idempotent - если уже включён, команда
    # просто завершится без ошибки)
    systemctl enable nginx >> "$LOG_FILE" 2>&1
    systemctl start nginx >> "$LOG_FILE" 2>&1

    if systemctl is-active --quiet nginx; then
        msg_ok "Nginx запущен и работает"
    else
        msg_err "Nginx не запущен. Проверьте: systemctl status nginx"
        return 1
    fi

    # Если установлен и активен ufw - открываем порты 80/443 для Nginx
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw allow 'Nginx Full' >> "$LOG_FILE" 2>&1
            msg_ok "Правила UFW для Nginx (порты 80/443) добавлены"
        fi
    fi

    msg_ok "Установка Nginx завершена"
    return 0
}

###############################################################################
#                       2) УСТАНОВКА / ОБНОВЛЕНИЕ САЙТА
###############################################################################

install_site() {
    msg_step "Настройка сайта"

    # Если nginx не установлен - сначала ставим его
    if ! command -v nginx >/dev/null 2>&1; then
        msg_warn "Nginx не найден, выполняю предварительную установку Nginx"
        install_nginx || return 1
    fi

    # Убедимся, что git установлен (на случай, если пользователь запускает
    # только этот пункт меню на уже частично настроенном сервере)
    ensure_package git || return 1

    # --- Запрос домена у пользователя ---
    local input_domain
    read -rp "Введите домен сайта (например: example.com) [${SITE_DOMAIN}]: " input_domain
    if [ -n "$input_domain" ]; then
        SITE_DOMAIN="$input_domain"
    fi
    if [ -z "$SITE_DOMAIN" ]; then
        msg_err "Домен не может быть пустым"
        return 1
    fi

    # --- Запрос URL git-репозитория с шаблоном сайта ---
    local input_repo
    read -rp "Введите URL git-репозитория шаблона сайта [${SITE_REPO}]: " input_repo
    if [ -n "$input_repo" ]; then
        SITE_REPO="$input_repo"
    fi
    if [ -z "$SITE_REPO" ]; then
        msg_err "URL репозитория не может быть пустым"
        return 1
    fi

    # Сохраняем введённые значения для последующих запусков скрипта
    save_config

    # --- Клонирование или обновление репозитория сайта ---
    mkdir -p /var/www

    if [ -d "${SITE_PATH}/.git" ]; then
        # Репозиторий уже клонирован ранее - просто обновляем его
        msg_step "Каталог $SITE_PATH уже является git-репозиторием, выполняю git pull"
        git -C "$SITE_PATH" pull >> "$LOG_FILE" 2>&1
        if [ $? -ne 0 ]; then
            msg_err "Ошибка при выполнении git pull в $SITE_PATH (см. $LOG_FILE)"
            return 1
        fi
        msg_ok "Репозиторий сайта обновлён (git pull)"
    else
        # Если каталог существует, но это не git-репозиторий - делаем backup,
        # чтобы не потерять возможные пользовательские данные
        if [ -d "$SITE_PATH" ]; then
            local backup_path
            backup_path="${SITE_PATH}.bak.$(date +%s)"
            msg_warn "Каталог $SITE_PATH существует, но не является git-репозиторием."
            msg_warn "Перемещаю его в $backup_path и клонирую новый репозиторий"
            mv "$SITE_PATH" "$backup_path"
        fi

        msg_step "Клонирование репозитория $SITE_REPO в $SITE_PATH"
        git clone "$SITE_REPO" "$SITE_PATH" >> "$LOG_FILE" 2>&1
        if [ $? -ne 0 ]; then
            msg_err "Ошибка клонирования репозитория $SITE_REPO (см. $LOG_FILE)"
            return 1
        fi
        msg_ok "Репозиторий сайта успешно клонирован"
    fi

    # Если в репозитории отсутствует index.html - создаём простую заглушку,
    # чтобы сайт сразу открывался в браузере
    if [ ! -f "${SITE_PATH}/index.html" ]; then
        msg_warn "Файл ${SITE_PATH}/index.html не найден, создаю заглушку"
        cat > "${SITE_PATH}/index.html" << EOF
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <title>${SITE_DOMAIN}</title>
</head>
<body>
    <h1>Сайт ${SITE_DOMAIN} успешно настроен</h1>
    <p>Замените этот файл содержимым из вашего репозитория.</p>
</body>
</html>
EOF
    fi

    # Выставляем владельца файлов сайта - пользователя nginx (www-data)
    chown -R www-data:www-data "$SITE_PATH"

    # --- Создание конфигурации Nginx для сайта ---
    msg_step "Создание конфигурации Nginx: $NGINX_CONF"
    cat > "$NGINX_CONF" << EOF
# Конфигурация сгенерирована автоматически скриптом установки.
server {
    listen 80;
    listen [::]:80;

    server_name ${SITE_DOMAIN} www.${SITE_DOMAIN};

    root ${SITE_PATH};
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    access_log /var/log/nginx/${SITE_DOMAIN}_access.log;
    error_log  /var/log/nginx/${SITE_DOMAIN}_error.log;
}
EOF

    # Создаём симлинк в sites-enabled (если уже существует - пересоздаём)
    ln -sf "$NGINX_CONF" "$NGINX_ENABLED"
    msg_ok "Симлинк $NGINX_ENABLED создан"

    # Отключаем дефолтный сайт nginx, чтобы он не конфликтовал по умолчанию
    if [ -L /etc/nginx/sites-enabled/default ]; then
        rm -f /etc/nginx/sites-enabled/default
        msg_ok "Дефолтный конфиг nginx (default) отключён"
    fi

    # Проверяем синтаксис конфигурации nginx перед перезапуском
    msg_step "Проверка конфигурации Nginx (nginx -t)"
    nginx -t >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        msg_err "Конфигурация Nginx содержит ошибки (см. $LOG_FILE)"
        return 1
    fi
    msg_ok "Конфигурация Nginx корректна"

    # Перезапускаем nginx, чтобы применить изменения
    systemctl restart nginx >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        msg_err "Не удалось перезапустить Nginx"
        return 1
    fi
    msg_ok "Nginx перезапущен с новой конфигурацией"

    msg_ok "Сайт ${SITE_DOMAIN} доступен по HTTP (http://${SITE_DOMAIN})"
    return 0
}

###############################################################################
#                  3) УСТАНОВКА / ОБНОВЛЕНИЕ SSL-СЕРТИФИКАТА
###############################################################################

install_ssl() {
    msg_step "Настройка SSL-сертификата Let's Encrypt"

    # Если домен ещё не известен - спрашиваем его у пользователя
    if [ -z "$SITE_DOMAIN" ]; then
        local input_domain
        read -rp "Домен для сайта ещё не настроен. Введите домен: " input_domain
        if [ -z "$input_domain" ]; then
            msg_err "Домен не указан, получение сертификата невозможно"
            return 1
        fi
        SITE_DOMAIN="$input_domain"
        save_config
    fi

    # Убеждаемся, что certbot установлен
    if ! command -v certbot >/dev/null 2>&1; then
        msg_warn "certbot не найден, выполняю предварительную установку Nginx/certbot"
        install_nginx || return 1
    fi

    # Запрашиваем email для уведомлений Let's Encrypt (можно пропустить)
    local input_email
    read -rp "Email для уведомлений Let's Encrypt (Enter - без email) [${CERTBOT_EMAIL}]: " input_email
    if [ -n "$input_email" ]; then
        CERTBOT_EMAIL="$input_email"
    fi
    save_config

    # Формируем аргументы certbot в зависимости от того, указан ли email
    local email_args
    if [ -n "$CERTBOT_EMAIL" ]; then
        email_args=(-m "$CERTBOT_EMAIL" --agree-tos --no-eff-email)
    else
        email_args=(--register-unsafely-without-email --agree-tos)
    fi

    # --- Получение / обновление сертификата ---
    # Сначала пробуем получить сертификат для домена и www.домена
    msg_step "Получение сертификата для ${SITE_DOMAIN} и www.${SITE_DOMAIN}"
    certbot --nginx \
        -d "$SITE_DOMAIN" -d "www.${SITE_DOMAIN}" \
        "${email_args[@]}" \
        --redirect --non-interactive >> "$LOG_FILE" 2>&1
    local result=$?

    if [ $result -ne 0 ]; then
        # Возможно, www.домен не существует в DNS - пробуем без www
        msg_warn "Не удалось получить сертификат для www.${SITE_DOMAIN}, пробую только для ${SITE_DOMAIN}"
        certbot --nginx \
            -d "$SITE_DOMAIN" \
            "${email_args[@]}" \
            --redirect --non-interactive >> "$LOG_FILE" 2>&1
        result=$?
    fi

    if [ $result -ne 0 ]; then
        msg_err "Не удалось получить SSL-сертификат для ${SITE_DOMAIN}."
        msg_err "Проверьте, что DNS-запись домена указывает на этот сервер, и см. $LOG_FILE"
        return 1
    fi

    msg_ok "SSL-сертификат для ${SITE_DOMAIN} получен и подключён к Nginx"

    # --- Проверка таймера автоматического продления сертификатов ---
    msg_step "Проверка таймера автопродления certbot.timer"

    if systemctl is-enabled --quiet certbot.timer 2>/dev/null; then
        msg_ok "certbot.timer уже включён (enabled)"
    else
        systemctl enable certbot.timer >> "$LOG_FILE" 2>&1
        if [ $? -eq 0 ]; then
            msg_ok "certbot.timer включён (enabled)"
        else
            msg_err "Не удалось включить certbot.timer"
            return 1
        fi
    fi

    if systemctl is-active --quiet certbot.timer; then
        msg_ok "certbot.timer активен (автопродление работает)"
    else
        systemctl start certbot.timer >> "$LOG_FILE" 2>&1
        if systemctl is-active --quiet certbot.timer; then
            msg_ok "certbot.timer запущен"
        else
            msg_err "certbot.timer не активен. Проверьте: systemctl status certbot.timer"
            return 1
        fi
    fi

    return 0
}

###############################################################################
#                          4) УСТАНОВКА CROWDSEC
###############################################################################

install_crowdsec() {
    msg_step "Установка CrowdSec и firewall-bouncer"

    # curl нужен для добавления официального репозитория CrowdSec
    ensure_package curl || return 1

    # --- Добавление официального репозитория CrowdSec (идемпотентно) ---
    if find /etc/apt/sources.list.d -maxdepth 1 -iname '*crowdsec*' 2>/dev/null | grep -q .; then
        msg_ok "Официальный репозиторий CrowdSec уже добавлен"
    else
        msg_step "Добавление официального репозитория CrowdSec"
        curl -s https://install.crowdsec.net | bash >> "$LOG_FILE" 2>&1
        if [ $? -ne 0 ]; then
            msg_err "Не удалось добавить репозиторий CrowdSec (см. $LOG_FILE)"
            return 1
        fi
        msg_ok "Репозиторий CrowdSec добавлен"
    fi

    # Обновляем индекс пакетов после добавления нового репозитория
    apt-get update -y >> "$LOG_FILE" 2>&1

    # --- Определяем, какой backend межсетевого экрана используется:
    #     классический iptables (legacy) или iptables через nftables (iptables-nft) ---
    local fw_backend="iptables"
    if command -v iptables >/dev/null 2>&1; then
        if iptables -V 2>/dev/null | grep -qi "nf_tables"; then
            fw_backend="nftables"
            msg_info "Обнаружен backend iptables-nft (nf_tables) -> bouncer будет настроен в режиме nftables"
        else
            msg_info "Обнаружен классический backend iptables-legacy -> bouncer будет настроен в режиме iptables"
        fi
    else
        msg_warn "Команда iptables не найдена, использую режим bouncer по умолчанию (iptables)"
    fi

    # --- Установка пакетов crowdsec и crowdsec-firewall-bouncer-iptables ---
    ensure_package crowdsec || return 1
    ensure_package crowdsec-firewall-bouncer-iptables || return 1

    # --- Настройка режима работы bouncer в соответствии с обнаруженным backend ---
    local bouncer_cfg="/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"
    if [ -f "$bouncer_cfg" ]; then
        if grep -q '^mode:' "$bouncer_cfg"; then
            sed -i "s/^mode:.*/mode: ${fw_backend}/" "$bouncer_cfg"
        else
            echo "mode: ${fw_backend}" >> "$bouncer_cfg"
        fi
        msg_ok "crowdsec-firewall-bouncer настроен в режиме: ${fw_backend}"
    else
        msg_warn "Файл $bouncer_cfg не найден, пропускаю настройку режима bouncer"
    fi

    # --- Проверка работы cscli ---
    if ! command -v cscli >/dev/null 2>&1; then
        msg_err "Команда cscli не найдена после установки CrowdSec"
        return 1
    fi

    msg_step "Версия CrowdSec / cscli"
    cscli version >> "$LOG_FILE" 2>&1
    msg_ok "cscli доступен: $(cscli version 2>/dev/null | head -n1)"

    # --- Установка необходимых коллекций правил ---
    local collections=(crowdsecurity/linux crowdsecurity/nginx crowdsecurity/http-cve)
    local col
    for col in "${collections[@]}"; do
        if cscli collections list 2>/dev/null | grep -q "$col"; then
            msg_ok "Коллекция $col уже установлена"
        else
            msg_step "Установка коллекции $col"
            cscli collections install "$col" >> "$LOG_FILE" 2>&1
            if [ $? -eq 0 ]; then
                msg_ok "Коллекция $col установлена"
            else
                msg_warn "Не удалось установить коллекцию $col (см. $LOG_FILE)"
            fi
        fi
    done

    msg_info "Текущий список установленных коллекций:"
    cscli collections list 2>/dev/null | tee -a "$LOG_FILE"

    # --- Включение и (пере)запуск сервисов ---
    systemctl enable crowdsec >> "$LOG_FILE" 2>&1
    systemctl enable crowdsec-firewall-bouncer >> "$LOG_FILE" 2>&1

    systemctl restart crowdsec >> "$LOG_FILE" 2>&1
    systemctl restart crowdsec-firewall-bouncer >> "$LOG_FILE" 2>&1

    # Даём службам немного времени на инициализацию перед проверкой статуса
    sleep 2

    if systemctl is-active --quiet crowdsec; then
        msg_ok "Служба crowdsec активна (enabled + running)"
    else
        msg_err "Служба crowdsec не запущена. Проверьте: systemctl status crowdsec"
        return 1
    fi

    if systemctl is-active --quiet crowdsec-firewall-bouncer; then
        msg_ok "Служба crowdsec-firewall-bouncer активна (enabled + running)"
    else
        msg_err "Служба crowdsec-firewall-bouncer не запущена. Проверьте: systemctl status crowdsec-firewall-bouncer"
        return 1
    fi

    msg_ok "Установка CrowdSec завершена"
    return 0
}

###############################################################################
#               5) УСТАНОВКА БЛОК-ЛИСТА CYBEROK SKIPA IPS
###############################################################################

# Создаёт исполняемый скрипт /usr/local/bin/update-cyberok.sh,
# который обновляет git-репозиторий со списком IP, пересобирает ipset
# и проверяет наличие правила iptables для блокировки этого набора.
create_cyberok_update_script() {
    msg_step "Создание скрипта автообновления: $CYBEROK_UPDATE_SCRIPT"

    # Heredoc с кавычками вокруг 'CYBEROK_SCRIPT_EOF' - переменные внутри
    # НЕ раскрываются на этапе генерации, они должны выполняться внутри
    # самого скрипта update-cyberok.sh при каждом его запуске.
    cat > "$CYBEROK_UPDATE_SCRIPT" << 'CYBEROK_SCRIPT_EOF'
#!/bin/bash
###############################################################################
# update-cyberok.sh
#
# Автоматическое обновление блок-листа CyberOK Skipa IPs:
#   1. обновляет git-репозиторий с актуальным списком подсетей;
#   2. пересобирает ipset-набор cyberok_skipa из файла lists/skipa_cidr.txt;
#   3. убеждается, что в цепочке INPUT есть правило iptables,
#      блокирующее трафик с адресов из этого набора.
#
# Запускается вручную или systemd-таймером cyberok-update.timer
###############################################################################

CYBEROK_DIR="/opt/CyberOK_Skipa_ips"
IPSET_NAME="cyberok_skipa"
LIST_FILE="${CYBEROK_DIR}/lists/skipa_cidr.txt"
LOG_FILE="/var/log/cyberok-update.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

log "=== Запуск обновления CyberOK Skipa IPs ==="

# --- Шаг 1: обновление git-репозитория ---
if [ -d "${CYBEROK_DIR}/.git" ]; then
    cd "$CYBEROK_DIR" || { log "ОШИБКА: не удалось перейти в $CYBEROK_DIR"; exit 1; }
    git pull >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log "ПРЕДУПРЕЖДЕНИЕ: git pull завершился с ошибкой, используем текущую версию списка"
    else
        log "Репозиторий успешно обновлён (git pull)"
    fi
else
    log "ОШИБКА: каталог $CYBEROK_DIR отсутствует или не является git-репозиторием"
    exit 1
fi

# --- Шаг 2: проверка наличия файла со списком подсетей ---
if [ ! -f "$LIST_FILE" ]; then
    log "ОШИБКА: файл со списком $LIST_FILE не найден"
    exit 1
fi

# --- Шаг 3: пересборка ipset-набора через временный набор (atomic swap) ---
# Используем временный набор, чтобы избежать "дырки" в правилах firewall
# на время пересборки списка.
TMP_SET="${IPSET_NAME}_tmp"

ipset create "$TMP_SET" hash:net -exist
ipset flush "$TMP_SET"

COUNT=0
while IFS= read -r line; do
    # Пропускаем пустые строки и строки-комментарии (начинающиеся с #)
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    if ipset add "$TMP_SET" "$line" -exist 2>>"$LOG_FILE"; then
        COUNT=$((COUNT + 1))
    fi
done < "$LIST_FILE"

log "Прочитано и добавлено записей во временный набор: $COUNT"

# Создаём основной набор, если он ещё не существует
if ! ipset list -n | grep -qx "$IPSET_NAME"; then
    ipset create "$IPSET_NAME" hash:net -exist
fi

# Атомарно меняем местами содержимое основного и временного наборов
ipset swap "$TMP_SET" "$IPSET_NAME"
ipset destroy "$TMP_SET"

log "ipset '$IPSET_NAME' обновлён, актуальное количество записей: $COUNT"

# --- Шаг 4: убеждаемся, что в iptables есть правило блокировки набора ---
if ! iptables -C INPUT -m set --match-set "$IPSET_NAME" src -j DROP 2>/dev/null; then
    iptables -I INPUT 1 -m set --match-set "$IPSET_NAME" src -j DROP
    log "Добавлено правило iptables: DROP для набора $IPSET_NAME"
else
    log "Правило iptables для набора $IPSET_NAME уже присутствует"
fi

log "=== Обновление CyberOK Skipa IPs завершено успешно ==="
exit 0
CYBEROK_SCRIPT_EOF

    chmod +x "$CYBEROK_UPDATE_SCRIPT"
    msg_ok "Скрипт $CYBEROK_UPDATE_SCRIPT создан и сделан исполняемым"
}

# Создаёт systemd unit и timer для ежедневного запуска update-cyberok.sh в 03:00
create_cyberok_timer() {
    msg_step "Создание systemd-сервиса и таймера cyberok-update"

    cat > /etc/systemd/system/cyberok-update.service << EOF
[Unit]
Description=Обновление блок-листа CyberOK Skipa IPs
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${CYBEROK_UPDATE_SCRIPT}
EOF

    cat > /etc/systemd/system/cyberok-update.timer << 'EOF'
[Unit]
Description=Ежедневное обновление блок-листа CyberOK Skipa IPs

[Timer]
# Основной запуск - каждый день в 03:00
OnCalendar=*-*-* 03:00:00
# Дополнительный запуск через 2 минуты после загрузки сервера -
# гарантирует восстановление ipset/iptables-правил после перезагрузки.
OnBootSec=2min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload >> "$LOG_FILE" 2>&1

    systemctl enable --now cyberok-update.timer >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        msg_err "Не удалось включить cyberok-update.timer"
        return 1
    fi

    if systemctl is-active --quiet cyberok-update.timer; then
        msg_ok "Таймер cyberok-update.timer активен (ежедневно в 03:00 + при загрузке)"
    else
        msg_err "Таймер cyberok-update.timer не активен. Проверьте: systemctl status cyberok-update.timer"
        return 1
    fi

    return 0
}

install_cyberok() {
    msg_step "Установка блок-листа CyberOK Skipa IPs"

    # Зависимости: git для клонирования репозитория, ipset для управления списками IP
    ensure_package git || return 1
    ensure_package ipset || return 1

    # --- Клонирование или обновление репозитория со списками IP ---
    mkdir -p /opt

    if [ -d "${CYBEROK_DIR}/.git" ]; then
        msg_step "Репозиторий CyberOK Skipa IPs уже существует, выполняю git pull"
        git -C "$CYBEROK_DIR" pull >> "$LOG_FILE" 2>&1
        if [ $? -ne 0 ]; then
            msg_err "Ошибка git pull в $CYBEROK_DIR (см. $LOG_FILE)"
            return 1
        fi
        msg_ok "Репозиторий CyberOK Skipa IPs обновлён"
    else
        msg_step "Клонирование репозитория $CYBEROK_REPO в $CYBEROK_DIR"
        git clone "$CYBEROK_REPO" "$CYBEROK_DIR" >> "$LOG_FILE" 2>&1
        if [ $? -ne 0 ]; then
            msg_err "Ошибка клонирования репозитория CyberOK Skipa IPs (см. $LOG_FILE)"
            return 1
        fi
        msg_ok "Репозиторий CyberOK Skipa IPs клонирован"
    fi

    # Репозиторий содержит готовые списки IP/подсетей в каталоге lists/
    # (форматы CIDR, Range, CheckPointCSV). Рекомендуемый способ применения -
    # загрузить список CIDR в ipset и заблокировать его правилом iptables.
    if [ ! -f "${CYBEROK_DIR}/lists/skipa_cidr.txt" ]; then
        msg_err "Файл ${CYBEROK_DIR}/lists/skipa_cidr.txt не найден в репозитории"
        return 1
    fi

    # --- Создание скрипта автообновления и его первый запуск ---
    create_cyberok_update_script

    msg_step "Первичное применение списка блокировки CyberOK Skipa IPs"
    bash "$CYBEROK_UPDATE_SCRIPT"
    if [ $? -ne 0 ]; then
        msg_err "Ошибка при первичном применении правил CyberOK (см. $CYBEROK_LOG)"
        return 1
    fi
    msg_ok "Правила блокировки CyberOK Skipa IPs применены (ipset: $CYBEROK_IPSET)"

    # --- Создание ежедневного systemd-таймера обновления ---
    create_cyberok_timer || return 1

    msg_ok "Установка CyberOK Skipa IPs завершена"
    return 0
}

###############################################################################
#                              6) ВКЛЮЧЕНИЕ BBR
###############################################################################

enable_bbr() {
    msg_step "Включение TCP BBR (congestion control)"

    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    msg_info "Текущий congestion control: ${current_cc:-неизвестно}"

    if [ "$current_cc" = "bbr" ]; then
        msg_ok "BBR уже включён, дополнительных действий не требуется"
    else
        msg_step "Добавление параметров BBR в /etc/sysctl.conf"

        # Добавляем/обновляем net.core.default_qdisc=fq
        if grep -q '^net\.core\.default_qdisc' /etc/sysctl.conf; then
            sed -i 's/^net\.core\.default_qdisc.*/net.core.default_qdisc=fq/' /etc/sysctl.conf
        else
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        fi

        # Добавляем/обновляем net.ipv4.tcp_congestion_control=bbr
        if grep -q '^net\.ipv4\.tcp_congestion_control' /etc/sysctl.conf; then
            sed -i 's/^net\.ipv4\.tcp_congestion_control.*/net.ipv4.tcp_congestion_control=bbr/' /etc/sysctl.conf
        else
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        fi

        msg_step "Применение настроек sysctl (sysctl -p)"
        sysctl -p >> "$LOG_FILE" 2>&1
        if [ $? -ne 0 ]; then
            msg_err "Ошибка применения sysctl -p (см. $LOG_FILE)"
            return 1
        fi
        msg_ok "Параметры sysctl применены"
    fi

    # --- Проверка наличия модуля ядра tcp_bbr ---
    if lsmod | grep -q '^tcp_bbr'; then
        msg_ok "Модуль ядра tcp_bbr загружен"
    else
        msg_warn "Модуль tcp_bbr не найден в lsmod, пробую загрузить вручную (modprobe)"
        modprobe tcp_bbr 2>>"$LOG_FILE"
        if lsmod | grep -q '^tcp_bbr'; then
            msg_ok "Модуль tcp_bbr успешно загружен"
        else
            msg_warn "Модуль tcp_bbr не отображается в lsmod (возможно, BBR встроен в ядро монолитно)"
        fi
    fi

    # --- Итоговая проверка ---
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$current_cc" = "bbr" ]; then
        msg_ok "BBR активирован. net.ipv4.tcp_congestion_control = ${current_cc}"
    else
        msg_err "BBR не активирован. net.ipv4.tcp_congestion_control = ${current_cc:-неизвестно}"
        msg_err "Возможно, требуется перезагрузка сервера для применения настроек"
        return 1
    fi

    return 0
}

###############################################################################
#                  7) УСТАНОВКА КОМАНДЫ myserverinfo
###############################################################################

myserverinfo_install() {
    msg_step "Установка команды myserverinfo"

    # Heredoc обёрнут в кавычки 'MYSERVERINFO_EOF' - переменные ($SITE_DOMAIN
    # и т.п.) НЕ раскрываются здесь, они будут вычисляться каждый раз
    # при запуске команды myserverinfo (через source конфигурационного файла).
    cat > "$MYSERVERINFO_PATH" << 'MYSERVERINFO_EOF'
#!/bin/bash
###############################################################################
# myserverinfo
#
# Интерактивная команда просмотра состояния сервера.
#
# При запуске без аргументов открывает меню выбора раздела информации
# (по аналогии с меню установочного скрипта) - можно посмотреть как всю
# информацию сразу, так и только нужный раздел (NGINX, SITE, SSL, CROWDSEC,
# FIREWALL BOUNCER, CYBEROK, BBR, SYSTEM).
#
# Также поддерживается запуск без меню: myserverinfo all | -a | --all
###############################################################################

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

CONFIG_FILE="/etc/myserver/config.conf"
SITE_PATH="/var/www/site"
CYBEROK_DIR="/opt/CyberOK_Skipa_ips"

# Подгружаем сохранённые значения (домен сайта и т.п.)
SITE_DOMAIN=""
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Печатает заголовок раздела
header() {
    echo "=================================================="
    echo "  $1"
    echo "=================================================="
    echo ""
}

# Определяет, какой процесс реально слушает указанный TCP-порт (IPv4/IPv6).
# Возвращает имя процесса (например "nginx", "xray"), "свободен" если порт
# не прослушивается, либо "неизвестно" если не удалось определить процесс
# (например, при запуске без прав root).
port_owner() {
    local port="$1"
    local line proc

    if ! command -v ss >/dev/null 2>&1; then
        echo "н/д (нет команды ss)"
        return
    fi

    # Ищем строку LISTEN, где локальный адрес заканчивается на ":<port>"
    line=$(ss -tlnp 2>/dev/null | awk -v p=":${port}\$" '$4 ~ p {print; exit}')

    if [ -z "$line" ]; then
        echo "свободен"
        return
    fi

    proc=$(echo "$line" | grep -oP 'users:\(\("\K[^"]+' 2>/dev/null)
    if [ -z "$proc" ]; then
        echo "неизвестно (нет прав root для определения процесса)"
    else
        echo "$proc"
    fi
}

# --- Раздел: общая информация о системе ---
print_system() {
    header "SYSTEM"

    echo "OS:"
    if [ -f /etc/os-release ]; then
        grep -m1 PRETTY_NAME /etc/os-release | cut -d'"' -f2
    else
        echo "неизвестно"
    fi
    echo ""

    echo "Kernel:"
    uname -r
    echo ""

    echo "Uptime:"
    uptime -p 2>/dev/null || uptime
    echo ""

    echo "CPU:"
    CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d':' -f2 | sed 's/^ *//')
    CPU_CORES=$(nproc)
    echo "${CPU_MODEL:-неизвестно} (${CPU_CORES} ядра/потока)"
    echo ""

    echo "RAM:"
    free -h | awk '/^Mem:/ {print "использовано "$3" из "$2}'
    echo ""

    echo "Disk:"
    df -h / | awk 'NR==2 {print "использовано "$3" из "$2" ("$5")"}'
    echo ""

    echo "IP:"
    hostname -I | awk '{print $1}'
}

# --- Раздел: NGINX ---
print_nginx() {
    header "NGINX"

    if command -v nginx >/dev/null 2>&1; then
        echo -e "Installed: ${GREEN}YES${NC}"
        if systemctl is-active --quiet nginx; then
            echo -e "Status: ${GREEN}ACTIVE${NC}"
        else
            echo -e "Status: ${RED}INACTIVE${NC}"
        fi
        echo "Version: $(nginx -v 2>&1 | sed 's#.*nginx/##')"

        # Порты, заданные в конфигурации (директивы listen во всех
        # подключенных конфигах, включая sites-enabled)
        local cfg_ports
        cfg_ports=$(nginx -T 2>/dev/null \
            | grep -E '^\s*listen\s' \
            | sed -E 's/^\s*listen\s+([^;]+);.*/\1/' \
            | awk '{print $1}' \
            | sed -E 's/^\[::\]://; s/^.*://' \
            | sort -un | paste -sd ',' - | sed 's/,/, /g')
        echo "Configured listen ports (nginx -T): ${cfg_ports:-н/д}"
        echo ""

        # Реальная проверка популярных портов веб-сервера: 80, 443, 8443.
        # Это полезно в схемах, когда 443 занят другим сервисом
        # (например, 3x-ui / xray с маскировкой под сайт), а сам сайт
        # на nginx работает на альтернативном порту (например, 8443).
        echo "Проверка портов (кто реально их слушает):"
        local p owner
        for p in 80 443 8443; do
            owner=$(port_owner "$p")
            case "$owner" in
                свободен)
                    echo -e "  Порт ${p}: ${YELLOW}свободен / не прослушивается${NC}"
                    ;;
                nginx)
                    echo -e "  Порт ${p}: ${GREEN}nginx${NC}"
                    ;;
                *)
                    echo -e "  Порт ${p}: ${YELLOW}${owner}${NC}"
                    ;;
            esac
        done
    else
        echo -e "Installed: ${RED}NO${NC}"
    fi
}

# --- Раздел: сайт ---
print_site() {
    header "SITE"

    echo "Domain: ${SITE_DOMAIN:-не настроен}"
    echo "Path: $SITE_PATH"
    if [ -d "${SITE_PATH}/.git" ]; then
        REPO_URL=$(git -C "$SITE_PATH" config --get remote.origin.url 2>/dev/null)
        LAST_UPDATE=$(git -C "$SITE_PATH" log -1 --format=%cd --date=local 2>/dev/null)
        echo "Git repository: ${REPO_URL:-н/д}"
        echo "Last update: ${LAST_UPDATE:-н/д}"
    else
        echo "Git repository: н/д"
        echo "Last update: н/д"
    fi
}

# --- Раздел: SSL ---
print_ssl() {
    header "SSL"

    if [ -n "$SITE_DOMAIN" ] && [ -d "/etc/letsencrypt/live/${SITE_DOMAIN}" ]; then
        CERT_FILE="/etc/letsencrypt/live/${SITE_DOMAIN}/fullchain.pem"
        echo -e "Installed: ${GREEN}YES${NC}"
        echo "Certificate: $CERT_FILE"
        EXP_DATE=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d'=' -f2)
        echo "Expiration date: ${EXP_DATE:-н/д}"
    else
        echo -e "Installed: ${RED}NO${NC}"
        echo "Certificate: н/д"
        echo "Expiration date: н/д"
    fi
}

# --- Раздел: CrowdSec ---
print_crowdsec() {
    header "CROWDSEC"

    if command -v cscli >/dev/null 2>&1; then
        echo -e "Installed: ${GREEN}YES${NC}"
        if systemctl is-active --quiet crowdsec; then
            echo -e "Status: ${GREEN}ACTIVE${NC}"
        else
            echo -e "Status: ${RED}INACTIVE${NC}"
        fi
        echo "Version: $(cscli version 2>/dev/null | head -n1)"
        echo ""
        echo "Active decisions (аналог 'cscli decisions list'):"
        if [ "$(id -u)" -eq 0 ]; then
            cscli decisions list 2>&1
        else
            echo "Для просмотра активных решений запустите myserverinfo с правами root (sudo)"
        fi
    else
        echo -e "Installed: ${RED}NO${NC}"
    fi
}

# --- Раздел: Firewall bouncer (CrowdSec) ---
print_bouncer() {
    header "FIREWALL BOUNCER"

    if dpkg -s crowdsec-firewall-bouncer-iptables >/dev/null 2>&1; then
        echo -e "Installed: ${GREEN}YES${NC}"
        if systemctl is-active --quiet crowdsec-firewall-bouncer; then
            echo -e "Status: ${GREEN}ACTIVE${NC}"
        else
            echo -e "Status: ${RED}INACTIVE${NC}"
        fi
    else
        echo -e "Installed: ${RED}NO${NC}"
    fi
}

# --- Раздел: CyberOK Skipa IPs ---
print_cyberok() {
    header "CYBEROK"

    if [ -d "${CYBEROK_DIR}/.git" ]; then
        echo -e "Installed: ${GREEN}YES${NC}"
        echo "Repository: $(git -C "$CYBEROK_DIR" config --get remote.origin.url 2>/dev/null)"
        echo "Last update: $(git -C "$CYBEROK_DIR" log -1 --format=%cd --date=local 2>/dev/null)"
        if systemctl is-active --quiet cyberok-update.timer; then
            echo -e "Timer: ${GREEN}ACTIVE${NC}"
        else
            echo -e "Timer: ${RED}INACTIVE${NC}"
        fi
    else
        echo -e "Installed: ${RED}NO${NC}"
        echo "Repository: н/д"
        echo "Last update: н/д"
        echo "Timer: н/д"
    fi
}

# --- Раздел: BBR ---
print_bbr() {
    header "BBR"

    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$CURRENT_CC" = "bbr" ]; then
        echo -e "Enabled: ${GREEN}YES${NC}"
    else
        echo -e "Enabled: ${RED}NO${NC}"
    fi
    echo "Current congestion control: ${CURRENT_CC:-неизвестно}"
}

# --- Вся информация сразу (все разделы подряд) ---
print_all() {
    print_system
    echo ""
    print_nginx
    echo ""
    print_site
    echo ""
    print_ssl
    echo ""
    print_crowdsec
    echo ""
    print_bouncer
    echo ""
    print_cyberok
    echo ""
    print_bbr
}

# Небольшая пауза перед возвратом в меню
pause() {
    echo ""
    read -rp "Нажмите Enter, чтобы вернуться в меню..." _unused
}

# Интерактивное меню выбора раздела информации
show_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}===========================================================${NC}"
        echo -e "${CYAN}${BOLD}          MYSERVERINFO - ИНФОРМАЦИЯ О СЕРВЕРЕ${NC}"
        echo -e "${CYAN}===========================================================${NC}"
        echo "  1) Вся информация"
        echo "  2) Система (ОС, ядро, CPU, RAM, диск, IP)"
        echo "  3) NGINX"
        echo "  4) Сайт"
        echo "  5) SSL"
        echo "  6) CrowdSec"
        echo "  7) Firewall bouncer"
        echo "  8) CyberOK Skipa IPs"
        echo "  9) BBR"
        echo "  0) Выход"
        echo -e "${CYAN}===========================================================${NC}"
        echo ""

        local choice
        read -rp "Выберите раздел [0-9]: " choice
        echo ""

        case "$choice" in
            1) print_all ;;
            2) print_system ;;
            3) print_nginx ;;
            4) print_site ;;
            5) print_ssl ;;
            6) print_crowdsec ;;
            7) print_bouncer ;;
            8) print_cyberok ;;
            9) print_bbr ;;
            0) exit 0 ;;
            *) echo "Некорректный выбор '$choice'. Введите число от 0 до 9." ;;
        esac

        pause
    done
}

# --- Точка входа ---
# Без аргументов - интерактивное меню.
# С аргументом all / -a / --all - вывод всей информации без меню (для скриптов).
case "${1:-}" in
    all|-a|--all)
        print_all
        ;;
    "")
        show_menu
        ;;
    *)
        echo "Использование: myserverinfo [all|-a|--all]"
        echo "Без аргументов открывает интерактивное меню выбора раздела информации."
        exit 1
        ;;
esac
MYSERVERINFO_EOF

    chmod +x "$MYSERVERINFO_PATH"
    msg_ok "Команда myserverinfo установлена в $MYSERVERINFO_PATH"
    msg_info "Запустите её командой: myserverinfo (откроется меню выбора раздела)"
    return 0
}

###############################################################################
#                     ФУНКЦИЯ "УСТАНОВИТЬ ВСЁ" (ПУНКТ 1 МЕНЮ)
###############################################################################

install_all() {
    msg_step "Запуск полной установки и настройки сервера"

    local had_errors=0

    install_nginx       || had_errors=1
    install_site        || had_errors=1

    # SSL может не получиться, если DNS-запись домена ещё не указывает
    # на этот сервер - не считаем это фатальной ошибкой всей установки,
    # но предупреждаем пользователя.
    if ! install_ssl; then
        msg_warn "Этап SSL пропущен/завершился с ошибкой. Проверьте DNS-записи домена"
        msg_warn "и повторно выберите пункт меню '3) Установить/обновить SSL'"
    fi

    install_crowdsec    || had_errors=1
    install_cyberok     || had_errors=1
    enable_bbr          || had_errors=1
    myserverinfo_install || had_errors=1

    echo ""
    if [ "$had_errors" -eq 0 ]; then
        msg_ok "Полная установка завершена успешно!"
    else
        msg_warn "Установка завершена, но некоторые этапы завершились с ошибками."
        msg_warn "Подробности смотрите в логе: $LOG_FILE"
    fi
}

###############################################################################
#                                  ГЛАВНОЕ МЕНЮ
###############################################################################

show_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}===========================================================${NC}"
        echo -e "${CYAN}${BOLD}     МЕНЮ УСТАНОВКИ И НАСТРОЙКИ VPS (Ubuntu 24.04)${NC}"
        echo -e "${CYAN}===========================================================${NC}"
        echo "  1) Установить всё"
        echo "  2) Установить/обновить сайт"
        echo "  3) Установить/обновить SSL"
        echo "  4) Установить/обновить CrowdSec"
        echo "  5) Установить/обновить CyberOK Skipa IPs"
        echo "  6) Включить BBR"
        echo "  7) Установить/обновить команду myserverinfo"
        echo "  8) Показать информацию о сервере"
        echo "  0) Выход"
        echo -e "${CYAN}===========================================================${NC}"
        echo ""

        local choice
        read -rp "Выберите пункт меню [0-8]: " choice

        case "$choice" in
            1)
                install_all
                pause
                ;;
            2)
                install_site
                pause
                ;;
            3)
                install_ssl
                pause
                ;;
            4)
                install_crowdsec
                pause
                ;;
            5)
                install_cyberok
                pause
                ;;
            6)
                enable_bbr
                pause
                ;;
            7)
                myserverinfo_install
                pause
                ;;
            8)
                # Гарантируем, что команда myserverinfo установлена,
                # затем запускаем её собственное меню выбора информации.
                myserverinfo_install >/dev/null
                echo ""
                "$MYSERVERINFO_PATH"
                ;;
            0)
                msg_info "Завершение работы скрипта"
                exit 0
                ;;
            *)
                msg_warn "Некорректный выбор '$choice'. Введите число от 0 до 8."
                ;;
        esac
    done
}

###############################################################################
#                                ТОЧКА ВХОДА
###############################################################################

main() {
    check_root

    # Создаём каталоги для логов и конфигурации
    mkdir -p "$(dirname "$LOG_FILE")"
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE"

    log "============================================================"
    log "Запуск скрипта установки myserver"
    log "============================================================"

    # Обновляем кэш apt один раз при старте, чтобы дальнейшие установки
    # пакетов из любого пункта меню проходили без отдельного apt-get update.
    apt-get update -y >> "$LOG_FILE" 2>&1

    show_menu
}

main "$@"
