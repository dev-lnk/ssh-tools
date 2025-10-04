#!/bin/bash

#############################################
# Скрипт установки Angie с модулем ACME
# Выполняется с локальной машины для настройки веб-сервера на удаленном сервере
#############################################

set -e  # Остановка при ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для вывода информационных сообщений
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

# Функция для вывода предупреждений
log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Функция для вывода ошибок
log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Функция для вывода успеха
log_success() {
    echo -e "${BLUE}[SUCCESS]${NC} $1"
}

# Проверка наличия .env файла
if [ ! -f .env ]; then
    log_error "Файл .env не найден!"
    log_info "Скопируйте .env.example в .env и заполните необходимые параметры:"
    log_info "cp .env.example .env"
    exit 1
fi

# Загрузка переменных из .env
log_info "Загрузка конфигурации из .env файла..."

# Удаляем Windows-style окончания строк (CRLF -> LF) если есть
sed -i 's/\r$//' .env 2>/dev/null || true

set -a  # Автоматический экспорт всех переменных
source .env
set +a  # Отключаем автоэкспорт

# Проверка обязательных переменных
required_vars=("SERVER_IP" "NEW_USER" "NEW_SSH_PORT" "NEW_USER_PASS" "URL" "ACME_EMAIL")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        log_error "Переменная $var не установлена в .env файле!"
        exit 1
    fi
done

log_info "Конфигурация загружена успешно"
log_info "Сервер: $SERVER_IP"
log_info "Порт: $NEW_SSH_PORT"
log_info "Пользователь: $NEW_USER"
log_info "Домен: $URL"
log_info "Email для ACME: $ACME_EMAIL"

log_info "=========================================="
log_info "Начало установки Angie с модулем ACME"
log_info "=========================================="

