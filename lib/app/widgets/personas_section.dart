import 'package:flutter/material.dart';

import '../../core/extensions/extension_registry.dart';
import '../../core/personas/persona_names.dart';
import '../../core/replies/reply_library.dart';
import '../../core/settings/app_settings.dart';
import '../assistant_theme.dart';
import '../layout.dart';
import 'grouped.dart';
import 'whole_word_text.dart';

/// Раздел «Помощники» в настройках: режим (Соло, Дуэт, Трио), помощник в
/// дуэте, кто ведёт расширения и оповещения, имя, род и стиль каждого с
/// живым примером из каталога ответов, «вы»/«ты», эмодзи, как часто
/// шутить.
///
/// Смена настроек меняет только то, как помощник говорит дальше: задачи,
/// история, черновик и выбор остаются (ADR-016).
class PersonasSection extends StatefulWidget {
  const PersonasSection({
    super.key,
    required this.settings,
    required this.onChanged,
    this.registry,
    this.showHeader = true,
    this.editing,
    this.onEditing,
  });

  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;

  /// Заголовок «Помощники» над режимом; вкладка «Помощники» его не
  /// повторяет.
  final bool showHeader;

  /// Компактный вид (вкладка «Помощники», [onEditing] задан): имя, род и
  /// стиль — только у помощника [editing] (его «Изменить» на карточке),
  /// «Как говорят» — свёрнуто в одну строку. Без [onEditing] видно всё.
  final String? editing;
  final ValueChanged<String?>? onEditing;

  /// Реестр расширений: стили из включённых паков ответов. `null` — только
  /// встроенные стили.
  final ExtensionRegistry? registry;

  /// Пример для предпросмотра стиля: факты одинаковы во всех стилях.
  static const Reply preview = Reply('task.created.withDue', <String, String>{
    'title': 'Купить хлеб',
    'due': 'завтра в 10:00',
  });

  @override
  State<PersonasSection> createState() => _PersonasSectionState();
}

class _PersonasSectionState extends State<PersonasSection> {
  /// «Как говорят» раскрыто в компактном виде.
  bool _speechOpen = false;

  bool get _compact => widget.onEditing != null;

  @override
  void initState() {
    super.initState();
    widget.registry?.addListener(_changed);
  }

  @override
  void didUpdateWidget(PersonasSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.registry != widget.registry) {
      oldWidget.registry?.removeListener(_changed);
      widget.registry?.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.registry?.removeListener(_changed);
    super.dispose();
  }

  /// Пак ответов включили, выключили или добавили: список стилей другой.
  void _changed() {
    if (mounted) setState(() {});
  }

  PersonaSettings get _personas => widget.settings.personas;

  void _set(PersonaSettings personas) =>
      widget.onChanged(widget.settings.copyWith(personas: personas));

