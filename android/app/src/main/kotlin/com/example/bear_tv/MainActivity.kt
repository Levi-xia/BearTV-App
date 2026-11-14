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
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private var updaterChannel: MethodChannel? = null
    private var storageChannel: MethodChannel? = null
    private var downloadsChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Keeps downloads running while the app is in the background; Dart
        // falls back to pausing when the start is refused.
        downloadsChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DOWNLOADS_CHANNEL)
        downloadsChannel?.setMethodCallHandler { call, result ->
                val title = call.argument<String>("title") ?: ""
                val text = call.argument<String>("text") ?: ""
                val progress = call.argument<Int>("progress") ?: -1
                val max = call.argument<Int>("max") ?: 0
                when (call.method) {
                    "start" -> result.success(
                        if (DownloadForegroundService.isRunning()) {
                            // Already up: refreshing avoids a redundant start
                            // call, which Android 12+ can refuse from the
                            // background.
                            DownloadForegroundService.update(title, text, progress, max)
                        } else {
                            DownloadForegroundService.start(
                                this,
                                title,
                                text,
                                progress,
                                max,
                            )
                        },
                    )
                    "update" -> result.success(
                        DownloadForegroundService.update(title, text, progress, max),
                    )
                    "stop" -> {
                        DownloadForegroundService.stop(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Downloads need to know how much room is left before queueing a task.
        storageChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL)
        storageChannel?.setMethodCallHandler { call, result ->
                when (call.method) {
                    "freeBytes" -> {
                        val path = call.argument<String>("path")
                        result.success(if (path.isNullOrEmpty()) null else freeBytes(path))
                    }
                    else -> result.notImplemented()
                }
            }

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
                                verifyInPlaceUpdate(File(path))
                                installApk(File(path))
                                result.success(null)
                            } catch (e: InstallBlocked) {
                                result.error("install_blocked", e.message, null)
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
        storageChannel?.setMethodCallHandler(null)
        storageChannel = null
        downloadsChannel?.setMethodCallHandler(null)
        downloadsChannel = null
        super.onDestroy()
    }

    /**
     * Bytes the app can still write on [path]'s volume (Android's per-app
     * quota aware). Walks up to the nearest existing ancestor so a not-yet
     * created downloads folder still answers.
     */
    private fun freeBytes(path: String): Long? {
        return try {
            var file = File(path)
            while (!file.exists() && file.parentFile != null) {
                file = file.parentFile!!
            }
            val usable = file.usableSpace
            if (usable > 0) usable else null
        } catch (e: Exception) {
            null
        }
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

    /**
     * Refuses an APK Android would not accept as an in-place update.
     *
     * The system only replaces an app while the package name, signing
     * certificate and a non-decreasing versionCode all match. Otherwise the
     * install fails with INSTALL_FAILED_* and the only way forward is to
     * uninstall first — which deletes `/data/data/<pkg>` and with it every
     * preference, the play history and all downloaded episodes. Checking here
     * turns that silent wipe into a readable reason.
     */
    private fun verifyInPlaceUpdate(apk: File) {
        if (!apk.exists()) throw InstallBlocked("安装包不存在，请重新下载")
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION") PackageManager.GET_SIGNATURES
        }
        val archive = packageManager.getPackageArchiveInfo(apk.absolutePath, flags)
            ?: throw InstallBlocked("安装包解析失败，请重新下载")
        if (archive.packageName != packageName) {
            throw InstallBlocked("安装包与当前应用不一致（${archive.packageName}），已取消安装")
        }
        val installed = packageInfo()
        val newCode = versionCodeOf(archive)
        val oldCode = versionCodeOf(installed)
        if (newCode < oldCode) {
            throw InstallBlocked(
                "安装包版本 ${archive.versionName}（$newCode）低于当前版本 " +
                    "${installed.versionName}（$oldCode），系统只能先卸载再安装，" +
                    "设置、播放记录和下载会一起清空。请用更高的版本号重新构建",
            )
        }
        if (signerDigests(installed) != signerDigests(archive)) {
            throw InstallBlocked(
                "安装包签名与当前版本不一致，系统只能先卸载再安装，" +
                    "设置、播放记录和下载会一起清空。请改用同一 keystore 构建",
            )
        }
    }

    private fun versionCodeOf(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION") info.versionCode.toLong()
        }

    @Suppress("DEPRECATION")
    private fun signerDigests(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners
        } else {
            info.signatures
        }
        return signatures?.map { sha256(it.toByteArray()) }?.toSet() ?: emptySet()
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }

    /** Native-side refusal to install; the message is shown verbatim in the UI. */
    private class InstallBlocked(message: String) : Exception(message)

    private companion object {
        const val CHANNEL = "bear_tv/updater"
        const val STORAGE_CHANNEL = "bear_tv/storage"
        const val DOWNLOADS_CHANNEL = "bear_tv/downloads"
    }
}