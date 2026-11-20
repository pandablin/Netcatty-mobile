package app.netcatty.mobile

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.content.ContextCompat

class SshKeepAliveService : Service() {
    companion object {
        private const val TAG = "SshKeepAliveService"
        private const val CHANNEL_ID = "netcatty_ssh_sessions"
        private const val NOTIFICATION_ID = 701

        // Touched only on the main thread: MethodChannel handlers and Service
        // lifecycle callbacks both run there, so no synchronisation is needed.
        /** startForegroundService() was called and onStartCommand() has not run yet. */
        private var startPending = false
        /** The service is in the foreground and has not been asked to stop. */
        private var running = false
        /** stop() arrived while a start was still pending. */
        private var stopRequested = false

        /**
         * Starts the keep-alive foreground service. Failures are logged and
         * swallowed: an SSH session must never die because Android refused to
         * show the keep-alive notification.
         */
        fun start(context: Context) {
            stopRequested = false
            if (running || startPending) return
            try {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, SshKeepAliveService::class.java),
                )
                startPending = true
            } catch (error: RuntimeException) {
                // ForegroundServiceStartNotAllowedException (Android 12+) or
                // IllegalStateException when the app is already in background.
                Log.w(TAG, "Unable to start keep-alive service", error)
            }
        }

        /**
         * Stops the service without tripping Android's fatal
         * "startForegroundService() did not then call startForeground()" check.
         *
         * A connection that fails within milliseconds (an IPv6 host on an
         * IPv4-only network, a refused local HTTP proxy) used to call
         * stopService() before the service reached startForeground(), which
         * crashes the whole app on Android 9+ (upstream issues #38 / #40).
         * In that window the stop is deferred to onStartCommand() instead.
         */
        fun stop(context: Context) {
            if (startPending) {
                stopRequested = true
                return
            }
            if (!running) return
            running = false
            context.stopService(Intent(context, SshKeepAliveService::class.java))
        }
    }

    private var cpuWakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        enterForeground()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Every startForegroundService() must be matched by startForeground(),
        // even when the service instance already exists.
        enterForeground()
        startPending = false
        if (stopRequested) {
            stopRequested = false
            running = false
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        acquireConnectionLocks()
        // The SSH sockets live in the Flutter process. Restarting only this
        // service after that process was killed cannot restore them and would
        // leave an orphan notification holding locks indefinitely.
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        running = false
        releaseConnectionLocks()
        super.onDestroy()
    }

    @SuppressLint("WakelockTimeout")
    private fun acquireConnectionLocks() {
        if (cpuWakeLock?.isHeld != true) {
            cpuWakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "$packageName:ssh-cpu",
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }
        if (wifiLock?.isHeld != true) {
            @Suppress("DEPRECATION")
            wifiLock = (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager)
                .createWifiLock(
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                    "$packageName:ssh-wifi",
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }
    }

    private fun releaseConnectionLocks() {
        cpuWakeLock?.let { if (it.isHeld) it.release() }
        cpuWakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
    }

    private fun enterForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "SSH 会话",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "保持正在使用的 SSH 连接"
                setShowBadge(false)
            },
        )
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Netcatty SSH 会话正在运行")
            .setContentText("点击返回终端；关闭全部会话后服务会自动停止")
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }
}
