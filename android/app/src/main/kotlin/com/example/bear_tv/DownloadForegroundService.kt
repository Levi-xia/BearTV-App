package com.example.bear_tv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Keeps the process alive while episodes download.
 *
 * The transfer engine is Dart, so moving the activity to the background does
 * not stop it — but Android is free to kill a cached process, which would leave
 * a half-written segment behind. A foreground service pins the process (and is
 * exempt from Doze), so the queue keeps running while the user watches
 * something else or the TV is idle.
 *
 * Driven from Dart through the `bear_tv/downloads` channel (see MainActivity and
 * lib/data/downloads/download_foreground.dart). Without this service the Dart
 * side falls back to pausing on background, which is still safe, just slower.
 */
class DownloadForegroundService : Service() {
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }
        val notification = buildNotification(
            title = intent?.getStringExtra(EXTRA_TITLE) ?: DEFAULT_TITLE,
            text = intent?.getStringExtra(EXTRA_TEXT).orEmpty(),
            progress = intent?.getIntExtra(EXTRA_PROGRESS, -1) ?: -1,
            max = intent?.getIntExtra(EXTRA_MAX, 0) ?: 0,
        )
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // Android 12+ can refuse the promotion (background start, battery
            // savers). Stop quietly: Dart keeps the pause-on-background path.
            stopSelf()
            return START_NOT_STICKY
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    /**
     * Removing the task kills the Flutter engine (and with it the Dart queue),
     * so don't leave a living notification behind.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopForegroundCompat()
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    /**
     * Android 15 caps `dataSync` services at 6 hours a day and calls this when
     * the budget runs out; without handling it the app would crash.
     */
    override fun onTimeout(startId: Int) {
        stopForegroundCompat()
        stopSelf()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        stopForegroundCompat()
        stopSelf()
    }

    private fun postUpdate(title: String, text: String, progress: Int, max: Int) {
        mainHandler.post {
            if (instance !== this) return@post
            val manager =
                getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                    ?: return@post
            manager.notify(
                NOTIFICATION_ID,
                buildNotification(title, text, progress, max),
            )
        }
    }

    private fun buildNotification(
        title: String,
        text: String,
        progress: Int,
        max: Int,
    ): Notification {
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            // The system download glyph exists on every API level and is the
            // right shape for a small icon (an adaptive launcher icon is not).
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(
                PendingIntent.getActivity(
                    this,
                    0,
                    Intent(this, MainActivity::class.java),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setSilent(true)
            .setLocalOnly(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
        if (max > 0 && progress >= 0) {
            builder.setProgress(max, progress.coerceAtMost(max), false)
        } else {
            builder.setProgress(0, 0, true)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Don't hold the first notification back for 10 s — the user should
            // see why the TV keeps working.
            builder.setForegroundServiceBehavior(
                NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE,
            )
        }
        return builder.build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "后台下载",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "下载剧集时保持应用在后台运行"
            setShowBadge(false)
            setSound(null, null)
            enableVibration(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    companion object {
        private const val CHANNEL_ID = "bear_tv_downloads"
        private const val NOTIFICATION_ID = 7311
        private const val ACTION_STOP = "com.example.bear_tv.downloads.STOP"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_PROGRESS = "progress"
        private const val EXTRA_MAX = "max"
        private const val DEFAULT_TITLE = "熊熊TV · 后台下载"

        /** The live service, so updates don't need a background start. */
        @Volatile
        private var instance: DownloadForegroundService? = null

        /**
         * When the last start was requested. The service is created
         * asynchronously, so an update that arrives before [instance] is set
         * must not be mistaken for "the service is gone".
         */
        @Volatile
        private var startRequestedAt = 0L

        fun isRunning(): Boolean = instance != null

        /**
         * Starts the service, or refreshes it when already up. Only call while
         * the app is in the foreground — Android 12+ refuses background starts.
         * Returns false when the system declined, so Dart can pause instead.
         */
        fun start(
            context: Context,
            title: String,
            text: String,
            progress: Int,
            max: Int,
        ): Boolean {
            val intent = Intent(context, DownloadForegroundService::class.java).apply {
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
                putExtra(EXTRA_PROGRESS, progress)
                putExtra(EXTRA_MAX, max)
            }
            return try {
                ContextCompat.startForegroundService(context, intent)
                startRequestedAt = SystemClock.elapsedRealtime()
                true
            } catch (e: Exception) {
                false
            }
        }

        /** Refreshes the notification of a running service; no-op when it's down. */
        fun update(title: String, text: String, progress: Int, max: Int): Boolean {
            val service = instance
            if (service != null) {
                service.postUpdate(title, text, progress, max)
                return true
            }
            // Still being delivered to onCreate: report "up" rather than
            // making Dart fall back to pausing for a start that is succeeding.
            return startRequestedAt > 0 &&
                SystemClock.elapsedRealtime() - startRequestedAt < START_GRACE_MS
        }

        fun stop(context: Context) {
            startRequestedAt = 0
            try {
                context.stopService(Intent(context, DownloadForegroundService::class.java))
            } catch (e: Exception) {
                // Already gone.
            }
        }

        private const val START_GRACE_MS = 5000L
    }
}
