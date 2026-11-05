# Коннекторы

Коннектор — подключаемый набор команд помощника. Встроенный коннектор `tasks` отвечает за задачи; следующие будут для внешних приложений: склад (halowarekeep), expeora, сторонние программы. Этот документ — точная инструкция, как написать коннектор, проверить его и подключить. Решение о коннекторах и правила безопасности — ADR-004 в `docs/DECISIONS.md`.

Языковой модели в приложении нет (ADR-001): коннектор распознаёт фразы правилами, на основе общего предварительного разбора `Utterance`.

## Как устроено

```text
сообщение
→ AssistantController: Utterance.analyze(текст) — один раз
→ если коннектор ждёт подтверждения и текст — «да»/«нет»: run этого коннектора
  с ConfirmationAnswer (см. «Подтверждение изменяющих действий»), конец
→ каждый коннектор: match(utterance) → ConnectorMatch? (без ввода-вывода)
→ «да, …»/«нет, …» с пояснением и без явных совпадений: тоже ответ владельцу
→ совпадения без маркера (implicit) отбрасываются, если есть явные
→ выбор самого уверенного совпадения (или уточнение, если спорно)
→ run(match, session) победителя (здесь можно ходить в сеть)
→ AssistantResponse → интерфейс
```

Код: `lib/core/connectors/`.

| Файл | Что в нём |
| --- | --- |
| `connector.dart` | `Connector`, `ConnectorInfo`, `ConnectorAccess`, `ConnectorMatch`, `AssistantSession`, `PendingConfirmation`, `ConfirmationAnswer`, `ConfirmationReply`; реэкспортирует `Utterance`, `AssistantResponse`, `AssistantStatus` |
| `utterance.dart` | `Utterance` — общий разбор сообщения: слова, кавычки, метки, срок, коды |
| `due_parser.dart` | `DueParser`, `DueParseResult`, `DueIssue`, `CharSpan` — сроки с фрагментами текста |
| `verb_forms.dart` | `VerbForms` — инфинитив и прошедшее время по окончаниям, основа глагола; общие правила для сроков, команд без маркера и поиска задач |
| `http_transport.dart` | `HttpTransport`, `HttpRequestData`, `HttpResponseData` — единственный путь в сеть |
| `secret_store.dart` | `SecretStore`, `InMemorySecretStore` — секреты не в открытых файлах |
| `tasks_connector.dart` | `TasksConnector` — встроенные задачи, образец реального коннектора |

Маршрутизатор — `lib/core/scenario/assistant_controller.dart` (`AssistantController`).

## Интерфейс

```dart
abstract interface class Connector {
  ConnectorInfo get info;
  ConnectorMatch? match(Utterance utterance);
  Future<AssistantResponse> run(ConnectorMatch match, AssistantSession session);
}
```

### `ConnectorInfo`

| Поле | Значение |
| --- | --- |
| `id` | постоянный id латиницей: `warehouse`. Уникален среди подключённых — повтор роняет конструктор `AssistantController`. Совпадает с полем `connector` в корпусе |
| `title` | имя для пользователя: «Склад». Попадает в уточнение «к чему относится команда» |
| `description` | одно предложение о возможностях |
| `examples` | фразы, которые коннектор обязан понимать; тест проверяет каждую |
| `requiresNetwork` | `true`, если `run` ходит в сеть |
| `access` | `readOnly` (по умолчанию) или `readWrite` |

### `match(Utterance utterance)`

- Чистая синхронная функция: без сети, файлов, хранилища, таймеров и изменения состояния. Вызывается на **каждое** сообщение у **каждого** коннектора.
- Возвращает `null`, если фраза не его. Лучше вернуть `null`, чем слабое совпадение «на всякий случай».
- Всё, что понадобится в `run` (код товара, разобранный срок), кладётся в `payload` — `run` не разбирает текст заново.
- Исключение в `match` не ломает помощника: маршрутизатор пропускает этот коннектор. Но это ошибка, её надо исправить.

### `run(ConnectorMatch match, AssistantSession session)`

