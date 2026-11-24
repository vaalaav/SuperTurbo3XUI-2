#!/usr/bin/env bash
# Статические проверки — те же, что в CI. Запуск: bash tests/lint.sh
# Нужны: shellcheck, ruff; actionlint — если установлен (в CI ставится всегда).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mapfile -t shell_files < <(git ls-files '*.sh' cli/my3xui)
echo "shellcheck: ${#shell_files[@]} файлов"
shellcheck --severity=warning --external-sources "${shell_files[@]}"

echo "ruff"
ruff check lib tests
ruff format --check --diff tests

if command -v actionlint >/dev/null; then
    echo "actionlint"
    actionlint
else
    echo "actionlint не установлен — пропуск (в CI выполняется)"
fi
echo "lint: ok"
