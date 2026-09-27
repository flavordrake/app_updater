/// Self-update for sideloaded Android apps, extracted from opsurface's
/// lib/update (#57, #62, #263) so every fleet app gets the same checked path:
/// fetch `latest.json`, compare the compiled-in build ordinal, download,
/// verify sha256 in memory, write only a verified APK, hand it to Android.
///
/// The app supplies its manifest URLs and its running ordinal; nothing here
/// knows an app name, a host list or a state-management library.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Every self-update failure (transport, status, shape, digest) is this type.
class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// `<dist root>/latest.json`.
Uri latestManifestUrl(Uri distRoot) => Uri.parse('${distRoot.toString().replaceAll(RegExp(r'/+$'), '')}/latest.json');

final RegExp _sha256Pattern = RegExp(r'^[0-9a-fA-F]{64}$');

/// One published build, as ship-apk.sh's gen-latest-json.sh writes it.
class UpdateInfo {
  const UpdateInfo({required this.version, required this.versionCode, required this.url, required this.sha256, required this.builtAt, required this.notes});

  /// A manifest that cannot be verified is worse than none: every field the
  /// installer needs is checked here.
  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    final Object? version = json['version'];
    if (version is! String || version.isEmpty) throw const UpdateException('latest.json has no version');
    final Object? versionCode = json['versionCode'];
    if (versionCode is! int) throw const UpdateException('latest.json versionCode is not a number');
    final Object? url = json['url'];
    final Uri? parsedUrl = url is String ? Uri.tryParse(url) : null;
    if (parsedUrl == null || !parsedUrl.hasScheme) throw const UpdateException('latest.json has no usable url');
    final Object? digest = json['sha256'];
    if (digest is! String || !_sha256Pattern.hasMatch(digest)) throw const UpdateException('latest.json sha256 is not 64 hex characters');
    final Object? builtAt = json['builtAt'];
    final Object? notes = json['notes'];
    return UpdateInfo(
      version: version,
      versionCode: versionCode,
      url: parsedUrl,
      sha256: digest.toLowerCase(),
      builtAt: builtAt is String ? DateTime.tryParse(builtAt)?.toUtc() : null,
      notes: notes is String ? notes : '',
    );
  }

  /// `x.y.z+B`.
  final String version;

  /// `B`, the build ordinal: the only field compared.
  final int versionCode;
  final Uri url;
  final String sha256;
  final DateTime? builtAt;
  final String notes;

  bool isNewerThan(int runningOrdinal) => versionCode > runningOrdinal;
}

/// The running build's ordinal from its compiled-in define (split-per-abi
/// offsets the platform versionCode by 1000 × abi, so the define is the truth,
/// opsurface #263); the platform build number only as a fallback.
int runningOrdinal({required String define, String platformBuildNumber = ''}) => int.tryParse(define) ?? int.tryParse(platformBuildNumber) ?? 0;

class UpdateChecker {
  UpdateChecker({http.Client? httpClient, this.timeout = const Duration(seconds: 5)}) : _http = httpClient ?? http.Client();
  final http.Client _http;
  final Duration timeout;

