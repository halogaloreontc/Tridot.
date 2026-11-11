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
}
