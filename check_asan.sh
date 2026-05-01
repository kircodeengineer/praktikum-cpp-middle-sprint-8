#!/bin/bash

# =============================================================================
# Проверка утечек памяти с AddressSanitizer до и после рефакторинга
# Использует: refactor_tool + clang++-20 + ASan + detect_leaks=1
# =============================================================================

# === Настройки путей ===
ROOT_DIR="${PWD}"
TESTS_ROOT="${ROOT_DIR}/tests"
TEST_DATA_DIR="${TESTS_ROOT}/tests_data"
REPORT_DIR="${TESTS_ROOT}/tests_report"
TMP_DIR="${TEST_DATA_DIR}/tmp"

REFACTOR_TOOL="./build/refactor_tool"
COMPILER="clang++-20"
CXX_FLAGS="-fsanitize=address -fno-omit-frame-pointer -g"

# === Переменные ASan ===
ASAN_OPTS="detect_leaks=1"  # КРИТИЧНО: без этого ASan НЕ ПОКАЗЫВАЕТ утечки!

# === Цвета ===
COLOR_INFO="\033[36m"
COLOR_SUCCESS="\033[32m"
COLOR_WARN="\033[33m"
COLOR_ERROR="\033[31m"
COLOR_RESET="\033[0m"

# === Функции ===
info() { echo -e "${COLOR_INFO}[INFO]${COLOR_RESET} $*"; }
success() { echo -e "${COLOR_SUCCESS}[OK]${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} $*" >&2; }
error() { echo -e "${COLOR_ERROR}[ERROR]${COLOR_RESET} $*" >&2; exit 1; }

# === Проверка окружения ===
info "Проверяем окружение..."

if [[ ! -x "$REFACTOR_TOOL" ]]; then
    error "Инструмент рефакторинга не найден или не исполняем: $REFACTOR_TOOL"
fi

if ! command -v "$COMPILER" &> /dev/null; then
    error "Компилятор $COMPILER не найден. Установите clang++-20."
fi

# === Создание структуры директорий ===
info "Подготавливаем структуру директорий..."

mkdir -p "$REPORT_DIR" || error "Не удалось создать $REPORT_DIR"
mkdir -p "$TMP_DIR/asan/before" || error "Не удалось создать $TMP_DIR/asan/before"
mkdir -p "$TMP_DIR/asan/after"  || error "Не удалось создать $TMP_DIR/asan/after"

# Очистка предыдущих результатов (сохраняем структуру)
rm -rf "$TMP_DIR/asan/before"/* "$TMP_DIR/asan/after"/* || error "Ошибка очистки временных данных"

success "Директории готовы."

# === Список тестов ===
TESTS=("leak_example")  # Можно добавить: "test1" "test2" "test3"

for TEST in "${TESTS[@]}"; do
    SOURCE_FILE="$TEST_DATA_DIR/${TEST}.cpp"

    if [[ ! -f "$SOURCE_FILE" ]]; then
        warn "Файл $SOURCE_FILE не найден — пропускаем."
        continue
    fi

    BEFORE_DIR="$TMP_DIR/asan/before/$TEST"
    AFTER_DIR="$TMP_DIR/asan/after/$TEST"

    mkdir -p "$BEFORE_DIR" || error "Не удалось создать $BEFORE_DIR"
    mkdir -p "$AFTER_DIR"  || error "Не удалось создать $AFTER_DIR"

    info "Обрабатываем тест: $TEST"

    # --- Копируем исходный файл ---
    cp "$SOURCE_FILE" "$BEFORE_DIR/${TEST}.cpp" || error "Ошибка копирования в BEFORE_DIR"
    cp "$SOURCE_FILE" "$AFTER_DIR/${TEST}.cpp"  || error "Ошибка копирования в AFTER_DIR"

    # --- Применяем рефакторинг ---
    info "Запускаем рефакторинг: $REFACTOR_TOOL $AFTER_DIR/${TEST}.cpp"
    if ! "$REFACTOR_TOOL" "$AFTER_DIR/${TEST}.cpp"; then
        warn "Рефакторинг $TEST не удался — продолжаем с оригиналом."
    fi

    # --- Компиляция до рефакторинга ---
    info "Компилируем исходную версию..."
    "$COMPILER" $CXX_FLAGS "$BEFORE_DIR/${TEST}.cpp" -o "$BEFORE_DIR/${TEST}" \
        2> "$BEFORE_DIR/compile.log"
    if [[ $? -ne 0 ]]; then
        warn "Сборка до рефакторинга провалилась. См. лог: $BEFORE_DIR/compile.log"
        cat "$BEFORE_DIR/compile.log"
        continue
    fi

    # --- Компиляция после рефакторинга ---
    info "Компилируем обработанную версию..."
    "$COMPILER" $CXX_FLAGS "$AFTER_DIR/${TEST}.cpp" -o "$AFTER_DIR/${TEST}" \
        2> "$AFTER_DIR/compile.log"
    if [[ $? -ne 0 ]]; then
        warn "Сборка после рефакторинга провалилась. См. лог: $AFTER_DIR/compile.log"
        cat "$AFTER_DIR/compile.log"
        continue
    fi

    # --- Запуск с AddressSanitizer (с детекцией утечек!) ---
    info "Запускаем программы с ASan (detect_leaks=1)..."

    ASAN_OPTIONS=$ASAN_OPTS "$BEFORE_DIR/${TEST}" 2> "$BEFORE_DIR/report.log" || true
    ASAN_OPTIONS=$ASAN_OPTS "$AFTER_DIR/${TEST}"  2> "$AFTER_DIR/report.log"  || true

    # --- Сохранение отчётов ---
    cp "$BEFORE_DIR/report.log" "$REPORT_DIR/asan_${TEST}_before.log"
    cp "$AFTER_DIR/report.log"  "$REPORT_DIR/asan_${TEST}_after.log"

    # --- Анализ результатов ---
    BEFORE_LOG="$REPORT_DIR/asan_${TEST}_before.log"
    AFTER_LOG="$REPORT_DIR/asan_${TEST}_after.log"

    if [[ -s "$BEFORE_LOG" ]]; then
        warn "ASan ОБНАРУЖИЛ УТЕЧКИ в исходной версии $TEST!"
        echo "--- Содержимое отчёта (до): ---"
        cat "$BEFORE_LOG"
        echo "-------------------------------"
    else
        success "ASan: утечек НЕТ в исходной версии $TEST"
    fi

    if [[ -s "$AFTER_LOG" ]]; then
        warn "ASan ОБНАРУЖИЛ УТЕЧКИ в обработанной версии $TEST!"
        echo "--- Содержимое отчёта (после): ---"
        cat "$AFTER_LOG"
        echo "----------------------------------"
    else
        success "ASan: утечек НЕТ в обработанной версии $TEST"
    fi
done

success "✅ Все тесты завершены."
info "Отчёты сохранены в: $REPORT_DIR/"
ls -1 "$REPORT_DIR" | grep "asan" | sed 's/^/  📄 /'

