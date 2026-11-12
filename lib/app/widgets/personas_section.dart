import 'package:flutter/material.dart';

import '../../core/extensions/extension_registry.dart';
import '../../core/replies/reply_library.dart';
import '../../core/settings/app_settings.dart';
import '../assistant_theme.dart';
import 'task_tile.dart';

/// Раздел «Помощники» в настройках: дуэт или соло, кто основной, стиль
/// каждого с живым примером из каталога ответов, «вы»/«ты», эмодзи,
/// как часто шутить.
///
/// Смена настроек меняет только то, как помощник говорит дальше: задачи,
/// история, черновик и выбор остаются (docs/PLANS.md, «Liorio и Noda»).
class PersonasSection extends StatefulWidget {
  const PersonasSection({
    super.key,
    required this.settings,
    required this.onChanged,
    this.registry,
  });

  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;

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
    final duo = personas.mode == AssistantMode.duo;
    return Column(
      key: const ValueKey<String>('personas-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionLabel('Помощники'),
        _Group(
          title: 'Режим',
          hint: duo
              ? 'Основной отвечает на всё, второй пишет первым — '
                  'например, о просроченных задачах. Написать можно любому: '
                  '«Нода, …» или выбор в поле ввода.'
              : 'Один помощник отвечает на всё и сам пишет первым.',
          children: <Widget>[
            _Choice(
              key: const ValueKey<String>('assistant-mode-duo'),
              label: 'Дуэт',
              selected: duo,
              onSelected: () =>
                  _set(personas.copyWith(mode: AssistantMode.duo)),
            ),
            _Choice(
              key: const ValueKey<String>('assistant-mode-solo'),
              label: 'Соло',
              selected: !duo,
              onSelected: () =>
                  _set(personas.copyWith(mode: AssistantMode.solo)),
            ),
          ],
        ),
        _Group(
          title: duo ? 'Основной' : 'Отвечает',
          children: <Widget>[
            for (final persona in Personas.all)
              _Choice(
                key: ValueKey<String>(
                  '${duo ? 'main' : 'solo'}-persona-${persona.id}',
                ),
                label: persona.russianName,
                accent: Color(persona.accentColor),
                selected:
                    (duo ? personas.main : personas.solo).id == persona.id,
                onSelected: () => _set(
                  duo
                      ? personas.copyWith(mainPersona: persona.id)
                      : personas.copyWith(soloPersona: persona.id),
                ),
              ),
          ],
        ),
        for (final persona in Personas.all)
          _PersonaStyle(
            persona: persona,
            personas: personas,
            library: library,
            onStyle: (String style) =>
                _set(personas.withStyle(persona.id, style)),
          ),
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
        SwitchListTile(
          key: const ValueKey<String>('setting-emoji'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          title: const Text(
            'Эмодзи в ответах',
            style: TextStyle(color: AssistantColors.text),
          ),
          subtitle: const Text(
            'Если стиль ими пользуется',
            style: technicalTextStyle,
          ),
          value: personas.emoji,
          onChanged: (bool value) => _set(personas.copyWith(emoji: value)),
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
    );
  }
}

/// Стиль одного помощника и пример ответа этим стилем.
class _PersonaStyle extends StatelessWidget {
  const _PersonaStyle({
    required this.persona,
    required this.personas,
    required this.library,
    required this.onStyle,
  });

  final Persona persona;
  final PersonaSettings personas;
  final ReplyLibrary library;
  final ValueChanged<String> onStyle;

  @override
  Widget build(BuildContext context) {
    final style = personas.styleOf(persona);
    final available = library.hasStyle(style);
    final voice = personas.voiceOf(persona);
    final preview = library.render(PersonasSection.preview, voice);
    final accent = Color(persona.accentColor);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              PersonaMark(persona: persona),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '${persona.russianName}: стиль',
                  style: const TextStyle(color: AssistantColors.text),
                ),
              ),
            ],
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
                  onSelected: () => onStyle(catalog.style),
                ),
            ],
          ),
          if (!available)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Стиль «$style» сейчас выключен или удалён — '
                '${persona.russianName} говорит нейтрально.',
                key: ValueKey<String>('style-missing-${persona.id}'),
                style: technicalTextStyle.copyWith(
                  color: AssistantColors.warning,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AssistantColors.panel,
              border: Border(left: BorderSide(color: accent, width: 2)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              preview,
              key: ValueKey<String>('style-preview-${persona.id}'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AssistantColors.text),
            ),
          ),
        ],
      ),
    );
  }
}

/// Подпись, кнопки выбора с переносом строк и пояснение.
class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children, this.hint});

  final String title;
  final String? hint;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: const TextStyle(color: AssistantColors.text)),
          const SizedBox(height: 8),
          // Перенос вместо прокрутки: на 320 px и крупном шрифте всё видно.
          Wrap(spacing: 8, runSpacing: 8, children: children),
          if (hint != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(hint!, style: technicalTextStyle),
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
      label: Text(label),
      selected: selected,
      onSelected: (_) {
        if (!selected) onSelected();
      },
      showCheckmark: false,
      labelStyle: TextStyle(
        color: selected ? AssistantColors.textStrong : AssistantColors.text,
      ),
      backgroundColor: AssistantColors.workspace,
      selectedColor: AssistantColors.bubble,
      side: BorderSide(
        color: selected
            ? (accent ?? AssistantColors.textStrong)
            : AssistantColors.border,
      ),
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

  /// Круглый знак (аватары «Мой Связной»), иначе — скруглённый квадрат.
  final bool round;

  /// Обводка вокруг круглого знака цветом фона под ним: знаки внахлёст.
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    final accent = Color(persona.accentColor);
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: round ? BoxShape.circle : BoxShape.rectangle,
            borderRadius: round ? null : BorderRadius.circular(size * .3),
            color: Color(persona.accentBackground),
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
