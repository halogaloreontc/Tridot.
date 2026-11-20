import 'app_profile.dart';
import 'connection.dart';
import 'generic_slot.dart';

/// Что не так с адресом или ссылкой входа ([ConnectionAddressException]):
/// код, а текст для экрана — у [ConnectionTexts] того подключения, куда
/// входят (склад говорит «склад», CRM — своим именем).
enum AddressProblem {
  /// Поле адреса пустое.
  empty,

  /// Не похоже на ссылку.
  notUrl,

  /// Не `https` и не `http`.
  scheme,

  /// Логин и пароль в самом адресе.
  userInfo,

  /// `http` не своей сети.
  httpRemote,

  /// Поле ссылки входа пустое.
  linkEmpty,

  /// Ссылка входа — не ссылка.
  notLink,

  /// В ссылке входа нет кода.
  noCode,

  /// Код ссылки входа не того вида.
  badCode,

  /// Ссылка `tridot://connect` испорчена.
  connectBroken,

  /// Код в ссылке `tridot://connect` испорчен.
  connectCode,
}

/// Тексты подключения для экрана (ADR-043): у склада — прежние, слово в
/// слово; у приложения из каталога — с его именем, падежами и родом из
/// профиля ([AppProfile]); у приложения, которое ещё не подключено
/// («Подключить приложение»), — о «приложении».
///
/// В текстах нет ни пароля, ни ключа, ни кода из ссылки.
sealed class ConnectionTexts {
  const ConnectionTexts();

  /// Тексты для слота [slot]: склад (слот из кода без профиля) или
  /// приложение из каталога.
  factory ConnectionTexts.of(ConnectionSlot slot) {
    final profile = slot.profile;
    return profile == null
        ? warehouse
        : GenericConnectionTexts(profile, title: slot.title);
  }

  /// Склад: прежние тексты.
  static const ConnectionTexts warehouse = WarehouseConnectionTexts();

  /// Приложение до подключения: «Укажите адрес приложения».
  static const ConnectionTexts app = GenericConnectionTexts(
    AppProfile(
      appId: 'app',
      name: 'приложение',
      forms: NameForms(
        nom: 'приложение',
        gen: 'приложения',
        dat: 'приложению',
        acc: 'приложение',
        ins: 'приложением',
        prep: 'приложении',
      ),
      inPhrase: 'в приложении',
      gender: AppGender.n,
    ),
    title: 'Приложение',
  );

  /// Это склад (тексты слово в слово прежние).
  bool get isWarehouse;

  /// «Склад», «Автосервис», «CRM».
  String get title;

  // ------------------------------------------------------------ адрес

  String address(AddressProblem problem);

  // ------------------------------------------------------------- вход

  /// Нет связи при входе по ссылке.
  String get offlineRetry;

  /// Нет связи («кто я»).
  String get offline;

  /// Нет связи при проверке пароля.
  String get offlineAddress;

  /// Нет связи при входе по логину.
  String get offlineInternet;

  /// «Обновить описание» до подключения.
  String get notConnectedYet;

  /// «Войти под логином» без подключения.
  String get connectFirst;

  /// Сервер ответил своим текстом [said].
  String serverSaid(String said);

  /// Сервер ответил ошибкой [status].
  String serverError(int status);

  /// Вход по ссылке: пароля в ответе нет.
  String get noPasswordSent;

  /// Ключ страницы не того вида (веб-помощник).
  String get keyWrongShape;

  /// Вход выполнен: [login] и кто это ([who]).
  String connected(String login, String who);

  /// Вход вручную по паролю без логина.
  String get connectedByPassword;

  /// «Кто я» не вышло.
  String get noWho;

  /// Пароль не введён.
  String get enterPassword;

  /// Пароль проверить нечем.
  String get cannotCheck;

  /// Пароль не принят.
  String get passwordRejected;

  /// Слишком много попыток.
  String get busyAttempts;

  /// По адресу не это приложение (ответ [status]).
  String notThisApp(int status);

  /// По адресу ответ не JSON.
  String get notJson;

  // ----------------------------------------------------------- экран

  /// «Адрес склада», «Адрес автосервиса».
  String get addressLabel;

  /// «Пароль склада»; у приложения — подпись из описания, если есть.
  String passwordLabel(String? fromDescription);

  /// Пояснение «Ввести вручную».
  String manualHint({required bool staff});

  /// Пояснение «Подключить по ссылке».
  String get linkHint;

  /// Пояснение «Войти под логином».
  String get staffHint;