- Здесь допустимы ввод-вывод и сеть (если `requiresNetwork: true`).
- Исключение превращается маршрутизатором в ответ `failed` с текстом «Не удалось выполнить действие: …» и `intent = match.commandId`. Ожидаемые ситуации (нет токена, 404, 401) лучше разбирать самому и отвечать понятным текстом.
- Ответ — `AssistantResponse(message, intent, status)`:
  - `completed` — ответ получен или действие выполнено (в том числе «товар не найден»);
  - `needsClarification` — нужен ответ пользователя, ничего не сделано;
  - `noAction` — действие невозможно, ничего не сделано (коннектор не настроен);
  - `failed` — ошибка.
- `intent` — `commandId` команды: `warehouse.locate`.

### `AssistantSession`

Общее состояние диалога; живёт столько же, сколько `AssistantController`.

| Член | Значение |
| --- | --- |
| `clock` | источник времени; не вызывайте `DateTime.now()` |
| `select(connectorId, itemId)` | запомнить выбранный объект («её», «его») |
| `selectedItemFor(connectorId)` | выбранный объект **этого** коннектора или `null` |
| `forget(connectorId, itemId)` | снять выбор, если выбран этот объект |
| `lastConnectorId` | какой коннектор обработал **предыдущее** сообщение; `null`, если его никто не взял или маршрутизатор переспросил |
| `requestConfirmation(PendingConfirmation)` | запомнить действие, которое ждёт «да» или «нет» в **следующем** сообщении |
| `pendingConfirmation` | ожидающее действие или `null`; маршрутизатор забирает его (`takePendingConfirmation`) в начале каждого сообщения |

Выбор хранится один на диалог: выбор товара снимает выбор задачи. Коннектор читает только `selectedItemFor(свой id)` — «Заверши её» после вопроса о товаре не завершит задачу.

### `Utterance` — общий разбор сообщения

Строится маршрутизатором один раз. Все смещения (`CharSpan`, полуоткрытые `[start, end)`) — в исходном тексте `original`.

| Член | Значение |
| --- | --- |
| `original` | текст как есть |
| `normalized` | нижний регистр, «ё» → «е»; длина та же, что у `original` |
| `analysisText` | `normalized`, где кавычки с содержимым и метки заменены пробелами |
| `tokens` | слова вне кавычек и меток: `text` (нормализованный), `original`, `span`, `isNumber` |
| `words` | только `text` слов |
| `quotedTitles` | названия в парных кавычках с фрагментами; `unbalancedQuotes` — незакрытая кавычка |
| `hashtags` | метки `#проект` вне кавычек: `name` без «#» в нижнем регистре |
| `due` | срок (`dueAt`, `precision`, `issue`) и `spans` — какие фрагменты занял срок вместе с предлогом |
| `codes` | числа из 5–6 цифр: артикулы, номера ячеек. Никогда не читаются как дата или время |
| `numbers` | все слова из одних цифр |
| `isQuestion` | есть «?» вне кавычек |
| `hasAnyWord({...})`, `firstOf({...})` | поиск нормализованных слов целиком |
| `tokensOutside(spans)`, `Utterance.isCovered(token, spans)` | слова вне фрагментов |
| `remainder(spans)` | остаток исходного текста без фрагментов, кавычек и меток: регистр сохранён, пробелы схлопнуты, знаки по краям убраны |
| `Utterance.capitalize(text)` | первая буква заглавная |

Правила, которые важно помнить:

- Слова сравниваются **целиком**: `hasAnyWord({'завтра'})` не срабатывает на «завтрак». Не ищите подстроки в `normalized`.
- «ё» уже заменена на «е»: пишите ключевые слова через «е» (`'еще'`, а не `'ещё'`).
- Слова — это буквы и цифры: «A-03» даёт два слова `a` и `03`, «2.10» — `2` и `10`.
- Дата, время и номер версии разбираются один раз в `due`; не разбирайте их сами. «до версии 2.10» не срок. «в 10» — срок только после «в/к» и если дальше нет обычного слова («в 2 магазинах» — не время), стоит инфинитив («в 10 позвонить») или сразу перед ним день («завтра в 10 созвон», «в следующий понедельник в 9 планёрка»).

## Шкала уверенности

