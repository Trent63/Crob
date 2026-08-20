#!/bin/bash
set -euo pipefail

# ============================================
# Чтение ввода с терминала (для запуска через bash <(curl ...))
# ============================================
ask() { read -r "$@" </dev/tty; }

# ============================================
# Настройки (правьте при необходимости)
# ============================================
DEFAULT_TAG="2.8.0"                   # версия Remnanode по умолчанию
DEFAULT_NODE_PORT="3000"              # NODE_PORT по умолчанию
DEFAULT_SELFSTEAL_PORT="8443"         # порт selfsteal по умолчанию
DEFAULT_TEMPLATE="1"                  # шаблон маскировки (1-11)
TAGS_TO_SHOW=15                       # сколько версий показывать
WEB_SERVER="--nginx"                  # веб-сервер selfsteal: --nginx или --caddy

# XTLS_PORT нужен ТОЛЬКО для ноды <= 2.7.x (для 2.8.0+ игнорируется).
ASK_XTLS_PORT="false"                 # "true" — спрашивать XTLS_PORT
DEFAULT_XTLS_PORT="61000"             # XTLS_PORT по умолчанию (legacy)

# ============================================
# Функции вывода
# ============================================
log()  { echo -e "\n\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\n\033[1;33m[~] $*\033[0m"; }
err()  { echo -e "\n\033[1;31m[!] $*\033[0m" >&2; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Запустите скрипт от root (sudo)."
        exit 1
    fi
}

# ============================================
# Получение и выбор версии Remnanode
# ============================================
fetch_tags() {
    local tags
    tags=$(curl -s --max-time 10 \
        "https://hub.docker.com/v2/repositories/remnawave/node/tags?page_size=50" 2>/dev/null \
        | grep -oE '"name":"[^"]+"' \
        | sed 's/"name":"//; s/"//' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -Vr -u) || true
    [[ -z "$tags" ]] && return 1
    echo "$tags"
}

choose_version() {
    local tags_raw
    if ! tags_raw=$(fetch_tags); then
        err "Не удалось получить список версий."
        ask -p "Введите версию вручную [по умолчанию: $DEFAULT_TAG]: " manual
        REMNANODE_TAG="${manual:-$DEFAULT_TAG}"
        return
    fi

    local versions=()
    while IFS= read -r line; do
        versions+=("$line")
    done < <(echo "$tags_raw" | head -n "$TAGS_TO_SHOW")

    echo -e "\n\033[1;36mДоступные версии Remnanode (новые сверху):\033[0m"
    local i
    for i in "${!versions[@]}"; do
        if [[ $i -eq 0 ]]; then
            printf "  \033[1;32m%2d)\033[0m %s  \033[38;5;244m(последняя)\033[0m\n" "$((i+1))" "${versions[$i]}"
        else
            printf "  \033[1;33m%2d)\033[0m %s\n" "$((i+1))" "${versions[$i]}"
        fi
    done
    echo -e "  \033[1;35m 0)\033[0m Ввести версию вручную"

    local choice
    while true; do
        ask -p $'\nВыберите номер версии [по умолчанию: 1]: ' choice
        choice="${choice:-1}"
        if [[ "$choice" == "0" ]]; then
            ask -p "Введите версию: " REMNANODE_TAG
            [[ -n "${REMNANODE_TAG// }" ]] && break
            err "Пусто. Повторите."; continue
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#versions[@]} )); then
            REMNANODE_TAG="${versions[$((choice-1))]}"; break
        fi
        err "Неверный ввод. Введите номер от 1 до ${#versions[@]} (или 0)."
    done
}

# ============================================
# Выбор порта
# ============================================
choose_port() {
    local prompt="$1" default="$2" varname="$3" input
    while true; do
        ask -p "$prompt [по умолчанию: $default]: " input
        input="${input:-$default}"
        if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
            printf -v "$varname" '%s' "$input"
            break
        fi
        err "Порт должен быть числом от 1 до 65535."
    done
}

# ============================================
# Выбор шаблона
# ============================================
choose_template() {
    echo -e "\n\033[1;36mШаблоны маскировочной страницы (1-11):\033[0m"
    cat <<'TPL'
   1) Шаблон 1        7) Шаблон 7
   2) Шаблон 2        8) Шаблон 8
   3) Шаблон 3        9) Шаблон 9
   4) Шаблон 4       10) Шаблон 10
   5) Шаблон 5       11) Шаблон 11
   6) Шаблон 6
