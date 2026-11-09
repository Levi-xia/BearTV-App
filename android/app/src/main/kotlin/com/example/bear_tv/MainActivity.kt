package com.example.bear_tv

import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var updaterChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        updaterChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        updaterChannel?.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAppInfo" -> result.success(appInfo())
                    "getDownloadDir" -> result.success(downloadDir().absolutePath)
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("bad_path", "missing apk path", null)
                        } else {
                            try {
                                installApk(File(path))
                                result.success(null)
                            } catch (e: Exception) {
                                result.error("install_failed", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        updaterChannel?.setMethodCallHandler(null)
        updaterChannel = null
        super.onDestroy()
    }

    /** Installed versionName/versionCode + the ABIs this device can run. */
    private fun appInfo(): Map<String, Any> {
        val info = packageInfo()
        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION") info.versionCode.toLong()
        }
        return mapOf(
            "versionName" to (info.versionName ?: ""),
            "versionCode" to versionCode,
            "supportedAbis" to (Build.SUPPORTED_ABIS ?: emptyArray<String>()).toList(),
        )
    }

    @Suppress("DEPRECATION")
    private fun packageInfo(): PackageInfo {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            packageManager.getPackageInfo(packageName, 0)
        }
    }

    /**
     * Where downloaded APKs land: app-specific external storage (no permission
     * needed, user-visible under Android/data) with an internal-files fallback.
     * Must match the `file_paths.xml` provider paths.
     */
    private fun downloadDir(): File {
        val base = getExternalFilesDir(null) ?: filesDir
        val dir = File(base, "updates")
        if (!dir.exists()) dir.mkdirs()
        return dir
    }

    /** Opens the system package installer for [apk]; the user confirms. */
    private fun installApk(apk: File) {
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", apk)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(intent)
    }

    private companion object {
        const val CHANNEL = "bear_tv/updater"
    }
}