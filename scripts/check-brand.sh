#!/usr/bin/env bash
# Проверяет, что в отслеживаемых файлах не осталось старого имени.
# Исключения: исторические спеки и планы в docs/superpowers.
# Выход 0 если чисто, 1 и список находок если нет.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# Регистр кириллицы git grep не сворачивает, поэтому заглавная буква указана явно.
hits=$(git grep -nIiE 'golosok|[Гг]олосо(к|ка|ку|ком|ке)([^а-яА-Я]|$)' -- . \
  ':!docs/superpowers/specs' ':!docs/superpowers/plans' ':!scripts/check-brand.sh' || true)

if [[ -n "$hits" ]]; then
  echo "Найдено старое имя:"
  echo "$hits"
  exit 1
fi
echo "Старого имени нет."