TPL
    local input
    while true; do
        ask -p "Выберите шаблон [по умолчанию: $DEFAULT_TEMPLATE]: " input
        input="${input:-$DEFAULT_TEMPLATE}"
        if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 11 )); then
            SELFSTEAL_TEMPLATE="$input"; break
        fi
        err "Введите номер шаблона от 1 до 11."
    done
}

# ============================================
# Ввод SECRET_KEY
# ============================================
input_secret_key() {
    echo -e "\n\033[1;36mSECRET_KEY из панели Remnawave\033[0m"
    echo -e "\033[38;5;244mСкопируйте значение SECRET_KEY (длинная строка eyJ... или base64).\033[0m"
    local RAW_KEY
    while true; do
        ask -p "Вставьте SECRET_KEY: " RAW_KEY
        SECRET_KEY="$(echo "$RAW_KEY" | sed -E 's/^[[:space:]]*SECRET_KEY[[:space:]]*=[[:space:]]*//; s/^["'\'']//; s/["'\'']$//')"
        if [[ -n "${SECRET_KEY// }" ]]; then
            break
        fi
        err "SECRET_KEY не может быть пустым."
    done
}

# ============================================
# Открытие портов в фаерволе
# ============================================
open_firewall_ports() {
    local ports=("$@")
    if command -v ufw >/dev/null 2>&1; then
        log "Открытие портов через ufw: ${ports[*]}"
        for p in "${ports[@]}"; do ufw allow "${p}/tcp" >/dev/null 2>&1 || true; done
        ufw reload >/dev/null 2>&1 || true
    elif command -v firewall-cmd >/dev/null 2>&1; then
        log "Открытие портов через firewalld: ${ports[*]}"
        for p in "${ports[@]}"; do firewall-cmd --add-port="${p}/tcp" --permanent >/dev/null 2>&1 || true; done
        firewall-cmd --reload >/dev/null 2>&1 || true
    elif command -v iptables >/dev/null 2>&1; then
        log "Открытие портов через iptables: ${ports[*]}"
        for p in "${ports[@]}"; do
            iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
        done
    else
        warn "Фаервол не найден. Порты не открыты автоматически."
    fi
}

# ============================================
# Ввод данных
# ============================================
require_root

if ! command -v curl >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y && apt-get install -y curl
fi

# --- Домен (РЕАЛЬНЫЙ, не example.com!) ---
echo -e "\n\033[1;36m📝 Ввод основных параметров\033[0m"
while true; do
    ask -p "Введите РЕАЛЬНЫЙ домен (НЕ example.com!): " CERT_DOMAIN
    if [[ "$CERT_DOMAIN" =~ ^example\. ]] || [[ "$CERT_DOMAIN" == "example.com" ]]; then
        err "example.com — это тестовый домен. Введите реальный домен, на который вы можете изменить DNS."
        continue
    fi
    [[ -n "${CERT_DOMAIN// }" ]] || { err "Домен не может быть пустым."; continue; }
    break
done

# --- Hostname из домена ---
HOSTNAME="$(echo "$CERT_DOMAIN" | cut -d. -f1 | tr '[:lower:]' '[:upper:]')"

# --- Версия Remnanode ---
choose_version

# --- SECRET_KEY ---
input_secret_key

# --- Порты ---
choose_port "Введите NODE_PORT" "$DEFAULT_NODE_PORT" NODE_PORT

XTLS_PORT=""
if [[ "$ASK_XTLS_PORT" == "true" ]]; then
    choose_port "Введите XTLS_PORT (legacy, для нод <=2.7.x)" "$DEFAULT_XTLS_PORT" XTLS_PORT
fi

choose_port "Введите порт selfsteal (HTTPS)" "$DEFAULT_SELFSTEAL_PORT" SELFSTEAL_PORT

# --- Шаблон ---
choose_template

# --- Проверка DNS ДО установки ---
log "Проверка DNS для $CERT_DOMAIN"
RESOLVED_IP="$(dig +short A "$CERT_DOMAIN" @1.1.1.1 2>/dev/null | head -1 || echo '')"
SERVER_IP="$(curl -s -4 --max-time 5 ifconfig.io 2>/dev/null || echo '')"

echo "Домен указывает на:   ${RESOLVED_IP:-❌ не разрешается}"
echo "IP этого сервера:     ${SERVER_IP:-❌ не определён}"

