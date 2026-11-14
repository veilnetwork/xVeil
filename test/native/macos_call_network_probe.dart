import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xveil/core/background_service_lifetime.dart';
import 'package:xveil/state/call_network_activity.dart';

/// Packaged runner check. No app providers, container, node or media capture.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Call network retirement QA'))),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_probe()));
}

Future<void> _probe() async {
  const channel = MethodChannel('xveil/call_network');
  var checks = 0;
  void require(bool condition) {
    checks++;
    if (!condition) throw StateError('packaged native resource check refused');
  }

  try {
    require(Platform.isMacOS);
    final old = CallNetworkActivity.shared;
    final originalOwner = Object();
    require(await old.acquire(originalOwner));
    require(await channel.invokeMethod<bool>('isActive') == true);
    final background = BackgroundServiceActions.platform();
    final retirement = await background.retireForErasure();
    await retirement.verifyReleasedResources();
    require(await channel.invokeMethod<bool>('isActive') == false);
    require(!await old.acquire(Object()));
    require(
      await channel.invokeMethod<bool>('setActive', {'active': true}) == false,
    );
    var foreignRefused = false;
    try {
      await channel.invokeMethod<void>('releaseRetirement', {
        'token': 'synthetic-foreign',
      });
    } on PlatformException {
      foreignRefused = true;
    }
    require(foreignRefused);
    await retirement.releaseAdmission();
    final fresh = CallNetworkActivity.shared;
    require(!identical(old, fresh));
    final currentOwner = Object();
    require(await fresh.acquire(currentOwner));
    require(await channel.invokeMethod<bool>('isActive') == true);
    await old.release(originalOwner);
    require(await channel.invokeMethod<bool>('isActive') == true);
    await fresh.release(currentOwner);
    require(await channel.invokeMethod<bool>('isActive') == false);
    await retirement.releaseAdmission();
    require(identical(CallNetworkActivity.shared, fresh));
    stdout.writeln(
      'XVEIL_NATIVE_RESOURCE_QA ${jsonEncode({'schema': 'xveil-native-resource-qa/1', 'passed': true, 'checks': checks})}',
    );
    await stdout.flush();
    exit(0);
  } catch (_) {
    // Cleanup only this probe's native process resources, without guessing a
    // successful test. The error report excludes paths, ids and native tokens.
    try {
      final token = await channel.invokeMethod<String>('retire');
      if (token != null) {
        await channel.invokeMethod<void>('releaseRetirement', {'token': token});
      }
    } catch (_) {}
    stdout.writeln(
      'XVEIL_NATIVE_RESOURCE_QA ${jsonEncode({'schema': 'xveil-native-resource-qa/1', 'passed': false, 'checks': checks})}',
    );
    await stdout.flush();
    exit(1);
  }
}