# Создаем удаленный скрипт для выполнения на сервере
REMOTE_SCRIPT=$(cat <<'EOF'
#!/bin/bash

set -e

# Функция для выполнения команд с sudo
run_sudo() {
    echo "$SUDO_PASS" | sudo -S "$@"
}

echo "[INFO] Обновление пакетов..."
export DEBIAN_FRONTEND=noninteractive
run_sudo apt-get update -qq

echo "[INFO] Установка необходимых зависимостей..."
run_sudo apt-get install -y -qq curl gnupg2 ca-certificates lsb-release ubuntu-keyring

echo "[INFO] Добавление ключа репозитория Angie..."
# Скачиваем открытый ключ репозитория Angie
run_sudo curl -o /etc/apt/trusted.gpg.d/angie-signing.gpg https://angie.software/keys/angie-signing.gpg

echo "[INFO] Добавление репозитория Angie..."
# Добавляем репозиторий Angie согласно официальной инструкции
run_sudo bash -c 'echo "deb https://download.angie.software/angie/$(. /etc/os-release && echo "$ID/$VERSION_ID $VERSION_CODENAME") main" > /etc/apt/sources.list.d/angie.list'

echo "[INFO] Обновление списка пакетов..."
run_sudo apt-get update

echo "[INFO] Установка Angie (с встроенным модулем ACME)..."
run_sudo apt-get install -y angie

echo "[INFO] Проверка статуса службы Angie после установки..."
run_sudo systemctl status angie --no-pager || true

echo "[INFO] Создание структуры директорий для сайта $URL..."
run_sudo mkdir -p /var/www/$URL
run_sudo mkdir -p /var/www/$URL/.well-known/acme-challenge

echo "[INFO] Создание тестового index.html..."
echo "\$SUDO_PASS" | sudo -S tee /var/www/$URL/index.html > /dev/null <<'HTML_EOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Hello World</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            margin: 0;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
        }
        .container {
            text-align: center;
            padding: 2rem;
            background: rgba(255, 255, 255, 0.1);
            border-radius: 10px;
            box-shadow: 0 8px 32px 0 rgba(31, 38, 135, 0.37);
        }
        h1 {
            font-size: 3rem;
            margin: 0;
        }
        p {
            font-size: 1.2rem;
            margin-top: 1rem;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Hello World</h1>
        <p>Сайт успешно работает!</p>
        <p>Powered by Angie</p>
    </div>
</body>
</html>
HTML_EOF

echo "[INFO] Настройка прав доступа для www-data..."
run_sudo chown -R www-data:www-data /var/www/$URL
run_sudo chmod -R 755 /var/www/$URL

echo "[INFO] Создание конфигурации Angie для $URL..."
echo "\$SUDO_PASS" | sudo -S tee /etc/angie/http.d/$URL.conf > /dev/null <<ANGIE_CONF_EOF
# HTTP сервер - для ACME challenge и основного контента
server {
    listen 80;
    server_name $URL;

    # ACME конфигурация для автоматического получения SSL сертификата
    acme letsencrypt;

    root /var/www/$URL;
    index index.html index.htm;

    # Путь для ACME challenge (для получения SSL сертификата)
    location /.well-known/acme-challenge/ {
        root /var/lib/angie/acme;
    }

    # Обслуживаем контент по HTTP
    location / {
        try_files \$uri \$uri/ =404;
    }

    # Логи
    access_log /var/log/angie/$URL-access.log;
    error_log /var/log/angie/$URL-error.log;
}

# HTTPS сервер
server {
    listen 443 ssl http2;
    server_name $URL;

    # SSL сертификаты (будут автоматически получены через ACME)
    # Используем переменные, предоставляемые модулем ACME
    ssl_certificate \$acme_cert_letsencrypt;
    ssl_certificate_key \$acme_cert_key_letsencrypt;

    root /var/www/$URL;
    index index.html index.htm;

    # Настройки SSL
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # Заголовки безопасности
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Обработка запросов
    location / {
        try_files \$uri \$uri/ =404;
    }

    # Логи
    access_log /var/log/angie/$URL-access.log;
    error_log /var/log/angie/$URL-error.log;
}
ANGIE_CONF_EOF

echo "[INFO] Настройка модуля ACME в основной конфигурации..."
# Удаляем старую неправильную конфигурацию ACME если она есть
run_sudo sed -i '/# ACME Client Configuration/d' /etc/angie/angie.conf
run_sudo sed -i '/acme_client.*acme-v02.api.letsencrypt.org/d' /etc/angie/angie.conf
run_sudo sed -i '/resolver/d' /etc/angie/angie.conf

# Добавляем правильную конфигурацию ACME client в http контексте
# Используем только IPv4 DNS resolver (ipv4=on ipv6=off)
if ! run_sudo grep -q "acme_client letsencrypt" /etc/angie/angie.conf; then
    run_sudo sed -i '/http {/a\    # ACME Client Configuration\n    resolver 8.8.8.8 ipv4=on ipv6=off;\n    acme_client letsencrypt https://acme-v02.api.letsencrypt.org/directory challenge=http;\n' /etc/angie/angie.conf
fi

echo "[INFO] Создание директории для ACME challenge..."
run_sudo mkdir -p /var/lib/angie/acme

echo "[INFO] Удаление старых файлов конфигурации если существуют..."
run_sudo rm -f /etc/angie/http.d/$URL-acme.conf

echo "[INFO] Проверка конфигурации Angie..."
if run_sudo angie -t; then
    echo "[INFO] Конфигурация Angie корректна"
else
    echo "[ERROR] Ошибка в конфигурации Angie!"
    exit 1
fi

echo "[INFO] Перезапуск Angie..."
run_sudo systemctl restart angie
run_sudo systemctl enable angie

echo "[INFO] Проверка статуса Angie..."
if run_sudo systemctl is-active --quiet angie; then
    echo "[SUCCESS] Angie успешно запущен"
else
    echo "[ERROR] Angie не запустился!"
    run_sudo systemctl status angie
    exit 1
fi

echo "[INFO] Ожидание 5 секунд для стабилизации сервиса..."
sleep 5

echo "[INFO] Инициализация получения SSL сертификата..."
echo "[INFO] Отправка HTTP запроса к $URL для инициализации ACME..."
# Отправляем запрос к домену, что инициирует процесс получения сертификата
curl -sI http://$URL/ > /dev/null 2>&1 || echo "[WARN] Не удалось подключиться к домену. Убедитесь что DNS настроен."

echo "[INFO] Ожидание получения сертификата (это может занять до 30 секунд)..."
sleep 10

# Проверяем логи на наличие информации о ACME
echo "[INFO] Проверка процесса получения сертификата..."
run_sudo tail -30 /var/log/angie/error.log | grep -i acme || echo "[INFO] Процесс ACME еще не начался или завершился"

# Проверяем доступность HTTPS
echo "[INFO] Проверка доступности HTTPS..."
if curl -sI --connect-timeout 5 https://$URL/ > /dev/null 2>&1; then
    echo "[SUCCESS] SSL сертификат успешно получен! HTTPS работает."
else
    echo "[WARN] HTTPS пока недоступен. Сертификат будет получен в фоновом режиме."
    echo "[INFO] Проверьте логи позже: sudo tail -f /var/log/angie/error.log"
fi

echo "[INFO] Настройка автоматического обновления сертификатов..."
# Создаем скрипт для обновления сертификатов
run_sudo bash -c "cat > /usr/local/bin/renew-ssl-certs.sh" << 'RENEW_SCRIPT_EOF'
#!/bin/bash
# Скрипт автоматического обновления SSL сертификатов

/usr/sbin/angie -s reload
systemctl reload angie

# Логирование
echo "$(date): SSL certificates renewed" >> /var/log/angie/ssl-renewal.log
RENEW_SCRIPT_EOF

run_sudo chmod +x /usr/local/bin/renew-ssl-certs.sh

# Добавляем задачу в cron для автоматического обновления (каждый день в 2:00)
(run_sudo crontab -l 2>/dev/null || true; echo "0 2 * * * /usr/local/bin/renew-ssl-certs.sh") | run_sudo crontab -

echo "[SUCCESS] Установка и настройка Angie завершена успешно!"
echo ""
echo "=========================================="
echo "Информация о конфигурации:"
echo "=========================================="
echo "Домен: $URL"
echo "Путь к сайту: /var/www/$URL"
echo "Конфигурация Angie: /etc/angie/http.d/$URL.conf"
echo "SSL сертификаты: управляются автоматически модулем ACME"
echo "Логи доступа: /var/log/angie/$URL-access.log"
echo "Логи ошибок: /var/log/angie/$URL-error.log"
echo "=========================================="
echo ""
echo "[INFO] Следующие шаги:"
echo "1. Проверьте работу сайта: http://$URL"
echo "2. Проверьте HTTPS (если сертификат получен): https://$URL"
echo "3. Если HTTPS не работает, проверьте логи: sudo tail -f /var/log/angie/error.log"
echo "4. Убедитесь что DNS записи для $URL указывают на $SERVER_IP"
echo "5. Автоматическое обновление сертификатов настроено (cron каждый день в 2:00)"
echo ""
echo "[ПРИМЕЧАНИЕ] Сейчас сайт работает по HTTP и HTTPS (если сертификат получен)"
echo "При необходимости можно настроить автоматический редирект с HTTP на HTTPS"
echo ""
EOF
)