if [[ -z "$RESOLVED_IP" ]] || [[ -z "$SERVER_IP" ]]; then
    err "DNS не настроена! Let's Encrypt не сможет выдать сертификат."
    ask -p "Продолжить с self-signed сертификатом? (y/n): " CONTINUE
    [[ "${CONTINUE,,}" == "y" ]] || { err "Отменено."; exit 1; }
elif [[ "$RESOLVED_IP" != "$SERVER_IP" ]]; then
    err "DNS домена указывает на ДРУГОЙ IP! ($RESOLVED_IP вместо $SERVER_IP)"
    ask -p "Продолжить? (y/n): " CONTINUE
    [[ "${CONTINUE,,}" == "y" ]] || { err "Отменено."; exit 1; }
else
    log "✅ DNS правильно настроена!"
fi

# --- Подтверждение ---
echo ""
log "Домен:            $CERT_DOMAIN"
log "Hostname:         $HOSTNAME"
log "Версия Remnanode: $REMNANODE_TAG"
log "NODE_PORT:        $NODE_PORT"
[[ -n "$XTLS_PORT" ]] && log "XTLS_PORT:        $XTLS_PORT (legacy)"
log "SECRET_KEY:       ${SECRET_KEY:0:12}...(скрыто, ${#SECRET_KEY} символов)"
log "Порт selfsteal:   $SELFSTEAL_PORT"
log "Шаблон:           $SELFSTEAL_TEMPLATE"
ask -p "Всё верно? (y/n): " CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || { err "Отменено."; exit 1; }

# ============================================
# Выполнение
# ============================================
log "Обновление системы"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

log "Установка зависимостей"
apt-get install -y curl dnsutils

log "Установка hostname: $HOSTNAME"
hostnamectl set-hostname "$HOSTNAME"

# --- Открытие портов ---
FW_PORTS=(443 80 "$NODE_PORT" "$SELFSTEAL_PORT")
[[ -n "$XTLS_PORT" ]] && FW_PORTS+=("$XTLS_PORT")
open_firewall_ports "${FW_PORTS[@]}"

# ============================================
# Установка remnanode
# ============================================
log "Установка remnanode $REMNANODE_TAG"

REMNA_ARGS=(install --force
    --tag "$REMNANODE_TAG"
    --secret-key "$SECRET_KEY"
    --port "$NODE_PORT")
[[ -n "$XTLS_PORT" ]] && REMNA_ARGS+=(--xtls-port "$XTLS_PORT")

bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh) \
    "${REMNA_ARGS[@]}" || { err "Ошибка установки remnanode"; exit 1; }

# ============================================
# Установка selfsteal
# ============================================
log "Установка selfsteal (автоматическое получение Let's Encrypt сертификата)"

bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh) \
    $WEB_SERVER --force \
    --domain "$CERT_DOMAIN" \
    --port "$SELFSTEAL_PORT" \
    --template "$SELFSTEAL_TEMPLATE" \
    install || {
    err "⚠️  Ошибка установки selfsteal"
    echo "Диагностика:"
    echo "1. Проверьте DNS: dig $CERT_DOMAIN"
    echo "2. Проверьте порты 80/443: ss -tlnp | grep -E ':80|:443'"
    echo "3. Проверьте логи: docker logs nginx-selfsteal 2>&1 | tail -50"
    exit 1
}

log "Готово!"
echo -e "\033[1;32m════════════════════════════════════════════\033[0m"
echo -e "  ✅ Установка завершена!"
echo -e ""
echo -e "  Домен:          $CERT_DOMAIN"
echo -e "  Hostname:       $HOSTNAME"
echo -e "  Remnanode:      $REMNANODE_TAG (порт $NODE_PORT)"
[[ -n "$XTLS_PORT" ]] && echo -e "  XTLS_PORT:      $XTLS_PORT"
echo -e "  Selfsteal:      порт $SELFSTEAL_PORT (шаблон $SELFSTEAL_TEMPLATE)"
echo -e ""
echo -e "  🔗 Reality конфиг:"
echo -e "     serverNames: [\"$CERT_DOMAIN\"]"
echo -e "     target: /dev/shm/nginx.sock"
echo -e "     xver: 1"
echo -e ""
echo -e "  📊 Проверка статуса:"
echo -e "     docker ps | grep -E 'remna|nginx'"
echo -e "     selfsteal status"
echo -e "     docker logs remnanode"
echo -e "\033[1;32m════════════════════════════════════════════\033[0m"
