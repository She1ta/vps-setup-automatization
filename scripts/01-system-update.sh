#!/usr/bin/env bash
# Первый этап подготовки VPS: обновление установленных пакетов, поддерживаемого ядра
# и очистка зависимостей. Скрипт не меняет SSH, сетевые правила или APT-репозитории.
# Поддерживаемые семейства ОС: Debian и Ubuntu с пакетным менеджером APT.

# Останавливаем выполнение при ошибках, неопределённых переменных и ошибках конвейеров.
set -Eeuo pipefail

# По умолчанию ничего не перезагружаем и не разрешаем удаление пакетов в full-upgrade.
DRY_RUN=0
ALLOW_REMOVALS=0
ALLOW_KERNEL_AUTOREMOVE=0
SKIP_KERNEL=0
KERNEL_PACKAGE=""

# Печатаем справку, чтобы поведение опасных операций было явным.
usage() {
    cat <<'HELP'
Использование: sudo bash scripts/01-system-update.sh [опции]
  --dry-run                   Только симуляция APT (списки пакетов не обновляются).
  --allow-removals            Разрешить удаления, предлагаемые full-upgrade.
  --allow-kernel-autoremove   Разрешить autoremove устаревших пакетов ядра.
  --kernel-package ИМЯ       Явно указать официальный метапакет ядра.
  --skip-kernel               Не устанавливать метапакет ядра.
  --help                      Показать эту справку.

Скрипт не обновляет версию дистрибутива (например, Debian 12 -> 13),
не изменяет источники APT и не выполняет reboot автоматически.
HELP
}

# Обрабатываем только известные параметры, чтобы опечатка не запускала опасный сценарий.
while (($#)); do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --allow-removals) ALLOW_REMOVALS=1 ;;
        --allow-kernel-autoremove) ALLOW_KERNEL_AUTOREMOVE=1 ;;
        --skip-kernel) SKIP_KERNEL=1 ;;
        --kernel-package)
            [[ $# -ge 2 && -n "$2" ]] || { echo 'Не указано имя пакета.' >&2; exit 2; }
            KERNEL_PACKAGE="$2"
            shift
            ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Неизвестный параметр: $1" >&2; usage; exit 2 ;;
    esac
    shift
done

# Взаимоисключающие настройки предотвращают неоднозначное поведение.
if ((SKIP_KERNEL)) && [[ -n "$KERNEL_PACKAGE" ]]; then
    echo 'Нельзя сочетать --skip-kernel и --kernel-package.' >&2
    exit 2
fi

# Для реальной установки нужны полномочия root; dry-run оставляем доступным без них.
if (( ! DRY_RUN )) && (( EUID != 0 )); then
    echo 'Для обновления требуется root: запустите через sudo.' >&2
    exit 1
fi

# Не допускаем запуска на неизвестных системах или системах без APT.
[[ -r /etc/os-release ]] || { echo 'Нет /etc/os-release.' >&2; exit 1; }
# shellcheck source=/dev/null
source /etc/os-release
[[ "$ID" == debian || "$ID" == ubuntu ]] || {
    echo "Неподдерживаемый дистрибутив: ${ID:-неизвестно}" >&2
    exit 1
}
for command_name in apt-get apt-cache dpkg-query uname df; do
    command -v "$command_name" >/dev/null || {
        echo "Отсутствует обязательная команда: $command_name" >&2
        exit 1
    }
done

# Не запускаем второй экземпляр параллельно: дополнительно APT использует свои блокировки.
if command -v flock >/dev/null; then
    LOCK_FILE="${TMPDIR:-/tmp}/vps-setup-system-update-$(id -u).lock"
    exec 9>"$LOCK_FILE"
    flock -n 9 || { echo 'Обновление уже выполняется.' >&2; exit 1; }
fi

# Сохраняем полный журнал с безопасными правами; для dry-run используем временную папку.
umask 077
if (( DRY_RUN )); then
    LOG_DIR="${TMPDIR:-/tmp}/vps-setup-logs-$(id -u)"
else
    LOG_DIR='/var/log/vps-setup'
fi
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/system-update-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Ошибки должны приводить к ненулевому коду завершения, а не к ложному успеху.
trap 'printf "[ОШИБКА] Команда завершилась с кодом %s (строка %s). Журнал: %s\n" "$?" "$LINENO" "$LOG_FILE" >&2' ERR

# Используем стабильный для скриптов apt-get и сохраняем локальные конфигурационные файлы.
APT_OPTIONS=(
    -o 'DPkg::Lock::Timeout=300'
    -o 'Dpkg::Options::=--force-confdef'
    -o 'Dpkg::Options::=--force-confold'
)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=l

# При симуляции не изменяем состояние APT; "update" не имеет режима симуляции.
run_apt() {
    if ((DRY_RUN)); then
        case "$1" in
            update|clean|autoclean)
                printf '[DRY-RUN] Пропущена изменяющая операция: apt-get %s\n' "$1"
                ;;
            *)
                apt-get -s "${APT_OPTIONS[@]}" "$@"
                ;;
        esac
    else
        apt-get -y "${APT_OPTIONS[@]}" "$@"
    fi
}

