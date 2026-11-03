#!/usr/bin/env bash
# =============================================================================
#  VPS Setup Script — Ubuntu 24.04
#  Компоненты: Nginx · SSL · CrowdSec · CyberOK/Skipa IP-блок · BBR
#  + команда myserverinfo
# =============================================================================

set -uo pipefail

# ─── Цвета ───────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
C='\033[0;36m'; B='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; N='\033[0m'

log_info()  { echo -e "${C}[INFO]${N}  $*"; }
log_ok()    { echo -e "${G}[OK]${N}    $*"; }
log_warn()  { echo -e "${Y}[WARN]${N}  $*"; }
log_err()   { echo -e "${R}[ERR]${N}   $*" >&2; }

banner() {
    clear
    echo -e "${BOLD}${C}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║           VPS AUTO-SETUP  ·  Ubuntu 24.04                ║"
    echo "║   Nginx · SSL · CrowdSec · IP-блок · BBR                 ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${N}"
}

# ─── Единый диалог: y=выполнить  s=пропустить  c=отмена ─────────────────────
ask_action() {
    local prompt="$1"
    while true; do
        echo -e "${Y}┌─ ${BOLD}${prompt}${N}"
        read -r -p "$(echo -e "${Y}└─ [y] выполнить  [s] пропустить  [c] отмена: ${N}")" ans
        case "${ans,,}" in
            y|yes|д|да)         return 0 ;;
            s|skip|п|пропустить)
                log_warn "Шаг пропущен."
                return 1
                ;;
            c|cancel|о|отмена)
                echo -e "${R}Установка отменена.${N}"
                exit 0
                ;;
            *) echo -e "${R}Введите y, s или c.${N}" ;;
        esac
    done
}

# ─── Базовые проверки ─────────────────────────────────────────────────────────
check_root() {
    [[ $EUID -eq 0 ]] || { log_err "Запустите от root: sudo bash $0"; exit 1; }
}

system_update() {
    log_info "Обновление пакетов..."
    apt-get update -qq
    apt-get install -y -qq \
        curl wget git ufw gnupg lsb-release ca-certificates \
        apt-transport-https software-properties-common snapd \
        nftables ipset 2>/dev/null
    systemctl enable nftables 2>/dev/null || true
}

# ═════════════════════════════════════════════════════════════════════════════
#  ШАГ 1 · NGINX
# ═════════════════════════════════════════════════════════════════════════════
install_nginx() {
    echo
    echo -e "${BOLD}══════════════ ШАГ 1: Nginx ══════════════${N}"
    echo "  Веб-сервер + базовые настройки безопасности."
    echo

    if ! ask_action "Установить Nginx?"; then
        NGINX_INSTALLED=false; return
    fi

    log_info "Добавляю официальный репозиторий nginx.org (mainline)..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor -o /etc/apt/keyrings/nginx.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/nginx.gpg] \
https://nginx.org/packages/mainline/ubuntu $(lsb_release -cs) nginx" \
        > /etc/apt/sources.list.d/nginx.list
    apt-get update -qq

    NGINX_VER=$(apt-cache madison nginx 2>/dev/null \
        | grep "nginx.org" | head -1 | awk '{print $3}')
    if [[ -n "$NGINX_VER" ]]; then
        apt-get install -y "nginx=${NGINX_VER}"
    else
        apt-get install -y nginx
    fi

    # Базовые security-заголовки
    cat > /etc/nginx/conf.d/security.conf <<'EOF'
server_tokens off;
server_names_hash_bucket_size 128;
add_header X-Frame-Options SAMEORIGIN;
add_header X-Content-Type-Options nosniff;
add_header X-XSS-Protection "1; mode=block";
add_header Referrer-Policy "strict-origin-when-cross-origin";
EOF

    systemctl enable nginx
    systemctl start  nginx
    ufw allow "Nginx Full" 2>/dev/null || true

    log_ok "Nginx $(nginx -v 2>&1 | grep -oP 'nginx/\K[\d.]+') установлен."
    NGINX_INSTALLED=true
}

