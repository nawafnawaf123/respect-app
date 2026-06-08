package com.example.rp_stream_hub

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class IncomingCallFirebaseMessagingService : FirebaseMessagingService() {

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)

        val data = message.data
        val type = data["type"] ?: ""

        if (type == "call") {
            val callId = data["callId"] ?: data["call_id"] ?: ""
            val callerName = data["callerName"] ?: data["caller_name"] ?: "مستخدم"
            val callerUsername = data["callerUsername"] ?: data["caller_username"] ?: ""
            val callerAvatar = data["callerAvatarPath"] ?: data["caller_avatar"] ?: ""
            val videoText = data["video"] ?: data["call_type"] ?: "false"
            val video = videoText == "true" || videoText == "video" || data["call_type"] == "video"

            if (callId.isNotBlank()) {
                IncomingCallForegroundService.start(
                    this,
                    callId,
                    callerName,
                    callerUsername,
                    callerAvatar,
                    video
                )
            }
        }
    }
}
