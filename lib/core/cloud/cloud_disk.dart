/// Облачный диск, с которого можно будет прикреплять файлы (ADR-019).
/// Подключения (OAuth) ещё нет: список подключённых дисков сейчас всегда
/// пуст, и меню «Облачный диск» честно предлагает «Подключить диск».
enum CloudDisk {
  yandex('Яндекс Диск'),
  google('Google Диск');

  const CloudDisk(this.label);

  /// Название для меню.
  final String label;
}

/// Что показывает пункт «Облачный диск» в «+».
sealed class CloudDiskMenu {
  const CloudDiskMenu();

  /// Пункт меню по подключённым дискам [connected] (повторы и порядок не
  /// важны, порядок в меню — как в [CloudDisk]):
  /// - ни одного — [CloudDiskConnect]: «Подключить диск»;
  /// - один — [CloudDiskSingle]: пункт сразу открывает этот диск, без
  ///   выбора;
  /// - несколько — [CloudDiskChoice]: подменю с дисками.
  static CloudDiskMenu entries(Iterable<CloudDisk> connected) {
    final disks = <CloudDisk>[
      for (final disk in CloudDisk.values)
        if (connected.contains(disk)) disk,
    ];
    return switch (disks) {
      <CloudDisk>[] => const CloudDiskConnect(),
      <CloudDisk>[final disk] => CloudDiskSingle(disk),
      _ => CloudDiskChoice(disks),
    };
  }
}

/// Ни один диск не подключён: пункт «Подключить диск».
final class CloudDiskConnect extends CloudDiskMenu {
  const CloudDiskConnect();

  /// Подпись пункта.
  static const String label = 'Подключить диск';
}

/// Подключён один диск: пункт без подменю.
final class CloudDiskSingle extends CloudDiskMenu {
  const CloudDiskSingle(this.disk);

  final CloudDisk disk;
}

/// Подключено несколько дисков: подменю с выбором.
final class CloudDiskChoice extends CloudDiskMenu {
  const CloudDiskChoice(this.disks);

  final List<CloudDisk> disks;
}
