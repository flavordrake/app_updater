# app_updater

Self-update for sideloaded Android Flutter apps: opsurface, mobiharness, and later mobissh.

The app publishes a `latest.json` beside its APK. This library checks it, downloads the newer build, verifies its sha256 in memory before anything is written, and hands the APK to the Android package installer.

## Manifest

```json
{"version": "0.1.0+7", "versionCode": 7, "url": "https://host/app/app-0.1.0+7.apk", "sha256": "<64 hex>", "builtAt": "2026-09-27T14:46:41Z", "notes": ""}
```

`versionCode` is the build ordinal and the only field compared. Compile the ordinal in with `--dart-define` (split-per-abi offsets the platform versionCode per ABI).

## Use

```yaml
dependencies:
  app_updater:
    git:
      url: https://github.com/flavordrake/app_updater.git
      ref: v0.1.0
```

```dart
final checker = UpdateChecker();
final info = await checker.check([Uri.parse(manifestUrl)], running: runningOrdinal(define: const String.fromEnvironment('MY_BUILD')));
if (info != null) {
  await for (final p in UpdateInstaller(appLabel: 'myapp').install(info)) { /* show p.stage, p.fraction */ }
}
```

## Android

The plugin brings its own manifest entries: `REQUEST_INSTALL_PACKAGES` and a FileProvider subclass with authority `${applicationId}.app_updater.fileprovider`, so it does not collide with an app's own provider. It only hands off files under `cache/app_updater/`. The native side is Java, so apps on AGP 9 with built-in Kotlin off still compile it.

## Guarantees

- A manifest that cannot be verified is refused, not guessed at.
- The first reachable manifest wins. When none answers, the error names every URL tried.
- An APK whose digest does not match is never written to disk.
- When Android refuses the hand-off, the APK is deleted and the message names the permission to grant.
