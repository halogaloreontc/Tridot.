import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/skills/weather/weather_codes.dart';
import '../../core/skills/weather/weather_service.dart';
import '../assistant_theme.dart';
import '../widgets/whole_word_text.dart';
import 'weather_kit.dart';
import '../layout.dart';
import '../widgets/app_dialog.dart';

/// Окно согласия на запросы к Open-Meteo (ADR-030). `true` — «Разрешить».
Future<bool> showWeatherConsent(BuildContext context) async {
  final accepted = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AppDialog(
      scrollable: true,
      icon: Icons.cloud_outlined,
      iconColor: context.colors.tileBlue,
      // Неразрывный дефис: «Open-» и «Meteo?» не расходятся по строкам.
      title: const WholeWordText('Разрешить прогноз Open\u2011Meteo?'),
      // Главное — что уходит в сеть; правила сервиса — подписью ниже.
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text(
            'Tridot отправит на сайт open-meteo.com только координаты '
            'города, округлённые примерно до километра, а при поиске\u00A0— '
            'название города. Задачи, чаты и ваше имя туда не уходят.',
            key: ValueKey<String>('weather-consent-text'),
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            'Сервис бесплатный и без регистрации, журналы сервера хранит до '
            '90 дней и никому не передаёт. Без интернета помощник покажет '
            'последний сохранённый прогноз.',
            style: metaStyle(context),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('weather-consent-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const ActionLabel('Отмена'),
        ),
        FilledButton(
          key: const ValueKey<String>('weather-consent-accept'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const ActionLabel('Разрешить'),
        ),
      ],
    ),
  );
  return accepted ?? false;
}

/// Сообщение об ошибке погоды для экрана настроек.
String weatherErrorText(WeatherError error) => switch (error) {
      WeatherError.offline => 'Нет связи с Open-Meteo',
      WeatherError.busy =>
        'Open-Meteo перегружен — попробуйте через несколько минут',
      WeatherError.failed => 'Open-Meteo ответил ошибкой — попробуйте позже',
      WeatherError.notFound => 'Город не найден — проверьте название',
      WeatherError.noConsent => 'Сначала разрешите сеть для погоды',
    };

/// «Настройки → Расширения → Погода → Настроить» (ADR-030): источник,
/// разрешение сети, город, своя ссылка и приложение.
final class WeatherScreen extends StatefulWidget {
  const WeatherScreen({super.key, required this.kit});

  final WeatherKit kit;

  @override
  State<WeatherScreen> createState() => _WeatherScreenState();
}

final class _WeatherScreenState extends State<WeatherScreen> {
  final TextEditingController _city = TextEditingController();
  final TextEditingController _link = TextEditingController();
  List<WeatherPlace> _results = const <WeatherPlace>[];
  String? _cityError;
  String? _linkError;
  String? _linkSaved;
  String? _check;
  bool _checkFailed = false;
  bool _busy = false;
  List<WeatherApp>? _apps;

  WeatherKit get _kit => widget.kit;
  WeatherSettings get _settings => _kit.settings;

  @override
  void initState() {
    super.initState();
    _kit.addListener(_changed);
    _link.text = _settings.link ?? '';
    unawaited(_kit.load());
  }

  @override
  void dispose() {
    _kit.removeListener(_changed);
    _city.dispose();
    _link.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (_link.text.isEmpty && _settings.link != null) {
      _link.text = _settings.link!;
    }
    setState(() {});
  }

  Future<void> _setSource(WeatherSource source) async {
    setState(() {
      _check = null;
      _results = const <WeatherPlace>[];
    });
    await _kit.setSource(source);
    if (source == WeatherSource.openMeteo &&
        !_settings.networkAllowed &&
        mounted) {
      await _allow();
    }
  }

  Future<void> _allow() async {
    final yes = await showWeatherConsent(context);
    if (yes) await _kit.allowNetwork();
  }