  @override
  Widget build(BuildContext context) {
    final library = widget.registry?.replyLibrary ?? ReplyLibrary.builtIn;
    final personas = _personas;
    final mode = personas.teamMode;
    final cast = personas.cast;
    final sado = cast.responder.russianName;
    final alone = cast.responder.gender == ReplyGender.female ? 'сама' : 'сам';
    final helpers = <Persona>[
      for (final id in Personas.helperIds) cast.byId(id),
    ];
    // Подсказка об обращении — именем первого активного помощника.
    final addressee = cast.active.length > 1 ? cast.active[1] : cast.responder;
    return Column(
      key: const ValueKey<String>('personas-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InsetGroup(
          header: widget.showHeader ? 'Помощники' : null,
          children: <Widget>[
            _Group(
              title: 'Режим',
              hint: '${switch (mode) {
                TeamMode.solo => '$sado делает всё $alone.',
                // Имя — только в именительном: своё имя пользователя
                // склонять не надо (ADR-017).
                TeamMode.duo => '$sado и один помощник на выбор; зона '
                    'выключенного — снова у главного.',
                TeamMode.trio => 'Все трое: $sado, ${helpers[0].russianName} и '
                    '${helpers[1].russianName}.',
              }} Написать помощнику напрямую: «${addressee.russianName}, …».',
              hintKey: const ValueKey<String>('assistant-mode-hint'),
              children: <Widget>[
                for (final (value, label) in const <(TeamMode, String)>[
                  (TeamMode.solo, 'Соло'),
                  (TeamMode.duo, 'Дуэт'),
                  (TeamMode.trio, 'Трио'),
                ])
                  _Choice(
                    key: ValueKey<String>('assistant-mode-${value.name}'),
                    label: label,
                    selected: mode == value,
                    onSelected: () => _set(personas.copyWith(teamMode: value)),
                  ),
              ],
            ),
            if (mode == TeamMode.duo)
              _Group(
                title: 'Помощник в дуэте',
                children: <Widget>[
                  for (final helper in helpers)
                    _Choice(
                      key: ValueKey<String>('duo-helper-${helper.id}'),
                      label: helper.russianName,
                      accent: PersonaColors.of(helper, context).$1,
                      selected: personas.duoHelper == helper.id,
                      onSelected: () =>
                          _set(personas.copyWith(duoHelper: helper.id)),
                    ),
                ],
              ),
            for (final (duty, title) in const <(PersonaDuty, String)>[
              (PersonaDuty.extensions, 'Расширения ведёт'),
              (PersonaDuty.notifications, 'Оповещения ведёт'),
            ])
              _DutyGroup(
                duty: duty,
                title: title,
                personas: personas,
                helpers: helpers,
                onSelected: (String id) => _set(personas.withDuty(duty, id)),
              ),
          ],
        ),
        for (final persona in cast.members)
          if (!_compact || widget.editing == persona.id)
            InsetGroup(
              key: ValueKey<String>('persona-group-${persona.id}'),
              header: persona.russianName,
              children: <Widget>[
                _PersonaStyle(
                  key: ValueKey<String>('persona-settings-${persona.id}'),
                  persona: persona,
                  personas: personas,
                  library: library,
                  onStyle: (String style) =>
                      _set(personas.withStyle(persona.id, style)),
                  onName: (String name) =>
                      _set(personas.withName(persona.id, name)),
                  onGender: (ReplyGender gender) =>
                      _set(personas.withGender(persona.id, gender)),
                ),
                if (_compact)
                  GroupedRow(
                    key: ValueKey<String>('persona-done-${persona.id}'),
                    title: 'Готово',
                    accent: true,
                    onTap: () => widget.onEditing!(null),
                  ),
              ],
            ),
        InsetGroup(
          header: 'Как говорят',
          children: <Widget>[
            if (_compact)
              GroupedRow(
                key: const ValueKey<String>('personas-speech-toggle'),
                title: 'Обращение, эмодзи и шутки',
                value: _speechOpen ? null : _speechSummary(personas),
                trailing: Icon(
                  _speechOpen ? Icons.expand_less : Icons.expand_more,
                  color: context.colors.icon,
                ),
                onTap: () => setState(() => _speechOpen = !_speechOpen),
              ),
            if (!_compact || _speechOpen) ...<Widget>[
              _Group(
                title: 'Обращение',
                children: <Widget>[
                  _Choice(
                    key: const ValueKey<String>('address-vy'),
                    label: 'На «вы»',
                    selected: personas.address == ReplyAddress.formal,
                    onSelected: () =>
                        _set(personas.copyWith(address: ReplyAddress.formal)),
                  ),
                  _Choice(
                    key: const ValueKey<String>('address-ty'),
                    label: 'На «ты»',
                    selected: personas.address == ReplyAddress.informal,
                    onSelected: () =>
                        _set(personas.copyWith(address: ReplyAddress.informal)),
                  ),
                ],
              ),
              GroupedSwitchRow(
                key: const ValueKey<String>('setting-emoji'),
                title: 'Эмодзи в ответах',
                subtitle: 'Если стиль ими пользуется',
                value: personas.emoji,
                onChanged: (bool value) =>
                    _set(personas.copyWith(emoji: value)),
              ),
              _Group(
                title: 'Шутки',
                hint: 'Как часто беседа добавляет каламбур к приветствию и '
                    '«спасибо». Ответы задач всегда без шуток.',
                children: <Widget>[
                  for (final (value, label) in const <(JokeFrequency, String)>[
                    (JokeFrequency.off, 'Не шутить'),
                    (JokeFrequency.rare, 'Изредка'),
                    (JokeFrequency.normal, 'Чаще'),
                  ])
                    _Choice(
                      key: ValueKey<String>('jokes-${value.name}'),
                      label: label,
                      selected: personas.jokes == value,
                      onSelected: () => _set(personas.copyWith(jokes: value)),
                    ),
                ],
              ),
            ],
          ],
        ),
      ],
    );
  }

  /// Свёрнутое «Как говорят»: «на «вы»» — коротко, без перечня.
  static String _speechSummary(PersonaSettings personas) =>
      personas.address == ReplyAddress.informal ? 'на «ты»' : 'на «вы»';
}

/// Кто ведёт обязанность: Лиорио или Нода. Если назначенного выключил
/// режим — подпись «сейчас делает Связной».
class _DutyGroup extends StatelessWidget {
  const _DutyGroup({
    required this.duty,
    required this.title,
    required this.personas,
    required this.helpers,
    required this.onSelected,
  });

