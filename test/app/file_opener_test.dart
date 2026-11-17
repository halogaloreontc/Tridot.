// «Открыть» и «Открыть папку»: команда для каждой системы списком
// аргументов, без оболочки; путь вне разрешённых папок не открывается.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/files/file_opener.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';

final class _FakeProcess implements Process {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

List<String>? _flat((String, List<String>)? argv) =>
    argv == null ? null : <String>[argv.$1, ...argv.$2];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('argv по системам', () {
    expect(
      _flat(FileOpener.openArgv(JobPlatform.linux, '/home/u/a.zip')),
      <String>['xdg-open', '/home/u/a.zip'],
    );
    expect(
      _flat(FileOpener.openArgv(JobPlatform.windows, r'C:\u\a.zip')),
      <String>['explorer.exe', r'C:\u\a.zip'],
    );
    expect(
      _flat(FileOpener.openArgv(JobPlatform.macos, '/u/a.zip')),
      <String>['open', '/u/a.zip'],
    );
    expect(FileOpener.openArgv(JobPlatform.android, '/a'), isNull);
    expect(
      _flat(FileOpener.revealArgv(JobPlatform.windows, r'C:\u\a.zip')),
      <String>['explorer.exe', r'/select,C:\u\a.zip'],
    );
    expect(
      _flat(FileOpener.revealArgv(JobPlatform.macos, '/u/a.zip')),
      <String>['open', '-R', '/u/a.zip'],
    );
    expect(
      _flat(FileOpener.revealArgv(JobPlatform.linux, '/нет/такой/a.zip')),
      <String>['xdg-open', '/нет/такой'],
    );
  });

  test('запуск без оболочки, отдельным процессом', () async {
    final calls = <(String, List<String>, bool)>[];
    final opener = FileOpener(
      platform: JobPlatform.linux,
      start: (
        String exe,
        List<String> args, {
        bool runInShell = false,
        ProcessStartMode mode = ProcessStartMode.normal,
      }) async {
        calls.add((exe, args, runInShell));
        expect(mode, ProcessStartMode.detached);
        return _FakeProcess();
      },
    );
    expect(await opener.open('/home/u/a b; rm -rf.zip'), isTrue);
    expect(calls.single.$1, 'xdg-open');
    expect(calls.single.$2, <String>['/home/u/a b; rm -rf.zip']);
    expect(calls.single.$3, isFalse);
    expect(opener.canReveal, isTrue);
  });

  test('путь вне разрешённых папок — отказ', () async {
    var started = false;
    final opener = FileOpener(
      platform: JobPlatform.linux,
      allowedRoots: <String>['/data/app/chats'],
      start: (
        String exe,
        List<String> args, {
        bool runInShell = false,
        ProcessStartMode mode = ProcessStartMode.normal,
      }) async {
        started = true;
        return _FakeProcess();
      },
    );
    expect(await opener.open('/etc/passwd'), isFalse);
    expect(await opener.open('/data/app/chats/../../etc/x'), isFalse);
    expect(started, isFalse);
    expect(opener.allowed('/data/app/chats/files/s/out/j1/a.zip'), isTrue);
  });

  test('Android: канал tridot/files, «Открыть папку» нет', () async {
    const channel = MethodChannel('tridot/files');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return true;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final opener = FileOpener(
      platform: JobPlatform.android,
      allowedRoots: <String>['/data/user/0/app/app_flutter'],
    );
    expect(opener.canReveal, isFalse);
    expect(
      await opener.open('/data/user/0/app/app_flutter/assistant/a.zip'),
      isTrue,
    );
    expect(calls.single.method, 'open');
    expect(await opener.open('/sdcard/a.zip'), isFalse);
    expect(await opener.reveal('/data/user/0/app/app_flutter/a.zip'), isFalse);
    expect(calls, hasLength(1));
  });

  test('имя для показа: Android передаёт его каналу, компьютер — нет',
      () async {
    const channel = MethodChannel('tridot/files');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return true;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final android = FileOpener(platform: JobPlatform.android);
    const stored = '/data/app/assistant/chats/files/s/m_1_0-0.pdf';
    expect(await android.open(stored, name: 'Отчёт за ноябрь.pdf'), isTrue);
    expect(calls.single.arguments, <String, Object?>{
      'path': stored,
      'name': 'Отчёт за ноябрь.pdf',
    });
    calls.clear();
    expect(await android.open(stored), isTrue);
    expect(calls.single.arguments, <String, Object?>{'path': stored});

    final started = <List<String>>[];
    final linux = FileOpener(
      platform: JobPlatform.linux,
      start: (
        String exe,
        List<String> args, {
        bool runInShell = false,
        ProcessStartMode mode = ProcessStartMode.normal,
      }) async {
        started.add(args);
        return _FakeProcess();
      },
    );
    expect(await linux.open('/home/u/a.pdf', name: 'Другое имя.pdf'), isTrue);
    expect(started.single, <String>['/home/u/a.pdf']);
  });
}
