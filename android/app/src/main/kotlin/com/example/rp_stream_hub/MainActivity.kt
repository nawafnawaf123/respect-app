package com.example.rp_stream_hub

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "incoming_call_channel"

    companion object {
        private val handledActions = LinkedHashMap<String, Long>()
        private const val ACTION_TTL_MS = 2 * 60 * 1000L

        private fun cleanupHandledActions() {
            val now = System.currentTimeMillis()
            val iterator = handledActions.entries.iterator()
            while (iterator.hasNext()) {
                val entry = iterator.next()
                if (now - entry.value > ACTION_TTL_MS) iterator.remove()
            }
        }

        private fun markActionHandled(action: String, callId: String): Boolean {
            cleanupHandledActions()
            val key = "$action:$callId"
            if (handledActions.containsKey(key)) return false
            handledActions[key] = System.currentTimeMillis()
            return true
        }
    }
    private lateinit var methodChannel: MethodChannel

    private var pendingAction: String? = null
    private var pendingCallId: String? = null
    private var pendingCallerName: String? = null
    private var pendingCallerUsername: String? = null
    private var pendingCallerAvatar: String? = null
    private var pendingVideo: Boolean = false

    private val callActionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            handleCallActionIntent(intent, true)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "showIncomingCall" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args == null) {
                        result.error("INVALID_ARGS", "Missing arguments", null)
                        return@setMethodCallHandler
                    }

                    val callId = args["callId"] as? String ?: ""
                    val callerName = args["callerName"] as? String ?: "مستخدم"
                    val callerUsername = args["callerUsername"] as? String ?: ""
                    val callerAvatar = args["callerAvatarPath"] as? String ?: ""
                    val video = args["video"] as? Boolean ?: false

                    if (callId.isBlank()) {
                        result.error("INVALID_CALL_ID", "callId is empty", null)
                        return@setMethodCallHandler
                    }

                    IncomingCallForegroundService.start(
                        this,
                        callId,
                        callerName,
                        callerUsername,
                        callerAvatar,
                        video
                    )

                    result.success(true)
                }

                "stopIncomingCall" -> {
                    try {
                        IncomingCallForegroundService.stop(this)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }

                "consumePendingCallAction" -> {
                    val action = pendingAction
                    val callId = pendingCallId

                    if (action != null && callId != null) {
                        val data = mapOf(
                            "action" to action,
                            "callId" to callId,
                            "callerName" to (pendingCallerName ?: "مستخدم"),
                            "callerUsername" to (pendingCallerUsername ?: ""),
                            "callerAvatarPath" to (pendingCallerAvatar ?: ""),
                            "video" to pendingVideo
                        )

                        clearPendingAction()
                        result.success(data)
                    } else {
                        result.success(null)
                    }
                }

                else -> result.notImplemented()
            }
        }

        handleCallActionIntent(intent, false)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleCallActionIntent(intent, true)
    }

    private fun handleCallActionIntent(intent: Intent?, sendNow: Boolean) {
        if (intent == null) return

        val action = intent.getStringExtra("action") ?: return
        val callId = intent.getStringExtra("callId") ?: return

        if (action.isBlank() || callId.isBlank()) return

        if (sendNow && !markActionHandled(action, callId)) {
            clearIntentCallAction(intent)
            return
        }

        pendingAction = action
        pendingCallId = callId
        pendingCallerName = intent.getStringExtra("callerName") ?: intent.getStringExtra("caller_name") ?: "مستخدم"
        pendingCallerUsername = intent.getStringExtra("callerUsername") ?: intent.getStringExtra("caller_username") ?: ""
        pendingCallerAvatar = intent.getStringExtra("callerAvatarPath")
            ?: intent.getStringExtra("callerAvatar")
                    ?: intent.getStringExtra("caller_avatar")
                    ?: ""
        pendingVideo = intent.getBooleanExtra("video", false)

        if (sendNow && ::methodChannel.isInitialized) {
            methodChannel.invokeMethod(
                "onCallAction",
                mapOf(
                    "action" to action,
                    "callId" to callId,
                    "callerName" to (pendingCallerName ?: "مستخدم"),
                    "callerUsername" to (pendingCallerUsername ?: ""),
                    "callerAvatarPath" to (pendingCallerAvatar ?: ""),
                    "video" to pendingVideo
                )
            )
            clearPendingAction()
            clearIntentCallAction(intent)
        }
    }

    private fun clearIntentCallAction(intent: Intent?) {
        try {
            intent?.removeExtra("action")
            intent?.removeExtra("callId")
            intent?.removeExtra("callerName")
            intent?.removeExtra("callerUsername")
            intent?.removeExtra("callerAvatarPath")
            intent?.removeExtra("video")
        } catch (_: Exception) {
        }
    }

    private fun clearPendingAction() {
        pendingAction = null
        pendingCallId = null
        pendingCallerName = null
        pendingCallerUsername = null
        pendingCallerAvatar = null
        pendingVideo = false
    }

    override fun onResume() {
        super.onResume()

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(
                    callActionReceiver,
                    IntentFilter("INCOMING_CALL_ACTION"),
                    Context.RECEIVER_NOT_EXPORTED
                )
            } else {
                @Suppress("DEPRECATION")
                registerReceiver(callActionReceiver, IntentFilter("INCOMING_CALL_ACTION"))
            }
        } catch (_: Exception) {
        }

        handleCallActionIntent(intent, true)
    }

    override fun onPause() {
        super.onPause()

        try {
            unregisterReceiver(callActionReceiver)
        } catch (_: Exception) {
        }
    }
}