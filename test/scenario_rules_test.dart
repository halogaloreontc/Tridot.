import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/due_parser.dart';
import 'package:local_assistant/core/connectors/noun_forms.dart';
import 'package:local_assistant/core/connectors/utterance.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';

/// Правила, которыми закрыты бывшие known_gap корпуса (docs/CORPUS.md):
/// завершение без «заверши», кавычки без команды, «в обед», «на этой
/// неделе», повторение, цели переноса, команда в конце фразы, заглавные,
/// буквы-двойники и опечатки в командах.
void main() {
  // Понедельник.
  final monday = DateTime(2026, 11, 2, 16, 30);
  ParsedCommand parse(String text, {DateTime? now}) =>
      ScenarioParser(clock: FixedClock(now ?? monday)).parse(text);

  group('завершение', () {
    test('«закрой задачу по …» — «по» убирается, начало в именительном', () {
      final command = parse('Закрой задачу по подготовке презентации');
      expect(command.intent, CommandIntent.completeTask);
      expect(command.targetQuery, 'Подготовка презентации');
    });

    test('«закрой «…»» — точное название', () {
      final command = parse('Закрой «Заказать подарок»');
      expect(command.intent, CommandIntent.completeTask);
      expect(command.title, 'Заказать подарок');
      expect(command.targetQuery, isNull);
    });

    test('«закрой» без «задачи» — только не бытовое', () {
      expect(parse('закрой окно').intent, CommandIntent.unknown);
      expect(parse('закрой дверь').intent, CommandIntent.unknown);
      expect(parse('закрой вкладку с почтой').intent, CommandIntent.unknown);
      expect(parse('закрой').intent, CommandIntent.unknown);
      expect(parse('магазин закрыт').intent, CommandIntent.unknown);
      expect(parse('закрой отчёт по проекту').targetQuery, 'Отчёт по проекту');
    });

    test('«я закрыла …» — сообщение о сделанном', () {
      final command = parse('я закрыла отчёт по проекту');
      expect(command.intent, CommandIntent.completeTask);
      expect(command.targetQuery, 'Отчёт по проекту');
      expect(command.pastTense, isTrue);
    });

    test('«всё, задача закрыта» — выбранная задача', () {
      final command = parse('всё, задача закрыта');
      expect(command.intent, CommandIntent.completeTask);
      expect(command.targetQuery, isNull);
    });

    test('«пометь готовым», «отметь как завершённое», «отметь что сдал»', () {
      expect(parse('пометь готовым задачу про ремонт').targetQuery, 'Ремонт');
      expect(
        parse('Отметь как завершенное письмо клиенту').targetQuery,
        'Письмо клиенту',
      );
      expect(
        parse('отметь что сдал отчёт по проекту').targetQuery,
        'Отчёт по проекту',
      );
      expect(parse('отметить юбилей').intent, CommandIntent.unknown);
    });

    test('«поставь галочку на …», «отметил …»', () {
      final tick = parse('Поставь галочку на звонить стоматологу');
      expect(tick.intent, CommandIntent.completeTask);
      expect(tick.targetQuery, 'Звонить стоматологу');
      final marked = parse('Отметил забрать вещи из химчистки');
      expect(marked.intent, CommandIntent.completeTask);
      expect(marked.targetQuery, 'Забрать вещи из химчистки');
      expect(parse('поставь чайник').intent, CommandIntent.unknown);
    });

    test('«по X всё готово», «с X всё, сделано»', () {
      expect(parse('По тренировке всё готово').targetQuery, 'Тренировка');
      // «С» перед целью убирается; творительный падеж не приводится.
      expect(parse('С врачом всё, сделано').targetQuery, 'Врачом');
      expect(parse('с отчётом всё готово').targetQuery, 'Отчётом');
      // «По» остаётся, если слово после него не привести.
      expect(parse('по отчёту всё, сделано').targetQuery, 'По отчёту');
    });

    test('«про» перед инфинитивом убирается, дата после «про» — цель', () {
      expect(
        parse('заверши задачу про позвонить подруге').targetQuery,
        'Позвонить подруге',
      );
      expect(
        parse('заверши задачу про 15 ноября, уже всё сделала').targetQuery,
        'Про 15 ноября',
      );
    });
  });

  group('название в кавычках без команды', () {
    test('со сроком — новая задача с точным названием', () {
      final command = parse('в пятницу в 18 "созвониться с клиентом"');
      expect(command.intent, CommandIntent.createTask);
      expect(command.title, 'созвониться с клиентом');
      expect(command.dueAt, DateTime(2026, 11, 6, 18));
      expect(command.implicit, isTrue);
    });

    test('«нужна задача „…“» и короткое пояснение после кавычек', () {
      expect(
        parse('Нужна задача „Зайти в банк“ послезавтра').title,
        'Зайти в банк',
      );
      final clinic = parse('через час "позвонить в клинику" по записи');
      expect(clinic.title, 'позвонить в клинику');
      expect(clinic.dueAt, DateTime(2026, 11, 2, 17, 30));
    });

    test('одни кавычки, «хочу», отрицание, длинный хвост — не команда', () {
      expect(parse('«купить хлеб»').intent, CommandIntent.unknown);
      expect(parse('"Кто тебя создал?"').intent, CommandIntent.unknown);
      expect(parse('хочу «отпуск»').intent, CommandIntent.unknown);
      expect(
        parse('в понедельник "записаться к стоматологу" не нужно').intent,
        CommandIntent.unknown,
      );
      expect(
        parse('«Купить хлеб» завтра для мамы с папой на даче').intent,
        CommandIntent.unknown,
      );
    });
  });

  group('«в обед»', () {
    test('часть дня 13:00 partOfDay, кончается в 15:00', () {
      final before = parse(
        'добавь позвонить маме в обед',
        now: DateTime(2026, 11, 2, 14, 59),
      );
      expect(before.dueAt, DateTime(2026, 11, 2, 13));
      expect(before.duePrecision, DuePrecision.partOfDay);
      final after = parse(
        'добавь позвонить маме в обед',
        now: DateTime(2026, 11, 2, 15),
      );
      expect(after.dueAt, DateTime(2026, 11, 3, 13));
      expect(after.title, 'Позвонить маме');
    });

    test('с днём, «утром и в обед», «на обед» в названии', () {
      expect(
        parse('в пятницу в обед добавь созвон').dueAt,
        DateTime(2026, 11, 6, 13),
      );
      final both = parse('Добавь задачу выпить витамины завтра утром и в обед');
      expect(both.dueIssue, DueIssue.conflictingTimes);
      expect(both.title, 'Выпить витамины');
      final lunch = parse('добавь сходить на обед с коллегами');
      expect(lunch.title, 'Сходить на обед с коллегами');
      expect(lunch.dueAt, isNull);
    });
  });

  group('«на этой неделе»', () {
    test('пятница этой недели, в выходные — воскресенье', () {
      final command = parse('добавь позвонить на этой неделе');
      expect(command.dueAt, DateTime(2026, 11, 6));
      expect(command.duePrecision, DuePrecision.date);
      expect(command.title, 'Позвонить');
      final saturday = parse(
        'добавь позвонить на этой неделе',
        now: DateTime(2026, 11, 7, 10),
      );
      expect(saturday.dueAt, DateTime(2026, 11, 8));
      expect(
        parse('перенеси отчёт на эту неделю').dueAt,
        DateTime(2026, 11, 6),
      );
    });

    test('без предлога — не срок', () {
      final command = parse('добавь отчёт этой недели');
      expect(command.title, 'Отчёт этой недели');
      expect(command.dueAt, isNull);
    });
  });

  group('повторение', () {
    test('«по пятницам», «каждую пятницу» — ближайшая пятница', () {
      final command = parse('Поставь задачу выносить мусор по пятницам');
      expect(command.title, 'Выносить мусор');
      expect(command.dueAt, DateTime(2026, 11, 6));
      expect(
        parse('добавь бассейн каждую пятницу').dueAt,
        DateTime(2026, 11, 6),
      );
      expect(
        parse(
          'добавь бассейн по понедельникам',
          now: DateTime(2026, 11, 2, 9),
        ).dueAt,
        DateTime(2026, 11, 9),
      );
      final recurring = parse('сделай recurring по пятницам — выносить мусор');
      expect(recurring.intent, CommandIntent.createTask);
      expect(recurring.title, 'Выносить мусор');
      expect(
        const DueParser().parse('по пятницам', monday).recurring,
        isTrue,
      );
    });

    test('вопрос и фраза с существительного — не задача', () {
      expect(
        parse('по пятницам у меня бассейн?').intent,
        CommandIntent.unknown,
      );
      expect(
        parse('по пятницам тренировка в 19:00').intent,
        CommandIntent.unknown,
      );
    });
  });

  group('цели переноса', () {
    test('части суток с прилагательным дня и «на выходной»', () {
      final morning = parse('сдвинь её на завтрашнее утро');
      expect(morning.dueAt, DateTime(2026, 11, 3, 9));
      expect(morning.duePrecision, DuePrecision.partOfDay);
      expect(morning.targetQuery, isNull);
      expect(
        parse('перенести эту задачу на выходной').dueAt,
        DateTime(2026, 11, 7),
      );
    });

    test('число месяца: «на 20 число», «на 18-е», «с 12-го на 18-е»', () {
      expect(
        parse('Отложи "собрать документы для визы" на 20 число').dueAt,
        DateTime(2026, 11, 20),
      );
      expect(parse('перенеси отчёт на 1-е').dueAt, DateTime(2026, 12, 1));
      final both = parse('перенеси отчёт с 12-го на 18-е');
      expect(both.dueAt, DateTime(2026, 11, 18));
      expect(both.targetQuery, 'Отчёт');
      final detached = parse('с встречи 12-го на 18-е перенеси');
      expect(detached.targetQuery, 'Встречи');
      // Без предлога и без нового срока «5-го» — не срок.
      expect(parse('добавь созвон 5-го вечером').title, 'Созвон 5-го вечером');
    });

    test('«на 15:00 пятницы», «на следующую неделю вторник»', () {
      expect(
        parse('перенеси «Сдать проект» на 15:00 пятницы').dueAt,
        DateTime(2026, 11, 6, 15),
      );
      final week =
          parse('перенести встречу с шефом на следующую неделю вторник');
      expect(week.dueAt, DateTime(2026, 11, 10));
      expect(week.dueIssue, DueIssue.none);
      expect(week.targetQuery, 'Встреча с шефом');
    });

    test('без нового срока, в прошлое, «с перенесением»', () {
      final later = parse('сдвинь запись к стоматологу на более позднее время');
      expect(later.targetQuery, 'Запись к стоматологу');
      expect(later.dueAt, isNull);
      expect(
        parse('перенести доклад с завтра на вчера').dueIssue,
        DueIssue.inPast,
      );
      expect(
        parse('перенеси отчёт с завтра на 5 дней назад').dueIssue,
        DueIssue.inPast,
      );
      final noun = parse('с перенесением на четверг пожалуйста');
      expect(noun.intent, CommandIntent.rescheduleTask);
      expect(noun.targetQuery, isNull);
      expect(noun.dueAt, DateTime(2026, 11, 5));
      // «вчера» без предлога — не срок.
      expect(parse('вчера звонил маме').intent, CommandIntent.completeTask);
    });

    test('пояснение после срока и запятой не входит в цель', () {
      expect(
        parse('перенеси встречу на 15 ноября, у меня тогда свободнее')
            .targetQuery,
        'Встреча',
      );
    });
  });

  group('команда в конце фразы', () {
    test('«…, добавь это», «…, запиши», «…, не забудь»', () {
      final shop = parse('Вечером нужно зайти в магазин, добавь это');
      expect(shop.intent, CommandIntent.createTask);
      expect(shop.title, 'Зайти в магазин');
      expect(shop.dueAt, DateTime(2026, 11, 2, 19));
      expect(
        parse('в обед надо сходить в аптеку, запиши').title,
        'Сходить в аптеку',
      );
      final bills = parse('через 2-3 дня оплатить коммуналку, не забудь');
      expect(bills.title, 'Оплатить коммуналку');
      expect(bills.dueIssue, DueIssue.conflictingDays);
      final oven = parse(
        'мне надо через полтора часа выключить духовку, поставь плз',
      );
      expect(oven.title, 'Выключить духовку');
      expect(oven.dueAt, DateTime(2026, 11, 2, 18));
      expect(
        parse('я в обед хочу напомнить прозвонить по страховке, поставь').title,
        'Прозвонить по страховке',
      );
    });

    test('после другой команды — не часть цели; без запятой — не команда', () {
      final move = parse('перенеси на завтра, не забудь');
      expect(move.intent, CommandIntent.rescheduleTask);
      expect(move.targetQuery, isNull);
      expect(parse('не забудь').intent, CommandIntent.unknown);
    });
  });

  group('устойчивость', () {
    test('сообщение заглавными — название обычным предложением', () {
      final command = parse('НАПОМНИ ВСТРЕЧА В 5 КОРПУСЕ СЕГОДНЯ В 15:00');
      expect(command.title, 'Встреча в 5 корпусе');
      expect(command.dueIssue, DueIssue.inPast);
      expect(
        parse('ЗАВЕРШИТЬ ВСТРЕЧУ В 5 КОРПУСЕ СЕГОДНЯ').targetQuery,
        'Встреча в 5 корпусе',
      );
      // Кавычки — точное название и заглавными.
      expect(parse('ДОБАВЬ "КУПИТЬ ХЛЕБ" ЗАВТРА').title, 'КУПИТЬ ХЛЕБ');
      // Не всё заглавными — регистр как написан.
      expect(
        parse('добавь отчёт для ООО Ромашка').title,
        'Отчёт для ООО Ромашка',
      );
    });

    test('латинские буквы-двойники в русских словах', () {
      final u = Utterance.analyze('добавь позвонить завтрa', now: monday);
      expect(u.original, 'добавь позвонить завтра');
      expect(u.due.dueAt, DateTime(2026, 11, 3));
      expect(Utterance.fixHomoglyphs('купить iPhone'), 'купить iPhone');
    });

    test('опечатки только в словах команды', () {
      final command = parse('поставни задачу позвонить +79001112233 в четверг');
      expect(command.intent, CommandIntent.createTask);
      expect(command.title, 'Позвонить +79001112233');
      final typo = parse('добавь задау позвонитть в поликлинику завтрa');
      expect(typo.title, 'Позвонитть в поликлинику');
      expect(typo.dueAt, DateTime(2026, 11, 3));
      expect(
        parse('пеернеси отчёт на завтра').intent,
        CommandIntent.rescheduleTask,
      );
      // Другая форма слова, а не опечатка.
      expect(parse('напомню завтра').intent, CommandIntent.unknown);
      expect(parse('запишу хлеб').intent, CommandIntent.unknown);
    });

    test('предлог перед инфинитивом и «по» в начале цели', () {
      expect(NounForms.nominative('про позвонить маме'), 'позвонить маме');
      expect(
        NounForms.nominative('по подготовке отчёта', allowPo: true),
        'подготовка отчёта',
      );
      expect(NounForms.nominative('по отчёту', allowPo: true), 'по отчёту');
      expect(NounForms.nominative('по подготовке'), 'по подготовке');
    });

    test('настоящие слова рядом с командами — не опечатки', () {
      for (final text in <String>[
        'записи в блоге не грузятся',
        'наполни ванну',
        'наполни бак завтра',
        'запомни, я люблю кофе',
        'запили видео про котиков',
        'отметки за четверть завтра',
        'добавки хочешь?',
        'двинь стол',
        'выполи грядку завтра',
        'обложи налогом завтра',
        'напомин завтра позвонить',
        // Не «отметь» и не «заверши»: завершения здесь нет.
        'отмерь ткань завтра',
        'отмени встречу',
        'заверни подарок завтра',
      ]) {
        expect(parse(text).intent, CommandIntent.unknown, reason: text);
      }
    });

    test('латинское название с русским окончанием не меняется', () {
      expect(Utterance.fixHomoglyphs('в Zoomе'), 'в Zoomе');
      expect(Utterance.fixHomoglyphs('для iPhoneа'), 'для iPhoneа');
      expect(Utterance.fixHomoglyphs('PDFку'), 'PDFку');
      expect(Utterance.fixHomoglyphs('в Excelе'), 'в Excelе');
      expect(Utterance.fixHomoglyphs('SMSку'), 'SMSку');
      expect(Utterance.fixHomoglyphs('Mилк'), 'Милк');
      expect(
        parse('напомни написать в Telegramе Пете').title,
        'Написать в Telegramе Пете',
      );
    });

    test('«не забудь», «поставь» в конце без дела — реплика', () {
      for (final text in <String>[
        'всё понятно, не забудь',
        'я забыл, не забудь',
        'у меня всё, не забудь',
        'чайник, поставь',
      ]) {
        expect(parse(text).intent, CommandIntent.unknown, reason: text);
      }
      expect(parse('купить хлеб, не забудь').title, 'Купить хлеб');
      final reschedule = parse('перенеси отчёт, не забудь');
      expect(reschedule.intent, CommandIntent.rescheduleTask);
      expect(reschedule.targetQuery, 'Отчёт');
    });

    test('«закрыл дверь» в прошедшем времени — бытовое', () {
      for (final text in <String>[
        'я закрыла дверь',
        'закрыл дверь',
        'я закрыла окно',
        'закрыл глаза',
      ]) {
        expect(parse(text).intent, CommandIntent.unknown, reason: text);
      }
      expect(parse('я закрыла отчёт').targetQuery, 'Отчёт');
    });

    test('кавычки со сроком: цитаты и приветствия — не задача', () {
      for (final text in <String>[
        '«Мастер и Маргарита» завтра в кино',
        '«Кто там?» в обед',
        '«Спокойной ночи» в 22:00',
      ]) {
        expect(parse(text).intent, CommandIntent.unknown, reason: text);
      }
      expect(
        parse('через час "позвонить в клинику" по записи').title,
        'позвонить в клинику',
      );
    });

    test('цель после «на завтрашний вечер»', () {
      final evening = parse('перенеси на завтрашний вечер звонок');
      expect(evening.targetQuery, 'Звонок');
      expect(evening.dueAt, DateTime(2026, 11, 3, 19));
      final morning = parse('перенеси на завтрашнее утро звонок');
      expect(morning.targetQuery, 'Звонок');
      expect(morning.dueAt, DateTime(2026, 11, 3, 9));
      expect(
        parse('перенеси созвон на завтрашний вечер встречи выпускников').dueAt,
        isNull,
      );
    });
  });
}
