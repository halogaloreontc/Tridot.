/// Варианты ответа на «Когда напомнить?» по времени суток.
///
/// Раньше после 18:00 первым вариантом всегда было «Через час», а до 18:00
/// — «Сегодня вечером», и кнопка отправляла слова «сегодня вечером»:
/// нажатая позже 19:00, она ставила срок на уже прошедшие 19:00 (без
/// вопроса — и напоминание не срабатывало), «Через час» в 23:30 —
/// напоминание в половине первого ночи, а нажатая после полуночи «Завтра
/// утром» уезжала на день вперёд. Теперь варианты зависят от того, сколько
/// сейчас, а кнопка несёт дату и время числами («3 ноября в 9:00»):
/// нажатая поздно, она даёт вопрос «это время уже прошло», а не тихий
/// прошедший срок.
abstract final class ReminderChoices {
  /// Утро и вечер — те же часы, что у частей суток ([PartOfDay]).
  static const int morningHour = 9;
  static const int eveningHour = 19;

  /// Позже этого «через час» — уже ночь: предлагается утро и вечер завтра.
  static const int lateHour = 21;

  /// До этого часа «утром» — сегодняшнее утро.
  static const int nightEndHour = 7;

  /// Варианты в порядке кнопок (без «Выбрать время» — его добавляет
  /// коннектор).
  static List<ReminderChoice> forNow(DateTime now) {
    DateTime at(int dayOffset, int hour) =>
        DateTime(now.year, now.month, now.day + dayOffset, hour);
    if (now.hour < nightEndHour) {
      return <ReminderChoice>[
        ReminderChoice('Утром', at(0, morningHour), _morning),
        ReminderChoice('Вечером', at(0, eveningHour), _evening),
      ];
    }
    if (now.hour < 18) {
      return <ReminderChoice>[
        ReminderChoice('Сегодня вечером', at(0, eveningHour), _evening),
        ReminderChoice('Завтра утром', at(1, morningHour), _morning),
      ];
    }
    if (now.hour < lateHour) {
      final hour = now.add(const Duration(hours: 1));
      return <ReminderChoice>[
        ReminderChoice(
          'Через час',
          DateTime(hour.year, hour.month, hour.day, hour.hour, hour.minute),
          const <String>{'через', 'час'},
        ),
        ReminderChoice('Завтра утром', at(1, morningHour), _morning),
      ];
    }
    return <ReminderChoice>[
      ReminderChoice('Завтра утром', at(1, morningHour), _morning),
      ReminderChoice('Завтра вечером', at(1, eveningHour), _evening),
    ];
  }

  static const Set<String> _morning = <String>{'утром', 'утро', 'завтра'};
  static const Set<String> _evening = <String>{'вечером', 'вечер', 'сегодня'};

  /// Срок числами для текста кнопки: «3 ноября в 9:00».
  static String dueText(DateTime at) {
    final minutes = at.minute.toString().padLeft(2, '0');
    return '${at.day} ${_months[at.month - 1]} в ${at.hour}:$minutes';
  }

  static const List<String> _months = <String>[
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  ];
}

/// Вариант «Когда напомнить?»: подпись кнопки, срок и слова ответа.
final class ReminderChoice {
  const ReminderChoice(this.label, this.at, this.answers);

  final String label;
  final DateTime at;

  /// Слова, по которым набранный ответ выбирает вариант, кроме подписи.
  final Set<String> answers;
}
