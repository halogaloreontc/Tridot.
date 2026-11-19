import 'first_person_verbs.dart';
import 'verb_forms.dart';

/// Перефразирование названий задач и заметок к ним (ADR-033) — только
/// правилами, без догадок: то, в чём правило не уверено, остаётся словами
/// пользователя, но без мусора по краям.
abstract final class TaskRephrase {
  /// Слова-обёртки просьбы в начале названия: «нужно», «надо бы»,
  /// «чтобы», «что», «можешь», «пожалуйста». Снимаются, только если за
  /// ними остаётся дело в инфинитиве («Нужно позвонить Андрею» →
  /// «Позвонить Андрею»): «Что их 22 шт» так и остаётся.
  static const Set<String> _wrappers = <String>{
    'что',
    'чтобы',
    'чтоб',
    // Просторечное «шоб/шобы» — то же «чтоб».
    'шоб',
    'шобы',
    'нужно',
    'надо',
    'бы',
    'необходимо',
    'обязательно',
    'пожалуйста',
    'можешь',
    'можно',
    'мне',
    'нам',
    'я',
    'мы',
    'еще',
    'ещё',
    // «Завтра же надо оплатить садик» — «же» после срока.
    'же',
  };

  /// Местоимения, которые не бывают названием: «напомни про них» — о
  /// текущей задаче, а не дело «Них».
  static const Set<String> pronouns = <String>{
    'них',
    'него',
    'нее',
    'неё',
    'ней',
    'нем',
    'нём',
    'это',
    'этом',
    'этого',
    'их',
    'она',
    'оно',
    'они',
    'он',
    'ее',
    'её',
    'его',
    'эту',
    'то',
    'том',
  };

  /// Предлоги перед местоимением: «про них», «об этом», «о ней».
  static const Set<String> _pronounPrepositions = <String>{
    'про',
    'о',
    'об',
    'обо',
    'насчет',
    'для',
  };

  static final RegExp _space = RegExp(r'\s+');
  static final RegExp _edgeJunk = RegExp(r'^[\s,.;:!…—–-]+|[\s,.;:!?…—–-]+$');

