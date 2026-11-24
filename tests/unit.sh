#!/usr/bin/env bash
# Модульные тесты — те же, что в CI. Запуск: bash tests/unit.sh  (root не нужен)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/unit -v
bash tests/unit/test_common.sh