  /// The manifest at [manifestUrl], whether or not it is newer.
  Future<UpdateInfo> fetch(Uri manifestUrl) async {
    final http.Response r;
    try {
      r = await _http.get(manifestUrl).timeout(timeout);
    } on TimeoutException {
      throw UpdateException('$manifestUrl timed out after ${timeout.inSeconds}s');
    } on Object catch (e) {
      throw UpdateException('$manifestUrl unreachable: $e');
    }
    if (r.statusCode != 200) throw UpdateException('$manifestUrl returned HTTP ${r.statusCode}');
    final Object? decoded;
    try {
      decoded = jsonDecode(r.body);
    } on FormatException catch (e) {
      throw UpdateException('$manifestUrl returned invalid JSON: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) throw UpdateException('$manifestUrl returned a ${decoded.runtimeType}, not an update manifest');
    return UpdateInfo.fromJson(decoded);
  }

  /// First reachable manifest wins; newer than [running] or null. When none
  /// answers the error names every URL tried, so "up to date" never masks
  /// "nothing reachable" (opsurface #62).
  Future<UpdateInfo?> check(List<Uri> manifestUrls, {required int running}) async {
    final List<String> tried = <String>[];
    for (final Uri url in manifestUrls) {
      try {
        final UpdateInfo info = await fetch(url);
        return info.isNewerThan(running) ? info : null;
      } on UpdateException {
        tried.add(url.toString());
      }
    }
    throw UpdateException('No update manifest reachable. Tried: ${tried.join(', ')}');
  }

  void close() => _http.close();
}

/// Explicit lifecycle, no boolean pile.
enum UpdateStage { idle, downloading, verifying, launching, handedOff, failed }

class UpdateProgress {
  const UpdateProgress({required this.stage, this.received = 0, this.total, this.message});
  static const UpdateProgress idle = UpdateProgress(stage: UpdateStage.idle);

  final UpdateStage stage;
  final int received;
  final int? total;

  /// Set on [UpdateStage.failed]: the reason in plain words.
  final String? message;

  /// Null is indeterminate.
  double? get fraction {
    final int? t = total;
    return (t == null || t <= 0) ? null : received / t;
  }

  bool get isBusy => switch (stage) {
        UpdateStage.downloading || UpdateStage.verifying || UpdateStage.launching => true,
        UpdateStage.idle || UpdateStage.handedOff || UpdateStage.failed => false,
      };
}

/// Downloads, verifies and hands off. The APK is buffered in memory and only
/// written once its digest matches, so an unverified APK never exists as a
/// file anything else could be pointed at.
class UpdateInstaller {
  UpdateInstaller({http.Client? httpClient, this.appLabel = 'this app'}) : _http = httpClient ?? http.Client();

  /// The plugin's own channel: cache dir and the FileProvider hand-off.
  static const MethodChannel channel = MethodChannel('dev.flavordrake.app_updater/installer');

  final http.Client _http;

  /// Named in the "allow installs" message.
  final String appLabel;

  Stream<UpdateProgress> install(UpdateInfo info) async* {
    try {
      final http.StreamedResponse response = await _http.send(http.Request('GET', info.url));
      if (response.statusCode != 200) {
        yield UpdateProgress(stage: UpdateStage.failed, message: '${info.url} returned HTTP ${response.statusCode}');
        return;
      }
      final int? total = response.contentLength;
      final BytesBuilder buffer = BytesBuilder(copy: false);
      yield UpdateProgress(stage: UpdateStage.downloading, total: total);
      await for (final List<int> chunk in response.stream) {
        buffer.add(chunk);
        yield UpdateProgress(stage: UpdateStage.downloading, received: buffer.length, total: total);
      }
      yield const UpdateProgress(stage: UpdateStage.verifying);
      final Uint8List bytes = buffer.takeBytes();
      final String digest = sha256.convert(bytes).toString();
      if (digest != info.sha256) {
        yield UpdateProgress(stage: UpdateStage.failed, message: 'checksum mismatch: expected ${info.sha256}, got $digest');
        return;
      }
      final File apk = await _write(bytes, info);
      yield const UpdateProgress(stage: UpdateStage.launching);
      final bool launched = await channel.invokeMethod<bool>('installApk', <String, Object?>{'path': apk.path}) ?? false;
      if (!launched) {
        await apk.delete();
        yield UpdateProgress(stage: UpdateStage.failed, message: 'Android declined the hand-off: allow $appLabel to install unknown apps, then try again.');
        return;
      }
      yield const UpdateProgress(stage: UpdateStage.handedOff);
    } on Object catch (e) {
      yield UpdateProgress(stage: UpdateStage.failed, message: '$e');
    }
  }

  Future<File> _write(Uint8List bytes, UpdateInfo info) async {
    final String? cacheDir = await channel.invokeMethod<String>('cacheDir');
    if (cacheDir == null || cacheDir.isEmpty) throw const UpdateException('no app cache directory to download into');
    // Must match android/src/main/res/xml/app_updater_paths.xml.
    final Directory dir = Directory('$cacheDir/app_updater');
    await dir.create(recursive: true);
    final File apk = File('${dir.path}/${fileNameFor(info)}');
    await apk.writeAsBytes(bytes, flush: true);
    return apk;
  }

  /// The published file name, reduced to safe characters.
  static String fileNameFor(UpdateInfo info) {
    final String published = info.url.pathSegments.isEmpty ? '' : info.url.pathSegments.last;
    final String safe = published.replaceAll(RegExp(r'[^A-Za-z0-9._+-]'), '_');
    return safe.isEmpty ? 'update-${info.versionCode}.apk' : safe;
  }

  void close() => _http.close();
}