  /// Текст окна «Выйти».
  String get logoutBody;

  /// Описание до подключения: встроенная копия или закреплённое.
  String get beforeConnect;

  // --------------------------------------------------------- карточка

  /// Заголовок карточки ответа, если у команды его нет.
  String get cardTitle;

  /// «Склад показал не всё — уточните запрос.»
  String get cardPartial;

  /// «Открыть в складе».
  String get cardOpenIn;

  /// «Открыть склад».
  String get cardOpen;

  /// «Отправляю на склад…».
  String get actionSending;

  /// «Итог неизвестен — «Проверить» спросит склад».
  String get actionUnknown;
}

/// Тексты склада — прежние, слово в слово.
final class WarehouseConnectionTexts extends ConnectionTexts {
  const WarehouseConnectionTexts();

  @override
  bool get isWarehouse => true;

  @override
  String get title => 'Склад';

  @override
  String address(AddressProblem problem) => switch (problem) {
        AddressProblem.empty => 'Укажите адрес склада.',
        AddressProblem.notUrl => 'Адрес не похож на ссылку.',
        AddressProblem.scheme => 'Нужен адрес https://… склада.',
        AddressProblem.userInfo =>
          'Логин и пароль в адресе не указывают — для них есть поля ниже.',
        AddressProblem.httpRemote =>
          'Без шифрования (http) можно только в своей сети. Для склада в '
              'интернете нужен адрес https://…',
        AddressProblem.linkEmpty =>
          'Вставьте ссылку со склада: «Подключить Связного» → «Скопировать '
              'ссылку».',
        AddressProblem.notLink =>
          'Это не ссылка. Скопируйте её на складе: «Подключить Связного» → '
              '«Показать QR» → «Скопировать ссылку».',
        AddressProblem.noCode =>
          'В ссылке нет кода входа. Скопируйте её заново на складе: '
              '«Подключить Связного» → «Показать QR» → «Скопировать ссылку».',
        AddressProblem.badCode =>
          'Код в ссылке обрезан или испорчен — скопируйте ссылку заново.',
        AddressProblem.connectBroken =>
          'Ссылка «Открыть в Tridot» испорчена — сделайте новый код на '
              'складе: «Подключить Связного».',
        AddressProblem.connectCode =>
          'Код в ссылке обрезан или испорчен — сделайте новый на складе.',
      };

  @override
  String get offlineRetry =>
      'Нет связи со складом. Проверьте интернет и попробуйте снова.';

  @override
  String get offline => 'Нет связи со складом.';

  @override
  String get offlineAddress =>
      'Нет связи со складом. Проверьте адрес и интернет.';

  @override
  String get offlineInternet => 'Нет связи со складом. Проверьте интернет.';

  @override
  String get notConnectedYet => 'Склад ещё не подключён.';

  @override
  String get connectFirst => 'Сначала подключите склад.';

  @override
  String serverSaid(String said) => 'Склад ответил: $said';

  @override
  String serverError(int status) => 'Склад ответил ошибкой $status.';

  @override
  String get noPasswordSent =>
      'Склад не прислал пароль — сделайте новую ссылку.';

  @override
  String get keyWrongShape =>
      'Склад передал ключ не того вида — обновите страницу склада.';

  @override
  String connected(String login, String who) {
    if (login.isEmpty) return 'Склад подключён.';
    return who.isEmpty
        ? 'Склад подключён: $login.'
        : 'Склад подключён: $login ($who).';
  }

  @override
  String get connectedByPassword => 'Склад подключён по паролю склада.';

  @override
  String get noWho => 'Склад не говорит, кто вошёл.';

  @override
  String get enterPassword => 'Введите пароль склада.';

  @override
  String get cannotCheck =>
      'Пароль не проверить: в описании нет команды по паролю склада.';

  @override
  String get passwordRejected => 'Склад не принял пароль.';

  @override
  String get busyAttempts =>
      'Склад просит подождать: слишком много попыток. Попробуйте '
      'через несколько минут.';

  @override
  String notThisApp(int status) =>
      'По этому адресу не склад или он переехал (ответ $status). '
      'Проверьте адрес.';

  @override
  String get notJson =>
      'По этому адресу отвечает не склад (ответ не JSON). Проверьте '
      'адрес.';

  @override
  String get addressLabel => 'Адрес склада';

  @override
  String passwordLabel(String? fromDescription) => 'Пароль склада';