| `confidence` | Когда |
| --- | --- |
| 0.9 | явная команда коннектора: глагол и объект, фраза целиком о нём. «Где лежит 64115», «Добавь задачу …» |
| 0.8–0.85 | команда понятна, но короче или опирается на контекст: «Заверши её», «Перенеси отчёт на завтра» |
| 0.6 | есть признаки, но фраза может быть частью чужой команды: «… где лежит 64115» внутри «Добавь задачу проверить, где лежит 64115» |
| < 0.5 | слабая догадка; такое совпадение не спорит с другими и выигрывает, только если больше никто не откликнулся. Обычно лучше вернуть `null` |

Встроенный `tasks`: создание и список — 0.9, перенос — 0.85, завершение — 0.8. Команды без маркера ниже: создание по инфинитиву («купить хлеб») — 0.6, со сроком («через 3 дня сдать отчёт») — 0.75; сообщение о сделанном без маркера («я купил хлеб») — 0.6. Такие совпадения помечены `ConnectorMatch(implicit: true)`: маршрутизатор отбрасывает их, если хоть один коннектор вернул явное совпадение, даже менее уверенное. Поэтому «узнать, где лежит 64115» (задачи угадали инфинитив, склад нашёл свой вопрос с 0.6) уходит складу без уточнения. Ставьте `implicit: true`, если намерение угадано только по форме фразы, без слова-команды.

## Правила уточнений

1. **Маршрутизатор** спрашивает «Не понял, к чему относится команда: «Задачи» или «Склад»?», если у двух **разных** коннекторов уверенность не ниже 0.5 (`AssistantController.ambiguityFloor`) и разница не больше 0.15 (`ambiguityMargin`). Ничего не выполняется. Поэтому не завышайте уверенность: 0.9 на любую фразу с числом создаст спор с задачами.
2. **Коннектор** спрашивает сам (`needsClarification`), если фраза его, но данных не хватает или они неоднозначны: несколько кодов, несколько найденных товаров, нет обязательного параметра. Уточнение не меняет данных и не ходит в сеть, если ответ сети не нужен для вопроса.
3. Не угадывайте: при сомнении — уточнение, а не действие.
4. **Изменяющие действия** (`access: readWrite`, всё, что меняет данные внешнего приложения) выполняются только после явного подтверждения пользователя (ADR-004). Стандартный способ — ожидание подтверждения в сессии, см. следующий раздел.

## Подтверждение изменяющих действий

Единый механизм для всех коннекторов: ожидание хранит `AssistantSession`, «да»/«нет» распознаёт и доставляет маршрутизатор. Своих полей `_pending` и проверок «а был ли вопрос последним» коннектору не нужно.

1. **Вопрос.** Первый `run` ничего не меняет: вызывает `session.requestConfirmation(PendingConfirmation(connectorId: id, commandId: 'warehouse.writeOff', itemId: '64115', payload: …))` и возвращает `needsClarification` с описанием действия и вопросом: «Списать 3 шт. артикула 64115 из ячейки A-03-2? Ответьте «да» или «нет».». В `payload` кладётся всё, что нужно для выполнения, — повторно текст разбирать не придётся.
2. **Ответ.** Маршрутизатор в начале **каждого** сообщения забирает ожидание (`takePendingConfirmation`) и проверяет сообщение целиком (`ConfirmationReply.of`):
   - «да», «ага», «угу», «конечно», «отмечай», «давай», «подтверждаю», «ок», «+», «👍», «✅» (в том числе «да, отмечай», «да, спасибо») — `ConfirmationReply.yes`;
   - «нет», «неа», «не надо», «отмена», «не отмечай», «нет, спасибо», «-», «👎» — `ConfirmationReply.no`;
   - ответ с пояснением — «да» или «нет» первым словом и дальше что угодно («да, купил хлеб», «нет, не купил», `ConfirmationReply.leading`) — тоже ответ, но только если ни один коннектор не нашёл в сообщении явной команды. «Нет, добавь задачу молоко» — новая команда: задачи вернули явное совпадение;
   - если ответ распознан, маршрутизатор **до обычного разбора** вызывает `run` коннектора-владельца с `ConnectorMatch(commandId: pending.commandId, confidence: 1, payload: ConfirmationAnswer(pending, reply))`. `match` других коннекторов не спрашивается: «да» не уйдёт чужому коннектору.
