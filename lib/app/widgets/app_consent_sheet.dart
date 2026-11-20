import 'package:flutter/material.dart';

import '../../core/connectors/manifest/app_connections.dart';
import '../../core/connectors/manifest/connection_service.dart';
import '../../core/connectors/manifest/connection_slots.dart';
import '../../core/connectors/manifest/generic_slot.dart';
import '../../core/connectors/manifest/manifest_format.dart';
import '../assistant_theme.dart';
import 'app_dialog.dart';
import 'warehouse_connection_card.dart' show warehouseHostLabel;
import 'whole_word_text.dart';

/// Хост для показа с портом, если он есть: «crm.example», «192.168.1.5:8080».
/// Дефис неразрывный ([warehouseHostLabel]).
String appHostLabel(Uri uri) => uri.hasPort
    ? '${warehouseHostLabel(uri)}:${uri.port}'
    : warehouseHostLabel(uri);

/// Что приложение сможет читать: «Найти клиента — «найди клиента Тестов»».
List<({String title, String example})> appReads(ManifestDescription d) =>
    <({String title, String example})>[
      for (final command in d.commands)
        if (!command.help)
          (
            title: command.title,
            example: command.examples.isEmpty ? '' : command.examples.first,
          ),
    ];

/// Что нужно для входа: подписи данных для входа и вход по ссылке.
List<String> appLoginNeeds(ManifestDescription d) => <String>[
      for (final MapEntry(:key, :value) in d.credentials.entries)
        if (key == 'token')
          value.label.isEmpty ? 'пароль приложения' : value.label
        else if (key == 'sid' && value.get != null)
          'логин и пароль сотрудника — по желанию',
      if (d.qr != null) 'или вход по QR-коду из приложения',
    ];

/// Шторка согласия «Подключить приложение» (ADR-043): **адрес крупно и
/// первым**, затем как приложение называет себя (его слова, не наши), что
/// оно сможет читать, что нужно для входа, что не так в описании и что
/// это только чтение. `true` — подключить.
Future<bool> showAppConsent(BuildContext context, ProbeResult probe) async {
  final yes = await showAppSheet<bool>(
    context: context,
    builder: (BuildContext context) => AppConsentSheet(probe: probe),
  );
  return yes ?? false;
}

final class AppConsentSheet extends StatelessWidget {
  const AppConsentSheet({super.key, required this.probe});

