#!/usr/bin/env bash
# =============================================================================
#  VPS Setup Script — Ubuntu 24.04
#  Компоненты: Nginx · SSL (Certbot) · Amnezia-Web-Panel (Docker)
#              CrowdSec · BBR
# =============================================================================

set -uo pipefail
# Не используем -e: обрабатываем ошибки вручную в каждой функции

# ─── Цвета ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Вспомогательные функции ─────────────────────────────────────────────────
log_info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

banner() {
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║           VPS AUTO-SETUP · Ubuntu 24.04                 ║"
    echo "║  Nginx · SSL · Amnezia Panel · CrowdSec · BBR           ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

# Спрашивает «да/нет» и возвращает 0 (да) или 1 (нет)
ask_yes_no() {
    local prompt="$1"
    while true; do
        read -r -p "$(echo -e "${YELLOW}${prompt} [y/n]: ${RESET}")" ans
        case "${ans,,}" in
            y|yes|д|да) return 0 ;;
            n|no|н|нет) return 1 ;;
            *) echo -e "${RED}Введите y или n.${RESET}" ;;
        esac
    done
}

# Спрашивает «продолжить или выйти»
ask_continue_or_exit() {
    echo -e "${YELLOW}Пропустить этот шаг и продолжить, или выйти из установки?${RESET}"
    while true; do
        read -r -p "$(echo -e "${YELLOW}[c]ontinue / [e]xit: ${RESET}")" ans
        case "${ans,,}" in
            c|continue|п|продолжить) return 0 ;;
            e|exit|в|выйти)
                echo -e "${RED}Установка прервана пользователем.${RESET}"
                exit 0
                ;;
            *) echo -e "${RED}Введите c или e.${RESET}" ;;
        esac
    done
}

# Проверяет, что скрипт запущен от root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Запустите скрипт от имени root: sudo bash $0"
        exit 1
    fi
}

# Базовое обновление системы
system_update() {
    log_info "Обновление списков пакетов..."
    apt-get update -qq
    apt-get install -y -qq curl wget git ufw snapd software-properties-common \
        ca-certificates gnupg lsb-release apt-transport-https 2>/dev/null
}

# ─── 1. NGINX ─────────────────────────────────────────────────────────────────
install_nginx() {
    echo
    echo -e "${BOLD}════════════════ ШАГ 1: Nginx ════════════════${RESET}"
    echo "  Установка и базовая настройка веб-сервера Nginx."
    echo

    if ask_yes_no "Установить Nginx?"; then
        log_info "Устанавливаю Nginx..."
        apt-get install -y nginx

        # Включить и запустить
        systemctl enable nginx
        systemctl start nginx

        # Базовая конфигурация безопасности
        cat > /etc/nginx/conf.d/security.conf <<'EOF'
server_tokens off;
server_names_hash_bucket_size 128;
add_header X-Frame-Options SAMEORIGIN;
add_header X-Content-Type-Options nosniff;
add_header X-XSS-Protection "1; mode=block";
add_header Referrer-Policy "strict-origin-when-cross-origin";
EOF

        # Открыть порты в UFW
        if command -v ufw &>/dev/null; then
            ufw allow "Nginx Full" 2>/dev/null || true
        fi

        log_ok "Nginx установлен и запущен."
        NGINX_INSTALLED=true
    else
        log_warn "Nginx пропущен."
        NGINX_INSTALLED=false
        ask_continue_or_exit
    fi
}

# ─── 2. САЙТ из GitHub ────────────────────────────────────────────────────────
setup_website() {
    echo
    echo -e "${BOLD}════════════════ ШАГ 2: Установка сайта из GitHub ════════════════${RESET}"
    echo "  Клонирование вашего шаблона сайта и настройка Nginx-хоста."
    echo

    if ! $NGINX_INSTALLED; then
        log_warn "Nginx не установлен — шаг пропускается."
        return
    fi

    if ask_yes_no "Установить сайт из вашего GitHub-шаблона?"; then

        # Спросить домен
        while true; do
            read -r -p "$(echo -e "${CYAN}Введите ваш домен (например, example.com): ${RESET}")" DOMAIN
            [[ -n "$DOMAIN" ]] && break
            echo -e "${RED}Домен не может быть пустым.${RESET}"
        done

        # Спросить ссылку на репозиторий
        while true; do
            read -r -p "$(echo -e "${CYAN}Ссылка на репозиторий GitHub (https://github.com/...): ${RESET}")" REPO_URL
            [[ -n "$REPO_URL" ]] && break
            echo -e "${RED}Ссылка не может быть пустой.${RESET}"
        done

        WEBROOT="/var/www/${DOMAIN}"
        log_info "Клонирую репозиторий в ${WEBROOT}..."
        rm -rf "${WEBROOT}"
        git clone "${REPO_URL}" "${WEBROOT}"
        chown -R www-data:www-data "${WEBROOT}"
        find "${WEBROOT}" -type d -exec chmod 755 {} \;
        find "${WEBROOT}" -type f -exec chmod 644 {} \;

        # Nginx vhost
        cat > "/etc/nginx/sites-available/${DOMAIN}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    root ${WEBROOT};
    index index.html index.htm index.php;

    access_log /var/log/nginx/${DOMAIN}_access.log;
    error_log  /var/log/nginx/${DOMAIN}_error.log;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Запретить доступ к скрытым файлам
    location ~ /\. {
        deny all;
    }
}
EOF

        ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"
        nginx -t && systemctl reload nginx || log_warn 'Nginx: ошибка конфига, reload пропущен'
        log_ok "Сайт ${DOMAIN} развёрнут из ${REPO_URL}."
    else
        log_warn "Установка сайта пропущена."
        DOMAIN=""
        ask_continue_or_exit
    fi
}

