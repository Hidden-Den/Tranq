# Протокол двери Tranq

Приложение слушает Unix-сокет `mcp.sock` в папке данных (`~/Library/Application Support/Tranq/mcp.sock`).
Построчный JSON, UTF-8: одна строка — один запрос, одна строка — один ответ. Имена полей в `snake_case`.
Swift и Go следуют этому файлу буквально.

```
запрос:  {"cmd": "<имя>", "args": {…}}
успех:   {"ok": true,  "data": <значение>, "language": "ru"}
отказ:   {"ok": false, "error": "<текст для человека>", "language": "ru"}
```

`language` — язык приложения, `ru` или `en`. Названия наборов и тексты `error` идут на нём.
Нечитаемая строка и неизвестная команда дают `ok: false` с понятным текстом, соединение остаётся открытым.
Любая команда сначала проходит проверку уровня доступа; отказ приходит как `ok: false` с текстом, который агент покажет человеку.

## Команды

| cmd | инструмент MCP | args | data |
|---|---|---|---|
| `packs` | `list_dictionary_packs` | нет | `[{"id","title","word_count","enabled"}]` |
| `words` | `list_user_words` | нет | `[{"spelling","variants":{"ru":[…],"en":[…]},"source":"manual\|learned\|mcp","hits","last_used"}]`, `last_used` — ISO 8601 или `null` |
| `set_pack` | `set_pack_enabled` | `{"id","enabled"}` | объект набора как в `packs` |
| `add_words` | `add_words` | `{"words":[{"spelling","variants":{"ru":[…],"en":[…]},"force_case"}]}` | `{"added":["…"],"skipped":{"<написание>":"<причина>"}}` |
| `remove_words` | `remove_words` | `{"spellings":["…"]}` | та же форма, что у `add_words` |
| `revert_agent_words` | `revert_agent_words` | нет | `{"removed_words":N,"removed_variants":M}` |
| `dictations` | `list_dictations` | `{"limit":20}` | `[{"date","spoken","text"}]`, `date` — строка как в истории |

Правила:

- `set_pack` с `enabled: false` — это выключение набора, оно требует полного доступа. Дверь выводит это из `enabled`, отдельного флага в запросе нет.
- `add_words` больше 50 слов отклоняется целиком. Пустой список — тоже.
- `dictations`: `limit` по умолчанию 20, больше 100 обрезается до 100, ноль и отрицательное дают 20. Заметки без сырой расшифровки пропускаются.
- Сокет принимает несколько соединений одновременно, ответ уходит только своему клиенту.