# Подключаемся к серверу и выполняем удаленный скрипт
log_info "Подключение к серверу $SERVER_IP:$NEW_SSH_PORT..."
log_info "Выполнение установки на удаленном сервере (это может занять несколько минут)..."

# Используем SSH ключ для подключения (соединение уже настроено)
ssh -o StrictHostKeyChecking=no -p "$NEW_SSH_PORT" "$NEW_USER@$SERVER_IP" \
    "export URL='$URL'; \
     export ACME_EMAIL='$ACME_EMAIL'; \
     export SERVER_IP='$SERVER_IP'; \
     export SUDO_PASS='$NEW_USER_PASS'; \
     bash -s" <<< "$REMOTE_SCRIPT"

log_info "=========================================="
log_success "✓ Установка Angie завершена успешно!"
log_info "=========================================="
log_info ""
log_info "Информация о конфигурации:"
log_info "- Домен: $URL"
log_info "- Путь к сайту: /var/www/$URL"
log_info "- Конфигурация Angie: /etc/angie/http.d/$URL.conf"
log_info "- SSL сертификаты: управляются автоматически модулем ACME"
log_info "- Логи доступа: /var/log/angie/$URL-access.log"
log_info "- Логи ошибок: /var/log/angie/$URL-error.log"
log_info ""
log_warn "ВАЖНО - Следующие шаги:"
log_info "1. Проверьте работу сайта: http://$URL"
log_info "2. Проверьте HTTPS (если сертификат получен): https://$URL"
log_info "3. Если HTTPS не работает, проверьте логи на сервере:"
log_info "   ssh -p $NEW_SSH_PORT $NEW_USER@$SERVER_IP"
log_info "   sudo tail -f /var/log/angie/error.log"
log_info "4. Убедитесь что DNS записи для $URL указывают на IP: $SERVER_IP"
log_info "5. Автоматическое обновление сертификатов настроено (cron каждый день в 2:00)"
log_info ""
log_warn "ПРИМЕЧАНИЕ:"
log_info "Сайт работает по HTTP и HTTPS (если сертификат получен)."
log_info "При необходимости можно настроить автоматический редирект с HTTP на HTTPS."
log_info ""

