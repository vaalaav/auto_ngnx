#!/usr/bin/env bash
# =============================================================================
#  VPS Setup Script — Ubuntu 24.04
#  Компоненты: Nginx · SSL (Certbot) · Amnezia-Web-Panel (Docker)
#              CrowdSec · BBR
# =============================================================================

set -euo pipefail

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
        nginx -t && systemctl reload nginx
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
        certbot --nginx -d "${DOMAIN}" -d "www.${DOMAIN}" \
            --non-interactive --agree-tos -m "${LE_EMAIL}" \
            --redirect

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

        # ── docker-compose.yml ──
        cat > "${PANEL_DATA_DIR}/docker-compose.yml" <<EOF
version: "3.8"

services:
  amnezia-panel:
    image: prvtpro/amnezia-panel:latest
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
        client_max_body_size 50M;
    }
}
EOF
                ln -sf "/etc/nginx/sites-available/${PANEL_DOMAIN}" \
                       "/etc/nginx/sites-enabled/${PANEL_DOMAIN}"
                nginx -t && systemctl reload nginx

                # SSL для поддомена
                if ${SSL_INSTALLED:-false} && [[ -n "${LE_EMAIL:-}" ]]; then
                    if ask_yes_no "Выпустить SSL для ${PANEL_DOMAIN}?"; then
                        certbot --nginx -d "${PANEL_DOMAIN}" \
                            --non-interactive --agree-tos -m "${LE_EMAIL}" --redirect
                        log_ok "SSL для ${PANEL_DOMAIN} выпущен."
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
        echo -e "${YELLOW}  ▶  URL панели: http://127.0.0.1:${PANEL_PORT}${RESET}"
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
        log_info "Добавляю репозиторий CrowdSec..."
        curl -s https://install.crowdsec.net | bash

        apt-get install -y crowdsec

        # ── Парсеры ──
        log_info "Устанавливаю парсеры и сценарии..."
        cscli hub update

        # SSH — всегда
        cscli collections install crowdsecurity/linux
        cscli collections install crowdsecurity/sshd

        if $NGINX_INSTALLED; then
            cscli collections install crowdsecurity/nginx
            log_ok "CrowdSec: парсер Nginx подключён."
        fi

        if ${AMNEZIA_INSTALLED:-false}; then
            # Docker-логи
            cscli collections install crowdsecurity/docker-logs 2>/dev/null || true
            log_ok "CrowdSec: парсер Docker-logs подключён."
        fi

        # ── Bouncer для NFTables ──
        log_info "Устанавливаю NFTables-bouncer..."
        apt-get install -y crowdsec-firewall-bouncer-nftables

        systemctl enable crowdsec-firewall-bouncer
        systemctl start  crowdsec-firewall-bouncer

        # ── Настройка acquis.yaml ──
        ACQUIS_FILE="/etc/crowdsec/acquis.yaml"

        # SSH
        if ! grep -q "/var/log/auth.log" "${ACQUIS_FILE}" 2>/dev/null; then
            cat >> "${ACQUIS_FILE}" <<'ACQUIS'

---
filenames:
  - /var/log/auth.log
labels:
  type: syslog
ACQUIS
        fi

        # Nginx
        if $NGINX_INSTALLED; then
            if ! grep -q "/var/log/nginx" "${ACQUIS_FILE}" 2>/dev/null; then
                cat >> "${ACQUIS_FILE}" <<'ACQUIS'

---
filenames:
  - /var/log/nginx/*.log
labels:
  type: nginx
ACQUIS
            fi
        fi

        # Docker-логи Amnezia
        if ${AMNEZIA_INSTALLED:-false}; then
            if ! grep -q "amnezia-panel" "${ACQUIS_FILE}" 2>/dev/null; then
                cat >> "${ACQUIS_FILE}" <<'ACQUIS'

---
source: docker
container_name:
  - amnezia-panel
labels:
  type: nginx
ACQUIS
            fi
        fi

        systemctl enable crowdsec
        systemctl restart crowdsec

        # ── Итоговая сводка ──
        log_ok "CrowdSec установлен."
        echo
        cscli collections list
        echo
        echo -e "${CYAN}  Полезные команды:${RESET}"
        echo "    cscli decisions list          — активные блокировки"
        echo "    cscli alerts list             — история тревог"
        echo "    cscli metrics                 — статистика"
        echo "    cscli ban add ip <IP> 24h     — ручная блокировка"
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

    print_summary
}

main "$@"