# ─── 3. SSL (Certbot) ─────────────────────────────────────────────────────────
install_ssl() {
    echo
    echo -e "${BOLD}════════════════ ШАГ 3: SSL-сертификат (Let's Encrypt) ════════════════${RESET}"
    echo "  Бесплатный TLS-сертификат через Certbot + автопродление."
    echo

    if [[ -z "${DOMAIN:-}" ]]; then
        log_warn "Домен не задан — пропускаю SSL."
        return
    fi

    if ask_yes_no "Получить SSL-сертификат для ${DOMAIN}?"; then
        log_info "Устанавливаю Certbot (snap)..."
        snap install --classic certbot 2>/dev/null || true
        ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true

        # Email для Let's Encrypt
        while true; do
            read -r -p "$(echo -e "${CYAN}Email для Let's Encrypt (уведомления о продлении): ${RESET}")" LE_EMAIL
            [[ -n "$LE_EMAIL" ]] && break
            echo -e "${RED}Email не может быть пустым.${RESET}"
        done

        log_info "Выпускаю сертификат для ${DOMAIN} и www.${DOMAIN}..."
        if certbot --nginx -d "${DOMAIN}" -d "www.${DOMAIN}" \
            --non-interactive --agree-tos -m "${LE_EMAIL}" \
            --redirect; then
            log_ok "Certbot успешно выпустил сертификат."
        else
            log_warn "Certbot завершился с ошибкой (см. /var/log/letsencrypt/letsencrypt.log)."
            log_warn "Установка продолжается — SSL можно выпустить позже вручную."
        fi

        # Таймер автопродления уже включён snap-пакетом,
        # но добавим cron как запасной вариант
        (crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx'") | \
            sort -u | crontab -

        log_ok "SSL-сертификат выпущен и настроено автопродление."
        SSL_INSTALLED=true
    else
        log_warn "SSL пропущен."
        SSL_INSTALLED=false
        ask_continue_or_exit
    fi
}

# ─── 4. AMNEZIA-WEB-PANEL (Docker) ────────────────────────────────────────────
install_amnezia_panel() {
    echo
    echo -e "${BOLD}════════════════ ШАГ 4: Amnezia Web Panel (Docker) ════════════════${RESET}"
    echo "  Веб-интерфейс управления AmneziaWG и Xray (XTLS-Reality)."
    echo "  Docker-образ: prvtpro/amnezia-panel"
    echo "  Доступ по умолчанию — admin / admin (смените сразу после входа!)"
    echo

    if ask_yes_no "Установить Amnezia Web Panel в Docker?"; then

        # ── Установка Docker ──
        if ! command -v docker &>/dev/null; then
            log_info "Docker не найден — устанавливаю..."
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
                | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg

            echo \
              "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
              https://download.docker.com/linux/ubuntu \
              $(lsb_release -cs) stable" \
              > /etc/apt/sources.list.d/docker.list

            apt-get update -qq
            apt-get install -y docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin docker-compose-plugin
            systemctl enable docker
            systemctl start docker
            log_ok "Docker установлен."
        else
            log_ok "Docker уже установлен."
        fi

        # ── Порт панели ──
        PANEL_PORT=5000
        read -r -p "$(echo -e "${CYAN}Порт для Amnezia Panel [по умолчанию: 5000]: ${RESET}")" _p
        [[ -n "$_p" ]] && PANEL_PORT="$_p"

        # ── Секретный ключ сессии ──
        SECRET_KEY=$(openssl rand -hex 32)
        log_info "Сгенерирован SECRET_KEY для сессий."

        # ── Каталог данных ──
        PANEL_DATA_DIR="/opt/amnezia-panel"
        mkdir -p "${PANEL_DATA_DIR}"

        # ── Определить последнюю версию образа ──
        log_info "Определяю последнюю версию образа с Docker Hub..."
        PANEL_TAG=$(curl -fsSL \
            "https://hub.docker.com/v2/repositories/prvtpro/amnezia-panel/tags?page_size=10" \
            | grep -oP '"name":"\K[^"]+' | grep -E '^[0-9]' | head -1)
        if [[ -z "$PANEL_TAG" ]]; then
            log_warn "Не удалось определить версию — использую 'latest'."
            PANEL_TAG="latest"
        else
            log_ok "Найдена версия: ${PANEL_TAG}"
        fi

        # ── docker-compose.yml ──
        cat > "${PANEL_DATA_DIR}/docker-compose.yml" <<EOF
version: "3.8"

services:
  amnezia-panel:
    image: prvtpro/amnezia-panel:${PANEL_TAG}
    container_name: amnezia-panel
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PANEL_PORT}:5000"
    volumes:
      - amnezia_data:/app/data
    environment:
      - SECRET_KEY=${SECRET_KEY}
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  amnezia_data:
EOF

        log_info "Запускаю контейнер Amnezia Panel..."
        docker compose -f "${PANEL_DATA_DIR}/docker-compose.yml" pull
        docker compose -f "${PANEL_DATA_DIR}/docker-compose.yml" up -d

        # ── Nginx reverse proxy ──
        if $NGINX_INSTALLED && [[ -n "${DOMAIN:-}" ]]; then
            read -r -p "$(echo -e "${CYAN}Поддомен для панели (например, panel.${DOMAIN}): ${RESET}")" PANEL_DOMAIN
            if [[ -n "$PANEL_DOMAIN" ]]; then
                cat > "/etc/nginx/sites-available/${PANEL_DOMAIN}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${PANEL_DOMAIN};

    # Certbot добавит HTTPS-блок автоматически
    location / {
        proxy_pass         http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
        client_max_body_size 50M;
    }
}
EOF
                ln -sf "/etc/nginx/sites-available/${PANEL_DOMAIN}" \
                       "/etc/nginx/sites-enabled/${PANEL_DOMAIN}"
                nginx -t && systemctl reload nginx || log_warn 'Nginx: ошибка конфига, reload пропущен'

                # SSL для поддомена — обязательный шаг для HTTPS
                if [[ -n "${LE_EMAIL:-}" ]]; then
                    log_info "Выпускаю SSL для ${PANEL_DOMAIN} (HTTPS обязателен для панели)..."
                    certbot --nginx -d "${PANEL_DOMAIN}" \
                        --non-interactive --agree-tos -m "${LE_EMAIL}" --redirect
                    log_ok "SSL для ${PANEL_DOMAIN} выпущен — панель доступна по HTTPS."
                else
                    if ask_yes_no "Выпустить SSL для ${PANEL_DOMAIN}?"; then
                        read -r -p "$(echo -e "${CYAN}Email для Let\'s Encrypt: ${RESET}")" LE_EMAIL
                        if certbot --nginx -d "${PANEL_DOMAIN}" \
                            --non-interactive --agree-tos -m "${LE_EMAIL}" --redirect; then
                        log_ok "SSL для ${PANEL_DOMAIN} выпущен."
                    else
                        log_warn "SSL для ${PANEL_DOMAIN} не выпущен — проверьте DNS и повторите: certbot --nginx -d ${PANEL_DOMAIN}"
                    fi
                    fi
                fi
            fi
        fi

        # ── Открыть порт только если нет Nginx ──
        if ! $NGINX_INSTALLED; then
            ufw allow "${PANEL_PORT}/tcp" 2>/dev/null || true
            log_info "Порт ${PANEL_PORT} открыт в UFW."
        fi

        log_ok "Amnezia Web Panel запущена."
        if [[ -n "${PANEL_DOMAIN:-}" ]]; then
            echo -e "${YELLOW}  ▶  URL панели: https://${PANEL_DOMAIN}${RESET}"
        else
            echo -e "${YELLOW}  ▶  URL панели: http://127.0.0.1:${PANEL_PORT} (только локально)${RESET}"
        fi
        echo -e "${YELLOW}  ▶  Логин: admin  |  Пароль: admin${RESET}"
        echo -e "${RED}  ⚠  НЕМЕДЛЕННО смените пароль после первого входа!${RESET}"
        AMNEZIA_INSTALLED=true
    else
        log_warn "Amnezia Web Panel пропущена."
        AMNEZIA_INSTALLED=false
        ask_continue_or_exit
    fi
}