  final PersonaDuty duty;
  final String title;
  final PersonaSettings personas;
  final List<Persona> helpers;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final cast = personas.cast;
    final assigned = personas.dutyOwnerId(duty);
    final fallback = !cast.isActive(assigned);
    final owner = cast.byId(assigned);
    final off = owner.gender == ReplyGender.female ? 'выключена' : 'выключен';
    return _Group(
      title: title,
      hint: fallback
          ? 'Сейчас делает ${cast.responder.russianName}: '
              '${owner.russianName} $off режимом.'
          : null,
      hintKey: ValueKey<String>('duty-${duty.name}-fallback'),
      children: <Widget>[
        for (final helper in helpers)
          _Choice(
            key: ValueKey<String>('duty-${duty.name}-${helper.id}'),
            label: helper.russianName,
            accent: PersonaColors.of(helper, context).$1,
            selected: assigned == helper.id,
            onSelected: () => onSelected(helper.id),
          ),
      ],
    );
  }
}

/// Один помощник: имя, род, стиль и пример ответа этим стилем.
class _PersonaStyle extends StatefulWidget {
  const _PersonaStyle({
    super.key,
    required this.persona,
    required this.personas,
    required this.library,
    required this.onStyle,
    required this.onName,
    required this.onGender,
  });

  final Persona persona;
  final PersonaSettings personas;
  final ReplyLibrary library;
  final ValueChanged<String> onStyle;

  /// Новое имя — только проверенное ([PersonaNames.validate]).
  final ValueChanged<String> onName;
  final ValueChanged<ReplyGender> onGender;

  @override
  State<_PersonaStyle> createState() => _PersonaStyleState();
}

class _PersonaStyleState extends State<_PersonaStyle> {
  late final TextEditingController _name =
      TextEditingController(text: widget.persona.russianName);
  final FocusNode _focus = FocusNode();

  /// Ошибка имени под полем; `null` — имя годится.
  String? _error;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(_PersonaStyle oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Имя сменили не здесь (сброс настроек, беседа): поле — за ним, если
    // пользователь сейчас его не правит.
    final current = widget.persona.russianName;
    if (!_focus.hasFocus &&
        current != oldWidget.persona.russianName &&
        _name.text != current) {
      _name.text = current;
      _error = null;
    }
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocus)
      ..dispose();
    _name.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (!_focus.hasFocus) _submit(_name.text);
  }

  String? _check(String value) => PersonaNames.validate(
        value,
        widget.persona.id,
        widget.personas.cast,
      );

  void _submit(String value) {
    final name = value.trim();
    if (name == widget.persona.russianName) {
      if (_error != null) setState(() => _error = null);
      return;
    }
    final error = _check(name);
    setState(() => _error = error);
    // Неверное имя не сохраняется: в настройках остаётся прежнее.
    if (error == null) {
      widget.onName(name);
      // Встроенное имя другого рода («Связной» при «она») род не меняет:
      // в поле — то, что покажут настройки (ADR-017).
      final shown = widget.personas
          .withName(widget.persona.id, name)
          .nameOf(widget.persona.id);
      if (shown != name) _name.text = shown;
    }
  }

  @override
  Widget build(BuildContext context) {
    final persona = widget.persona;
    final personas = widget.personas;
    final library = widget.library;
    final style = personas.styleOf(persona);
    final available = library.hasStyle(style);
    final voice = personas.voiceOf(persona);
    final preview = library.render(PersonasSection.preview, voice);
    final accent = PersonaColors.of(persona, context).$1;
    final isSado = persona.id == Personas.sado.id;
    // Род главного до выбора не отмечен: ни «он», ни «она».
    final ReplyGender? gender = isSado && !personas.sadoGenderChosen
        ? null
        : personas.genderOf(persona.id);
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              PersonaDot(persona: persona, size: 10),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  key: ValueKey<String>('persona-name-${persona.id}'),
                  controller: _name,
                  focusNode: _focus,
                  maxLength: PersonaNames.maxLength,
                  textInputAction: TextInputAction.done,
                  style: TextStyle(color: context.colors.textStrong),
                  onChanged: (String value) {
                    // Ошибка видна сразу, сохраняется — по «Готово» или
                    // когда поле теряет фокус.
                    final error = value.trim() == persona.russianName
                        ? null
                        : _check(value);
                    if (error != _error) setState(() => _error = error);
                  },
                  onSubmitted: _submit,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: 'Имя',
                    counterText: '',
                    errorText: _error,
                    errorMaxLines: 3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            key: ValueKey<String>('persona-gender-${persona.id}'),
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text(
                'Род:',
                style: text.bodyMedium!.copyWith(color: context.colors.muted),
              ),
              for (final (value, label) in const <(ReplyGender, String)>[
                (ReplyGender.male, 'Он'),
                (ReplyGender.female, 'Она'),
              ])
                _Choice(
                  key: ValueKey<String>(
                    'persona-gender-${persona.id}-${value.name}',
                  ),
                  label: label,
                  accent: accent,
                  selected: gender == value,
                  onSelected: () => widget.onGender(value),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${persona.russianName}: стиль',
            style: text.bodyMedium!.copyWith(color: context.colors.muted),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final catalog in library.styles)
                _Choice(
                  key: ValueKey<String>(
                    'style-${persona.id}-${catalog.style}',
                  ),
                  label: catalog.title,
                  accent: accent,
                  selected: catalog.style == style,
                  onSelected: () => widget.onStyle(catalog.style),
                ),
            ],
          ),
          if (!available)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Стиль «$style» сейчас выключен или удалён — '
                '${persona.russianName} говорит нейтрально.',
                key: ValueKey<String>('style-missing-${persona.id}'),
                style: metaStyle(context).copyWith(
                  color: context.colors.warning,
                ),
              ),
            ),
          const SizedBox(height: 8),
          // Пример — пузырём заливкой на уровень выше листа, без полосы.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: context.colors.raised,
              borderRadius: BorderRadius.circular(AppRadius.inner),
            ),
            child: Text(
              preview,
              key: ValueKey<String>('style-preview-${persona.id}'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: text.bodyLarge!.copyWith(color: context.colors.text),
            ),
          ),
          // Пример склоняется в мужском роде, пока род главного не выбран
          // (ADR-016): об этом сказано прямо, чтобы пример не спорил с
          // неотмеченными «Он» и «Она».
          if (gender == null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Пример — в мужском роде, пока род не выбран.',
                key: ValueKey<String>('style-preview-note-${persona.id}'),
                style: metaStyle(context),
              ),
            ),
        ],
      ),
    );
  }
}