3. **Выполнение.** `run` различает ответ по типу `payload`: `ConfirmationAnswer` → при `confirmed` выполнить действие (проверив, что объект ещё существует), иначе ответить «Хорошо, не …» и ничего не делать.
4. **Срок жизни — одно сообщение.** Любое другое сообщение («нет, добавь задачу …», вопрос «да?», новая команда, «кстати») снимает ожидание и разбирается как обычно; «да» после него — уже обычная фраза. Новый вопрос заменяет прежний.
5. Вопрос и отказ не меняют выбранный объект (`select`).

Встроенные задачи — собственные данные приложения: явные команды («Заверши отчёт») выполняются сразу. Тем же механизмом задачи подтверждают завершение по сообщению о сделанном: «я купил хлеб» → «Отметить «Купить хлеб» выполненной?» → «да». Код — `TasksConnector._askToComplete` и `_answer`, тесты — `test/assistant_controller_test.dart` (группа «завершение по сообщению о сделанном») и `test/connectors/router_test.dart`.

## Сеть и секреты

- В сеть ходит только `run` и только через `HttpTransport`, полученный в конструкторе. Своих `HttpClient` не создавайте: так тесты подставляют подделку, а приложение решает, давать ли сеть.
- `HttpTransport.send` бросает исключение при обрыве и таймауте (`HttpRequestData.timeout`, по умолчанию 10 с); ответ 4xx/5xx — это `HttpResponseData`, а не исключение. Готовой сетевой реализации в приложении пока нет — она добавляется вместе с первым сетевым коннектором (см. чек-лист).
- Токены, ключи и пароли — только через `SecretStore` (ключ `<id>.<имя>`: `warehouse.token`). Не в `settings.json`, не в коде, не в логах и не в тексте ответа. Для приложения нужна реализация на защищённом хранилище платформы; `InMemorySecretStore` — для тестов.
- Если секрета нет — ответ `noAction` с понятным текстом и **без** обращения к сети. Не ссылайтесь в тексте на экран или пункт меню, которого в приложении нет.

### Как секреты и настройки попадают в коннектор

Сейчас в приложении **нет** ни экрана настроек коннекторов, ни постоянного `SecretStore`: есть только интерфейс `SecretStore` и `InMemorySecretStore` для тестов (всё в нём теряется при перезапуске). Автор первого сетевого коннектора делает эти части сам:

1. **Постоянный `SecretStore`.** Реализация интерфейса на защищённом хранилище платформы (Keychain на macOS/iOS, Keystore на Android). Новая зависимость (например, пакет защищённого хранилища) — отдельное решение: запишите его в `docs/DECISIONS.md`. Создаётся один раз в `lib/main.dart` и передаётся всем коннекторам. Хранить секреты в `settings.json` или в открытом файле нельзя (ADR-004).
2. **Несекретные настройки** — адрес сервиса (`baseUri`) и подобное. Передаются в конструктор коннектора из `lib/main.dart`. Если адрес меняется у пользователя, храните его в обычных настройках приложения рядом с другими, а не в `SecretStore`, — и не кладите туда же токен.
3. **Значения, которые выдаёт другое приложение** (общий токен, id сессии из QR-кода у halowarekeep), — это секреты: кто их знает, тот получает доступ. Они пишутся в `SecretStore` (`halowarekeep.token`, `halowarekeep.session`), а не в настройки.
4. **Как пользователь их вводит.** Нужен свой путь записи `SecretStore.write`, его в приложении пока нет ни одного. Варианты: раздел на экране настроек приложения; отдельный экран подключения, который открывается из ответа коннектора; сканирование QR-кода (нужны пакет камеры, разрешения камеры в `AndroidManifest.xml` и `Info.plist`, и это тоже запись в `docs/DECISIONS.md`). Сам `match`/`run` не должен принимать токен из текста чата: сообщения сохраняются в истории открытым текстом.
5. **Ответ без настройки.** Пока путь из п. 4 не сделан, `run` без секрета отвечает `noAction` текстом вида «Склад не подключён: токен склада не задан.» — без ссылки на несуществующий экран. Когда экран появится, укажите в тексте, где он.
6. **Сброс.** При 401/403 сообщите, что нужно подключиться заново; удалять секрет молча не нужно — пользователь может просто повторить попытку после исправления на стороне сервиса.

