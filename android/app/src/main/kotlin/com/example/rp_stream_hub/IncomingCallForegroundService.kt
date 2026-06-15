package com.example.rp_stream_hub

import android.app.*
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class IncomingCallForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "respect_calls_channel_service"
        private val activeCalls = LinkedHashMap<String, Long>()
        private const val ACTIVE_CALL_TTL_MS = 2 * 60 * 1000L

        private fun cleanupActiveCalls() {
            val now = System.currentTimeMillis()
            val iterator = activeCalls.entries.iterator()
            while (iterator.hasNext()) {
                val entry = iterator.next()
                if (now - entry.value > ACTIVE_CALL_TTL_MS) iterator.remove()
            }
        }

        private fun markIncomingShown(callId: String): Boolean {
            cleanupActiveCalls()
            if (callId.isBlank()) return false
            if (activeCalls.containsKey(callId)) return false
            activeCalls[callId] = System.currentTimeMillis()
            return true
        }
        private const val NOTIFICATION_ID = 101
        const val ACTION_SHOW_INCOMING_CALL = "SHOW_INCOMING_CALL"
        const val EXTRA_CALL_ID = "call_id"
        const val EXTRA_CALLER_NAME = "caller_name"
        const val EXTRA_CALLER_USERNAME = "caller_username"
        const val EXTRA_CALLER_AVATAR = "caller_avatar"
        const val EXTRA_VIDEO = "video"

        fun start(context: Context, callId: String, callerName: String, callerUsername: String, callerAvatar: String, video: Boolean) {
            val intent = Intent(context, IncomingCallForegroundService::class.java).apply {
                action = ACTION_SHOW_INCOMING_CALL
                putExtra(EXTRA_CALL_ID, callId)
                putExtra(EXTRA_CALLER_NAME, callerName)
                putExtra(EXTRA_CALLER_USERNAME, callerUsername)
                putExtra(EXTRA_CALLER_AVATAR, callerAvatar)
                putExtra(EXTRA_VIDEO, video)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            try { activeCalls.clear() } catch (_: Exception) {}
            context.stopService(Intent(context, IncomingCallForegroundService::class.java))
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_SHOW_INCOMING_CALL) {
            val callId = intent.getStringExtra(EXTRA_CALL_ID) ?: ""
            val callerName = intent.getStringExtra(EXTRA_CALLER_NAME) ?: "مستخدم"
            val callerUsername = intent.getStringExtra(EXTRA_CALLER_USERNAME) ?: ""
            val callerAvatar = intent.getStringExtra(EXTRA_CALLER_AVATAR) ?: ""
            val video = intent.getBooleanExtra(EXTRA_VIDEO, false)

            if (!markIncomingShown(callId)) {
                return START_NOT_STICKY
            }

            val notification = buildForegroundNotification(callId, callerName, callerUsername, callerAvatar, video)
            startForeground(NOTIFICATION_ID, notification)
            showFullScreenIncomingCall(callId, callerName, callerUsername, callerAvatar, video)
        }
        return START_NOT_STICKY
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ringtoneUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()

            val channel = NotificationChannel(
                CHANNEL_ID,
                "Respect Incoming Calls",
                NotificationManager.IMPORTANCE_MAX
            ).apply {
                description = "شاشة ورنين المكالمات الواردة"
                setSound(ringtoneUri, attrs)
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 800, 400, 800, 400, 800)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildForegroundNotification(
        callId: String,
        callerName: String,
        callerUsername: String,
        callerAvatar: String,
        video: Boolean
    ): Notification {
        val fullScreenIntent = Intent(this, IncomingCallFullScreenActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra("callId", callId)
            putExtra("callerName", callerName)
            putExtra("callerUsername", callerUsername)
            putExtra("callerAvatar", callerAvatar)
            putExtra("video", video)
        }

        val fullScreenPendingIntent = PendingIntent.getActivity(
            this,
            callId.hashCode(),
            fullScreenIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val ringtoneUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(if (video) "مكالمة فيديو واردة" else "مكالمة صوتية واردة")
            .setContentText("من $callerName")
            .setSmallIcon(android.R.drawable.ic_menu_call)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setSound(ringtoneUri)
            .setVibrate(longArrayOf(0, 800, 400, 800, 400, 800))
            .setFullScreenIntent(fullScreenPendingIntent, true)
            .setContentIntent(fullScreenPendingIntent)
            .build()
    }

    private fun showFullScreenIncomingCall(callId: String, callerName: String, callerUsername: String, callerAvatar: String, video: Boolean) {
        val intent = Intent(this, IncomingCallFullScreenActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra("callId", callId)
            putExtra("callerName", callerName)
            putExtra("callerUsername", callerUsername)
            putExtra("callerAvatar", callerAvatar)
            putExtra("video", video)
        }
        startActivity(intent)
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