# ═════════════════════════════════════════════════════════════════════════════
#  ШАГ 2 · САЙТ из GitHub
# ═════════════════════════════════════════════════════════════════════════════
setup_website() {
    echo
    echo -e "${BOLD}══════════════ ШАГ 2: Сайт из GitHub ══════════════${N}"
    echo "  Клонирование шаблона и настройка Nginx-хоста."
    echo

    DOMAIN=""; REPO_URL=""

    if ! $NGINX_INSTALLED; then
        log_warn "Nginx не установлен — шаг пропущен."; return
    fi

    if ! ask_action "Развернуть сайт из GitHub-шаблона?"; then return; fi

    while true; do
        read -r -p "$(echo -e "${C}Домен сайта (например, example.com): ${N}")" DOMAIN
        [[ -n "$DOMAIN" ]] && break
        echo -e "${R}Домен не может быть пустым.${N}"
    done

    while true; do
        read -r -p "$(echo -e "${C}Ссылка на репозиторий (https://github.com/...): ${N}")" REPO_URL
        [[ -n "$REPO_URL" ]] && break
        echo -e "${R}Ссылка не может быть пустой.${N}"
    done

    WEBROOT="/var/www/${DOMAIN}"
    log_info "Клонирую ${REPO_URL} → ${WEBROOT}..."
    rm -rf "${WEBROOT}"
    git clone "${REPO_URL}" "${WEBROOT}"
    chown -R www-data:www-data "${WEBROOT}"
    find "${WEBROOT}" -type d -exec chmod 755 {} \;
    find "${WEBROOT}" -type f -exec chmod 644 {} \;

    cat > "/etc/nginx/sites-available/${DOMAIN}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    root ${WEBROOT};
    index index.html index.htm;

    access_log /var/log/nginx/${DOMAIN}_access.log;
    error_log  /var/log/nginx/${DOMAIN}_error.log;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ /\. { deny all; }

    # Кэширование статики
    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }
}
EOF

    # Отключить дефолтный хост если есть
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"
    nginx -t && systemctl reload nginx \
        || log_warn "Nginx: ошибка конфига, проверьте вручную."

    log_ok "Сайт ${DOMAIN} развёрнут из ${REPO_URL}."
}