## Пошагово: новый коннектор

1. Придумайте `id`, `title`, 3–5 примеров фраз и `commandId` для каждой команды (`warehouse.locate`).
2. Создайте файл `lib/core/connectors/<id>_connector.dart` с классом, реализующим `Connector`.
3. Напишите `match`: признаки фразы из `Utterance` (`codes`, `hasAnyWord`, `due`, `quotedTitles`), уверенность по шкале, `payload`.
4. Напишите `run`: секреты из `SecretStore`, запрос через `HttpTransport`, разбор ответа, понятный текст для каждого исхода.
5. Тесты с подделками (`test/connectors/`): каждый пример из `info.examples` распознаётся; чужие фразы (задачи, фразы с датами) — `null`; все исходы `run`; без секрета нет запросов.
6. Фразы — в корпус (`test/corpus/connectors.jsonl`, см. ниже), фабрику коннектора — в `_connectorFactories` в `test/scenario_corpus_test.dart`.
7. Подключите в `lib/main.dart`.
8. Пройдите чек-лист в конце.

## Полный пример: «Пример склада»

Учебный коннектор только для чтения: отвечает на «где лежит {код}». Тот же код лежит в `test/connectors/example_warehouse_connector.dart` и проверяется тестами `test/connectors/example_warehouse_connector_test.dart`; если меняете пример, меняйте оба места.

Сервис склада вымышленный: `GET {baseUri}items/{код}/location` с заголовком `Authorization: Bearer {токен}` отвечает `{"cell": "A-03-2", "quantity": 12}`, 404 — нет товара, 401/403 — неверный токен.

```dart
import 'dart:convert';

import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';

/// Что `match` разобрал из фразы и передаёт в `run`.
final class LocateRequest {
  const LocateRequest(this.codes);

  /// Артикулы из фразы. Больше одного — `run` переспросит.
  final List<String> codes;
}

/// «Пример склада»: только чтение, отвечает на «где лежит {код}».
final class ExampleWarehouseConnector implements Connector {
  ExampleWarehouseConnector({
    required HttpTransport transport,
    required SecretStore secrets,
    required Uri baseUri,
  })  : _transport = transport,
        _secrets = secrets,
        _baseUri = baseUri;

  static const String id = 'warehouse_example';

  /// Ключ токена в [SecretStore]: `<id коннектора>.<имя>`.
  static const String tokenKey = '$id.token';

  final HttpTransport _transport;
  final SecretStore _secrets;
  final Uri _baseUri;

  static const Set<String> _questionWords = <String>{'где'};

  static const Set<String> _locateVerbs = <String>{
    'лежит',
    'лежат',
    'хранится',
    'хранятся',
    'находится',
    'находятся',
  };

  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: id,
        title: 'Пример склада',
        description: 'Подсказывает, в какой ячейке лежит товар по артикулу.',
        examples: <String>[
          'Где лежит 64115',
          'где хранится артикул 64115?',
          '64115 где лежит',
        ],
        requiresNetwork: true,
        access: ConnectorAccess.readOnly,
      );

  @override
  ConnectorMatch? match(Utterance utterance) {
    final codes = utterance.codes;
    if (codes.isEmpty) return null;
    final asksWhere = utterance.hasAnyWord(_questionWords);
    final saysLies = utterance.hasAnyWord(_locateVerbs);
    if (!asksWhere && !saysLies) return null;
    // Фраза целиком о складе: начинается с «где» или с кода и содержит
    // и вопрос, и глагол. Иначе «где лежит» может быть частью другой
    // команды («Добавь задачу проверить, где лежит 64115») — тогда уверенность
    // средняя, и команда с явным глаголом уверенно победит.
    final first = utterance.tokens.first.text;
    final wholePhrase = first == 'где' || codes.contains(first);
    return ConnectorMatch(
      connectorId: id,
      commandId: 'warehouse.locate',
      confidence: asksWhere && saysLies && wholePhrase ? 0.9 : 0.6,
      payload: LocateRequest(codes),
    );
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    final request = match.payload! as LocateRequest;
    if (request.codes.length > 1) {
      return AssistantResponse(
        message: 'Какой артикул найти: ${request.codes.join(' или ')}?',
        intent: match.commandId,
        status: AssistantStatus.needsClarification,
      );
    }
    final code = request.codes.single;
    final token = await _secrets.read(tokenKey);
    if (token == null) {
      return AssistantResponse(
        message: 'Склад не подключён: токен склада не задан.',
        intent: match.commandId,
        status: AssistantStatus.noAction,
      );
    }
    final response = await _transport.send(
      HttpRequestData(
        method: 'GET',
        uri: _baseUri.resolve('items/${Uri.encodeComponent(code)}/location'),
        headers: <String, String>{
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      ),
    );
    if (response.statusCode == 404) {
      return AssistantResponse(
        message: 'Артикул $code на складе не найден.',
        intent: match.commandId,
        status: AssistantStatus.completed,
      );
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      return AssistantResponse(
        message: 'Склад не принял токен. Подключите склад заново.',
        intent: match.commandId,
        status: AssistantStatus.failed,
      );
    }
    if (!response.isSuccess) {
      return AssistantResponse(
        message: 'Склад ответил ошибкой ${response.statusCode}.',
        intent: match.commandId,
        status: AssistantStatus.failed,
      );
    }
    // Неверный JSON бросит исключение — маршрутизатор вернёт `failed`.
    final json = jsonDecode(response.body) as Map<String, Object?>;
    final cell = json['cell'] as String;
    final quantity = json['quantity'] as int;
    return AssistantResponse(
      message: 'Артикул $code лежит в ячейке $cell, остаток $quantity шт.',
      intent: match.commandId,
      status: AssistantStatus.completed,
    );
  }
}
```

