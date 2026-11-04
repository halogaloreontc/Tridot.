# corpus-gen — фразы для регрессионного корпуса

Инструмент разработки: языковые модели придумывают и размечают русские команды для
`test/corpus/`. В приложение он не входит; само приложение по-прежнему работает без
языковой модели (ADR-001). Формат корпуса — `docs/CORPUS.md`.

## Как это работает

```text
generate      несколько моделей придумывают фразы по теме → work/candidates.jsonl
import-manual фразы, вставленные из веб-чатов (Kimi, ChatGPT, Grok…)
      ↓       дубли корпуса и уже собранных фраз отбрасываются
label         две модели ДРУГИХ семейств независимо размечают каждую фразу
      ↓       согласны и уверены → agreed; иначе → disputed
review        вы решаете спорные: выбрать разметку, ввести свою, отклонить
      ↓
promote       принятые фразы прогоняются через текущий ScenarioParser
              (tool/parse_phrases.dart) и дописываются в test/corpus/generated.jsonl:
              парсер согласен → active, не согласен → known_gap (список работ)
```

Разметчик описывает, как фразу **должен** понять помощник, а не как её понимает
сегодняшний парсер. Поэтому `known_gap` — это найденные пробелы, а не ошибки разметки.
Спецификация разметки — `LABEL_SYSTEM` в `corpus_gen/prompts.py`; при изменении правил
парсера обновляйте её вместе с `docs/CORPUS.md`.

В модели уходят только синтетические фразы. Реальные задачи и `tasks.json` никуда не
отправляются.

## Установка на macOS

Нужен Python 3.11+ и Flutter SDK (для `dart` в шаге `promote`). Проще всего через
[uv](https://docs.astral.sh/uv/):

```bash
brew install uv
```

```bash
cd tools/corpus_gen
uv venv
uv pip install -e ".[dev]"
cp config.example.toml config.toml
```

Проверка без сети и ключей:

```bash
.venv/bin/pytest
```

## Ключи и источники

`config.toml` описывает источники; ключи передаются только через переменные окружения.
Источник без ключа или с моделью-заглушкой `<…>` пропускается:

```bash
.venv/bin/corpus-gen sources
```

Ключи удобно держать в файле вне репозитория, например `~/.config/corpus-gen.env`:

```bash
export ANTHROPIC_API_KEY=...
export MOONSHOT_API_KEY=...
export DEEPSEEK_API_KEY=...
```

```bash
source ~/.config/corpus-gen.env
```

### Ollama (локально, бесплатно)

На Mac с Apple Silicon модели работают в общей оперативной памяти: на 64 ГБ свободно
помещаются модели ~30B в 4-битной квантизации (~20 ГБ). Установка:

```bash
brew install ollama
```

```bash
ollama serve
```

В другом окне скачайте модель и впишите её имя в `model` источника `ollama`:

```bash
ollama pull <имя модели>
```

```bash
ollama list
```

## Типичный цикл

```bash
.venv/bin/corpus-gen generate --topic tricky --count 20
```

```bash
.venv/bin/corpus-gen label
```

```bash
.venv/bin/corpus-gen review
```

```bash
.venv/bin/corpus-gen promote
```

```bash
cd ../.. && flutter test test/scenario_corpus_test.dart
```

Темы: `create`, `reschedule`, `complete`, `list`, `unknown`, `tricky` (ловушки),
`gaps` (естественные формулировки, которых парсер может ещё не знать). `--count` — фраз от
каждого генератора; `--source` можно указать несколько раз.

Фразы из веб-чата: попросите модель в чате «придумай 30 фраз …», сохраните ответ в файл по
одной фразе на строку (номера и маркеры списка срезаются автоматически, кавычки — нет):

```bash
.venv/bin/corpus-gen import-manual phrases.txt --source kimi-web
```

Расход по источникам — по ценам из `config.toml`:

```bash
.venv/bin/corpus-gen stats
```

## Состояние

- `work/candidates.jsonl` — все фразы со статусами `new`, `agreed`, `disputed`, `error`,
  `accepted`, `rejected`, `promoted` и всеми разметками. Перезаписывается атомарно.
- `work/usage.jsonl` — токены и стоимость каждого запроса.
- `work/` и `config.toml` не попадают в git.

`label` можно запускать повторно: размечаются только новые фразы и недостающие разметки
после ошибок сети или лимитов.
