# Веб-помощник «Связной» на складе

Решение — ADR-032 (`docs/DECISIONS.md`). Выпуск и шаги владельца —
`tool/widget_release/README.md`.

## Что это

Тот же «Связной», собранный для браузера из общего кода Tridot: описание
склада (`assets/connectors/depotdesk.assistant.json`), `ManifestConnector`,
каталог ответов, карточки склада (`WarehouseCardView`) и действий
(`ActionCardView`). Склад DepotDesk или halowarekeep ставит его к себе в
`assistant/v/<версия>-<sha8>/` и открывает кнопкой-роботом в шапке —
фреймом того же адреса поверх склада: на телефоне во весь экран, на
компьютере справа шириной 420.

Чего в помощнике нет: задач, файлов, паролей, конвертера, голоса Vosk,
сканера QR, уведомлений, настроек — только склад, калькулятор и беседа.
Помощник один — Связной, без эмодзи.

## Код

| Файл | Что |
|---|---|
| `lib/web_widget/main.dart` | Точка входа сборки `flutter build web -t lib/web_widget/main.dart` |
| `lib/web_widget/widget_session.dart` | Вся логика без браузера: вход по ключу, разговор, новый ключ, голос, обновление (тесты на VM) |
| `lib/web_widget/widget_app.dart` | Компактный чат по ADR-027 (тесты виджетов на VM) |
| `lib/web_widget/widget_protocol.dart` | Сообщения `postMessage`: разбор и сборка |
| `lib/web_widget/widget_storage.dart` | `localStorage` за интерфейсом: запись подключения, кэш описания, история |
| `lib/web_widget/widget_texts.dart` | Тексты вместо путей приложения («Обновите страницу склада») |
| `lib/web_widget/browser_host.dart` | `postMessage` и `localStorage` браузера (`package:web`) |
| `lib/web_widget/fetch_transport.dart` | `HttpTransport` поверх `fetch` (`package:web`) |
| `web/index.html`, `web/flutter_bootstrap.js` | Страница без `<base>`, CSP, CanvasKit из архива |
| `tool/widget_release/` | Сборка, архив, подпись, `latest.json`, загрузка в бакет |

Код с `package:web` — только `browser_host.dart`, `fetch_transport.dart` и
`main.dart`; остальное проверяется на VM. Тест
`test/web_widget/web_graph_test.dart` следит за графом импортов: никаких
`dart:ffi`, `path_provider`, `file_selector`, `mobile_scanner`, `record`;
`dart:io` — только в известных файлах, чей файловый код помощник не
вызывает (в вебе это заглушки), и никогда — на пути коннектора склада.
Для этого `JsonConnectionStore` вынесен в
`lib/core/connectors/manifest/connection_store_io.dart` (импортирует
только `lib/main.dart`).

## Вход

1. Страница склада (свой вход сотрудника) вызывает `assist_web_key` — склад
   выдаёт ключ помощника (`scope: assist`), привязанный к входу страницы:
   гаснет при выходе, виден на странице «Подключить Связного» как
   «Веб-помощник», его можно отключить.
2. Помощник шлёт `hello`, страница отвечает `init` с адресом склада и
   ключом.
3. `ConnectionService.connectWithKey`: описание с сервера (не получено —
   встроенное), ключ — только в памяти (`InMemorySecretStore`), пароль
   склада не нужен (`tokenless`), затем `ask_me` — логин, имя, роль,
   права. Прежний ключ на складе не гасится: его заменяет склад.
4. Права — роль сотрудника и переключатели администратора склада: их
   проверяет сервер. «Разрешить действия» у помощника включено для логина
   входа — решает склад.
5. 403 `need: login` или 401 без пароля — `need-key`, страница присылает
   `key`, вопрос повторяется один раз.

Запросы идут `fetch` с `credentials: omit` (cookie склада не уходят),
`redirect: error`, тайм-аут — `AbortController`.

## Договор `postMessage` (версия `api` 1)

В каждом сообщении `svz: 1`. Помощник принимает сообщения только с того же
адреса (`origin`) и только от окна родителя, отправляет — только родителю
на свой адрес.

| направление | `type` | поля |
|---|---|---|
| помощник → склад | `hello` | `version`, `api` |
| склад → помощник | `init` | `base`, `sid`, `login`, `name`, `roleLabel`, `theme` (`light`/`dark`), `device` (`phone`/`desktop`), `voice: {available, reason}` |
| помощник → склад | `need-key` | — |
| склад → помощник | `key` | `sid` или `error` |
| помощник → склад | `close` | — |
| склад → помощник | `back`, `logout`, `visible: {on}` | — |
| склад → помощник | `theme` | `theme` (`light`/`dark`) — тему склада переключили, пока помощник загружен |
| помощник → склад | `open` | `hash` (`#/…` или пусто — главная склада) |
| помощник → склад | `update-ready` | `version` |
| помощник → склад | `voice` | `op` (`start`/`stop`/`cancel`/`download`), `id`, `lang: ru-RU` |
| склад → помощник | `voice-ev` | `id`, `ev` (`state`/`partial`/`final`/`error`), `text`, `code` |