Что здесь важно:

- `match` смотрит только на `utterance.codes` и слова целиком. Код «64115» уже отделён от дат: «Где лежит 15.11» не совпадёт, потому что кодов нет.
- Уверенность 0.9 только если фраза целиком о складе (начинается с «где» или с кода). В «Добавь задачу проверить, где лежит 64115» складу достаётся 0.6, задачам 0.9 — разница больше 0.15, побеждают задачи без уточнения.
- `run` сначала проверяет многозначность и токен — до сети.
- Неожиданный ответ (не JSON) бросает исключение, и маршрутизатор отвечает `failed`; помощник не падает.

### Тест с подделками

Подделка сети — `test/connectors/fakes.dart`:

```dart
final class FakeHttpTransport implements HttpTransport {
  FakeHttpTransport(this.respond);

  final HttpResponseData Function(HttpRequestData request) respond;
  final List<HttpRequestData> requests = <HttpRequestData>[];

  @override
  Future<HttpResponseData> send(HttpRequestData request) async {
    requests.add(request);
    return respond(request);
  }
}
```

Фрагмент теста (полностью — `test/connectors/example_warehouse_connector_test.dart`):

```dart
final transport = FakeHttpTransport(
  (HttpRequestData request) => const HttpResponseData(
    statusCode: 200,
    body: '{"cell": "A-03-2", "quantity": 12}',
  ),
);
final warehouse = ExampleWarehouseConnector(
  transport: transport,
  secrets: InMemorySecretStore(<String, String>{
    ExampleWarehouseConnector.tokenKey: 'секрет',
  }),
  baseUri: Uri.parse('https://warehouse.example/api/'),
);
final assistant = AssistantController(
  connectors: <Connector>[tasksConnector, warehouse],
  clock: FixedClock(DateTime(2026, 11, 2, 16, 30)),
);

final response = await assistant.handle('Где лежит 64115?');

expect(response.status, AssistantStatus.completed);
expect(transport.requests.single.headers['Authorization'], 'Bearer секрет');
```

Проверяйте вместе с задачами в одном `AssistantController`: так видно, что коннекторы не перехватывают фразы друг друга.

## Подключение в `lib/main.dart`

