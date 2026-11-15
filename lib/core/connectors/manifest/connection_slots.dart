import 'connection.dart';
import 'manifest_format.dart';

/// Подключения, которые знает «Tridot». Новое приложение — новый слот
/// со своими текстами (expeora — позже, docs/PLANS.md).
abstract final class ConnectionSlots {
  /// Путь к подключению склада в приложении.
  static const String warehousePath =
      'Мой Связной → Помощники → Роли → Кладовщик';

  /// Склад DepotDesk (и его предшественник halowarekeep — то же описание,
  /// другой `app.id`; ADR-031). Файлы подключения — под прежним
  /// `halowarekeep`: старые подключения работают без нового входа.
  static const ConnectionSlot warehouse = ConnectionSlot(
    id: 'warehouse',
    title: 'Склад',
    appId: 'halowarekeep',
    alsoAccepts: <String>{'depotdesk'},
    description: 'Остатки, ячейки, цены и приходы склада DepotDesk. Чтение; '
        'перемещение и отметка проведения — только если разрешить действия '
        'в роли «Кладовщик».',
    aliases: <String>['на складе', 'в складе', 'склад'],
    helpPhrases: <String>[
      'что умеет склад',
      'что может склад',
      'что знает склад',
      'помощь по складу',
      'справка по складу',
      'команды склада',
      'что спросить у склада',
    ],
    // Описание до 1.4.56 не знает входа по ссылке: действие и поля —
    // из кода склада (api.php, qr_take). `scope: assist` — ключ только для
    // вопросов помощнику (склад 1.4.62); старый склад поле не знает.
    builtInQr: ManifestQr(
      action: 'qr_take',
      body: <String, String>{'scope': 'assist'},
      device: 'device',
      ttl: 600,
      errors: <String, String>{
        '400': 'Ссылка обрезана или испорчена — скопируйте её заново.',
        '410': 'Код устарел или уже использован — сделайте новый на складе: '
            '«Складской помощник» → «Показать QR».',
        '429': 'Слишком много попыток — подождите десять минут.',
      },
    ),
    builtInAsset: 'assets/connectors/depotdesk.assistant.json',
    commandReplies: <String, String>{'price': 'price'},
    // Описание даёт нейтральный факт ({text}), каталог — голос помощника.
    replies: <String, String>{
      'warehouse.answer': '{text}',
      'warehouse.more': 'Показаны не все — {вы:уточните|ты:уточни} запрос.',
      'warehouse.empty': '{text}',
      'warehouse.fallbackEmpty':
          '{text} {вы:Спросите|ты:Спроси}, например: {examples}.',
      'warehouse.reply': '{text}',
      'warehouse.price': 'Цены я пока не называю — {вы:посмотрите|ты:'
          'посмотри} цену в карточке артикула в самом складе.',
      'warehouse.help': 'Склад понимает: {list}.',
      'warehouse.ask': '{вы:Уточните|ты:Уточни}, что искать: {label}. '
          'Например: «{example}».',
      'warehouse.serverSaid': 'Склад ответил: {error}',
      'warehouse.notConnected': 'Склад не подключён. {вы:Подключите|ты:'
          'Подключи} его: $warehousePath.',
      'warehouse.auth.token': 'Склад не принял пароль — {вы:подключитесь|ты:'
          'подключись} заново: $warehousePath.',
      'warehouse.auth.expired': 'Личный ключ склада устарел: остатки видны, '
          'а приходы — после нового входа. {вы:Отсканируйте|ты:Отсканируй} '
          'новый QR со склада («Складской помощник» → «Показать QR»): '
          '$warehousePath.',
      'warehouse.auth.staff': 'Это видно только под своим логином. '
          '{вы:Подключитесь|ты:Подключись} по QR со склада '
          '(«Складской помощник» → «Показать QR»): $warehousePath.',
      'warehouse.auth.role': 'Учётная запись на складе ждёт роли — '
          '{вы:попросите|ты:попроси} администратора её назначить.',
      'warehouse.offline': 'Нет связи со складом. {вы:Проверьте|ты:Проверь} '
          'интернет и {вы:спросите|ты:спроси} ещё раз.',
      'warehouse.timeout': 'Склад не ответил вовремя. {вы:Попробуйте|ты:'
          'Попробуй} ещё раз чуть позже.',
      'warehouse.serverError': 'Склад отвечает с ошибкой. {вы:Попробуйте|ты:'
          'Попробуй} позже.',
      'warehouse.busy': 'Склад просит подождать: слишком много запросов. '
          '{вы:Попробуйте|ты:Попробуй} через минуту.',
    },
    protectedReplies: <String>{
      'warehouse.serverSaid',
      'warehouse.notConnected',
      'warehouse.auth.token',
      'warehouse.auth.expired',
      'warehouse.auth.staff',
      'warehouse.auth.role',
      'warehouse.offline',
      'warehouse.timeout',
      'warehouse.serverError',
      'warehouse.busy',
    },
  );

  static const List<ConnectionSlot> all = <ConnectionSlot>[warehouse];
}
