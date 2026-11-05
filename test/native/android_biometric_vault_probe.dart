// Isolated Android stand only. No node, microphone, or user container.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:hidden_volume/hidden_volume.dart';
import 'package:xveil/core/local_authentication.dart';
import 'package:xveil/core/quick_unlock_vault.dart';

const _package = 'network.veil.xveil.qa.biometric20261105.vault_probe';
const _password = 'PUBLIC synthetic biometric fixture; never a user password';
const _scope = 'disposable-biometric-vault-fixture';

bool _containerCheck(Map<String, Object> arguments) {
  final path = arguments['path'] as String;
  final password = Uint8List.fromList(
    utf8.encode(arguments['password'] as String),
  );
  HvSpace? space;
  try {
    final create = arguments['create'] == true && !File(path).existsSync();
    space = create
        ? HvSpace.create(path: path, password: password)
        : HvSpace.open(path: path, password: password);
    if (create) {
      space.commit([
        HvWriteOpPut(
          namespace: 1,
          key: utf8.encode('marker'),
          value: utf8.encode('biometric fixture'),
        ),
      ]);
    }
    final marker = space.get(1, utf8.encode('marker'));
    return marker != null && utf8.decode(marker) == 'biometric fixture';
  } on HvException catch (error) {
    if (error.kind == 'AuthFailed') return false;
    rethrow;
  } finally {
    space?.close();
    password.fillRange(0, password.length, 0);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kDebugMode || !Platform.isAndroid) {
    throw StateError('Isolated Android debug stand required');
  }
  final directory = await getApplicationSupportDirectory();
  if (!directory.path.split('/').contains(_package)) {
    throw StateError('Refusing a non-probe sandbox');
  }
  runApp(MaterialApp(home: _Probe(directory)));
}

class _Probe extends StatefulWidget {
  const _Probe(this.directory);
  final Directory directory;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  final _vault = QuickUnlockVault(
    const QuickUnlockSecretStore(),
    _scope,
    LocalScreenAuthentication(),
  );
  bool _busy = false;
  String _status =
      'Проверка фиктивной записи; пользовательские данные не используются';

  Future<void> _run(String operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '$operation: ожидается ответ ОС';
    });
    final result = <String, Object?>{'operation': operation};
    try {
      switch (operation) {
        case 'Статус':
          result['available'] = await LocalScreenAuthentication().available();
          result['configured'] = (await _vault.options()).system;
        case 'Настроить':
          result['containerCreated'] = await compute(_containerCheck, {
            'path': '${widget.directory.path}/biometric-fixture.hv',
            'password': _password,
            'create': true,
          });
          await _vault.configure(password: _password, system: true);
          result['configured'] = (await _vault.options()).system;
        case 'Открыть':
          final restored = await _vault.openSystem(
            'Проверка тестового быстрого входа',
          );
          result['passwordMatched'] = restored == _password;
          result['encryptedContainerOpened'] =
              restored != null &&
              await compute(_containerCheck, {
                'path': '${widget.directory.path}/biometric-fixture.hv',
                'password': restored,
              });
        case 'Пароль контейнера':
          result['wrongPasswordRejected'] = !await compute(_containerCheck, {
            'path': '${widget.directory.path}/biometric-fixture.hv',
            'password': 'wrong fixture password',
          });
          result['encryptedContainerOpened'] = await compute(_containerCheck, {
            'path': '${widget.directory.path}/biometric-fixture.hv',
            'password': _password,
          });
        case 'Удалить':
          await _vault.forget();
          result['removed'] = !(await _vault.options()).enabled;
      }
      result['success'] =
          result['passwordMatched'] != false &&
          result['encryptedContainerOpened'] != false;
    } catch (error) {
      result['success'] = false;
      result['type'] = error.runtimeType.toString();
      if (error is PlatformException) result['code'] = error.code;
      // Local stand evidence only: never include this raw file in a report.
      await File(
        '${widget.directory.path}/failure-private.txt',
      ).writeAsString(error.toString());
    }
    final report = File('${widget.directory.path}/result.json');
    await report.writeAsString(jsonEncode(result));
    if (mounted) {
      setState(() {
        _busy = false;
        _status = jsonEncode(result);
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Отпечаток — отдельный QA стенд')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_status),
          const SizedBox(height: 24),
          for (final operation in [
            'Статус',
            'Настроить',
            'Открыть',
            'Пароль контейнера',
            'Удалить',
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: FilledButton(
                onPressed: _busy ? null : () => _run(operation),
                child: Text(operation),
              ),
            ),
        ],
      ),
    ),
  );
}