# ─── 5. CROWDSEC ──────────────────────────────────────────────────────────────
install_crowdsec() {
    echo
    echo -e "${BOLD}════════════════ ШАГ 5: CrowdSec ════════════════${RESET}"
    echo "  Collaborative IPS с парсерами для Nginx, Docker и SSH."
    echo

    if ask_yes_no "Установить и настроить CrowdSec?"; then

        # ── Попытка 1: apt через официальный репозиторий ──
        CS_INSTALLED_NATIVE=false
        log_info "Попытка установки CrowdSec через apt..."
        if curl -s --max-time 15 https://install.crowdsec.net | bash &&            apt-get install -y --no-install-recommends crowdsec crowdsec-firewall-bouncer-nftables 2>/dev/null; then
            CS_INSTALLED_NATIVE=true
            log_ok "CrowdSec установлен через apt."
        else
            log_warn "Apt-установка не удалась (возможно, CDN заблокирован). Переключаюсь на Docker..."
        fi

        if $CS_INSTALLED_NATIVE; then
            # ── Нативная установка: парсеры ──
            cscli hub update
            cscli collections install crowdsecurity/linux crowdsecurity/sshd
            $NGINX_INSTALLED && cscli collections install crowdsecurity/nginx
            ${AMNEZIA_INSTALLED:-false} && cscli collections install crowdsecurity/docker-logs 2>/dev/null || true

            # ── Настройка acquis.yaml ──
            ACQUIS_FILE="/etc/crowdsec/acquis.yaml"
            grep -q "/var/log/auth.log" "${ACQUIS_FILE}" 2>/dev/null || cat >> "${ACQUIS_FILE}" <<'ACQ'

---
filenames:
  - /var/log/auth.log
labels:
  type: syslog
ACQ

            if $NGINX_INSTALLED; then
                grep -q "/var/log/nginx" "${ACQUIS_FILE}" 2>/dev/null || cat >> "${ACQUIS_FILE}" <<'ACQ'

---
filenames:
  - /var/log/nginx/*.log
labels:
  type: nginx
ACQ
            fi

            if ${AMNEZIA_INSTALLED:-false}; then
                grep -q "amnezia-panel" "${ACQUIS_FILE}" 2>/dev/null || cat >> "${ACQUIS_FILE}" <<'ACQ'

---
source: docker
container_name:
  - amnezia-panel
labels:
  type: nginx
ACQ
            fi

            systemctl enable crowdsec crowdsec-firewall-bouncer
            systemctl restart crowdsec crowdsec-firewall-bouncer
            log_ok "CrowdSec (нативный) запущен."
            cscli collections list

        else
            # ── Установка через Docker (fallback при недоступном CDN) ──
            log_info "Устанавливаю CrowdSec в Docker..."

            # Собрать список коллекций
            CS_COLLECTIONS="crowdsecurity/linux crowdsecurity/sshd"
            $NGINX_INSTALLED && CS_COLLECTIONS="${CS_COLLECTIONS} crowdsecurity/nginx"

            mkdir -p /opt/crowdsec/data /opt/crowdsec/config /opt/crowdsec/acquis.d

            # acquis.yaml для Docker-контейнера
            ACQUIS_FILE="/opt/crowdsec/config/acquis.yaml"
            cat > "${ACQUIS_FILE}" <<EOF
---
filenames:
  - /var/log/auth.log
labels:
  type: syslog
EOF
            if $NGINX_INSTALLED; then
                cat >> "${ACQUIS_FILE}" <<EOF

---
filenames:
  - /var/log/nginx/*.log
labels:
  type: nginx
EOF
            fi
            if ${AMNEZIA_INSTALLED:-false}; then
                cat >> "${ACQUIS_FILE}" <<EOF

---
source: docker
container_name:
  - amnezia-panel
labels:
  type: nginx
EOF
            fi

            # Запустить CrowdSec
            docker run -d                 --name crowdsec                 --restart unless-stopped                 --network host                 -e COLLECTIONS="${CS_COLLECTIONS}"                 -v /var/log:/var/log:ro                 -v /var/run/docker.sock:/var/run/docker.sock:ro                 -v /opt/crowdsec/data:/var/lib/crowdsec/data                 -v /opt/crowdsec/config:/etc/crowdsec                 crowdsecurity/crowdsec:latest

            log_info "Ожидаю запуска CrowdSec (15 сек)..."
            sleep 15

            # Получить API-ключ и запустить bouncer
            CS_API_KEY=$(docker exec crowdsec cscli bouncers add nftables-bouncer -o raw 2>/dev/null || echo "")
            if [[ -n "$CS_API_KEY" ]]; then
                docker run -d                     --name crowdsec-bouncer                     --restart unless-stopped                     --network host                     --privileged                     -e CROWDSEC_LAPI_URL=http://127.0.0.1:8080                     -e CROWDSEC_LAPI_KEY="${CS_API_KEY}"                     crowdsecurity/cs-firewall-bouncer:latest
                log_ok "CrowdSec Bouncer запущен."
            else
                log_warn "Не удалось получить API-ключ для bouncer — добавьте вручную: docker exec crowdsec cscli bouncers add mybouncer"
            fi

            log_ok "CrowdSec (Docker) установлен."
            docker exec crowdsec cscli collections list 2>/dev/null || true
        fi

        echo
        echo -e "${CYAN}  Полезные команды CrowdSec:${RESET}"
        if $CS_INSTALLED_NATIVE; then
            echo "    cscli decisions list    — активные блокировки"
            echo "    cscli alerts list       — история тревог"
            echo "    cscli metrics           — статистика"
        else
            echo "    docker exec crowdsec cscli decisions list"
            echo "    docker exec crowdsec cscli alerts list"
            echo "    docker exec crowdsec cscli metrics"
        fi
    else
        log_warn "CrowdSec пропущен."
        ask_continue_or_exit
    fi
}

# ─── 6. BBR ───────────────────────────────────────────────────────────────────
enable_bbr() {
    echo
    echo -e "${BOLD}════════════════ ШАГ 6: BBR (TCP-оптимизация) ════════════════${RESET}"
    echo "  Алгоритм Google BBR увеличивает пропускную способность TCP."
    echo

    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    echo "  Текущий алгоритм: ${CURRENT_CC}"

    if [[ "$CURRENT_CC" == "bbr" ]]; then
        log_ok "BBR уже включён — пропускаю."
        return
    fi

    if ask_yes_no "Включить BBR?"; then
        log_info "Включаю BBR..."

        # Добавить/обновить параметры ядра
        SYSCTL_FILE="/etc/sysctl.d/99-bbr.conf"
        cat > "${SYSCTL_FILE}" <<'EOF'
# TCP BBR — Google Bottleneck Bandwidth and Round-trip propagation time
net.core.default_qdisc       = fq
net.ipv4.tcp_congestion_control = bbr
EOF

        sysctl -p "${SYSCTL_FILE}"

        # Проверка
        ACTIVE_CC=$(sysctl -n net.ipv4.tcp_congestion_control)
        if [[ "$ACTIVE_CC" == "bbr" ]]; then
            log_ok "BBR успешно активирован."
        else
            log_warn "Не удалось активировать BBR (ядро может не поддерживать). Текущий: ${ACTIVE_CC}"
        fi
    else
        log_warn "BBR пропущен."
        ask_continue_or_exit
    fi
}

# ─── ПРОВЕРКА ДОСТУПНОСТИ ПАНЕЛИ И ЗАКРЫТИЕ ПОРТА 5000 ───────────────────────
check_panel_and_close_port() {
    [[ "${AMNEZIA_INSTALLED:-false}" == "false" ]] && return
    [[ -z "${PANEL_DOMAIN:-}" ]] && return

    echo
    echo -e "${BOLD}════════ Проверка доступности панели по HTTPS ════════${RESET}"
    log_info "Проверяю https://${PANEL_DOMAIN} ..."

    HTTP_CODE=$(curl -fsSL --max-time 15 --retry 3 --retry-delay 5 \
        -o /dev/null -w "%{http_code}" "https://${PANEL_DOMAIN}" 2>/dev/null || echo "000")

    if [[ "$HTTP_CODE" =~ ^(200|301|302|303|401|403)$ ]]; then
        log_ok "Панель доступна по HTTPS (HTTP ${HTTP_CODE})."

        # Закрыть порт 5000 в UFW
        if ufw status 2>/dev/null | grep -q "5000"; then
            ufw delete allow 5000/tcp 2>/dev/null || true
            ufw delete allow 5000      2>/dev/null || true
            log_ok "Порт 5000 закрыт в UFW."
        fi

        # Убедиться что контейнер слушает только на 127.0.0.1
        CURRENT_BIND=$(grep -A1 "ports:" /opt/amnezia-panel/docker-compose.yml \
            | grep -oP "[\d.]+(?=:${PANEL_PORT:-5000}:5000)" | head -1)
        if [[ "$CURRENT_BIND" != "127.0.0.1" ]]; then
            log_info "Перепривязываю контейнер на 127.0.0.1:${PANEL_PORT:-5000}..."
            sed -i "s|[0-9.]*:${PANEL_PORT:-5000}:5000|127.0.0.1:${PANEL_PORT:-5000}:5000|" \
                /opt/amnezia-panel/docker-compose.yml
            docker compose -f /opt/amnezia-panel/docker-compose.yml up -d --no-deps
            log_ok "Прямой доступ по порту 5000 закрыт — только через HTTPS."
        else
            log_ok "Контейнер уже привязан к 127.0.0.1 — всё в порядке."
        fi

        echo -e "${GREEN}  ✔  Панель доступна: https://${PANEL_DOMAIN}${RESET}"
    else
        log_warn "Панель недоступна по HTTPS (код: ${HTTP_CODE})."
        echo -e "${YELLOW}  Возможные причины:${RESET}"
        echo "    • DNS ещё не распространился (подождите 5-10 мин)"
        echo "    • SSL-сертификат не выпущен для ${PANEL_DOMAIN}"
        echo "    • Nginx не перезагружен"
        echo
        echo -e "${YELLOW}  Диагностика:${RESET}"
        echo "    curl -I https://${PANEL_DOMAIN}"
        echo "    systemctl status nginx"
        echo "    docker ps | grep amnezia"
        echo
        echo -e "${YELLOW}  Когда панель заработает по HTTPS, закройте порт 5000:${RESET}"
        echo "    ufw delete allow 5000/tcp"
        echo "    sed -i 's|0.0.0.0:5000:5000|127.0.0.1:5000:5000|' /opt/amnezia-panel/docker-compose.yml"
        echo "    docker compose -f /opt/amnezia-panel/docker-compose.yml up -d"
    fi
}

# ─── ИТОГ ─────────────────────────────────────────────────────────────────────
print_summary() {
    echo
    echo -e "${BOLD}${GREEN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                  УСТАНОВКА ЗАВЕРШЕНА                    ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"

    echo -e "${BOLD}Итог:${RESET}"
    echo -e "  Nginx:              $(${NGINX_INSTALLED:-false}     && echo "${GREEN}✔ установлен${RESET}" || echo "${YELLOW}— пропущен${RESET}")"
    echo -e "  Сайт (${DOMAIN:-—}): $( [[ -n "${DOMAIN:-}" ]]     && echo "${GREEN}✔ развёрнут${RESET}"  || echo "${YELLOW}— пропущен${RESET}")"
    echo -e "  SSL:                $(${SSL_INSTALLED:-false}       && echo "${GREEN}✔ выпущен${RESET}"    || echo "${YELLOW}— пропущен${RESET}")"
    echo -e "  Amnezia Panel:      $(${AMNEZIA_INSTALLED:-false}   && echo "${GREEN}✔ запущена${RESET}"   || echo "${YELLOW}— пропущена${RESET}")"
    CROWDSEC_OK=false
    systemctl is-active --quiet crowdsec 2>/dev/null && CROWDSEC_OK=true
    echo -e "  CrowdSec:           $(${CROWDSEC_OK}               && echo "${GREEN}✔ активен${RESET}"    || echo "${YELLOW}— пропущен${RESET}")"
    BBR_ACTIVE=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    echo -e "  BBR:                $([[ "$BBR_ACTIVE" == "bbr" ]] && echo "${GREEN}✔ включён${RESET}"    || echo "${YELLOW}— не активен${RESET}")"

    if ${AMNEZIA_INSTALLED:-false}; then
        echo
        echo -e "${BOLD}Amnezia Panel:${RESET}"
        if [[ -n "${PANEL_DOMAIN:-}" ]]; then
            echo -e "  URL: https://${PANEL_DOMAIN}"
        else
            echo -e "  URL: http://<IP>:${PANEL_PORT:-5000}"
        fi
        echo -e "  Логин: ${RED}admin${RESET} / Пароль: ${RED}admin${RESET} — ${BOLD}смените немедленно!${RESET}"
        echo -e "  Данные панели: /opt/amnezia-panel/"
    fi

    echo
    log_info "Лог установки сохранён в /var/log/vps_setup.log"
}


# ─── УСТАНОВКА КОМАНДЫ MYSERVERINFO ──────────────────────────────────────────
install_myserverinfo() {
    log_info "Устанавливаю команду myserverinfo..."

    MENU_PATH="/usr/local/bin/myserverinfo"

    cat > "${MENU_PATH}" << 'MENUEOF'
#!/usr/bin/env bash
# myserverinfo — интерактивное меню состояния сервера

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'
DIM='\033[2m'; RESET='\033[0m'

detect_panel_domain() {
    grep -rl "127.0.0.1:5000" /etc/nginx/sites-enabled/ 2>/dev/null \
        | xargs grep -h "server_name" 2>/dev/null \
        | grep -oP 'server_name\s+\K\S+' | head -1
}
PANEL_DOMAIN=$(detect_panel_domain)

print_header() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════╗"
    printf "  ║  SERVER INFO  •  %-30s  ║\n" "$(hostname)"
    printf "  ║  %-47s  ║\n" "$(date '+%d.%m.%Y %H:%M:%S')  •  $(uptime -p)"
    echo "  ╚══════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

divider() { echo -e "${DIM}  ──────────────────────────────────────────────${RESET}"; }

press_back() {
    echo; divider
    echo -e "  ${DIM}Нажмите ${RESET}${BOLD}Enter${RESET}${DIM} для возврата в меню...${RESET}"
    read -r
}

show_nginx() {
    print_header
    echo -e "  ${BOLD}${BLUE}▶  NGINX${RESET}"; divider
    systemctl is-active --quiet nginx \
        && echo -e "  Служба:  ${GREEN}● работает${RESET}" \
        || echo -e "  Служба:  ${RED}✖ остановлена${RESET}"
    echo -e "  Версия:  ${CYAN}$(nginx -v 2>&1 | grep -oP 'nginx/\K[\d.]+')${RESET}"
    divider
    echo -e "  ${BOLD}Виртуальные хосты:${RESET}"
    for f in /etc/nginx/sites-enabled/*; do
        SN=$(grep -m1 "server_name" "$f" 2>/dev/null | awk '{print $2}' | tr -d ';')
        SSL=$( grep -q "ssl_certificate" "$f" 2>/dev/null && echo "${GREEN}🔒 HTTPS${RESET}" || echo "${YELLOW}HTTP${RESET}" )
        echo -e "    ${CYAN}$(basename "$f")${RESET}  →  ${SN}  ${SSL}"
    done
    divider
    echo -e "  ${BOLD}Последние 10 ошибок:${RESET}"
    tail -10 /var/log/nginx/error.log 2>/dev/null | sed 's/^/    /' || echo -e "    ${DIM}Лог пуст${RESET}"
    divider
    echo -e "  ${BOLD}Топ-5 IP (access.log):${RESET}"
    awk '{print $1}' /var/log/nginx/access.log 2>/dev/null \
        | sort | uniq -c | sort -rn | head -5 | awk '{printf "    %6s  %s\n",$1,$2}' \
        || echo -e "    ${DIM}Нет данных${RESET}"
    press_back
}

show_crowdsec() {
    print_header
    echo -e "  ${BOLD}${BLUE}▶  CROWDSEC${RESET}"; divider
    if command -v cscli &>/dev/null; then
        CSCLI="cscli"
        systemctl is-active --quiet crowdsec \
            && echo -e "  Режим:  ${CYAN}нативный${RESET}  ${GREEN}● работает${RESET}" \
            || echo -e "  Режим:  ${CYAN}нативный${RESET}  ${RED}✖ остановлен${RESET}"
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^crowdsec$"; then
        CSCLI="docker exec crowdsec cscli"
        echo -e "  Режим:  ${CYAN}Docker${RESET}  ${GREEN}● работает${RESET}"
    else
        echo -e "  ${RED}CrowdSec не обнаружен.${RESET}"; press_back; return
    fi
    divider
    echo -e "  ${BOLD}Активные блокировки:${RESET}"
    DECISIONS=$($CSCLI decisions list 2>/dev/null)
    echo "$DECISIONS" | grep -q "No active" \
        && echo -e "    ${GREEN}Нет активных блокировок${RESET}" \
        || echo "$DECISIONS" | head -20 | sed 's/^/    /'
    divider
    echo -e "  ${BOLD}Последние 5 тревог:${RESET}"
    $CSCLI alerts list --limit 5 2>/dev/null | sed 's/^/    /' || echo -e "    ${DIM}Нет данных${RESET}"
    divider
    echo -e "  ${BOLD}Bouncers:${RESET}"
    $CSCLI bouncers list 2>/dev/null | sed 's/^/    /' || echo -e "    ${DIM}Нет данных${RESET}"
    press_back
}

show_amnezia() {
    print_header
    echo -e "  ${BOLD}${BLUE}▶  AMNEZIA PANEL${RESET}"; divider
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^amnezia-panel$"; then
        echo -e "  Контейнер:  ${GREEN}● $(docker inspect --format='{{.State.Status}}' amnezia-panel 2>/dev/null)${RESET}"
        echo -e "  Образ:      ${CYAN}$(docker inspect --format='{{.Config.Image}}' amnezia-panel 2>/dev/null)${RESET}"
        HTTP_LOCAL=$(curl -so /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:5000 2>/dev/null || echo "000")
        [[ "$HTTP_LOCAL" =~ ^(200|301|302|401|403)$ ]] \
            && echo -e "  Локальный:  ${GREEN}✔ HTTP ${HTTP_LOCAL}${RESET}" \
            || echo -e "  Локальный:  ${RED}✖ не отвечает${RESET}"
        if [[ -n "$PANEL_DOMAIN" ]]; then
            HTTP_EXT=$(curl -so /dev/null -w "%{http_code}" --max-time 10 "https://${PANEL_DOMAIN}" 2>/dev/null || echo "000")
            [[ "$HTTP_EXT" =~ ^(200|301|302|401|403)$ ]] \
                && echo -e "  HTTPS:      ${GREEN}✔ https://${PANEL_DOMAIN}${RESET}" \
                || echo -e "  HTTPS:      ${RED}✖ не отвечает${RESET}"
        fi
        divider
        echo -e "  ${BOLD}Ресурсы:${RESET}"
        docker stats amnezia-panel --no-stream \
            --format "    CPU: {{.CPUPerc}}   RAM: {{.MemUsage}} ({{.MemPerc}})" 2>/dev/null
        divider
        echo -e "  ${BOLD}Последние 15 строк лога:${RESET}"
        docker logs amnezia-panel --tail 15 2>/dev/null | sed 's/^/    /'
        divider
        [[ -n "$PANEL_DOMAIN" ]] && echo -e "  ${GREEN}${BOLD}URL: https://${PANEL_DOMAIN}${RESET}"
    else
        echo -e "  ${RED}✖ Контейнер не запущен${RESET}"
        echo -e "  ${YELLOW}Запуск: docker compose -f /opt/amnezia-panel/docker-compose.yml up -d${RESET}"
    fi
    press_back
}

main_menu() {
    while true; do
        print_header
        NGX_S=$(  systemctl is-active nginx    2>/dev/null || echo "inactive")
        AMZ_N=$(  docker ps --format '{{.Names}}' 2>/dev/null | grep -c "amnezia-panel" || echo 0)
        CS_N=$(   systemctl is-active crowdsec 2>/dev/null || echo "inactive")
        CS_D=$(   docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^crowdsec$"     || echo 0)
        [[ "$NGX_S" == "active"  ]] && N="${GREEN}●${RESET}" || N="${RED}●${RESET}"
        [[ "$AMZ_N" -gt 0        ]] && A="${GREEN}●${RESET}" || A="${RED}●${RESET}"
        ( [[ "$CS_N" == "active" ]] || [[ "$CS_D" -gt 0 ]] ) && C="${GREEN}●${RESET}" || C="${RED}●${RESET}"
        echo -e "  ${BOLD}1${RESET}  ${N}  Состояние Nginx"
        echo -e "  ${BOLD}2${RESET}  ${C}  Блокировки CrowdSec"
        echo -e "  ${BOLD}3${RESET}  ${A}  Панель Amnezia"
        echo; divider
        echo -e "  ${BOLD}0${RESET}  ${DIM}Выйти${RESET}"; echo
        read -r -p "$(echo -e "  ${CYAN}→ ${RESET}")" CH
        case "$CH" in
            1) show_nginx    ;;
            2) show_crowdsec ;;
            3) show_amnezia  ;;
            0|q|Q) echo -e "\n  ${DIM}До свидания.${RESET}\n"; exit 0 ;;
            *) echo -e "  ${RED}Неверный выбор.${RESET}"; sleep 1 ;;
        esac
    done
}

main_menu
MENUEOF

    chmod +x "${MENU_PATH}"
    log_ok "Команда myserverinfo установлена → введите: myserverinfo"
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────
main() {
    # Сохранять вывод в лог
    exec > >(tee -a /var/log/vps_setup.log) 2>&1

    check_root
    banner

    echo -e "${BOLD}Этот скрипт установит компоненты по вашему выбору.${RESET}"
    echo "  Для каждого шага будет запрошено подтверждение."
    echo "  При отказе — возможность пропустить или выйти."
    echo

    # Глобальные флаги
    NGINX_INSTALLED=false
    SSL_INSTALLED=false
    AMNEZIA_INSTALLED=false
    DOMAIN=""
    LE_EMAIL=""
    PANEL_PORT=5000
    PANEL_DOMAIN=""

    system_update

    install_nginx       # ШАГ 1
    setup_website       # ШАГ 2
    install_ssl         # ШАГ 3
    install_amnezia_panel  # ШАГ 4
    install_crowdsec    # ШАГ 5
    enable_bbr          # ШАГ 6

    check_panel_and_close_port  # Проверка HTTPS и закрытие порта 5000
    install_myserverinfo        # Установка команды myserverinfo

    print_summary
}

main "$@"
