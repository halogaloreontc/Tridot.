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