  static String _key(String word) => word
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'^[^0-9a-zа-я]+|[^0-9a-zа-я-]+$'), '');

  /// Чистое название в повелительно-инфинитивной форме или пустая строка,
  /// если от названия ничего не осталось (одно местоимение). Первая буква
  /// заглавная, знаки в конце убраны, имена, числа и артикулы — как были.
  static String title(String raw) {
    var text = raw.replaceAll(_edgeJunk, '').replaceAll(_space, ' ');
    if (text.isEmpty) return '';
    text = _withoutStory(text);
    var words = text.split(' ');
    final keys = words.map(_key).toList();
    if (keys.every(
      (String k) => pronouns.contains(k) || _pronounPrepositions.contains(k),
    )) {
      return '';
    }
    // Обёртка в начале: снимаем, если за ней — дело («Нужно позвонить»,
    // «Что купить хлеб», «Я позвонил маме» → «Позвонить маме»).
    var i = 0;
    while (i < words.length && _wrappers.contains(keys[i])) {
      i++;
    }
    if (i > 0 && i < words.length) {
      final next = keys[i];
      final subject = keys.take(i).any((String k) => k == 'я' || k == 'мы');
      final pastToInfinitive = subject && VerbForms.isPastVerb(next)
          ? VerbForms.toInfinitive(next)
          : null;
      // «Я позвоню маме» → «Позвонить маме»: будущее время — только по
      // закрытой таблице (ADR-033), «я кашу» — не глагол.
      final futureToInfinitive =
          subject ? FirstPersonVerbs.infinitive(next) : null;
      if (VerbForms.isInfinitive(next)) {
        words = words.sublist(i);
      } else if (pastToInfinitive != null) {
        words = <String>[pastToInfinitive, ...words.sublist(i + 1)];
      } else if (futureToInfinitive != null) {
        words = <String>[futureToInfinitive, ...words.sublist(i + 1)];
      } else if (subject &&
          (next == 'буду' || next == 'будем') &&
          i + 1 < words.length &&
          VerbForms.isInfinitive(keys[i + 1])) {
        // «Я буду звонить маме по пятницам» → «Звонить маме по пятницам».
        words = words.sublist(i + 1);
      }
    }
    text = words.join(' ').replaceAll(_edgeJunk, '');
    if (text.isEmpty) return '';
    return text[0].toUpperCase() + text.substring(1);
  }

  /// Рассказ вокруг дела, сказанного внутри длинного сообщения:
  ///
  /// - части через запятую до первой части с инфинитивом — о себе («у
  ///   меня тут завал, ничего не успеваю, будь другом, скинуть Лене
  ///   фотки») и без инфинитива — снимаются;
  /// - в конце — части только из слов [_tailAdverbs] («…, заранее»);
  /// - рассказ о себе без инфинитива перед «надо/нужно (бы)» и делом
  ///   («я тут подумал что надо бы записаться к стоматологу», «блин совсем
  ///   вылетело из головы, же надо оплатить садик») — дело;
  /// - «у меня/у нас (тут)» в начале перед событием («у меня ужин с
  ///   родителями») — событие.
  ///
  /// Только с признаком рассказа о себе ([_selfWords]): «Вася говорил,
  /// что надо починить кран» остаётся словами пользователя.
  static String _withoutStory(String text) {
    var clauses = text.split(RegExp(r'\s*,\s*'));
    List<String> keysOf(String clause) =>
        clause.split(' ').map(_key).where((String k) => k.isNotEmpty).toList();
    bool hasInfinitive(String clause) =>
        keysOf(clause).any(VerbForms.isInfinitive);
    bool aboutSelf(String clause) => keysOf(clause).any(_selfWords.contains);
    while (clauses.length > 1 &&
        keysOf(clauses.last).every(_tailAdverbs.contains)) {
      clauses = clauses.sublist(0, clauses.length - 1);
    }
    final deed = clauses.indexWhere(
      (String c) =>
          keysOf(c).isNotEmpty && VerbForms.isInfinitive(keysOf(c)[0]),
    );
    if (deed > 0 &&
        !clauses.take(deed).any(hasInfinitive) &&
        clauses.take(deed).any(aboutSelf)) {
      clauses = clauses.sublist(deed);
    }
    final split = text.split(RegExp(r'\s*,\s*')).length;
    var result = clauses.length == split ? text : clauses.join(', ');
    // «… надо (бы) <инфинитив>» после рассказа о себе.
    final words = result.split(' ');
    final keys = words.map(_key).toList();
    for (var i = 1; i < keys.length - 1; i++) {
      if (keys[i] != 'надо' && keys[i] != 'нужно') continue;
      final at = keys[i + 1] == 'бы' ? i + 2 : i + 1;
      if (at >= keys.length || !VerbForms.isInfinitive(keys[at])) break;
      final story = keys.take(i);
      if (story.any(VerbForms.isInfinitive) ||
          !story.any(_selfWords.contains)) {
        break;
      }
      result = words.sublist(at).join(' ');
      break;
    }
    // «У меня ужин с родителями» → «Ужин с родителями».
    final own = RegExp(
      r'^у\s+(?:меня|нас)\s+(?:тут\s+)?(?=\S+\s+\S)',
      caseSensitive: false,
    ).firstMatch(result);
    if (own != null && !hasInfinitive(result)) {
      result = result.substring(own.end);
    }
    return result;
  }

  /// Признаки рассказа о себе.
  static const Set<String> _selfWords = <String>{
    'я',
    'меня',
    'мне',
    'блин',
    'головы',
    'другом',
    'подумал',
    'подумала',
  };

  /// Слова в конце названия, которые ничего не говорят о деле.
  static const Set<String> _tailAdverbs = <String>{
    'заранее',
    'обязательно',
    'срочно',
    'пожалуйста',
    'плиз',
  };

  /// Заметка к задаче — короткая строка фактов: «их 22шт в ок, 1шт в
  /// уценке под артикулом 67782» → «22 шт в ОК, 1 шт в уценке, арт.
  /// 67782». Числа не меняются; местоимения в начале («их», «там») —
  /// это задача, к которой пишется заметка, их в тексте нет.
  static String note(String raw) {
    var text = raw.replaceAll(_edgeJunk, '').replaceAll(_space, ' ');
    // «что», «их», «там», «у них», «по ним» в начале.
    final lead = RegExp(
      r'^(?:(?:что|чтобы|их|они|там|тут|у них|по ним|по нему|у него|у нее|у неё|про них|о них)[\s,]+)+',
      caseSensitive: false,
    );
    text = text.replaceFirst(lead, '');
    // Штуки: «22шт», «22 штуки», «22 шт.» → «22 шт».
    text = text.replaceAllMapped(
      RegExp(
        r'(\d+)\s*(?:шт\.?|штук[аи]?|штуки)(?=[\s,.;]|$)',
        caseSensitive: false,
      ),
      (Match m) => '${m[1]} шт',
    );
    // Артикул: «под артикулом 67782», «с артикулом», «артикул», «арт».
    text = text.replaceAllMapped(
      RegExp(
        r'[\s,]*(?:под|с|по)?\s*(?:артикул(?:ом|у|а)?|арт\.?)\s*№?\s*([0-9A-Za-zА-Яа-я-]*\d[0-9A-Za-zА-Яа-я-]*)',
        caseSensitive: false,
      ),
      (Match m) => ', арт. ${m[1]}',
    );
    // Известные статусы: «ок» → «ОК».
    text = text.replaceAllMapped(
      RegExp(r'(^|[\s,(])(?:ок|ok|окей)(?=$|[\s,.;)])', caseSensitive: false),
      (Match m) => '${m[1]}ОК',
    );
    text = text
        .replaceAll(RegExp(r'\s+,'), ',')
        .replaceAll(RegExp(r',(?=\S)'), ', ')
        .replaceAll(RegExp(r',\s*,'), ',')
        .replaceAll(_space, ' ')
        .replaceAll(_edgeJunk, '');
    return text;
  }
}