/// Подпись, кнопки выбора с переносом строк и пояснение.
class _Group extends StatelessWidget {
  const _Group({
    required this.title,
    required this.children,
    this.hint,
    this.hintKey,
  });

  final String title;
  final String? hint;
  final Key? hintKey;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          WholeWordText(
            title,
            style: text.bodyLarge!.copyWith(color: context.colors.textStrong),
          ),
          const SizedBox(height: 8),
          // Перенос вместо прокрутки: на 320 px и крупном шрифте всё видно.
          Wrap(spacing: 8, runSpacing: 8, children: children),
          if (hint != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(hint!, key: hintKey, style: metaStyle(context)),
          ],
        ],
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.accent,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      // Длинное слово («Нейтральный» при шрифте 200 %) уменьшается целиком.
      label: WholeWordText(label),
      selected: selected,
      onSelected: (_) {
        if (!selected) onSelected();
      },
      showCheckmark: false,
      // Заливкой без рамки (тема); выбранный — тоном акцента помощника.
      labelStyle: TextStyle(
        color:
            selected ? (accent ?? context.colors.accent) : context.colors.text,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
      ),
      selectedColor: (accent ?? context.colors.accent).withValues(alpha: 0.15),
    );
  }
}

/// Метка помощника: буква имени в кружке его цвета.
class PersonaMark extends StatelessWidget {
  const PersonaMark({
    super.key,
    required this.persona,
    this.size = 18,
    this.round = false,
    this.ring,
  });

  final Persona persona;
  final double size;

  /// Круглый знак (аватары на карточке «Мой …»), иначе — скруглённый
  /// квадрат.
  final bool round;

  /// Обводка вокруг круглого знака цветом фона под ним: знаки внахлёст.
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    final accent = PersonaColors.of(persona, context).$1;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: round ? BoxShape.circle : BoxShape.rectangle,
            borderRadius: round ? null : BorderRadius.circular(size * .3),
            color: PersonaColors.of(persona, context).$2,
            border: ring == null ? null : Border.all(color: ring!, width: 2),
          ),
          // Буква не растёт с крупным шрифтом: знак фиксированного
          // размера.
          child: Center(
            child: MediaQuery.withNoTextScaling(
              child: Text(
                persona.russianInitial,
                style: TextStyle(
                  fontSize: size * .5,
                  height: 1,
                  fontWeight: FontWeight.w600,
                  color: accent,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Точка помощника (ADR-027): тихий знак его цвета у имени — в ленте, в
/// шапке сессии. Буквы и рамки нет.
class PersonaDot extends StatelessWidget {
  const PersonaDot({super.key, required this.persona, this.size = 8});

  final Persona persona;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: SizedBox.square(
          dimension: size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: PersonaColors.of(persona, context).$1,
            ),
          ),
        ),
      );
}
