package dev.flavordrake.app_updater;

import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;

import androidx.annotation.NonNull;
import androidx.core.content.FileProvider;

import java.io.File;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * The native half of the self-update hand-off (ported from opsurface's
 * MainActivity, #57). Dart downloads and verifies; only the FileProvider
 * content:// URI and the install intent must be native.
 *
 * SECURITY: the only input from Dart is a path, and it must resolve inside
 * cache/app_updater/; anything else is refused before the provider sees it.
 */
public class AppUpdaterPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
  private MethodChannel channel;
  private Context context;

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    context = binding.getApplicationContext();
    channel = new MethodChannel(binding.getBinaryMessenger(), "dev.flavordrake.app_updater/installer");
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    channel.setMethodCallHandler(null);
    channel = null;
    context = null;
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    switch (call.method) {
      case "cacheDir":
        result.success(context.getCacheDir().getAbsolutePath());
        break;
      case "installApk":
        result.success(installApk(call.argument("path")));
        break;
      default:
        result.notImplemented();
    }
  }

  /** False when the install cannot start; the owner is sent to the unknown-apps grant screen. */
  private boolean installApk(String path) {
    if (path == null) return false;
    File apk = new File(path);
    File root = new File(context.getCacheDir(), "app_updater");
    try {
      if (!apk.getCanonicalPath().startsWith(root.getCanonicalPath() + File.separator)) return false;
    } catch (java.io.IOException e) {
      return false;
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !context.getPackageManager().canRequestPackageInstalls()) {
      context.startActivity(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + context.getPackageName())).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
      return false;
    }
    Uri uri = FileProvider.getUriForFile(context, context.getPackageName() + ".app_updater.fileprovider", apk);
    context.startActivity(new Intent(Intent.ACTION_VIEW)
        .setDataAndType(uri, "application/vnd.android.package-archive")
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
    return true;
  }
}