  Future<void> _search() async {
    final query = _city.text.trim();
    if (query.length < 2) {
      setState(() => _cityError = 'Введите название города');
      return;
    }
    setState(() {
      _busy = true;
      _cityError = null;
    });
    try {
      final found = await _kit.search(query);
      if (!mounted) return;
      setState(() {
        _results = found;
        _cityError =
            found.isEmpty ? weatherErrorText(WeatherError.notFound) : null;
      });
    } on WeatherException catch (e) {
      if (mounted) setState(() => _cityError = weatherErrorText(e.error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick(WeatherPlace place) async {
    await _kit.setPlace(place);
    if (!mounted) return;
    setState(() {
      _results = const <WeatherPlace>[];
      _city.clear();
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || !mounted) return;
    final parsed = WeatherLink.parse(text);
    _link.text = parsed.url ?? text.trim();
    await _saveLink();
  }

  Future<void> _saveLink() async {
    final issue = await _kit.setLink(_link.text);
    if (!mounted) return;
    setState(() {
      _linkError = issue?.message;
      _linkSaved = issue == null ? 'Ссылка сохранена' : null;
      if (issue == null && _settings.link != null) _link.text = _settings.link!;
    });
  }

  Future<void> _chooseApp() async {
    final apps = _apps ??= await _kit.links.weatherApps();
    if (!mounted) return;
    final picked = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            if (apps.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: WholeWordText(
                  'Знакомых приложений погоды не нашлось.',
                  style: metaStyle(context),
                ),
              ),
            for (var i = 0; i < apps.length; i++)
              ListTile(
                key: ValueKey<String>('weather-app-$i'),
                leading: const Icon(Icons.apps),
                title: Text(apps[i].label),
                onTap: () => Navigator.of(context).pop(apps[i]),
              ),
            if (_kit.links.canPickApp)
              ListTile(
                key: const ValueKey<String>('weather-app-other'),
                leading: const Icon(Icons.more_horiz),
                title: const Text('Другое приложение…'),
                onTap: () => Navigator.of(context).pop('other'),
              ),
          ],
        ),
      ),
    );
    WeatherApp? app = picked is WeatherApp ? picked : null;
    if (picked == 'other') app = await _kit.links.pickApp();
    if (app != null) await _kit.setApp(app);
  }

  Future<void> _runCheck() async {
    setState(() {
      _busy = true;
      _check = null;
    });
    String text;
    var failed = false;
    if (_settings.source == WeatherSource.openMeteo) {
      final result = await _kit.check();
      final forecast = result.forecast;
      if (result.missingPlace) {
        text = 'Сначала выберите город';
        failed = true;
      } else if (forecast != null && !result.stale) {
        text = 'Связь есть: сейчас '
            '${WeatherFormat.temp(forecast.current.temperature)}, '
            '${WeatherCodes.sky(forecast.current.code)}';
      } else {
        text = weatherErrorText(result.error ?? WeatherError.failed);
        failed = true;
      }
    } else {
      final outcome = await _kit.openAgain();
      failed = outcome != WeatherLaunch.opened;
      text = switch (outcome) {
        WeatherLaunch.opened => 'Открылось',
        WeatherLaunch.fallback =>
          'Приложение не открылось — открыта ваша ссылка',
        WeatherLaunch.linkFailed =>
          'Ссылка не открылась: на устройстве не нашлось браузера',
        WeatherLaunch.appMissing => 'Приложение не открылось — выберите другое',
      };
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _check = text;
      _checkFailed = failed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    final source = settings.source;
    final colors = context.colors;
    final heading = TextStyle(
      color: colors.textStrong,
      fontWeight: FontWeight.w600,
    );
    return Scaffold(
      backgroundColor: colors.workspace,
      appBar: AppBar(title: const Text('Погода')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const WholeWordText(
            'Откуда помощник берёт погоду. Без вашего разрешения Tridot в '
            'сеть не ходит.',
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<WeatherSource>(
            key: const ValueKey<String>('weather-source'),
            initialValue: source == WeatherSource.none ? null : source,
            isExpanded: true,
            itemHeight: null,
            dropdownColor: colors.raised,
            borderRadius: BorderRadius.circular(12),
            icon: Icon(Icons.unfold_more, color: colors.icon),
            hint: const WholeWordText('Не выбран'),
            // В поле — короткое имя, что оно делает — строкой под полем:
            // длинное «Open-Meteo — прогноз в чате» при крупном шрифте
            // обрезалось до «Open-Meteo —».
            selectedItemBuilder: (BuildContext context) => <Widget>[
              for (final value in _sourceOptions)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: WholeWordText(_sourceName(value)),
                ),
            ],
            style: TextStyle(
              fontFamily: AppFonts.text,
              fontSize: 16,
              color: colors.textStrong,
            ),
            decoration: InputDecoration(
              labelText: 'Источник',
              helperText: _sourceHelp(source),
              helperMaxLines: 3,
              fillColor: colors.raised,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
            items: <DropdownMenuItem<WeatherSource>>[
              for (final value in _sourceOptions)
                DropdownMenuItem<WeatherSource>(
                  value: value,
                  child: WholeWordText(
                    '${_sourceName(value)} — ${_sourceAction(value)}',
                  ),
                ),
            ],
            onChanged: (WeatherSource? value) {
              if (value != null) unawaited(_setSource(value));
            },
          ),
          if (source == WeatherSource.openMeteo) ..._openMeteo(context),
          if (source == WeatherSource.app) ..._app(context, heading),
          if (source != WeatherSource.none) ..._linkField(context, heading),
          if (source != WeatherSource.none) ...<Widget>[
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton(
                  key: const ValueKey<String>('weather-check'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 44),
                  ),
                  onPressed: _busy ? null : _runCheck,
                  child: const Text('Проверить'),
                ),
                if (_kit.service.hasData)
                  OutlinedButton(
                    key: const ValueKey<String>('weather-clear'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                    onPressed: () => unawaited(_kit.clearData()),
                    child: const Text('Удалить данные погоды'),
                  ),
              ],
            ),
            if (_check != null) ...<Widget>[
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: WholeWordText(
                  _check!,
                  key: const ValueKey<String>('weather-check-result'),
                  style: TextStyle(
                    color: _checkFailed ? colors.danger : colors.textStrong,
                  ),
                ),
              ),
            ],
          ],
          // Указание источника — только когда данные и правда от Open-Meteo.
          if (source == WeatherSource.openMeteo) ...<Widget>[
            const SizedBox(height: 24),
            WholeWordText(
              'Данные погоды: Open-Meteo.com, лицензия CC BY 4.0',
              key: const ValueKey<String>('weather-attribution'),
              style: metaStyle(context),
            ),
          ],
        ],
      ),
    );
  }

  List<WeatherSource> get _sourceOptions => <WeatherSource>[
        WeatherSource.openMeteo,
        WeatherSource.link,
        if (_kit.links.supportsApps) WeatherSource.app,
      ];

  static String _sourceName(WeatherSource source) => switch (source) {
        WeatherSource.openMeteo => 'Open-Meteo',
        WeatherSource.link => 'Своя ссылка',
        WeatherSource.app => 'Приложение погоды',
        WeatherSource.none => 'Не выбран',
      };

  static String _sourceAction(WeatherSource source) => switch (source) {
        WeatherSource.openMeteo => 'прогноз в чате',
        WeatherSource.link => 'открыть страницу',
        WeatherSource.app => 'открыть его',
        WeatherSource.none => '',
      };

  static String? _sourceHelp(WeatherSource source) => switch (source) {
        WeatherSource.openMeteo => 'Прогноз приходит прямо в чат',
        WeatherSource.link => 'Помощник открывает вашу страницу в браузере',
        WeatherSource.app => 'Помощник открывает приложение погоды',
        WeatherSource.none => null,
      };

  List<Widget> _openMeteo(BuildContext context) {
    final settings = _settings;
    final colors = context.colors;
    final allowed = settings.networkAllowedAt;
    return <Widget>[
      const SizedBox(height: 16),
      if (allowed == null)
        Container(
          key: const ValueKey<String>('weather-network-off'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.raised,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              WholeWordText(
                'Сеть для погоды не разрешена',
                style: TextStyle(color: colors.textStrong),
              ),
              const SizedBox(height: 8),
              FilledButton(
                key: const ValueKey<String>('weather-consent-open'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                onPressed: () => unawaited(_allow()),
                child: const Text('Разрешить…'),
              ),
            ],
          ),
        )
      else
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          children: <Widget>[
            WholeWordText(
              // «1 ноября» не разрывается между строками.
              'Сеть разрешена '
              '${WeatherFormat.date(allowed).replaceAll(' ', '\u00a0')}',
              key: const ValueKey<String>('weather-consent-state'),
              style: metaStyle(context),
            ),
            TextButton(
              key: const ValueKey<String>('weather-consent-revoke'),
              // Без своего отступа слева — вровень с текстом над ним.
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
              onPressed: () => unawaited(_kit.revokeNetwork()),
              child: const Text('Отозвать'),
            ),
          ],
        ),
      const SizedBox(height: 16),
      WholeWordText(
        settings.place == null
            ? 'Город не выбран'
            : 'Город: ${settings.place!.label}',
        key: const ValueKey<String>('weather-city'),
        style: TextStyle(color: colors.textStrong),
      ),
      const SizedBox(height: 8),
      TextField(
        key: const ValueKey<String>('weather-city-field'),
        controller: _city,
        enabled: allowed != null,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => unawaited(_search()),
        decoration: const InputDecoration(
          labelText: 'Город',
          hintText: 'Например, Казань',
        ),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton(
          key: const ValueKey<String>('weather-city-search'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed:
              allowed == null || _busy ? null : () => unawaited(_search()),
          child: const Text('Найти'),
        ),
      ),
      if (_cityError != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: WholeWordText(
            _cityError!,
            key: const ValueKey<String>('weather-city-error'),
            style: TextStyle(color: colors.danger),
          ),
        ),
      for (var i = 0; i < _results.length; i++)
        ListTile(
          key: ValueKey<String>('weather-city-result-$i'),
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.place_outlined, color: colors.icon),
          title: WholeWordText(_results[i].label),
          onTap: () => unawaited(_pick(_results[i])),
        ),
    ];
  }

  List<Widget> _app(BuildContext context, TextStyle heading) {
    final app = _settings.app;
    return <Widget>[
      const SizedBox(height: 20),
      Text('Приложение', style: heading),
      const SizedBox(height: 4),
      WholeWordText(
        app == null ? 'Приложение не выбрано' : app.label,
        key: const ValueKey<String>('weather-app-label'),
        style: metaStyle(context),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton(
          key: const ValueKey<String>('weather-app-choose'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: () => unawaited(_chooseApp()),
          child: const Text('Выбрать приложение'),
        ),
      ),
    ];
  }

  List<Widget> _linkField(BuildContext context, TextStyle heading) {
    final colors = context.colors;
    final source = _settings.source;
    return <Widget>[
      const SizedBox(height: 20),
      Text(
        switch (source) {
          WeatherSource.openMeteo => 'Ссылка для «Подробнее»',
          WeatherSource.app => 'Запасная ссылка',
          _ => 'Своя ссылка',
        },
        style: heading,
      ),
      const SizedBox(height: 8),
      TextField(
        key: const ValueKey<String>('weather-link-field'),
        controller: _link,
        keyboardType: TextInputType.url,
        autocorrect: false,
        onSubmitted: (_) => unawaited(_saveLink()),
        decoration: const InputDecoration(hintText: 'https://…'),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          OutlinedButton(
            key: const ValueKey<String>('weather-link-paste'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => unawaited(_paste()),
            child: const Text('Вставить'),
          ),
          OutlinedButton(
            key: const ValueKey<String>('weather-link-save'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => unawaited(_saveLink()),
            child: const Text('Сохранить'),
          ),
          if (_settings.link != null)
            TextButton(
              key: const ValueKey<String>('weather-link-clear'),
              style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: () {
                _link.clear();
                setState(() => _linkSaved = null);
                unawaited(_kit.clearLink());
              },
              child: const Text('Убрать'),
            ),
        ],
      ),
      if (_linkError != null || _linkSaved != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: WholeWordText(
            _linkError ?? _linkSaved!,
            key: const ValueKey<String>('weather-link-error'),
            style: TextStyle(
              color: _linkError != null ? colors.danger : colors.muted,
            ),
          ),
        ),
      const SizedBox(height: 4),
      WholeWordText(
        'Ссылка хранится только на этом устройстве и открывается в '
        'браузере. Tridot сам по ней не ходит.',
        style: metaStyle(context),
      ),
    ];
  }
}