# ═════════════════════════════════════════════════════════════════════════════
#  ШАГ 3 · SSL (Certbot)
# ═════════════════════════════════════════════════════════════════════════════
install_ssl() {
    echo
    echo -e "${BOLD}══════════════ ШАГ 3: SSL (Let's Encrypt) ══════════════${N}"
    echo "  Бесплатный TLS-сертификат + автопродление."
    echo

    LE_EMAIL=""; SSL_INSTALLED=false

    if [[ -z "${DOMAIN:-}" ]]; then
        log_warn "Домен не задан — шаг пропущен."; return
    fi

    if ! ask_action "Выпустить SSL-сертификат для ${DOMAIN}?"; then return; fi

    log_info "Устанавливаю Certbot (snap)..."
    snap install --classic certbot 2>/dev/null || true
    ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true

    while true; do
        read -r -p "$(echo -e "${C}Email для Let's Encrypt: ${N}")" LE_EMAIL
        [[ -n "$LE_EMAIL" ]] && break
        echo -e "${R}Email не может быть пустым.${N}"
    done

    log_info "Выпускаю сертификат для ${DOMAIN} и www.${DOMAIN}..."
    if certbot --nginx -d "${DOMAIN}" -d "www.${DOMAIN}" \
        --non-interactive --agree-tos -m "${LE_EMAIL}" --redirect; then
        # Cron-продление
        (crontab -l 2>/dev/null; \
         echo "0 3 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx'") \
            | sort -u | crontab -
        log_ok "SSL выпущен. Автопродление настроено."
        SSL_INSTALLED=true
    else
        log_warn "Certbot завершился с ошибкой."
        log_warn "Проверьте DNS и повторите вручную:"
        echo "  certbot --nginx -d ${DOMAIN} -d www.${DOMAIN} -m EMAIL --agree-tos --redirect"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  ШАГ 4 · CROWDSEC
# ═════════════════════════════════════════════════════════════════════════════
install_crowdsec() {
    echo
    echo -e "${BOLD}══════════════ ШАГ 4: CrowdSec ══════════════${N}"
    echo "  Collaborative IPS: парсеры SSH + Nginx, nftables-bouncer."
    echo

    if ! ask_action "Установить CrowdSec?"; then return; fi

    CS_INSTALLED_NATIVE=false

    # ── Попытка 1: apt ──
    log_info "Пробую установку через apt (packagecloud)..."
    if curl -fsSL --max-time 20 https://install.crowdsec.net | bash 2>/dev/null \
       && apt-get install -y crowdsec crowdsec-firewall-bouncer-nftables 2>/dev/null; then

        CS_INSTALLED_NATIVE=true
        log_ok "CrowdSec установлен через apt."

    else
        log_warn "Apt недоступен (CDN заблокирован). Переключаюсь на Docker..."

        # ── Fallback: Docker ──
        if ! command -v docker &>/dev/null; then
            log_info "Устанавливаю Docker..."
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
                | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
                > /etc/apt/sources.list.d/docker.list
            apt-get update -qq
            apt-get install -y docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin docker-compose-plugin
            systemctl enable docker && systemctl start docker
        fi

        CS_TAG=$(curl -fsSL \
            "https://hub.docker.com/v2/repositories/crowdsecurity/crowdsec/tags?page_size=20" \
            2>/dev/null | grep -oP '"name":"\K[^"]+' \
            | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
        CS_TAG="${CS_TAG:-latest}"

        BOUNCER_TAG=$(curl -fsSL \
            "https://hub.docker.com/v2/repositories/crowdsecurity/cs-firewall-bouncer/tags?page_size=20" \
            2>/dev/null | grep -oP '"name":"\K[^"]+' \
            | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
        BOUNCER_TAG="${BOUNCER_TAG:-latest}"

        log_ok "CrowdSec Docker тег: ${CS_TAG}"
        log_ok "Bouncer Docker тег:  ${BOUNCER_TAG}"

        mkdir -p /opt/crowdsec/data /opt/crowdsec/config

        CS_COLLECTIONS="crowdsecurity/linux crowdsecurity/sshd"
        ${NGINX_INSTALLED:-false} && CS_COLLECTIONS="${CS_COLLECTIONS} crowdsecurity/nginx"

        # acquis.yaml
        cat > /opt/crowdsec/config/acquis.yaml <<AEOF
---
filenames:
  - /var/log/auth.log
labels:
  type: syslog
AEOF
        ${NGINX_INSTALLED:-false} && cat >> /opt/crowdsec/config/acquis.yaml <<AEOF

---
filenames:
  - /var/log/nginx/*.log
labels:
  type: nginx
AEOF

        docker run -d \
            --name crowdsec \
            --restart unless-stopped \
            --network host \
            -e COLLECTIONS="${CS_COLLECTIONS}" \
            -v /var/log:/var/log:ro \
            -v /var/run/docker.sock:/var/run/docker.sock:ro \
            -v /opt/crowdsec/data:/var/lib/crowdsec/data \
            -v /opt/crowdsec/config:/etc/crowdsec \
            "crowdsecurity/crowdsec:${CS_TAG}"

        log_info "Жду запуска CrowdSec (15 сек)..."
        sleep 15

        CS_API_KEY=$(docker exec crowdsec cscli bouncers add nftables-bouncer -o raw 2>/dev/null || echo "")
        if [[ -n "$CS_API_KEY" ]]; then
            docker run -d \
                --name crowdsec-bouncer \
                --restart unless-stopped \
                --network host \
                --privileged \
                -e CROWDSEC_LAPI_URL=http://127.0.0.1:8080 \
                -e CROWDSEC_LAPI_KEY="${CS_API_KEY}" \
                "crowdsecurity/cs-firewall-bouncer:${BOUNCER_TAG}"
            log_ok "CrowdSec bouncer запущен."
        else
            log_warn "API-ключ не получен. Добавьте bouncer вручную:"
            echo "  docker exec crowdsec cscli bouncers add mybouncer"
        fi
    fi

    if $CS_INSTALLED_NATIVE; then
        # Коллекции и acquis
        cscli hub update
        cscli collections install crowdsecurity/linux crowdsecurity/sshd
        ${NGINX_INSTALLED:-false} && cscli collections install crowdsecurity/nginx

        ACQUIS=/etc/crowdsec/acquis.yaml
        grep -q "/var/log/auth.log" "${ACQUIS}" 2>/dev/null || cat >> "${ACQUIS}" <<'AEOF'

---
filenames:
  - /var/log/auth.log
labels:
  type: syslog
AEOF
        if ${NGINX_INSTALLED:-false}; then
            grep -q "/var/log/nginx" "${ACQUIS}" 2>/dev/null || cat >> "${ACQUIS}" <<'AEOF'

---
filenames:
  - /var/log/nginx/*.log
labels:
  type: nginx
AEOF
        fi

        systemctl enable crowdsec crowdsec-firewall-bouncer 2>/dev/null || true
        systemctl restart crowdsec crowdsec-firewall-bouncer 2>/dev/null || true
    fi

    log_ok "CrowdSec настроен."
}

# ═════════════════════════════════════════════════════════════════════════════
#  ШАГ 5 · БЛОКИРОВКА CyberOK / Skipa IP
# ═════════════════════════════════════════════════════════════════════════════

SKIPA_LIST_URL="https://raw.githubusercontent.com/tread-lightly/CyberOK_Skipa_ips/main/lists/skipa_cidr.txt"
SKIPA_LOCAL="/etc/skipa_block/skipa_cidr.txt"
SKIPA_NFT_SET="skipa_block"
SKIPA_UPDATE_SCRIPT="/usr/local/bin/skipa_update"

install_skipa_block() {
    echo
    echo -e "${BOLD}══════════════ ШАГ 5: Блокировка CyberOK/Skipa IP ══════════════${N}"
    echo "  Блокировка сканеров РКН/ГРЧЦ/НКЦКИ через nftables."
    echo "  Источник: github.com/tread-lightly/CyberOK_Skipa_ips (CIDR-лист)"
    echo "  Автообновление: ежедневно в 04:00."
    echo

    if ! ask_action "Установить блокировку CyberOK/Skipa IP?"; then return; fi

    mkdir -p /etc/skipa_block

    # ── Скрипт обновления (используется и при первом запуске) ──
    cat > "${SKIPA_UPDATE_SCRIPT}" <<'UEOF'
#!/usr/bin/env bash
# Обновление списка CyberOK/Skipa IP и применение через nftables
set -uo pipefail

LIST_URL="https://raw.githubusercontent.com/tread-lightly/CyberOK_Skipa_ips/main/lists/skipa_cidr.txt"
LOCAL="/etc/skipa_block/skipa_cidr.txt"
SET_NAME="skipa_block"
TMP=$(mktemp)
LOG="/var/log/skipa_update.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" | tee -a "${LOG}"; }

log "Загружаю список..."
if ! curl -fsSL --max-time 30 --retry 3 "${LIST_URL}" -o "${TMP}"; then
    log "ОШИБКА: не удалось загрузить список."
    rm -f "${TMP}"; exit 1
fi

# Фильтруем только валидные CIDR/IP строки
grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]' "${TMP}" \
    | grep -v '^#' | sed 's/[[:space:]]//g' \
    | sort -u > "${LOCAL}"
rm -f "${TMP}"

COUNT=$(wc -l < "${LOCAL}")
log "Загружено ${COUNT} записей."

# Создать/обновить nftables-таблицу
nft list table ip "${SET_NAME}" &>/dev/null && nft delete table ip "${SET_NAME}"

nft add table ip "${SET_NAME}"
nft add chain ip "${SET_NAME}" input  \
    '{ type filter hook input priority -1 ; policy accept ; }'
nft add chain ip "${SET_NAME}" output \
    '{ type filter hook output priority -1 ; policy accept ; }'

nft add set ip "${SET_NAME}" blocklist \
    '{ type ipv4_addr ; flags interval ; auto-merge ; }'

# Загружаем блоками по 200 записей (nft имеет лимит длины команды)
mapfile -t ENTRIES < "${LOCAL}"
TOTAL=${#ENTRIES[@]}
BATCH=200
for ((i=0; i<TOTAL; i+=BATCH)); do
    CHUNK=("${ENTRIES[@]:$i:$BATCH}")
    ELEMENTS=$(IFS=', '; echo "${CHUNK[*]}")
    nft add element ip "${SET_NAME}" blocklist "{ ${ELEMENTS} }" 2>/dev/null || true
done

# Правила блокировки
nft add rule ip "${SET_NAME}" input  ip saddr @blocklist drop
nft add rule ip "${SET_NAME}" output ip daddr @blocklist drop

# Сохранить правила для автозагрузки при перезагрузке
nft list table ip "${SET_NAME}" > /etc/nftables.d/skipa.nft 2>/dev/null || true

LOADED=$(nft list set ip "${SET_NAME}" blocklist 2>/dev/null \
    | grep -oP '(?<=elements = \{)[^}]+' | tr ',' '\n' | grep -c '\.' || echo 0)
log "Заблокировано ${LOADED} адресов/подсетей. Готово."
UEOF
    chmod +x "${SKIPA_UPDATE_SCRIPT}"

    # ── Настроить автозагрузку nftables-правил при старте системы ──
    mkdir -p /etc/nftables.d
    if ! grep -q "skipa.nft" /etc/nftables.conf 2>/dev/null; then
        cat >> /etc/nftables.conf <<'EOF'

# CyberOK/Skipa IP block
include "/etc/nftables.d/skipa.nft"
EOF
    fi

    # ── Первый запуск ──
    log_info "Загружаю и применяю список IP..."
    if bash "${SKIPA_UPDATE_SCRIPT}"; then
        log_ok "Список применён."
    else
        log_warn "Не удалось применить список при первом запуске."
        log_warn "Попробуйте позже: ${SKIPA_UPDATE_SCRIPT}"
    fi

    # ── Cron: ежедневное обновление в 04:00 ──
    (crontab -l 2>/dev/null; \
     echo "0 4 * * * ${SKIPA_UPDATE_SCRIPT} >> /var/log/skipa_update.log 2>&1") \
        | sort -u | crontab -

    log_ok "Автообновление списка добавлено в cron (ежедневно 04:00)."
    echo
    echo -e "  Полезные команды:"
    echo -e "    ${C}${SKIPA_UPDATE_SCRIPT}${N}              — обновить список вручную"
    echo -e "    ${C}nft list set ip skipa_block blocklist${N} — просмотр заблокированных"
    echo -e "    ${C}tail -f /var/log/skipa_update.log${N}    — лог обновлений"
}

# ═════════════════════════════════════════════════════════════════════════════
#  ШАГ 6 · BBR
# ═════════════════════════════════════════════════════════════════════════════
enable_bbr() {
    echo
    echo -e "${BOLD}══════════════ ШАГ 6: BBR ══════════════${N}"
    echo "  TCP BBR (VadimBoev/bbr) — оптимизация пропускной способности."
    echo

    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if [[ "$CURRENT_CC" == "bbr" ]]; then
        log_ok "BBR уже активен — шаг пропущен."; return
    fi

    if ! ask_action "Включить BBR?"; then return; fi

    log_info "Запускаю скрипт VadimBoev/bbr..."
    if wget -qO- https://raw.githubusercontent.com/VadimBoev/bbr/main/enable_bbr.sh | bash; then
        log_ok "Скрипт BBR выполнен."
    else
        log_warn "Не удалось загрузить скрипт. Применяю локально..."
        cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc       = fq
net.ipv4.tcp_congestion_control = bbr
EOF
        sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1
    fi

    ACTIVE=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    [[ "$ACTIVE" == "bbr" ]] \
        && log_ok "BBR активирован." \
        || log_warn "BBR не активирован (ядро: ${ACTIVE}). Попробуйте перезагрузить сервер."
}

# ═════════════════════════════════════════════════════════════════════════════
#  КОМАНДА myserverinfo
# ═════════════════════════════════════════════════════════════════════════════
install_myserverinfo() {
    log_info "Устанавливаю команду myserverinfo..."

    cat > /usr/local/bin/myserverinfo <<'MENUEOF'
#!/usr/bin/env bash
# myserverinfo — интерактивное меню состояния сервера

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
C='\033[0;36m'; B='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; N='\033[0m'

detect_panel_domain() {
    grep -rl "127.0.0.1:5000" /etc/nginx/sites-enabled/ 2>/dev/null \
        | xargs grep -h "server_name" 2>/dev/null \
        | grep -oP 'server_name\s+\K\S+' | grep -v '^_' | head -1
}

get_cscli() {
    if command -v cscli &>/dev/null && systemctl is-active --quiet crowdsec 2>/dev/null; then
        echo "cscli"
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^crowdsec$"; then
        echo "docker exec crowdsec cscli"
    else
        echo ""
    fi
}

print_header() {
    clear
    local ip; ip=$(hostname -I | awk '{print $1}')
    echo -e "${BOLD}${C}"
    echo   "  ╔════════════════════════════════════════════════════╗"
    printf "  ║  🖥  %-47s║\n" "$(hostname)  ·  ${ip}"
    printf "  ║  📅  %-47s║\n" "$(date '+%d.%m.%Y %H:%M:%S')  ·  $(uptime -p)"
    echo   "  ╚════════════════════════════════════════════════════╝"
    echo -e "${N}"
}

div()     { echo -e "${DIM}  ────────────────────────────────────────────────────${N}"; }
section() { echo; echo -e "  ${BOLD}${B}$*${N}"; div; }

press_back() {
    echo; div
    echo -e "  ${DIM}Нажмите ${N}${BOLD}Enter${N}${DIM} для возврата в меню...${N}"
    read -r
}

# ── 0. Информация о системе ─────────────────────────────────────────────────
show_sysinfo() {
    print_header
    section "▶  ИНФОРМАЦИЯ О СИСТЕМЕ"

    # ОС
    OS_NAME=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    OS_KERNEL=$(uname -r)
    OS_ARCH=$(uname -m)
    echo -e "  ОС:           ${C}${OS_NAME}${N}"
    echo -e "  Ядро:         ${C}${OS_KERNEL}  (${OS_ARCH})${N}"
    UPTIME_S=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
    [[ -n "$UPTIME_S" ]] &&         printf "  Uptime:       ${C}%dd %02dh %02dm${N}
"             $((UPTIME_S/86400)) $(((UPTIME_S%86400)/3600)) $(((UPTIME_S%3600)/60))

    section "Процессор"
    CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null         | cut -d: -f2 | sed 's/^ //')
    CPU_CORES=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo)
    CPU_FREQ_CUR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
    CPU_FREQ_MAX=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null)
    echo -e "  Модель:       ${C}${CPU_MODEL:-неизвестно}${N}"
    echo -e "  Ядер:         ${C}${CPU_CORES}${N}"
    if [[ -n "$CPU_FREQ_CUR" ]]; then
        printf "  Частота:      ${C}%.1f ГГц (макс: %.1f ГГц)${N}
"             "$(echo "scale=2; $CPU_FREQ_CUR / 1000000" | bc)"             "$(echo "scale=2; $CPU_FREQ_MAX / 1000000" | bc)"
    else
        CPU_FREQ_INFO=$(grep -m1 "cpu MHz" /proc/cpuinfo 2>/dev/null             | cut -d: -f2 | sed 's/^ //' | awk '{printf "%.1f ГГц", $1/1000}')
        echo -e "  Частота:      ${C}${CPU_FREQ_INFO:-недоступно}${N}"
    fi

    section "Память"
    MEM_TOTAL=$(awk '/MemTotal/  {printf "%.1f", $2/1024/1024}' /proc/meminfo)
    MEM_FREE=$( awk '/MemAvailable/{printf "%.1f", $2/1024/1024}' /proc/meminfo)
    MEM_USED=$( awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%.1f",(t-a)/1024/1024}' /proc/meminfo)
    SWAP_TOTAL=$(awk '/SwapTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)
    SWAP_FREE=$(awk '/SwapFree/  {printf "%.1f", $2/1024/1024}' /proc/meminfo)
    echo -e "  RAM:          ${C}${MEM_USED} ГБ использовано / ${MEM_TOTAL} ГБ всего (свободно: ${MEM_FREE} ГБ)${N}"
    echo -e "  Swap:         ${C}${SWAP_TOTAL} ГБ всего (свободно: ${SWAP_FREE} ГБ)${N}"

    section "Диск"
    df -h --output=target,size,used,avail,pcent 2>/dev/null         | grep -E "^(/|/var|/home|/boot)"         | awk '{printf "    %-15s %6s  исп: %6s  своб: %6s  (%s)
", $1,$2,$3,$4,$5}'         || df -h / | awk 'NR==2 {printf "    /  всего: %s  исп: %s  своб: %s
",$2,$3,$4}'

    section "Сеть"
    for iface in $(ip -o link show 2>/dev/null         | awk -F': ' '$2 !~ /lo|docker|veth|br-/{print $2}' | head -5); do
        IP_ADDR=$(ip -4 addr show "$iface" 2>/dev/null             | grep -oP '(?<=inet )\S+' | head -1)
        RX=$(cat "/sys/class/net/${iface}/statistics/rx_bytes" 2>/dev/null             | awk '{printf "%.1f МБ", $1/1024/1024}')
        TX=$(cat "/sys/class/net/${iface}/statistics/tx_bytes" 2>/dev/null             | awk '{printf "%.1f МБ", $1/1024/1024}')
        echo -e "    ${C}${iface}${N}  ${IP_ADDR:-нет IP}  ↓${RX}  ↑${TX}"
    done

    press_back
}

# ── 1. Nginx ────────────────────────────────────────────────────────────────
show_nginx() {
    print_header
    section "▶  NGINX"

    systemctl is-active --quiet nginx \
        && echo -e "  Служба:   ${G}● активна${N}" \
        || echo -e "  Служба:   ${R}✖ остановлена${N}"
    echo -e "  Версия:   ${C}$(nginx -v 2>&1 | grep -oP 'nginx/\K[\d.]+')${N}"

    NGINX_PID=$(systemctl show nginx --property=MainPID --value 2>/dev/null)
    if [[ -n "$NGINX_PID" && "$NGINX_PID" != "0" ]]; then
        UP=$(ps -o etimes= -p "$NGINX_PID" 2>/dev/null | tr -d ' ')
        [[ -n "$UP" ]] && printf "  Uptime:   ${C}%dd %02dh %02dm${N}\n" \
            $((UP/86400)) $(((UP%86400)/3600)) $(((UP%3600)/60))
    fi

    CONF=$(nginx -t 2>&1)
    echo "$CONF" | grep -q "successful" \
        && echo -e "  Конфиг:   ${G}✔ синтаксис OK${N}" \
        || echo -e "  Конфиг:   ${R}✖ ошибка синтаксиса${N}"

    section "Виртуальные хосты"
    for f in /etc/nginx/sites-enabled/*; do
        [[ -f "$f" ]] || continue
        SN=$(grep -m1 "server_name" "$f" 2>/dev/null | awk '{print $2}' | tr -d ';')
        SSL=$(grep -q "ssl_certificate" "$f" 2>/dev/null \
            && echo -e "${G}🔒 HTTPS${N}" || echo -e "${Y}HTTP${N}")
        echo -e "    ${C}$(basename "$f")${N}  →  ${SN:-?}  ${SSL}"
    done

    section "Топ-10 IP (access.log)"
    awk '{print $1}' /var/log/nginx/access.log 2>/dev/null \
        | sort | uniq -c | sort -rn | head -10 \
        | awk '{printf "    %6s  %s\n",$1,$2}' \
        || echo -e "    ${DIM}Нет данных${N}"

    section "Последние 10 ошибок (error.log)"
    tail -10 /var/log/nginx/error.log 2>/dev/null \
        | sed 's/^/    /' || echo -e "    ${DIM}Лог пуст${N}"

    press_back
}

# ── 2. CrowdSec ──────────────────────────────────────────────────────────────
show_crowdsec() {
    print_header
    section "▶  CROWDSEC — decisions list"

    CSCLI=$(get_cscli)
    if [[ -z "$CSCLI" ]]; then
        echo -e "  ${R}CrowdSec не обнаружен или не запущен.${N}"; press_back; return
    fi

    if [[ "$CSCLI" == "cscli" ]]; then
        echo -e "  Режим:   ${C}нативный${N}  ${G}● активен${N}"
    else
        echo -e "  Режим:   ${C}Docker${N}  ${G}● активен${N}"
    fi

    CS_VER=$($CSCLI version 2>/dev/null | grep -oP 'version:\s*\K\S+' | head -1)
    [[ -n "$CS_VER" ]] && echo -e "  Версия:  ${C}${CS_VER}${N}"

    section "Активные блокировки (cscli decisions list)"
    DECISIONS=$($CSCLI decisions list 2>/dev/null)
    if echo "$DECISIONS" | grep -qiE "no active|empty"; then
        echo -e "    ${G}✔ Нет активных блокировок${N}"
    else
        echo "$DECISIONS" | sed 's/^/    /'
    fi

    section "Последние 10 тревог (alerts)"
    $CSCLI alerts list --limit 10 2>/dev/null \
        | sed 's/^/    /' || echo -e "    ${DIM}Нет данных${N}"

    section "Статистика парсеров"
    $CSCLI metrics 2>/dev/null \
        | awk '/Acquisition Metrics/{p=1}p' | head -20 \
        | sed 's/^/    /' || echo -e "    ${DIM}Нет данных${N}"

    section "Bouncers"
    $CSCLI bouncers list 2>/dev/null \
        | sed 's/^/    /' || echo -e "    ${DIM}Нет данных${N}"

    press_back
}

# ── 3. CyberOK/Skipa блок ───────────────────────────────────────────────────
show_skipa() {
    print_header
    section "▶  CYBEROK / SKIPA IP БЛОК"

    if nft list table ip skipa_block &>/dev/null; then
        echo -e "  nftables:  ${G}● таблица активна${N}"
        COUNT=$(nft list set ip skipa_block blocklist 2>/dev/null \
            | grep -oP '(?<=elements = \{)[^}]+' | tr ',' '\n' | grep -c '\.' 2>/dev/null || echo 0)
        echo -e "  Записей:   ${C}${COUNT}${N}"
    else
        echo -e "  nftables:  ${R}✖ таблица не найдена${N}"
    fi

    if [[ -f /etc/skipa_block/skipa_cidr.txt ]]; then
        FILE_COUNT=$(wc -l < /etc/skipa_block/skipa_cidr.txt)
        echo -e "  Файл:      ${C}/etc/skipa_block/skipa_cidr.txt (${FILE_COUNT} строк)${N}"
        MOD=$(stat -c '%y' /etc/skipa_block/skipa_cidr.txt 2>/dev/null | cut -c1-16)
        echo -e "  Обновлён:  ${C}${MOD}${N}"
    fi

    CRON=$(crontab -l 2>/dev/null | grep skipa_update || echo "")
    [[ -n "$CRON" ]] \
        && echo -e "  Cron:      ${G}✔ автообновление включено${N}" \
        || echo -e "  Cron:      ${Y}⚠ автообновление не найдено в cron${N}"

    section "Последний лог обновления"
    tail -10 /var/log/skipa_update.log 2>/dev/null \
        | sed 's/^/    /' || echo -e "    ${DIM}Лог пуст${N}"

    section "Управление"
    echo -e "    ${C}skipa_update${N}                           — обновить список сейчас"
    echo -e "    ${C}nft list set ip skipa_block blocklist${N}  — все заблокированные IP"

    press_back
}

# ── 4. Открытые порты ───────────────────────────────────────────────────────
show_ports() {
    print_header
    section "▶  ОТКРЫТЫЕ ПОРТЫ"

    printf "    ${BOLD}%-8s %-28s %s${N}\n" "Протокол" "Адрес:Порт" "Процесс"
    div
    ss -tulnp 2>/dev/null | awk 'NR>1 {
        gsub(/users:\(\(/,"",$NF); gsub(/\)\)/,"",$NF)
        printf "    %-8s %-28s %s\n", $1, $5, $NF
    }' | sort -k2

    section "Правила UFW"
    if command -v ufw &>/dev/null; then
        UFW_S=$(ufw status 2>/dev/null)
        echo "$UFW_S" | grep -q "active" \
            && echo -e "  UFW:  ${G}● активен${N}" \
            || echo -e "  UFW:  ${Y}⚠ неактивен${N}"
        echo "$UFW_S" | grep -v "^Status" | grep -v "^$" | sed 's/^/    /'
    fi

    section "Docker — проброшенные порты"
    docker ps --format "table {{.Names}}\t{{.Ports}}" 2>/dev/null \
        | sed 's/^/    /' || echo -e "    ${DIM}Docker не доступен${N}"

    press_back
}

# ── 5. BBR ──────────────────────────────────────────────────────────────────
show_bbr() {
    print_header
    section "▶  TCP BBR"

    CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    QD=$(sysctl -n net.core.default_qdisc          2>/dev/null || echo "?")

    [[ "$CC" == "bbr" ]] \
        && echo -e "  Алгоритм:    ${G}✔ BBR активен${N}" \
        || echo -e "  Алгоритм:    ${R}✖ не активен (${CC})${N}"
    echo -e "  Планировщик: ${C}${QD}${N}"

    section "Доступные алгоритмы"
    sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null \
        | sed 's/^/    /' || echo -e "    ${DIM}Нет данных${N}"

    section "Конфигурационный файл"
    if [[ -f /etc/sysctl.d/99-bbr.conf ]]; then
        echo -e "  ${G}✔ /etc/sysctl.d/99-bbr.conf${N}"
        cat /etc/sysctl.d/99-bbr.conf | sed 's/^/    /'
    elif grep -q "bbr" /etc/sysctl.conf 2>/dev/null; then
        echo -e "  ${G}✔ настройки в /etc/sysctl.conf${N}"
        grep "bbr\|fq" /etc/sysctl.conf | sed 's/^/    /'
    else
        echo -e "    ${Y}Конфигурационный файл BBR не найден${N}"
    fi

    if [[ "$CC" != "bbr" ]]; then
        section "Включить BBR"
        echo -e "    ${Y}wget -qO- https://raw.githubusercontent.com/VadimBoev/bbr/main/enable_bbr.sh | bash${N}"
    fi

    press_back
}

# ── Главное меню ────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        print_header

        NGX=$(systemctl is-active nginx 2>/dev/null || echo "off")
        CS_N=$(systemctl is-active crowdsec 2>/dev/null || echo "off")
        CS_D=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^crowdsec$" || echo 0)
        NFT=$(nft list table ip skipa_block &>/dev/null && echo "on" || echo "off")
        BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "off")

        iN=$( [[ "$NGX"  == "active" ]]  && echo "${G}●${N}" || echo "${R}●${N}")
        iC=$( ( [[ "$CS_N" == "active" ]] || [[ "$CS_D" -gt 0 ]] ) \
              && echo "${G}●${N}" || echo "${R}●${N}")
        iS=$( [[ "$NFT"  == "on"     ]]  && echo "${G}●${N}" || echo "${R}●${N}")
        iB=$( [[ "$BBR"  == "bbr"    ]]  && echo "${G}●${N}" || echo "${Y}●${N}")

        echo -e "  ${BOLD}1${N}  ${G}●${N}  Информация о системе"
        echo -e "  ${BOLD}2${N}  ${iN}  Состояние Nginx"
        echo -e "  ${BOLD}3${N}  ${iC}  Блокировки CrowdSec (decisions list)"
        echo -e "  ${BOLD}4${N}  ${iS}  Статус CyberOK/Skipa IP-блока"
        echo -e "  ${BOLD}5${N}  ${G}●${N}  Открытые порты"
        echo -e "  ${BOLD}6${N}  ${iB}  Проверка BBR"
        echo
        div
        echo -e "  ${BOLD}0${N}  ${DIM}Выйти${N}"
        echo
        read -r -p "$(echo -e "  ${C}→ ${N}")" CH

        case "$CH" in
            1) show_sysinfo  ;;
            2) show_nginx    ;;
            3) show_crowdsec ;;
            4) show_skipa    ;;
            5) show_ports    ;;
            6) show_bbr      ;;
            0|q|Q) echo -e "\n  ${DIM}До свидания.${N}\n"; exit 0 ;;
            *) echo -e "  ${R}Введите цифру от 0 до 6.${N}"; sleep 1 ;;
        esac
    done
}

main_menu
MENUEOF

    chmod +x /usr/local/bin/myserverinfo

    # Алиас для удобства
    ln -sf /usr/local/bin/skipa_update /usr/local/bin/skipa_update 2>/dev/null || true

    log_ok "Команда myserverinfo установлена. Введите: myserverinfo"
}

# ═════════════════════════════════════════════════════════════════════════════
#  ИТОГОВЫЙ ОТЧЁТ
# ═════════════════════════════════════════════════════════════════════════════
print_summary() {
    echo
    echo -e "${BOLD}${G}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                   УСТАНОВКА ЗАВЕРШЕНА                    ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${N}"

    NGX_V=$(nginx -v 2>&1 | grep -oP 'nginx/\K[\d.]+' || echo "—")
    BBR_V=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "—")
    NFT_C=$(nft list set ip skipa_block blocklist 2>/dev/null \
        | grep -oP '(?<=elements = \{)[^}]+' | tr ',' '\n' | grep -c '\.' 2>/dev/null || echo 0)

    echo -e "  Nginx:             $(${NGINX_INSTALLED:-false} \
        && echo "${G}✔ v${NGX_V}${N}" || echo "${Y}— пропущен${N}")"
    echo -e "  Сайт:              $([[ -n "${DOMAIN:-}" ]] \
        && echo "${G}✔ ${DOMAIN}${N}"   || echo "${Y}— пропущен${N}")"
    echo -e "  SSL:               $(${SSL_INSTALLED:-false} \
        && echo "${G}✔ Let's Encrypt${N}" || echo "${Y}— пропущен${N}")"

    CS_OK=false
    systemctl is-active --quiet crowdsec 2>/dev/null && CS_OK=true
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^crowdsec$" && CS_OK=true
    echo -e "  CrowdSec:          $(${CS_OK} \
        && echo "${G}✔ активен${N}" || echo "${Y}— пропущен${N}")"

    echo -e "  Skipa IP-блок:     $([[ $NFT_C -gt 0 ]] \
        && echo "${G}✔ ${NFT_C} записей${N}" || echo "${Y}— пропущен / пусто${N}")"

    echo -e "  BBR:               $([[ "$BBR_V" == "bbr" ]] \
        && echo "${G}✔ активен${N}" || echo "${Y}— ${BBR_V}${N}")"

    echo
    echo -e "  ${BOLD}Команды:${N}"
    echo -e "    ${C}myserverinfo${N}     — статус всех компонентов"
    echo -e "    ${C}skipa_update${N}     — обновить список IP вручную"
    [[ -n "${DOMAIN:-}" ]] && \
    echo -e "    ${C}https://${DOMAIN}${N}  — ваш сайт"
    echo
    log_info "Лог: /var/log/vps_setup.log"
}

# ═════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═════════════════════════════════════════════════════════════════════════════
main() {
    exec > >(tee -a /var/log/vps_setup.log) 2>&1

    check_root
    banner

    echo -e "  ${BOLD}Для каждого шага:${N}"
    echo -e "    ${G}[y]${N} выполнить  ${Y}[s]${N} пропустить  ${R}[c]${N} отменить всё"
    echo

    # Глобальные флаги
    NGINX_INSTALLED=false
    SSL_INSTALLED=false
    DOMAIN=""
    LE_EMAIL=""

    system_update

    install_nginx
    setup_website
    install_ssl
    install_crowdsec
    install_skipa_block
    enable_bbr
    install_myserverinfo

    print_summary
}

main "$@"
