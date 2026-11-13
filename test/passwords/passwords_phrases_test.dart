// Фразы навыка «Пароли» (ADR-014, раздел 6): чистый разбор без хранилища.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/utterance.dart';
import 'package:local_assistant/core/skills/passwords/passwords_phrases.dart';
import 'package:local_assistant/core/skills/passwords/service_aliases.dart';

PasswordCommand? parse(String text) => PasswordPhrases.parse(
      Utterance.analyze(text, now: DateTime(2026, 11, 2, 16, 30)),
    );

void main() {
  group('команды и сервис', () {
    const cases = <String, (String, String?)>{
      'забыл пароль от почты': (PasswordCommands.hint, 'почта'),
      'Не помню пароль от Госуслуг!': (PasswordCommands.hint, 'Госуслуги'),
      'какой у меня пароль от сбера?': (PasswordCommands.hint, 'Сбер'),
      'Какой пароль от Тинькоффа': (PasswordCommands.hint, 'Т-Банк'),
      'забыл пароль от «Старый форум»': (PasswordCommands.hint, 'Старый форум'),
      'забыл пароль от почты, пожалуйста': (PasswordCommands.hint, 'почта'),
      'пароль от почты забыл': (PasswordCommands.hint, 'почта'),
      'покажи пароль от почты': (PasswordCommands.reveal, 'почта'),
      'дай пароль от wi-fi': (PasswordCommands.reveal, 'Wi-Fi'),
      'скопируй пароль от вк': (PasswordCommands.copy, 'ВКонтакте'),
      'запомни пароль от озона': (PasswordCommands.add, 'Озон'),
      'сохрани новый пароль': (PasswordCommands.add, null),
      'смени пароль от почты': (PasswordCommands.change, 'почта'),
      'удали пароль от Старого Форума': (
        PasswordCommands.delete,
        'Старого Форума',
      ),
      'какой у меня логин от госуслуг': (PasswordCommands.login, 'Госуслуги'),
      'на какую почту я регистрировался в озоне': (
        PasswordCommands.login,
        'Озон',
      ),
      'забыл мастер-пароль': (PasswordCommands.masterForgot, null),
      'не помню пароль от хранилища': (PasswordCommands.masterForgot, null),
      'открой пароли': (PasswordCommands.open, null),
      'запри пароли': (PasswordCommands.lock, null),
      'какие пароли сохранены': (PasswordCommands.list, null),
      'потерял телефон': (PasswordCommands.lostDevice, null),
      'как восстановить пароль от сайта': (PasswordCommands.recoverHelp, null),
      'что умеешь с паролями': (PasswordCommands.help, null),
      'сгенерируй пароль': (PasswordCommands.generate, null),
      'проверь мои пароли': (PasswordCommands.check, null),
      'потренируй меня': (PasswordCommands.train, null),
      'потренируй меня в паролях': (PasswordCommands.train, null),
      // Тренировка названной записи — сервис из фразы, не первая в очереди.
      'проверь, помню ли я пароль от госуслуг': (
        PasswordCommands.train,
        'Госуслуги',
      ),
      'проверить, помню ли я пароль от wifi': (PasswordCommands.train, 'Wi-Fi'),
      // «Нужен пароль от …» — забытый пароль, а не новый.
      'мне нужен пароль от почты': (PasswordCommands.hint, 'почта'),
      'нужен пароль от wifi': (PasswordCommands.hint, 'Wi-Fi'),
      'нужен пароль на 20 символов': (PasswordCommands.generate, null),
      'нужен новый случайный пароль': (PasswordCommands.generate, null),
      'сделай копию паролей': (PasswordCommands.backup, null),
      'импортируй пароли из браузера': (PasswordCommands.import, null),
      'импорт паролей из браузера': (PasswordCommands.import, null),
      'перенеси пароли из firefox': (PasswordCommands.import, null),
      'сделай резервную копию паролей': (PasswordCommands.backup, null),
      'резервная копия паролей': (PasswordCommands.backup, null),
      'восстанови пароли из копии': (PasswordCommands.restore, null),
      'восстановить хранилище из резервной копии': (
        PasswordCommands.restore,
        null,
      ),
    };
    for (final MapEntry(key: text, value: (cmd, query)) in cases.entries) {
      test(text, () {
        final command = parse(text);
        expect(command, isNotNull);
        expect(command!.cmd, cmd);
        expect(command.query, query);
        expect(command.implicit, isFalse);
        expect(command.confidence, greaterThanOrEqualTo(0.75));
      });
    }
  });

  test('«потренируй меня …» о другом — не тренировка паролей', () {
    for (final text in <String>[
      'потренируй меня в английском',
      'потренируй меня отжиматься',
    ]) {
      expect(parse(text), isNull, reason: text);
    }
  });

  test('чужая просьба придумать пароль — не генератор', () {
    final command = parse('маша просила придумать пароль для wifi');
    expect(command?.cmd, isNot(PasswordCommands.generate));
    expect(
      PasswordPhrases.looksLike(
        Utterance.analyze(
          'маша просила придумать пароль для wifi',
          now: DateTime(2026, 11, 2),
        ),
      ),
      isTrue,
    );
  });

  test('чужая просьба в настоящем времени — не команда', () {
    for (final text in <String>[
      'мама просит придумать пароль',
      'мама хочет придумать пароль',
      'коллеги просят придумать пароль для wifi',
      'папа спрашивает пароль от почты',
      'сын предлагает придумать пароль',
    ]) {
      expect(parse(text), isNull, reason: text);
    }
    // Своя просьба — по-прежнему генератор.
    expect(parse('привет, придумай пароль')?.cmd, PasswordCommands.generate);
    expect(parse('придумай пароль')?.cmd, PasswordCommands.generate);
  });

  test('«у меня от почты» — сервис после предлога', () {
    for (final text in <String>[
      'нужен пароль у меня от почты',
      'нужен пароль от почты',
    ]) {
      final command = parse(text)!;
      expect(command.cmd, PasswordCommands.hint, reason: text);
      expect(command.query, 'почта', reason: text);
    }
  });

  test('«без цифр и символов» выключает и цифры, и символы', () {
    for (final text in <String>[
      'сгенерируй пароль без цифр и символов',
      'сгенерируй пароль без символов и цифр',
      'сгенерируй пароль без символов, цифр',
    ]) {
      final options = parse(text)!.options;
      expect(options['symbols'], false, reason: text);
      expect(options['digits'], false, reason: text);
    }
    expect(
      parse('сгенерируй пароль без похожих и символов')!.options,
      containsPair('noLookAlike', true),
    );
    expect(
      parse('сгенерируй пароль без цифр')!.options.containsKey('symbols'),
      isFalse,
    );
  });

  test('«пароль» одним словом — справка, уступает всему', () {
    final command = parse('пароль')!;
    expect(command.cmd, PasswordCommands.help);
    expect(command.implicit, isTrue);
    expect(command.confidence, PasswordPhrases.firm);
  });

  test('маркеры задачи — фраза уходит задачам', () {
    for (final text in <String>[
      'напомни завтра сменить пароль от почты',
      'пароль от wifi записать в задачи',
      'сменить пароль от почты завтра',
    ]) {
      final command = parse(text)!;
      expect(command.implicit, isTrue, reason: text);
      expect(command.confidence, PasswordPhrases.yielded, reason: text);
      // Но сетевым коннекторам её всё равно не отдают.
      expect(
        PasswordPhrases.looksLike(
          Utterance.analyze(text, now: DateTime(2026, 11, 2)),
        ),
        isTrue,
        reason: text,
      );
    }
    // «пароль на 24 символа» — не срок.
    expect(parse('пароль на 24 символа')!.implicit, isFalse);
  });

  test('не фразы о паролях', () {
    for (final text in <String>[
      'купить хлеб',
      'пароль — это важно',
      'потерял ключи от машины',
      'где лежит 64115',
      'покажи задачи',
      'закрой задачу «Купить хлеб»',
      'привет',
    ]) {
      expect(parse(text), isNull, reason: text);
    }
  });

  test('в разборе нет значения после сервиса', () {
    // «пароль от почты Kx9…» — SecretGuard скроет токен до маршрутизатора;
    // разбор сам по себе тоже не отдаёт ничего, кроме сервиса.
    final command = parse('забыл пароль от почты')!;
    expect('$command', 'PasswordCommand(passwords.hint)');
  });

  group('ServiceAliases', () {
    test('синонимы и падежи', () {
      expect(ServiceAliases.display('почты'), 'почта');
      expect(ServiceAliases.display('тинькоффа'), 'Т-Банк');
      expect(ServiceAliases.display('Госуслуг'), 'Госуслуги');
      expect(ServiceAliases.display('Мой Форум'), 'Мой Форум');
      expect(ServiceAliases.needles('вк'), contains('вконтакте'));
    });

    test('нестрогое сравнение с названиями записи', () {
      expect(ServiceAliases.matches('почта', <String>['Gmail']), isTrue);
      expect(
        ServiceAliases.matches('госуслуги', <String>['Госуслуги']),
        isTrue,
      );
      expect(
        ServiceAliases.matches('гоcуслуги', <String>['Госуслуги']),
        isTrue,
      );
      expect(ServiceAliases.matches('форума', <String>['Форум']), isTrue);
      expect(ServiceAliases.matches('озон', <String>['ozon.ru']), isTrue);
      expect(ServiceAliases.matches('почта', <String>['Форум']), isFalse);
      expect(ServiceAliases.matches('вк', <String>['Озон']), isFalse);
    });

    test('расстояние Левенштейна', () {
      expect(ServiceAliases.distance('форум', 'форум'), 0);
      expect(ServiceAliases.distance('форум', 'фарум'), 1);
      expect(ServiceAliases.distance('', 'abc'), 3);
      expect(ServiceAliases.distance('kitten', 'sitting'), 3);
    });
  });

  // Фразы второго корпуса (generated.jsonl): обращение, порядок слов,
  // синонимы. Каждое правило — с примерами, которые навык брать не должен:
  // задачи, беседа, склад, калькулятор и чужие дела не перехватываются.
  group('обращение и вежливость не мешают', () {
    const cases = <String, String>{
      'Лиорио, запри пароли': PasswordCommands.lock,
      'Лиорио, открой хранилище паролей': PasswordCommands.open,
      'удали пароль от озона, Лиорио': PasswordCommands.delete,
      'заблокируй хранилище пожалуйста': PasswordCommands.lock,
      'запри хранилище, иду спать': PasswordCommands.lock,
      'Лиорио, заблокируй доступ к паролям': PasswordCommands.lock,
      'разблокируй кошелёк с паролями, пожалуйста': PasswordCommands.open,
      'нужно зайти в пароли, открой пожалуйста': PasswordCommands.open,
      'у меня новый пароль от сбера, Лиорио, записать его куда?':
          PasswordCommands.add,
      'список всех пароллей': PasswordCommands.list,
    };
    for (final MapEntry(key: text, value: cmd) in cases.entries) {
      test(text, () => expect(parse(text)?.cmd, cmd));
    }
    test('одно имя — не команда', () => expect(parse('Лиорио'), isNull));
    test('«закрой задачу, …» — не хранилище', () {
      expect(parse('закрой задачу про пароли'), isNull);
    });
  });

  group('логин и почта для входа', () {
    const cases = <String, String?>{
      'лиорио, на какой имейл регался в озоне': 'Озон',
      'Лиорио, вспомни на какой почтовый адрес я ходил в сбер': 'Сбер',
      'какой у меня логин приписан к госуслугам': 'Госуслуги',
      'какой логин я вбивал в рабочий ноутбук при первом входе': null,
      'напоминай мне логин от вк пожалуйста': 'ВКонтакте',
      'лиорио, где мой логин от озона': 'Озон',
      'забыл на какой почте регистрировался в вк': 'ВКонтакте',
      'вк какой там логин?': 'ВКонтакте',
      'Лиорио а я на каком логине сижу в банке': null,
      'напомни почту для рабочего ноутбука': null,
      'почту от озона напомни': 'Озон',
      'на какой почте висит мой аккаунт в сбере': null,
      'подскажи адрес почты для входа в озон': 'Озон',
      'какая почта привязана к госуслугам?': 'Госуслуги',
      'Лиорио, на что зарегистрирован сбер?': 'Сбер',
      'подскажи на какую почту я ставил озон': 'Озон',
      'забыл под каким именем зашел в почту': 'почта',
      'не помню почту для вк': 'ВКонтакте',
      'какой у меня аккаунт в госуслугах?': 'Госуслуги',
    };
    for (final MapEntry(key: text, value: service) in cases.entries) {
      test(text, () {
        final command = parse(text);
        expect(command?.cmd, PasswordCommands.login);
        expect(command?.implicit, isFalse);
        if (service != null) expect(command?.query, service);
      });
    }
    test('не вопрос о входе', () {
      // Без глагола входа и без «логина» — не о нём.
      expect(parse('на какую почту отправить отчёт'), isNull);
      expect(parse('на каком сайте я регистрировался'), isNull);
      expect(parse('под каким именем записать задачу'), isNull);
      // «Напомни почту проверить» — задача: нет предлога и сервиса.
      expect(parse('напомни почту проверить'), isNull);
    });
  });

  group('потерянное и новое устройство', () {
    const lost = <String>[
      'а если телефон украли и хранилище заблокировано — есть шанс что-то '
          'восстановить?',
      'телефон разбился, как достать пароли?',
      'мобила сломалась, пароли пропали',
      'что делать с паролями если телефон потерян',
      'телефон утопил в кофе, хранилище не запустилось, что теперь с '
          'паролями от почты и вк?',
      'телефон украли и пароль от сбера в памяти пропал, что делать теперь',
      'Лиорио, разбил экран на телефоне и не могу зайти в хранилище, что '
          'делать?',
      'как переставить пароли на новый ноутбук?',
      'как перенести хранилище на новый ноутбук, если старый уже не работает?',
      'сменил телефон на другой, как перенести все пароли',
      'переезжаю на рабочий ноутбук, а пароли в хранилище на телефоне, как '
          'их вытащить?',
      'Лиорио, а при переезде на другой телефон мастер пароль тот же '
          'остаётся?',
      // Без слова о паролях — только с вопросом, как вернуть данные.
      'Лиорио, потерял смартфон, как вернуть доступ к данным?',
      'Лиорио, аппарат потерял, как восстановить всё?',
      'купил новый ноут, как перенести всё туда?',
      'Лиорио, сменил ноут, нужно восстановить доступ',
      'нужно перенести всё из старого ноута в новый, подсказать как?',
    ];
    for (final text in lost) {
      test(text, () => expect(parse(text)?.cmd, PasswordCommands.lostDevice));
    }
    test('не переезд и не потеря', () {
      // Пароль от устройства — подсказка, а не потеря.
      expect(
        parse('забыл пароль от нового ноутбука')?.cmd,
        PasswordCommands.hint,
      );
      expect(parse('потерял пароль от телефона'), isNull);
      expect(
        parse('сменил пароль телефона')?.cmd,
        isNot(PasswordCommands.lostDevice),
      );
      // Настройка, а не переезд.
      expect(parse('купил новый телефон, поставь пароль'), isNull);
      // Без слова о паролях и без вопроса о данных — задача.
      expect(parse('разбил телефон, нужно купить новый'), isNull);
      expect(parse('купить чехол, потерял телефон'), isNull);
      expect(parse('потерял телефон, нужно перенести все контакты'), isNull);
      expect(parse('перенос данных на новый комп'), isNull);
    });
  });

  group('мастер-пароль и хранилище не открывается', () {
    const cases = <String>[
      'Лиорио, что делать если мастер пароль вылетел из головы?',
      'хранилище не открывается после обновления, мастер пароль вроде не менял',
      'мастер-пароль пропал из головы, хранилище не открывается уже третий '
          'день',
      'как вспомнить мастер пароль?',
      'мастер пароль забыла, помоги',
      'как восстановить доступ если забыл главный код?',
      'мастер пароль сбросить можно или хранилище стёрется полностью?',
      'Лиорио, доступ к хранилищу пропал, не вхожу',
      'не могу зайти в сейф, подсказка не помогает',
    ];
    for (final text in cases) {
      test(text, () => expect(parse(text)?.cmd, PasswordCommands.masterForgot));
    }
    test('не забытый мастер-пароль', () {
      expect(
        parse('смени мастер-пароль')?.cmd,
        isNot(PasswordCommands.masterForgot),
      );
      expect(parse('забыл главный код от домофона'), isNull);
      // Вопрос об импорте и тренировка важнее.
      expect(
        parse('а импорт из старого хранилища возможен если мастер пароль от '
                'него не помню?')
            ?.cmd,
        PasswordCommands.help,
      );
      expect(
        parse('а есть ли какая то тренировка памяти чтобы не забывать мастер '
                'пароль?')
            ?.cmd,
        PasswordCommands.train,
      );
    });
  });

  group('генератор', () {
    const cases = <String, Map<String, Object?>>{
      'сделай длинный пароль без цифр': <String, Object?>{'digits': false},
      'Лиорио, сделай пароль на 15 знаков': <String, Object?>{'length': 15},
      'сделай пароль из 4 слов': <String, Object?>{'mode': 'words', 'words': 4},
      'сделай простой пароль для вк': <String, Object?>{},
      'нужен запоминающийся пароль для почты': <String, Object?>{
        'mode': 'words',
      },
      'сгенерируй на 16 символов без цифр, для вк хочу': <String, Object?>{
        'length': 16,
        'digits': false,
      },
      'нужен на 20 символов, только буквы и цифры': <String, Object?>{
        'length': 20,
        'symbols': false,
      },
      'нужен для wifi на 24 символа, с заглавными и цифрами': <String, Object?>{
        'length': 24,
      },
      'придумай из 5 слов для роутера, чтобы в голову уложилось':
          <String, Object?>{'mode': 'words', 'words': 5},
      'придумай из 6 слов пароль': <String, Object?>{'words': 6},
      'хочеться пароль который легко запомнить, на 12 символов, Лиорио':
          <String, Object?>{'length': 12},
    };
    for (final MapEntry(key: text, value: options) in cases.entries) {
      test(text, () {
        final command = parse(text);
        expect(command?.cmd, PasswordCommands.generate);
        for (final MapEntry(:key, :value) in options.entries) {
          expect(command!.options[key], value, reason: key);
        }
      });
    }
    test('не генератор', () {
      // Настройка устройства, а не новый пароль.
      expect(parse('сделай пароль на wifi'), isNull);
      // Существительное после глагола — не пароль.
      expect(parse('придумай стих из 5 слов'), isNull);
      expect(parse('нужен текст на 200 символов'), isNull);
      expect(parse('придумай название из 3 слов для озона'), isNull);
      // «Из N слов» без классов символов и без сервиса.
      expect(parse('придумай из 5 слов для мамы'), isNull);
      // О другом человеке.
      expect(parse('Маша просила сделать простой пароль для вк'), isNull);
      // «Нужен пароль от почты» — по-прежнему подсказка.
      expect(parse('нужен пароль от почты')?.cmd, PasswordCommands.hint);
    });
  });

  group('проверка надёжности', () {
    const cases = <String>[
      'какие пароли надо сменить',
      'а есть у меня вообще слабые пароли в хранилище?',
      'нет ли одинаковых между сбером и почтой?',
      'посмотри насколько надёжный мой пароль от госуслуг, пожалуйста',
      'насколько надёжен мой пароль от озона, проверь пожалуйста',
      'Лиорио, а мой пароль от банка не слишком простой?',
      'есть ли у меня повторы в паролях',
      'поставь оценку надёжности моему паролю от вк, интересно',
      'какие сервисы у меня на один и тот же пароль, скажи',
      'проверь надёжность пароля от почты',
      'найди слишком простые пароли',
      'лиорио, глянь какие пароли плохие',
    ];
    for (final text in cases) {
      test(text, () => expect(parse(text)?.cmd, PasswordCommands.check));
    }
    test('не проверка', () {
      expect(
        parse('придумай простые пароли')?.cmd,
        isNot(PasswordCommands.check),
      );
      expect(parse('нет ли одинаковых между Машей и Петей'), isNull);
      expect(parse('найди простые решения'), isNull);
      // Задача: «напомни» уступает задачам.
      expect(
        parse('напомни проверить надёжность пароля от почты')?.implicit,
        isTrue,
      );
    });
  });

  group('копия, импорт и справка', () {
    const cases = <String, String>{
      'бэкап паролей сделай': PasswordCommands.backup,
      'импорт паролей из резервной копии': PasswordCommands.restore,
      'импортируй пароли из файла': PasswordCommands.import,
      'Лиорио, можно импортировать пароли из файла?': PasswordCommands.import,
      'хочу импорт из браузера': PasswordCommands.import,
      'перенеси всё из сафари': PasswordCommands.import,
      'импортируй всё из текстовика': PasswordCommands.import,
      'я скачал файл с паролями, куда его теперь грузить?':
          PasswordCommands.import,
      'перенести пароли из яндекса сюда, реально?': PasswordCommands.import,
      'импорт из хрома, как это вообще работает?': PasswordCommands.help,
      'импорт из оперы есть или только из хрома?': PasswordCommands.help,
      'после импорта из сафари не всё открылось, что делать?':
          PasswordCommands.help,
      'Лиорио, можно импортировать из двух браузеров за один раз?':
          PasswordCommands.help,
      'копия хранилища не открывается, в чём может быть дело':
          PasswordCommands.help,
      'Лиорио, как сделать бэкап хранилища?': PasswordCommands.help,
      'как часто лучше копировать хранилище, а то боюсь потерять':
          PasswordCommands.help,
      'Лиорио, помоги восстановить доступ к паролям':
          PasswordCommands.recoverHelp,
    };
    for (final MapEntry(key: text, value: cmd) in cases.entries) {
      test(text, () => expect(parse(text)?.cmd, cmd));
    }
    test('без опоры на пароли — общая копия приложения, не навык', () {
      expect(parse('Лиорио, сделай бэкап'), isNull);
      expect(parse('восстановление из бэкапа'), isNull);
      expect(parse('как восстановить всё из бэкапа?'), isNull);
      expect(parse('бэкап в облако можно делать или только локально?'), isNull);
      expect(parse('импорт задач из файла'), isNull);
      expect(parse('билеты в оперу на завтра'), isNull);
      // «Скопируй …, можно?» — не вопрос о копии.
      expect(parse('скопируй пароль от почты'), isNotNull);
    });
  });

  group('показать, подсказать, сменить, добавить', () {
    const cases = <String, String>{
      'выдай мне пароль от госуслуг': PasswordCommands.reveal,
      'отдай пароль от сбера': PasswordCommands.reveal,
      'давай пароль от рабочего ноутбука': PasswordCommands.reveal,
      'скини пароль от роутера': PasswordCommands.reveal,
      'скинь пж пароль от вк': PasswordCommands.reveal,
      'а можно скинуть пароль от госуслуг?': PasswordCommands.reveal,
      'хочу увидеть пароль от рабочего ноутбука': PasswordCommands.reveal,
      'нужен пароль от почты, покажи': PasswordCommands.reveal,
      'пароль от вк, скопируй': PasswordCommands.copy,
      'помоги вспомнить пароль от банка, плиз': PasswordCommands.hint,
      'вспомнить пароль от озона не могу': PasswordCommands.hint,
      'помнишь какой пароль я записывала от госуслуг?': PasswordCommands.hint,
      'напомните пожалуйста пароль от сбера': PasswordCommands.hint,
      'пароль от вк напомни': PasswordCommands.hint,
      'хочу изменить пароль от банка': PasswordCommands.change,
      'переключи пароль от почты на новый, старый уже не актуален':
          PasswordCommands.change,
      'Лиорио, поменялся пароль от банка, обнови запись пожалуйста':
          PasswordCommands.change,
      'добавить пароль от банка': PasswordCommands.add,
      'новый пароль от сбера сохрани': PasswordCommands.add,
      'хочу записать пароль от wifi, добавь в хранилище': PasswordCommands.add,
      'сохрани мне доступ к рабочему ноутбуку': PasswordCommands.add,
      'что у меня в паролях': PasswordCommands.list,
      'сколько у меня всего паролей в хранелище?': PasswordCommands.list,
      'сколько записей в паролях сейчас вообще?': PasswordCommands.list,
      'покажи список паролей': PasswordCommands.list,
      'тренировка памяти по паролю от роутера': PasswordCommands.train,
      'режим тренировки памяти пожалуйста': PasswordCommands.train,
      'хочу потренировать память на пароли': PasswordCommands.train,
      'Лиорио, давай проверим как я помню пароли': PasswordCommands.train,
    };
    for (final MapEntry(key: text, value: cmd) in cases.entries) {
      test(text, () {
        final command = parse(text);
        expect(command?.cmd, cmd);
        expect(command?.implicit, isFalse);
      });
    }
    test('о другом человеке или деле — не команда навыка', () {
      // Получатель после глагола показа.
      expect(parse('скинь Пете пароль от wifi'), isNull);
      expect(parse('отдай маме пароль от wifi'), isNull);
      // «Напомнить маме сменить пароль» — дело для другого человека.
      expect(
        parse('напомнить маме сменить пароль от почты, она всё забывает'),
        isNull,
      );
      expect(parse('Маша просила сменить пароль от почты'), isNull);
      // Отглагольное действие перед паролем — название дела.
      expect(
        parse('лиорио, в календарь: смена пароля от госуслуг в середине марта'),
        isNull,
      );
      // Инфинитив чужого глагола перед паролем — по-прежнему дело.
      expect(parse('узнать пароль от wifi'), isNull);
      expect(parse('хочу посмотреть кино'), isNull);
      // Глагол напоминания в конце после инфинитива — задача.
      expect(parse('пароль от вк поменять, напомни')?.implicit, isTrue);
      // Слова разговора — не чужое дело.
      expect(
        parse('можешь поменять пароль от почты')?.cmd,
        PasswordCommands.change,
      );
      expect(
        parse('слушай, покажи пароль от почты')?.cmd,
        PasswordCommands.reveal,
      );
      // Без слова о паролях «запись про X» — не навык.
      expect(parse('убери запись про роутер'), isNull);
      expect(parse('удали запись про встречу'), isNull);
      expect(parse('тренировка в зале завтра'), isNull);
      expect(parse('потренируй меня в английском'), isNull);
    });
  });

  group('ревью: фразы не о своих паролях навык не берёт', () {
    // Ложные срабатывания прошлого раунда: дела с инфинитивом, темы
    // «про пароли», почта и адреса людей, техника, тексты с числом
    // символов, физический сейф, перенос закладок, склад.
    const texts = <String>[
      // Проверка: тема или дело, а не просьба.
      'написать статью про одинаковые пароли',
      'надо объяснить сотрудникам, почему простые пароли опасны',
      'провести лекцию для бабушек про слабые пароли',
      'подготовить доклад о надёжности паролей',
      'прочитать статью о надёжности паролей',
      'узнать, есть ли слабые пароли',
      // Логин: почта и адреса людей и посылок, почтовое отделение.
      'узнать, какой имейл у нового клиента',
      'уточнить, какая почта у бухгалтера',
      'узнать, на какой адрес была доставка',
      'где почта в Химках',
      'где почта в нашем районе',
      'где почта для отправки посылок',
      'на какой адрес была отправлена посылка',
      'на какую почту был отправлен счёт',
      'на какой адрес был отправлен заказ 120734',
      'какая почта у Ивана',
      'какой адрес почты у Маши',
      'подскажи почту для связи с поддержкой',
      'какой имейл у тебя',
      // Устройство без паролей: техника, магазин, 1С.
      'компьютер сломался, нужно восстановить базу в 1С',
      'ноутбук сломался, надо восстановить базу в 1с',
      'телефон не включается, нужно вернуть всё в магазин',
      'аппарат сломался, надо вернуть всё на склад',
      'кофейный аппарат сломался, нужно вернуть все в магазин',
      'устройство не работает, нужно вернуть всё в сервис',
      'купил телефон, надо вернуть всё в магазин',
      'купил новый ноутбук, нужно перенести данные',
      // Тренировка не паролей.
      'записаться на мастер-класс по тренировке памяти',
      'мастер-класс по тренировке памяти',
      'тренировка памяти для детей',
      'тренировка памяти по английскому',
      // Перенос не паролей.
      'перенеси с хрома закладки',
      'перенеси всё из сафари в заметки',
      'перенеси данные из csv в таблицу',
      'перенеси всё из оперы',
      'забери с оперы',
      // Техника и настоящий сейф.
      'как сбросить главный код на котле',
      'главный код ошибки на котле как сбросить',
      'главное код вспомнить к экзамену',
      'сейф не открывается',
      'доступ к сейфу закрыт',
      'закрой сейф, уходим',
      // Тексты с числом символов.
      'сделай для поста на 280 символов текст',
      'сделай для отчёта аннотацию на 500 символов',
      'нужна для сайта на 2000 знаков статья',
      'хочу для твиттера на 280 символов что-нибудь',
      'придумай на 140 символов слоган',
      'придумай для вк пост из 10 слов',
      // Копии не паролей.
      'копию билетов в оперу можно распечатать?',
      'резервный выход в опере возможен?',
      'можно резервную копию документов сделать в облачном хранилище?',
      'копия ключа от хранилища есть или нет',
      // Склад.
      'сколько записей в хранилище',
    ];
    for (final text in texts) {
      test(text, () => expect(parse(text), isNull));
    }
  });

  group('ревью: общие правила вместо формы одной строки', () {
    const cases = <String, String>{
      // Копия — в любом порядке слов.
      'сделай бэкап паролей': PasswordCommands.backup,
      'создай бэкап паролей': PasswordCommands.backup,
      'сохрани бэкап паролей': PasswordCommands.backup,
      'сделай бэкап хранилища': PasswordCommands.backup,
      'бэкап паролей, сделай': PasswordCommands.backup,
      'бэкап паролей сделай': PasswordCommands.backup,
      // Импорт из браузера и файла — и инфинитивом; txt и csv в приложении
      // загружает только импорт паролей.
      'хочу перенести данные из хрома': PasswordCommands.import,
      'хочу импортировать данные из хрома': PasswordCommands.import,
      'перенеси данные из хрома': PasswordCommands.import,
      'импортируй всё из текстовика': PasswordCommands.import,
      'Лиорио, хочу загрузить список из обычного txt': PasswordCommands.import,
      'загрузи всё из txt': PasswordCommands.import,
      'импорт из оперы': PasswordCommands.import,
      // Инфинитив команды навыка — команда.
      'стереть пароль от вк': PasswordCommands.delete,
      'удалить пароль от вк': PasswordCommands.delete,
      'показать пароль от вк': PasswordCommands.reveal,
      'сменить пароль от вк': PasswordCommands.change,
      'добавить пароль от банка': PasswordCommands.add,
      'скопировать пароль от вк': PasswordCommands.copy,
      // Тренировка памяти без другого предмета.
      'тренировка памяти': PasswordCommands.train,
      'тренировка памяти посложнее, пожалуйста, я уже простые запоминаю':
          PasswordCommands.train,
      'тренировка памяти по паролям': PasswordCommands.train,
      // Сейф — целой фразой, как раньше.
      'открой сейф': PasswordCommands.open,
      'закрой сейф': PasswordCommands.lock,
      'не могу зайти в сейф, подсказка не помогает':
          PasswordCommands.masterForgot,
      'забыл главный код': PasswordCommands.masterForgot,
      'главный код вылетел из головы': PasswordCommands.masterForgot,
      // Почта для входа — у сервиса, устройства или с глаголом входа.
      'какая почта для госуслуг': PasswordCommands.login,
      'напомни почту для рабочего ноутбука': PasswordCommands.login,
      'подскажи на какой почте я в озн был': PasswordCommands.login,
      'забыл на какой почте регистрировался в вк': PasswordCommands.login,
      'забыл какой логин у меня в вк подскажи': PasswordCommands.login,
      // Генератор: параметры, сервис, слово «пароль» в хвосте.
      'сделай для роутера на 20 символов': PasswordCommands.generate,
      'придумай из 6 слов пароль': PasswordCommands.generate,
      'сгенерируй на 16 символов без цифр, для вк хочу':
          PasswordCommands.generate,
      // Устройство: вопрос «как» или доступ.
      'купил новый ноут, как перенести всё туда?': PasswordCommands.lostDevice,
      'Лиорио, сменил ноут, нужно восстановить доступ':
          PasswordCommands.lostDevice,
      'нужно перенести всё из старого ноута в новый, подсказать как?':
          PasswordCommands.lostDevice,
      // Проверка своими словами и инфинитивом самой проверки.
      'проверить, есть ли слабые пароли': PasswordCommands.check,
      'а есть у меня вообще слабые пароли': PasswordCommands.check,
      'сколько записей в хранилище паролей': PasswordCommands.list,
    };
    for (final MapEntry(key: text, value: cmd) in cases.entries) {
      test(text, () => expect(parse(text)?.cmd, cmd));
    }
  });

  test('новые фразы о паролях не видит ни один сетевой коннектор', () {
    // Без слова «пароль»: их прячет от сети сам разбор (looksLike).
    for (final text in <String>[
      'лиорио, на какой имейл регался в озоне',
      'Лиорио, потерял смартфон, как вернуть доступ к данным?',
      'хочу импорт из браузера',
      'сгенерируй на 16 символов без цифр, для вк хочу',
      'режим тренировки памяти пожалуйста',
    ]) {
      expect(
        PasswordPhrases.looksLike(
          Utterance.analyze(text, now: DateTime(2026, 11, 2, 16, 30)),
        ),
        isTrue,
        reason: text,
      );
    }
  });
}
