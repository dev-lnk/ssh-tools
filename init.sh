#!/bin/bash

#############################################
# Скрипт первоначальной настройки сервера Ubuntu 24
# Выполняется с локальной машины для настройки удаленного сервера
#############################################

set -e  # Остановка при ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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
required_vars=("USER" "INIT_PORT" "SERVER_IP" "INIT_PASS" "NEW_USER" "NEW_USER_PASS" "PUBLIC_KEY" "NEW_SSH_PORT" "NEW_ROOT_PASS")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        log_error "Переменная $var не установлена в .env файле!"
        exit 1
    fi
done

log_info "Конфигурация загружена успешно"
log_info "Сервер: $SERVER_IP"
log_info "Порт: $INIT_PORT"
log_info "Пользователь: $USER"
log_info "Новый пользователь: $NEW_USER"
log_info "Новый SSH порт: $NEW_SSH_PORT"

# Проверка доступности sshpass
if ! command -v sshpass &> /dev/null; then
    log_error "sshpass не установлен!"
    log_info "Установите его: sudo apt-get install sshpass"
    exit 1
fi

log_info "=========================================="
log_info "Начало настройки сервера"
log_info "=========================================="

# Создаем временный скрипт для выполнения на удаленном сервере
REMOTE_SCRIPT=$(cat <<'EOF'
#!/bin/bash

set -e

echo "[INFO] Обновление пакетов..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

echo "[INFO] Изменение пароля пользователя: $USER"
echo "$USER:$NEW_ROOT_PASS" | chpasswd
echo "[INFO] Пароль пользователя $USER успешно изменен"

echo "[INFO] Создание нового пользователя: $NEW_USER"
# Создаем пользователя если не существует
if id "$NEW_USER" &>/dev/null; then
    echo "[WARN] Пользователь $NEW_USER уже существует"
else
    useradd -m -s /bin/bash "$NEW_USER"
    echo "$NEW_USER:$NEW_USER_PASS" | chpasswd
    usermod -aG sudo "$NEW_USER"
    echo "[INFO] Пользователь $NEW_USER создан и добавлен в группу sudo"
fi

echo "[INFO] Настройка SSH ключей для пользователя: $USER"
# Настройка SSH для текущего пользователя (root)
mkdir -p /root/.ssh
chmod 700 /root/.ssh
echo "$PUBLIC_KEY" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

echo "[INFO] Настройка SSH ключей для нового пользователя: $NEW_USER"
# Настройка SSH для нового пользователя
mkdir -p /home/$NEW_USER/.ssh
chmod 700 /home/$NEW_USER/.ssh
echo "$PUBLIC_KEY" > /home/$NEW_USER/.ssh/authorized_keys
chmod 600 /home/$NEW_USER/.ssh/authorized_keys
chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/.ssh

echo "[INFO] Установка Fail2ban..."
apt-get install -y -qq fail2ban

echo "[INFO] Настройка Fail2ban..."
cat > /etc/fail2ban/jail.local <<'FAIL2BAN_EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
destemail = root@localhost
sendername = Fail2Ban
action = %(action_)s

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 5
FAIL2BAN_EOF

# Обновляем порт в конфигурации Fail2ban
sed -i "s/port = ssh/port = $NEW_SSH_PORT/" /etc/fail2ban/jail.local

echo "[INFO] Настройка SSH конфигурации..."
# Создаем backup оригинального файла
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Изменяем порт SSH
sed -i "s/^#*Port .*/Port $NEW_SSH_PORT/" /etc/ssh/sshd_config
if ! grep -q "^Port $NEW_SSH_PORT" /etc/ssh/sshd_config; then
    echo "Port $NEW_SSH_PORT" >> /etc/ssh/sshd_config
fi

# Отключаем вход по паролю
sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*UsePAM .*/UsePAM no/' /etc/ssh/sshd_config

# Отключаем root login через SSH (опционально, можно закомментировать)
# sed -i 's/^#*PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config

echo "[INFO] Перезапуск служб..."
systemctl restart fail2ban
systemctl enable fail2ban

echo "[INFO] Перезапуск SSH службы..."
systemctl restart ssh

echo "[INFO] Настройка фаерволла UFW..."
# Установка UFW если не установлен
if ! command -v ufw &> /dev/null; then
    apt-get install -y -qq ufw
fi

# Сброс всех правил UFW
ufw --force reset

# Установка политик по умолчанию
ufw default deny incoming
ufw default allow outgoing

# Разрешаем необходимые порты
ufw allow $NEW_SSH_PORT/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

# Включаем UFW
ufw --force enable

echo "[INFO] Фаерволл настроен и включен"

echo "[SUCCESS] Настройка сервера завершена успешно!"
echo "[INFO] Новый SSH порт: $NEW_SSH_PORT"
echo "[INFO] Вход по паролю отключен, используйте SSH ключ"
echo "[INFO] Fail2ban настроен с максимум 5 попытками"
echo "[INFO] Фаерволл настроен: разрешены порты $NEW_SSH_PORT, 80, 443"
EOF
)

# Экспортируем переменные и выполняем скрипт на удаленном сервере
log_info "Подключение к серверу $SERVER_IP:$INIT_PORT..."
log_info "Выполнение настройки на удаленном сервере (это может занять несколько минут)..."

sshpass -p "$INIT_PASS" ssh -o StrictHostKeyChecking=no -p "$INIT_PORT" "$USER@$SERVER_IP" \
    "export USER='$USER'; \
     export NEW_ROOT_PASS='$NEW_ROOT_PASS'; \
     export NEW_USER='$NEW_USER'; \
     export NEW_USER_PASS='$NEW_USER_PASS'; \
     export PUBLIC_KEY='$PUBLIC_KEY'; \
     export NEW_SSH_PORT='$NEW_SSH_PORT'; \
     bash -s" <<< "$REMOTE_SCRIPT"

log_info "=========================================="
log_info "✓ Настройка сервера завершена успешно!"
log_info "=========================================="
log_info ""
log_info "Важная информация:"
log_info "- SSH порт изменен на: $NEW_SSH_PORT"
log_info "- Пароль пользователя $USER изменен на новый"
log_info "- Создан новый пользователь: $NEW_USER"
log_info "- Вход по паролю отключен (только SSH ключ)"
log_info "- Fail2ban установлен и настроен (макс. 5 попыток)"
log_info ""
log_info "Для подключения используйте:"
log_info "ssh -p $NEW_SSH_PORT $NEW_USER@$SERVER_IP"
log_info ""
log_warn "ВАЖНО: Убедитесь, что ваш SSH ключ работает перед закрытием текущей сессии!"

