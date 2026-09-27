import 'dart:convert';
import 'dart:io';

import 'package:app_updater/app_updater.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The shared self-update path (extracted from opsurface lib/update).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<int> apk = utf8.encode('fake apk bytes');
  final String digest = sha256.convert(apk).toString();
  Map<String, Object?> manifest({int code = 7, String? sha}) => <String, Object?>{
        'version': '0.1.0+$code',
        'versionCode': code,
        'url': 'https://h.ts.net/app/app-0.1.0+$code-20260927T000000+0000.apk',
        'sha256': sha ?? digest,
        'builtAt': '2026-09-27T00:00:00Z',
        'notes': '',
      };

  group('manifest', () {
    test('parses the published shape and refuses what cannot be verified', () {
      expect(UpdateInfo.fromJson(manifest()).versionCode, 7);
      expect(() => UpdateInfo.fromJson(<String, dynamic>{...manifest(), 'sha256': 'abc'}), throwsA(isA<UpdateException>()));
      expect(() => UpdateInfo.fromJson(<String, dynamic>{...manifest(), 'versionCode': '7'}), throwsA(isA<UpdateException>()));
      expect(() => UpdateInfo.fromJson(<String, dynamic>{...manifest(), 'url': 'not a url'}), throwsA(isA<UpdateException>()));
    });

    test('the running ordinal is the compiled-in define, else the platform number, else 0', () {
      expect(runningOrdinal(define: '5', platformBuildNumber: '2005'), 5);
      expect(runningOrdinal(define: '', platformBuildNumber: '3'), 3);
      expect(runningOrdinal(define: '', platformBuildNumber: 'x'), 0);
      expect(latestManifestUrl(Uri.parse('https://h/app//')).toString(), 'https://h/app/latest.json');
    });
  });

  group('checker', () {
    test('offers a newer build, stays quiet when current, and tries every URL before failing', () async {
      final List<Uri> hit = <Uri>[];
      final UpdateChecker c = UpdateChecker(httpClient: MockClient((http.Request r) async {
        hit.add(r.url);
        if (r.url.host == 'down') return http.Response('', 502);
        return http.Response(jsonEncode(manifest()), 200);
      }));
      expect((await c.check(<Uri>[Uri.parse('https://down/latest.json'), Uri.parse('https://up/latest.json')], running: 6))?.versionCode, 7);
      expect(await c.check(<Uri>[Uri.parse('https://up/latest.json')], running: 7), isNull);
      await expectLater(c.check(<Uri>[Uri.parse('https://down/latest.json')], running: 1), throwsA(isA<UpdateException>().having((UpdateException e) => e.message, 'message', contains('https://down/latest.json'))));
      expect(hit.first.host, 'down');
    });
  });

  group('installer', () {
    late Directory cache;
    final List<MethodCall> calls = <MethodCall>[];
    setUp(() {
      cache = Directory.systemTemp.createTempSync('app_updater_');
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(UpdateInstaller.channel, (MethodCall call) async {
        calls.add(call);
        return switch (call.method) { 'cacheDir' => cache.path, 'installApk' => true, _ => null };
      });
    });

    test('a verified APK is written under cache/app_updater and handed off', () async {
      final UpdateInstaller i = UpdateInstaller(httpClient: MockClient((http.Request r) async => http.Response.bytes(apk, 200)));
      final List<UpdateProgress> seen = await i.install(UpdateInfo.fromJson(manifest())).toList();
      expect(seen.last.stage, UpdateStage.handedOff);
      final String path = calls.firstWhere((MethodCall c) => c.method == 'installApk').arguments['path'] as String;
      expect(path, startsWith('${cache.path}/app_updater/'));
      expect(File(path).readAsBytesSync(), apk);
    });

    test('a digest mismatch fails and nothing is written or handed off', () async {
      final UpdateInstaller i = UpdateInstaller(httpClient: MockClient((http.Request r) async => http.Response.bytes(utf8.encode('tampered'), 200)));
      final List<UpdateProgress> seen = await i.install(UpdateInfo.fromJson(manifest())).toList();
      expect(seen.last.stage, UpdateStage.failed);
      expect(seen.last.message, contains('checksum mismatch'));
      expect(calls.where((MethodCall c) => c.method == 'installApk'), isEmpty);
      expect(Directory('${cache.path}/app_updater').existsSync(), isFalse);
    });

    test('a refused hand-off deletes the APK and says what to grant', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(UpdateInstaller.channel, (MethodCall call) async => call.method == 'cacheDir' ? cache.path : false);
      final UpdateInstaller i = UpdateInstaller(httpClient: MockClient((http.Request r) async => http.Response.bytes(apk, 200)), appLabel: 'mobiharness');
      final List<UpdateProgress> seen = await i.install(UpdateInfo.fromJson(manifest())).toList();
      expect(seen.last.message, contains('allow mobiharness to install unknown apps'));
      expect(Directory('${cache.path}/app_updater').listSync(), isEmpty);
    });
  });
}