  @override
  String manualHint({required bool staff}) =>
      'Адрес склада и пароль склада. Логин и пароль сотрудника — '
      'по желанию: без них видны только остатки и ячейки. Пароль '
      'сотрудника не сохраняется — только личный ключ.';

  @override
  String get linkHint =>
      'На складе: «Складской помощник» → «Показать QR» → «Скопировать '
      'ссылку» (склад 1.4.62) или «Профиль» → «Войти на телефоне» '
      '→ «Скопировать ссылку». Вставьте её сюда. Код одноразовый и '
      'сработает только один раз: не открывайте ссылку «#qr=» в '
      'браузере.\n'
      'Если таких кнопок нет — склад старше 1.4.56: подключите его '
      'вручную (ниже).';

  @override
  String get staffHint =>
      'Приходы видны только под своим логином. Можно и по ссылке '
      'выше.';

  @override
  String get logoutBody =>
      'Пароль склада и личный ключ будут удалены с устройства. Адрес '
      'и описание останутся.';

  @override
  String get beforeConnect => 'Встроенная копия — до подключения';

  @override
  String get cardTitle => 'Склад';

  @override
  String get cardPartial => 'Склад показал не всё — уточните запрос.';

  @override
  String get cardOpenIn => 'Открыть в складе';

  @override
  String get cardOpen => 'Открыть склад';

  @override
  String get actionSending => 'Отправляю на склад…';

  @override
  String get actionUnknown => 'Итог неизвестен — «Проверить» спросит склад';
}

/// Тексты приложения из каталога подключений: имя, падежи и род — из
/// профиля. Без падежей или без рода (`CRM`) — обороты без согласования:
/// «Ответ CRM: …», «Подключение к CRM готово».
final class GenericConnectionTexts extends ConnectionTexts {
  const GenericConnectionTexts(this.profile, {required this.title});

  final AppProfile profile;

  @override
  final String title;

  @override
  bool get isWarehouse => false;

  NameForms get _c => profile.cases;

  /// Род для согласования; `null` — без согласования.
  AppGender? get _gender => profile.declinable ? profile.gender : null;

  bool get _plural => _gender == AppGender.pl;

  /// «Автосервис» в начале предложения.
  String get _head => GenericSlotTexts.capitalize(_c.nom);

  String _past(String masculine) =>
      GenericSlotTexts.pastTense(masculine, _gender ?? AppGender.m);

  /// «в автосервисе», «в CRM».
  String get _here => profile.inPhrase ?? 'в ${_c.prep}';

  /// «в автосервис», «на склад», «в CRM».
  String get _to {
    final phrase = profile.inPhrase;
    final preposition =
        phrase == null ? 'в' : phrase.substring(0, phrase.indexOf(' '));
    return '$preposition ${_c.acc}';
  }

  String get _connectedWord => switch (_gender) {
        AppGender.f => 'подключена',
        AppGender.n => 'подключено',
        AppGender.pl => 'подключены',
        _ => 'подключён',
      };

  @override
  String address(AddressProblem problem) => switch (problem) {
        AddressProblem.empty => 'Укажите адрес ${_c.gen}.',
        AddressProblem.notUrl => 'Адрес не похож на ссылку.',
        AddressProblem.scheme => 'Нужен адрес https://… ${_c.gen}.',
        AddressProblem.userInfo =>
          'Логин и пароль в адресе не указывают — для них есть поля ниже.',
        AddressProblem.httpRemote =>
          'Без шифрования (http) можно только в своей сети. Для ${_c.gen} '
              'в интернете нужен адрес https://…',
        AddressProblem.linkEmpty =>
          'Вставьте ссылку входа — её даёт само приложение.',
        AddressProblem.notLink =>
          'Это не ссылка. Скопируйте ссылку входа заново $_here.',
        AddressProblem.noCode =>
          'В ссылке нет кода входа. Скопируйте её заново $_here.',
        AddressProblem.badCode =>
          'Код в ссылке обрезан или испорчен — скопируйте ссылку заново.',
        AddressProblem.connectBroken =>
          'Ссылка «Открыть в Tridot» испорчена — сделайте новый код '
              '$_here.',
        AddressProblem.connectCode =>
          'Код в ссылке обрезан или испорчен — сделайте новый $_here.',
      };

  String get _noLink => 'Нет связи ${GenericSlotTexts.withS(_c.ins)}.';

  @override
  String get offlineRetry => '$_noLink Проверьте интернет и попробуйте снова.';

  @override
  String get offline => _noLink;