- `back`: идёт распознавание — отменить, иначе `close`.
- Escape на компьютере ловит сам помощник (фокус внутри фрейма) и ведёт себя
  как `back`; страница склада ловит Escape, когда фокус у неё.
- `logout`: ключ уже погашен вместе со входом — помощник стирает свои
  ключи `svz:*` и ключ в памяти без запроса на склад.
- `update-ready`: раз в 10 минут и при `visible: {on: true}` помощник читает
  `assistant/current.json`; версия другая — сообщает, только когда ничем не
  занят (ответ не готовится, поле ввода пусто, голос не слушает, карточка
  действия не ждёт ответа).

## Голос

Только в приложениях склада для Android (модуль Capacitor `WhVoice`,
распознавание на устройстве: `SpeechRecognizer.createOnDeviceSpeechRecognizer`,
Android 12+, ru-RU, без облака). `window.Capacitor` есть только у главной
страницы, поэтому распознавание запускает страница склада, а помощник шлёт
ей `voice` и получает `voice-ev`.

| `voice.reason` | Что показывает помощник |
|---|---|
| `ok` (`available: true`) | Кнопка микрофона; `partial` — в строке над полем, `final` — вопрос складу |
| `sdk`, `no-ondevice` | Кнопка — подсказка «Нажмите микрофон на клавиатуре» |
| `no-lang` | Кнопка — `download`: скачать русский |
| `web` | Кнопки нет (браузер, компьютер, Electron) |

## Хранение в браузере

`localStorage`, все ключи начинаются с `svz:` (страница склада при выходе
стирает их по началу): `svz:conn:<app>` — запись подключения без ключей,
`svz:desc:<app>` — кэш описания, `svz:hist:<логин>` — история (200
сообщений, не больше ~1 МБ). Ключ помощника — только в памяти.

## Сборка и размер

```sh
flutter build web --release -t lib/web_widget/main.dart \
  --no-web-resources-cdn --no-source-maps
```

JS + CanvasKit (без `--wasm`: WasmGC нет в старых WebView и Safari).
`tool/widget_release` убирает лишнее: варианты CanvasKit кроме `canvaskit/`
и `chromium/`, символы отладки, ассеты Tridot (паки, пароли, голос,
каталоги — ядро берёт их из `builtin_replies.g.dart`), шрифты Cormorant и
JetBrains Mono (и из `FontManifest.json`), `NOTICES` → `LICENSES.txt`.
Архив — около 7 МБ, при первом открытии в Chrome скачивается около 3,5 МБ
со сжатием (main.dart.js ~0,9, chromium/canvaskit.wasm ~2,1, шрифты);
дальше — из кэша: папки версий не меняются.

Тега `<base>` нет: папка версии заранее неизвестна, относительные пути
считаются от адреса `index.html`. Своего service worker нет; страница
склада исключает `/assistant/` из своего `sw.js`. CSP в `<meta>`: только
свой адрес, `wasm-unsafe-eval` для CanvasKit. Запасных шрифтов нет, за
gstatic помощник не ходит.

## Формат выпуска

- `svyaznoy-web-<версия>.zip`: файлы сборки и в корне `_release.json`
  (`{product: "svyaznoy-web", version, minApi, minServer: {depotdesk,
  halowarekeep}, notes, files: {путь: sha256}, total}`) и `_release.sig`
  (base64 подписи Ed25519 байтов `"SVYAZNOY-WEB-RELEASE-V1\n"` +
  `_release.json`).
- `latest.json`: `{version, minApi, minServer, url, size, sha256, notes,
  sig}`; `sig` — base64 подписи `"SVYAZNOY-WEB-LATEST-V1\n<version>\n<sha256>\n<size>\n<minApi>"`.
- Имена в архиве — только то, что примет склад: без `..`, `\`, ведущей
  `/`, имён с точкой в начале; расширения `html js mjs json wasm css png
  svg ico webp otf ttf woff2 bin symbols txt frag`; не больше 3000 файлов и
  80 МБ. Время файлов постоянное: одинаковая сборка — одинаковый архив.
- Подпись — OpenSSL 3 (`openssl pkeyutl -sign -rawin`), проверка на
  складе — `sodium_crypto_sign_verify_detached` (совместимость проверяет
  тест `test/tool/widget_release_test.dart`, если есть `php` с sodium).

## Проверки

К проверкам Tridot добавляется сборка помощника:
`flutter build web --release -t lib/web_widget/main.dart --no-web-resources-cdn --no-source-maps`.
Сборка APK не меняется.