Коннекторы передаются списком; порядок важен только при равной уверенности (и тогда всё равно будет уточнение):

```dart
final assistant = AssistantController(
  connectors: <Connector>[
    TasksConnector(taskService: tasks, parser: ScenarioParser(clock: clock)),
    WarehouseConnector(
      transport: transport,   // реализация HttpTransport для приложения
      secrets: secretStore,   // реализация SecretStore на защищённом хранилище
      baseUri: Uri.parse('https://…/api/'),
    ),
  ],
  clock: clock,
);
```

## Фразы коннектора в корпусе

Корпус (`docs/CORPUS.md`) общий для всех коннекторов. Строка с полем `connector` относится к этому коннектору; без поля — к `tasks`.

```json
{"id":"wh-001","text":"Где лежит 64115","connector":"warehouse","intent":"warehouse.locate","source":"manual"}
{"id":"wh-002","text":"Где лежит отчёт","connector":"warehouse","intent":"unknown","note":"без кода не отвечаем"}
```

- Для коннектора, отличного от `tasks`, `intent` — ожидаемый `commandId` или `unknown` («этот коннектор не должен откликнуться»). Поля разбора задач (`title`, `due`, …) в таких строках могут быть только пустыми (`null`, `none`) — их значения не проверяются.
- Для каждой строки с `intent` ≠ `unknown` тест проверяет и маршрутизацию: среди всех коннекторов из `_connectorFactories` должен победить указанный, причём без уточнения «к чему относится команда».
- Чтобы корпус знал коннектор, добавьте фабрику в `_connectorFactories` (`test/scenario_corpus_test.dart`) с подделками сети и секретов — `match` их не трогает.
- Новые фразы удобно размечать `tools/corpus_gen` (модели — только при разработке, ADR-001): файл тем `tools/corpus_gen/topics/<id>.toml`, где `intents` — **ровно** ваши `commandId` плюс `unknown` (формат — `tools/corpus_gen/README.md`). Генератор пишет такие фразы со `status: active`, а проверяет их этот тест; если строка падает, исправьте разметку или коннектор либо поставьте ей `known_gap`.

## Чек-лист перед подключением

- [ ] `id` уникален, `title` понятен пользователю, `examples` проверены тестом.
- [ ] `match` без ввода-вывода; чужие фразы (задачи, даты, вопросы без кода) дают `null`.
- [ ] Уверенность по шкале; фразы задач с теми же словами не дают спора (проверено корпусом).
- [ ] `access: readOnly`, если коннектор ничего не меняет. Для `readWrite` — подтверждение каждого изменяющего действия через `session.requestConfirmation` (раздел «Подтверждение изменяющих действий»), с тестами на «да», «нет», постороннее сообщение и устаревший вопрос.
- [ ] Секреты только через `SecretStore`; без секрета нет сетевых запросов; секреты не попадают в ответы и логи.
- [ ] Все исходы `run` (успех, не найдено, 401/403, 5xx, обрыв, испорченный ответ) покрыты тестами с подделкой.
- [ ] Фразы в `test/corpus/connectors.jsonl`, фабрика в `_connectorFactories`.
- [ ] Подключён в `lib/main.dart`.
- [ ] **Разрешения на сеть для release-сборок** (добавляются вместе с первым сетевым коннектором, сейчас их нет):
  - [ ] Android: `<uses-permission android:name="android.permission.INTERNET"/>` в `android/app/src/main/AndroidManifest.xml` (в debug-манифесте оно уже есть, поэтому без него ошибка проявится только в release);
  - [ ] macOS: ключ `com.apple.security.network.client` = `true` в `macos/Runner/Release.entitlements` и `macos/Runner/DebugProfile.entitlements`;
  - [ ] реализация `HttpTransport` для приложения (например, на `dart:io` `HttpClient` с таймаутом из запроса) и `SecretStore` на защищённом хранилище платформы.
- [ ] Есть путь, которым пользователь задаёт секреты и настройки коннектора (экран, QR-код), см. «Как секреты и настройки попадают в коннектор»; тексты ответов не ссылаются на несуществующие экраны.
- [ ] Обновлены `README.md` и, если поменялись правила, `docs/DECISIONS.md`.