  @override
  String get offlineAddress => '$_noLink Проверьте адрес и интернет.';

  @override
  String get offlineInternet => '$_noLink Проверьте интернет.';

  @override
  String get notConnectedYet => _gender == null
      ? 'Подключения ${GenericSlotTexts.withK(_c.dat)} ещё нет.'
      : '$_head ещё не $_connectedWord.';

  @override
  String get connectFirst => 'Сначала подключите ${_c.acc}.';

  @override
  String serverSaid(String said) => _gender == null
      ? 'Ответ ${_c.gen}: $said'
      : '$_head ${_past('ответил')}: $said';

  @override
  String serverError(int status) => _gender == null
      ? 'Ответ ${_c.gen} — ошибка $status.'
      : '$_head ${_past('ответил')} ошибкой $status.';

  @override
  String get noPasswordSent => _gender == null
      ? 'Пароль от ${_c.gen} не пришёл — сделайте новую ссылку.'
      : '$_head не ${_past('прислал')} пароль — сделайте новую ссылку.';

  @override
  String get keyWrongShape =>
      'Ключ ${_c.gen} не того вида — обновите страницу приложения.';

  @override
  String connected(String login, String who) {
    final head = _gender == null
        ? 'Подключение ${GenericSlotTexts.withK(_c.dat)} готово'
        : '$_head $_connectedWord';
    if (login.isEmpty) return '$head.';
    return who.isEmpty ? '$head: $login.' : '$head: $login ($who).';
  }

  @override
  String get connectedByPassword => _gender == null
      ? 'Подключение ${GenericSlotTexts.withK(_c.dat)} готово: по паролю.'
      : '$_head $_connectedWord по паролю.';

  @override
  String get noWho => '$_head не ${_plural ? 'говорят' : 'говорит'}, кто '
      'вошёл.';

  @override
  String get enterPassword => 'Введите пароль ${_c.gen}.';

  @override
  String get cannotCheck =>
      'Пароль не проверить: в описании нет команды по паролю ${_c.gen}.';

  @override
  String get passwordRejected => _gender == null
      ? 'Пароль для ${_c.gen} не принят.'
      : '$_head не ${_past('принял')} пароль.';

  @override
  String get busyAttempts => _gender == null
      ? 'Слишком много попыток — подождите несколько минут.'
      : '$_head ${_plural ? 'просят' : 'просит'} подождать: слишком много '
          'попыток. Попробуйте через несколько минут.';

  @override
  String notThisApp(int status) =>
      'По этому адресу ${_c.nom} не ${_plural ? 'отвечают' : 'отвечает'} '
      '(ответ $status). Проверьте адрес.';

  @override
  String get notJson =>
      'По этому адресу отвечает не ${_c.nom} (ответ не JSON). Проверьте '
      'адрес.';

  @override
  String get addressLabel => 'Адрес ${_c.gen}';

  @override
  String passwordLabel(String? fromDescription) {
    final label = fromDescription?.trim() ?? '';
    return label.isEmpty ? 'Пароль ${_c.gen}' : label;
  }

  @override
  String manualHint({required bool staff}) => staff
      ? 'Адрес и пароль ${_c.gen}. Логин и пароль сотрудника — по '
          'желанию. Пароль сотрудника не сохраняется — только личный ключ.'
      : 'Адрес и пароль ${_c.gen}. Пароль хранится только на этом '
          'устройстве.';

  @override
  String get linkHint =>
      'Ссылку входа или QR даёт само приложение. Вставьте её сюда. Код '
      'одноразовый и сработает только один раз: не открывайте ссылку в '
      'браузере.';

  @override
  String get staffHint =>
      'Часть данных видна только под своим логином. Можно и по ссылке '
      'выше.';

  @override
  String get logoutBody => 'Пароль и личный ключ будут удалены с '
      'устройства. Адрес и описание останутся.';

  @override
  String get beforeConnect => 'Закреплённое описание — до подключения';

  @override
  String get cardTitle => title;

  @override
  String get cardPartial => _gender == null
      ? 'Ответ ${_c.gen} — не весь: уточните запрос.'
      : '$_head ${_past('показал')} не всё — уточните запрос.';

  @override
  String get cardOpenIn => 'Открыть $_here';

  @override
  String get cardOpen => 'Открыть ${_c.acc}';

  @override
  String get actionSending => 'Отправляю $_to…';

  @override
  String get actionUnknown => 'Итог неизвестен — «Проверить» спросит '
      '${_c.acc}';
}