# Проверяем, что метапакет предлагается настроенными репозиториями.
package_available() {
    local candidate
    candidate="$(apt-cache policy "$1" | awk '/^[[:space:]]*Candidate:/ { print $2; exit }')"
    [[ -n "$candidate" && "$candidate" != '(none)' ]]
}

# Выбираем ветку официального ядра; уже установленный метапакет имеет приоритет.
select_kernel_package() {
    local running_kernel arch candidate
    running_kernel="$(uname -r)"
    arch="$(dpkg --print-architecture)"

    # Пользовательский выбор имеет приоритет, но допускаются только имена пакетов.
    if [[ -n "$KERNEL_PACKAGE" ]]; then
        [[ "$KERNEL_PACKAGE" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || {
            echo 'Некорректное имя пакета ядра.' >&2; return 1;
        }
        printf '%s\n' "$KERNEL_PACKAGE"
        return
    fi

    # Debian использует имена linux-image-amd64 / linux-image-cloud-amd64 и аналоги.
    if [[ "$ID" == debian ]]; then
        case "$arch" in
            amd64|arm64) ;;
            *) echo "Для Debian/$arch укажите --kernel-package или --skip-kernel." >&2; return 1 ;;
        esac
        if [[ "$running_kernel" == *-cloud-"$arch" ]]; then
            candidate="linux-image-cloud-$arch"
        elif [[ "$running_kernel" == *-rt-"$arch" ]]; then
            candidate="linux-image-rt-$arch"
        elif [[ "$running_kernel" == *-"$arch" ]]; then
            candidate="linux-image-$arch"
        else
            echo "Неизвестная разновидность ядра Debian: $running_kernel" >&2
            echo 'Укажите --kernel-package или --skip-kernel.' >&2
            return 1
        fi
        printf '%s\n' "$candidate"
        return
    fi

    # На Ubuntu нельзя заменять linux-aws/linux-azure/HWE на generic наугад.
    # Ищем установленные метапакеты, включая HWE-варианты, прежде чем выбирать по uname.
    local installed package
    installed="$(dpkg-query -W -f='${binary:Package} ${db:Status-Abbrev}\n' 'linux-*' 2>/dev/null || true)"
    while read -r package status rest; do
        if [[ "$status" == ii && "$package" =~ ^linux-(generic|virtual|aws|azure|gcp|oracle|kvm)(-hwe-[0-9.]+)?$ ]]; then
            printf '%s\n' "$package"
            return
        fi
    done <<< "$installed"

    # При отсутствии метапакета используем только явно распознанный тип ядра.
    case "$running_kernel" in
        *-aws) candidate='linux-aws' ;;
        *-azure) candidate='linux-azure' ;;
        *-gcp) candidate='linux-gcp' ;;
        *-oracle) candidate='linux-oracle' ;;
        *-kvm) candidate='linux-kvm' ;;
        *-virtual) candidate='linux-virtual' ;;
        *-generic) candidate='linux-generic' ;;
        *) echo "Неизвестная разновидность ядра Ubuntu: $running_kernel" >&2; return 1 ;;
    esac
    printf '%s\n' "$candidate"
}

# Выполняем предварительный просмотр удалений при полном разрешении зависимостей.
guarded_full_upgrade() {
    local plan
    plan="$(apt-get -s "${APT_OPTIONS[@]}" full-upgrade)"
    printf '%s\n' "$plan"
    if grep -q '^Remv ' <<< "$plan" && (( ! ALLOW_REMOVALS )); then
        echo '[СТОП] full-upgrade предлагает удалить пакеты.' >&2
        echo 'Изучите строки Remv и повторите с --allow-removals, если удаления допустимы.' >&2
        return 1
    fi
    run_apt full-upgrade
}

