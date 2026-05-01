#!/bin/bash

# =============================================================================
# Замер производительности до и после рефакторинга с помощью perf
# Использует: refactor_tool + clang++-20 + perf stat (-r 3) + умный парсинг
# =============================================================================

# === Настройки путей ===
ROOT_DIR="${PWD}"
TESTS_ROOT="$ROOT_DIR/tests"
TEST_DATA_DIR="$TESTS_ROOT/tests_data"
REPORT_DIR="$TESTS_ROOT/tests_report"
TMP_DIR="$TEST_DATA_DIR/tmp"

TOOL="./build/refactor_tool"
COMPILER="clang++-20"
CXX_FLAGS="-g -O2"

# Используем -r 3: три прогона для стабильности
PERF_CMD="perf stat -r 3 -d -d -d"  # Три уровня детализации

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

if [[ ! -x "$TOOL" ]]; then
    error "Инструмент рефакторинга не найден: $TOOL"
fi

if ! command -v "$COMPILER" &> /dev/null; then
    error "Компилятор $COMPILER не найден. Установите clang++-20."
fi

if ! command -v perf &> /dev/null; then
    error "Утилита 'perf' не найдена. Установите linux-tools-common или аналог."
fi

# Проверим, разрешён ли доступ к perf
if [[ $(cat /proc/sys/kernel/perf_event_paranoid) -gt 0 ]]; then
    warn "perf_event_paranoid = $(cat /proc/sys/kernel/perf_event_paranoid)"
    warn "Доступ к аппаратным счётчикам ограничен."
    warn "Рекомендуется: sudo sh -c 'echo -1 > /proc/sys/kernel/perf_event_paranoid'"
fi

# === Создание директорий ===
BEFORE_DIR="$TMP_DIR/perf/before"
AFTER_DIR="$TMP_DIR/perf/after"

info "Подготавливаем временные директории..."
rm -rf "$TMP_DIR/perf"
mkdir -p "$BEFORE_DIR" || error "Не удалось создать $BEFORE_DIR"
mkdir -p "$AFTER_DIR"  || error "Не удалось создать $AFTER_DIR"
success "Временные директории готовы."

# === Копируем тестовый файл ===
SOURCE="$TEST_DATA_DIR/perf_example.cpp"
BEFORE_SRC="$BEFORE_DIR/perf_example.cpp"
AFTER_SRC="$AFTER_DIR/perf_example.cpp"

if [[ ! -f "$SOURCE" ]]; then
    error "Тестовый файл не найден: $SOURCE"
fi

cp "$SOURCE" "$BEFORE_SRC" || error "Не удалось скопировать исходный файл (до)"
cp "$SOURCE" "$AFTER_SRC"  || error "Не удалось скопировать исходный файл (после)"
info "Файл для теста: perf_example.cpp"

# === Рефакторинг ===
info "Запускаем рефакторинг..."
if ! "$TOOL" "$AFTER_SRC"; then
    warn "Рефакторинг не удался — продолжаем с оригиналом."
fi

# === Компиляция ===
info "Компилируем версии с -O2 для корректного бенчмарка..."

"$COMPILER" $CXX_FLAGS "$BEFORE_SRC" -o "$BEFORE_DIR/perf_example" \
    2> "$BEFORE_DIR/compile.log"
[[ $? -ne 0 ]] && error "Сборка 'до' провалилась. См. лог: $BEFORE_DIR/compile.log"

"$COMPILER" $CXX_FLAGS "$AFTER_SRC" -o "$AFTER_DIR/perf_example" \
    2> "$AFTER_DIR/compile.log"
[[ $? -ne 0 ]] && error "Сборка 'после' провалилась. См. лог: $AFTER_DIR/compile.log"

success "Сборка завершена."

# === Запуск perf ===
info "Запускаем perf stat (3 прогона) для сравнения производительности..."

$PERF_CMD "$BEFORE_DIR/perf_example" 2> "$BEFORE_DIR/report.log" || true
$PERF_CMD "$AFTER_DIR/perf_example"  2> "$AFTER_DIR/report.log"  || true

# === Сохранение отчётов ===
mkdir -p "$REPORT_DIR" || error "Не удалось создать $REPORT_DIR"
cp "$BEFORE_DIR/report.log" "$REPORT_DIR/perf_report_before.log"
cp "$AFTER_DIR/report.log"  "$REPORT_DIR/perf_report_after.log"
success "Отчёты сохранены в: $REPORT_DIR/"

# === Умный парсинг метрик ===
get_perf_metric() {
    local file="$1"
    local metric="$2"
    # Извлекаем первое число из строки, содержащей метрику (без регулярных выражений в awk)
    grep -i "$metric" "$file" 2>/dev/null | head -1 | tr ',' ' ' | awk '{
        for(i=1; i<=NF; i++) {
            if ($i ~ /^[0-9]+[.]?[0-9]*$/) {
                print $i
                exit
            }
        }
    }' || echo "N/A"
}

# === Сбор метрик ===
CYCLES_BEFORE=$(get_perf_metric "$BEFORE_DIR/report.log" "cycles")
CYCLES_AFTER=$(get_perf_metric "$AFTER_DIR/report.log" "cycles")

INSTR_BEFORE=$(get_perf_metric "$BEFORE_DIR/report.log" "instructions")
INSTR_AFTER=$(get_perf_metric "$AFTER_DIR/report.log" "instructions")

# === Расчёт IPC (Instructions Per Cycle) ===
IPC_BEFORE="N/A"
IPC_AFTER="N/A"

if [[ "$CYCLES_BEFORE" != "N/A" && "$INSTR_BEFORE" != "N/A" && "$CYCLES_BEFORE" != "0" ]]; then
    IPC_BEFORE=$(awk "BEGIN {printf \"%.2f\", $INSTR_BEFORE / $CYCLES_BEFORE}")
fi

if [[ "$CYCLES_AFTER" != "N/A" && "$INSTR_AFTER" != "N/A" && "$CYCLES_AFTER" != "0" ]]; then
    IPC_AFTER=$(awk "BEGIN {printf \"%.2f\", $INSTR_AFTER / $CYCLES_AFTER}")
fi

# === Вывод отчёта ===
info "Краткий анализ результатов:"

echo
printf "  %-20s %-15s %-15s\n" "Метрика" "До" "После"
printf "  %-20s %-15s %-15s\n" "Циклы (cycles)" "$CYCLES_BEFORE" "$CYCLES_AFTER"
printf "  %-20s %-15s %-15s\n" "Инструкции" "$INSTR_BEFORE" "$INSTR_AFTER"
printf "  %-20s %-15s %-15s\n" "IPC (instr/cycle)" "$IPC_BEFORE" "$IPC_AFTER"
echo

# === Сравнение IPC ===
if [[ "$IPC_BEFORE" != "N/A" && "$IPC_AFTER" != "N/A" ]]; then
    if (( $(echo "$IPC_AFTER > $IPC_BEFORE" | bc -l 2>/dev/null || echo "0") )); then
        success "✅ IPC улучшился — возможное ускорение!"
    elif (( $(echo "$IPC_AFTER < $IPC_BEFORE" | bc -l 2>/dev/null || echo "0") )); then
        warn "📉 IPC снизился — производительность могла упасть."
    else
        info "➡️ IPC не изменился — производительность на том же уровне."
    fi
else
    warn "Не удалось рассчитать IPC. Проверьте, что perf собрал данные о cycles и instructions."
    info "Совет: убедитесь, что программа выполняется достаточно долго."
fi

success "✅ Замер производительности завершён."