  final ProbeResult probe;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final description = probe.description!;
    final base = probe.base!;
    final profile = probe.profile;
    final meta = metaStyle(context);
    final reads = appReads(description);
    final needs = appLoginNeeds(description);
    final heading = Theme.of(context).textTheme.labelMedium!.copyWith(
          color: colors.muted,
        );
    Widget section(String text) => Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 4),
          child: WholeWordText(text, style: heading),
        );
    final local = base.scheme == 'http';
    return AppSheet(
      key: const ValueKey<String>('app-consent'),
      icon: Icons.hub_outlined,
      title: WholeWordText(
        appHostLabel(base),
        key: const ValueKey<String>('app-consent-host'),
        style: TextStyle(
          fontSize: 22,
          height: 1.25,
          fontWeight: FontWeight.w700,
          color: colors.textStrong,
        ),
      ),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          WholeWordText(
            local
                ? 'Адрес в своей сети, без шифрования. Подключайте, только '
                    'если знаете это приложение.'
                : 'Адрес приложения. Подключайте, только если знаете его.',
            key: const ValueKey<String>('app-consent-address-note'),
            style: meta,
          ),
          const SizedBox(height: 12),
          WholeWordText(
            'Так приложение называет себя: «${description.appTitle}»',
            key: const ValueKey<String>('app-consent-title'),
            style: TextStyle(fontSize: 15, color: colors.text),
          ),
          if (description.about.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: WholeWordText(
                description.about,
                key: const ValueKey<String>('app-consent-about'),
                style: meta,
              ),
            ),
          if (profile != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: WholeWordText(
                'В Связном: «${GenericSlotTexts.title(profile)}». '
                'Обращаться: ${GenericSlotTexts.aliases(profile).map((String a) => '«${a.replaceAll(' ', '\u00a0')}»').join(', ')}.',
                key: const ValueKey<String>('app-consent-name'),
                style: meta,
              ),
            ),
          section('Что сможет читать'),
          if (reads.isEmpty)
            WholeWordText('Команд в описании нет.', style: meta)
          else
            for (final (i, read) in reads.indexed)
              Padding(
                key: ValueKey<String>('app-consent-read-$i'),
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: WholeWordText(
                  read.example.isEmpty
                      ? read.title
                      : '${read.title} — «${read.example}»',
                  style: TextStyle(fontSize: 15, color: colors.text),
                ),
              ),
          section('Вход'),
          WholeWordText(
            needs.isEmpty
                ? 'Данных для входа описание не просит.'
                : 'Понадобится: ${needs.join(', ')}. Вход — после '
                    '«Подключить», на экране подключения. Пароль хранится '
                    'только на этом устройстве.',
            key: const ValueKey<String>('app-consent-login'),
            style: TextStyle(fontSize: 15, color: colors.text),
          ),
          if (probe.problems.isNotEmpty || probe.profileWarnings.isNotEmpty)
            section('Что не так'),
          for (final problem in probe.problems)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: WholeWordText(
                problem,
                key: const ValueKey<String>('app-consent-problem'),
                style: TextStyle(fontSize: 15, color: colors.danger),
              ),
            ),
          for (final warning in probe.profileWarnings)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: WholeWordText(
                'Отброшено из описания: $warning.',
                style: TextStyle(fontSize: 13, color: colors.warning),
              ),
            ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.raised,
              borderRadius: BorderRadius.circular(12),
            ),
            child: WholeWordText(
              'Только чтение: изменять данные в приложении Связной не будет.',
              key: const ValueKey<String>('app-consent-readonly'),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: colors.textStrong,
              ),
            ),
          ),
        ],
      ),
      actions: <Widget>[
        DialogCancel(onPressed: () => Navigator.of(context).pop(false)),
        FilledButton(
          key: const ValueKey<String>('app-consent-yes'),
          onPressed:
              probe.canAdd ? () => Navigator.of(context).pop(true) : null,
          child: const ActionLabel('Подключить'),
        ),
      ],
    );
  }
}

/// Подтверждение входа по ссылке или QR в уже подключённое приложение
/// [service] (ADR-043): хост из ссылки крупно, код не показывается.
/// Ссылка на другой адрес сюда не попадает: приложение — `app.id` + хост.
Future<bool> confirmAppLink(
  BuildContext context,
  ConnectionService service,
  QrLink link,
) async {
  final colors = context.colors;
  final title = service.slot.title;
  final yes = await showAppSheet<bool>(
    context: context,
    builder: (BuildContext context) => AppSheet(
      key: const ValueKey<String>('app-link-confirm'),
      icon: Icons.link,
      title: WholeWordText('Войти в «$title»?'),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            appHostLabel(link.base),
            key: const ValueKey<String>('app-link-host'),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: colors.textStrong,
            ),
          ),
          const SizedBox(height: 8),
          const WholeWordText(
            'Связной войдёт под логином, который показал код, и будет '
            'только читать. Ключ хранится на этом устройстве; отключить его '
            'можно на экране подключения («Выйти»).',
          ),
        ],
      ),
      actions: <Widget>[
        DialogCancel(onPressed: () => Navigator.of(context).pop(false)),
        FilledButton(
          key: const ValueKey<String>('app-link-yes'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const ActionLabel('Войти'),
        ),
      ],
    ),
  );
  return yes ?? false;
}

/// Слот склада, если [probe] нашла его по адресу.
bool probeIsWarehouse(ProbeResult probe) =>
    probe.knownSlot?.id == ConnectionSlots.warehouse.id;