# Не удаляем потенциально нужное ядро и ключевые системные службы без особого разрешения.
guarded_autoremove() {
    local plan
    plan="$(apt-get -s "${APT_OPTIONS[@]}" autoremove --purge)"
    printf '%s\n' "$plan"
    if grep -Eq '^Remv (openssh-server|sudo|systemd|grub-|initramfs-tools|ufw|docker)' <<< "$plan"; then
        echo '[СТОП] autoremove предлагает удалить критический пакет. Очистка пропущена.' >&2
        return 0
    fi
    if grep -Eq '^Remv (linux-image-|linux-modules-|linux-headers-)' <<< "$plan" &&
       (( ! ALLOW_KERNEL_AUTOREMOVE )); then
        echo '[ПРЕДУПРЕЖДЕНИЕ] Обнаружены кандидаты на удаление старых ядер.'
        echo 'Очистка пропущена. После контрольной перезагрузки используйте --allow-kernel-autoremove.'
        return 0
    fi
    run_apt autoremove --purge
}

# Печатаем контекст; эта информация нужна для анализа логов и диагностики загрузки.
printf '=== Системное обновление VPS ===\n'
printf 'ОС: %s | архитектура: %s | текущее ядро: %s\n' \
    "${PRETTY_NAME:-$ID}" "$(dpkg --print-architecture)" "$(uname -r)"
printf 'Режим симуляции: %s\nЖурнал: %s\n' "$DRY_RUN" "$LOG_FILE"

# Сообщаем об оставшихся после прошлых операций ошибках dpkg вместо их сокрытия.
if [[ -n "$(dpkg --audit)" ]]; then
    dpkg --audit
    echo 'Исправьте незавершённые операции dpkg до обновления.' >&2
    exit 1
fi

# Показываем свободное пространство, поскольку ядра и initramfs используют /boot.
df -h / /boot 2>/dev/null || df -h /

# В dry-run списки пакетов уже должны быть свежими; реальный запуск обновляет индексы.
echo '=== Этап 1: обновление индексов и установленных пакетов ==='
if (( DRY_RUN )); then
    echo '[DRY-RUN] Используются имеющиеся локальные индексы APT.'
else
    apt-get -o 'APT::Update::Error-Mode=any' update
fi
run_apt upgrade

# Ядро контейнеров LXC/OpenVZ/Docker контролирует хост; не пытаемся его заменить.
echo '=== Этап 2: выбор и обновление ядра ==='
if (( SKIP_KERNEL )); then
    echo 'Установка метапакета ядра пропущена по запросу.'
elif command -v systemd-detect-virt >/dev/null &&
     systemd-detect-virt --quiet --container; then
    if [[ -n "$KERNEL_PACKAGE" ]]; then
        echo 'В контейнере нельзя выбрать ядро хоста через --kernel-package.' >&2
        exit 1
    fi
    echo 'Контейнерная виртуализация: ядро управляется хостом. Этап пропущен.'
else
    SELECTED_KERNEL_PACKAGE="$(select_kernel_package)" || exit 1
    if ! package_available "$SELECTED_KERNEL_PACKAGE"; then
        echo "Нет доступного кандидата для $SELECTED_KERNEL_PACKAGE. Проверьте репозитории APT." >&2
        exit 1
    fi
    printf 'Выбран официальный метапакет ядра: %s\n' "$SELECTED_KERNEL_PACKAGE"
    run_apt install "$SELECTED_KERNEL_PACKAGE"
fi

# Повторяем обновление, учитывая новые зависимости и изменённые пакеты ядра.
echo '=== Этап 3: повторная синхронизация и полный upgrade ==='
run_apt update
guarded_full_upgrade

# Удаляем только зависимости, считающиеся неиспользуемыми по данным APT.
echo '=== Этап 4: очистка устаревших зависимостей и кэша ==='
guarded_autoremove
run_apt autoclean

# Показываем удерживаемые пакеты и непогашенные обновления после обработки.
echo '=== Контрольный отчёт ==='
printf 'Ядро, запущенное сейчас: %s\n' "$(uname -r)"
echo 'Закреплённые (held) пакеты:'
apt-mark showhold || true
echo 'Оставшиеся обновления (симуляция):'
apt-get -s "${APT_OPTIONS[@]}" full-upgrade | grep -E '^(Inst |Remv |[0-9]+ upgraded,)' || true
if command -v dkms >/dev/null; then
    echo 'Состояние сторонних модулей DKMS (проверьте перед перезагрузкой):'
    dkms status || true
fi
if [[ -f /run/reboot-required ]]; then
    echo 'Необходима перезагрузка по индикатору /run/reboot-required.'
else
    echo 'После обновления ядра перезагрузка может потребоваться даже без reboot-required.'
fi
if (( DRY_RUN )); then
    echo 'Симуляция не меняла систему; планы следующих этапов являются приблизительными.'
fi
echo "Готово. Журнал: $LOG_FILE"
