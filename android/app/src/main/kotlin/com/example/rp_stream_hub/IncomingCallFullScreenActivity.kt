package com.example.rp_stream_hub

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.animation.AnticipateOvershootInterpolator
import android.view.animation.DecelerateInterpolator
import android.widget.ImageView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat

class IncomingCallFullScreenActivity : AppCompatActivity() {

    private lateinit var tvCallerName: TextView
    private lateinit var tvCallerUsername: TextView
    private lateinit var tvCallType: TextView
    private lateinit var ivAvatar: ImageView
    private lateinit var ivAcceptIcon: ImageView
    private lateinit var ivDeclineIcon: ImageView
    private lateinit var swipeThumb: View
    private lateinit var swipeTrack: View
    private lateinit var swipePillContainer: View
    private lateinit var actionFlashOverlay: View

    private var callId: String = ""
    private var callerName: String = ""
    private var callerUsername: String = ""
    private var callerAvatar: String = ""
    private var video: Boolean = false

    private var downRawX = 0f
    private var maxTravel = 0f
    private var currentTranslation = 0f
    private var isTracking = false
    private val thresholdRatio = 0.55f
    private var hasCrossedThreshold = false
    private var actionTriggered = false

    private var pulseAnimator: ValueAnimator? = null
    private var springBackAnimator: ValueAnimator? = null
    private var vibrator: Vibrator? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_incoming_call)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }

        val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        keyguardManager.requestDismissKeyguard(this, null)

        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        val wakeLock = pm.newWakeLock(
            PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
            "RespectApp:IncomingCallWakeLock"
        )
        wakeLock.acquire(15_000L)

        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
        )

        callId = intent.getStringExtra("callId") ?: ""
        callerName = intent.getStringExtra("callerName") ?: "مستخدم"
        callerUsername = intent.getStringExtra("callerUsername") ?: ""
        callerAvatar = intent.getStringExtra("callerAvatar") ?: ""
        video = intent.getBooleanExtra("video", false)

        tvCallerName = findViewById(R.id.tvCallerName)
        tvCallerUsername = findViewById(R.id.tvCallerUsername)
        tvCallType = findViewById(R.id.tvCallType)
        ivAvatar = findViewById(R.id.ivAvatar)
        ivAcceptIcon = findViewById(R.id.ivAcceptIcon)
        ivDeclineIcon = findViewById(R.id.ivDeclineIcon)
        swipeThumb = findViewById(R.id.swipeThumb)
        swipeTrack = findViewById(R.id.swipeTrack)
        swipePillContainer = findViewById(R.id.swipePillContainer)
        actionFlashOverlay = findViewById(R.id.actionFlashOverlay)

        tvCallerName.text = callerName
        tvCallerUsername.text = callerUsername
        tvCallType.text = if (video) "مكالمة فيديو واردة" else "مكالمة صوتية واردة"

        vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val manager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
            manager.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }

        swipeThumb.translationX = 0f
        setupSwipeGesture()

        swipePillContainer.post {
            calculateTravelBounds()
            startPulseAnimation()
        }
    }

    private fun calculateTravelBounds() {
        val containerWidth = swipePillContainer.width.toFloat()
        val thumbWidth = swipeThumb.width.toFloat()
        maxTravel = (containerWidth / 2f) - (thumbWidth / 2f) - 6f
        if (maxTravel < 40f) maxTravel = 80f
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun setupSwipeGesture() {
        swipeThumb.setOnTouchListener { _, event ->
            if (actionTriggered) return@setOnTouchListener false

            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    if (maxTravel <= 0f) calculateTravelBounds()

                    downRawX = event.rawX
                    isTracking = true
                    hasCrossedThreshold = false

                    stopPulseAnimation()
                    springBackAnimator?.cancel()

                    ViewCompat.animate(swipeThumb)
                        .scaleX(1.08f)
                        .scaleY(1.08f)
                        .setDuration(120)
                        .start()

                    true
                }

                MotionEvent.ACTION_MOVE -> {
                    if (!isTracking) return@setOnTouchListener false

                    val deltaX = event.rawX - downRawX
                    currentTranslation = deltaX.coerceIn(-maxTravel, maxTravel)
                    swipeThumb.translationX = currentTranslation

                    val ratio = kotlin.math.abs(currentTranslation) / maxTravel
                    updateIcons(ratio)

                    if (!hasCrossedThreshold && ratio >= thresholdRatio) {
                        hasCrossedThreshold = true
                        triggerHapticLight()
                    } else if (hasCrossedThreshold && ratio < thresholdRatio) {
                        hasCrossedThreshold = false
                    }

                    true
                }

                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    isTracking = false

                    ViewCompat.animate(swipeThumb)
                        .scaleX(1f)
                        .scaleY(1f)
                        .setDuration(200)
                        .start()

                    val ratio = kotlin.math.abs(currentTranslation) / maxTravel

                    if (ratio >= thresholdRatio) {
                        actionTriggered = true

                        val isAccept = currentTranslation > 0f
                        animateToEdge(if (isAccept) 1f else -1f)
                    } else {
                        springBackToCenter()
                    }

                    true
                }

                else -> false
            }
        }
    }

    private fun updateIcons(ratio: Float) {
        if (currentTranslation < -8f) {
            ivDeclineIcon.alpha = (0.6f + ratio * 0.4f).coerceIn(0.6f, 1f)
            ivDeclineIcon.scaleX = 1f + ratio * 0.35f
            ivDeclineIcon.scaleY = 1f + ratio * 0.35f

            ivAcceptIcon.alpha = (0.6f - ratio * 0.4f).coerceIn(0.2f, 0.6f)
            ivAcceptIcon.scaleX = 1f
            ivAcceptIcon.scaleY = 1f
        } else if (currentTranslation > 8f) {
            ivAcceptIcon.alpha = (0.6f + ratio * 0.4f).coerceIn(0.6f, 1f)
            ivAcceptIcon.scaleX = 1f + ratio * 0.35f
            ivAcceptIcon.scaleY = 1f + ratio * 0.35f

            ivDeclineIcon.alpha = (0.6f - ratio * 0.4f).coerceIn(0.2f, 0.6f)
            ivDeclineIcon.scaleX = 1f
            ivDeclineIcon.scaleY = 1f
        } else {
            resetIcons()
        }
    }

    private fun resetIcons() {
        ivAcceptIcon.alpha = 0.6f
        ivAcceptIcon.scaleX = 1f
        ivAcceptIcon.scaleY = 1f

        ivDeclineIcon.alpha = 0.6f
        ivDeclineIcon.scaleX = 1f
        ivDeclineIcon.scaleY = 1f
    }

    private fun animateToEdge(direction: Float) {
        val target = direction * maxTravel

        ObjectAnimator.ofFloat(currentTranslation, target).apply {
            duration = 180
            interpolator = DecelerateInterpolator()

            addUpdateListener {
                val value = it.animatedValue as Float
                swipeThumb.translationX = value
                currentTranslation = value
            }

            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    val accepted = direction > 0f
                    triggerActionFlash(accepted)

                    // تأخير تنفيذ الإجراء لضمان وضوح التأثير البصري
                    swipePillContainer.postDelayed({
                        executeAction(accepted)
                    }, 200)
                }
            })

            start()
        }
    }

    private fun springBackToCenter() {
        springBackAnimator = ObjectAnimator.ofFloat(currentTranslation, 0f).apply {
            duration = 500
            interpolator = AnticipateOvershootInterpolator(1.6f)

            addUpdateListener {
                val value = it.animatedValue as Float
                currentTranslation = value
                swipeThumb.translationX = value
            }

            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    currentTranslation = 0f
                    hasCrossedThreshold = false
                    resetIcons()
                    startPulseAnimation()
                }
            })

            start()
        }
    }

    private fun triggerActionFlash(accepted: Boolean) {
        val color = if (accepted) 0x3322C55E.toInt() else 0x33EF4444.toInt()

        actionFlashOverlay.setBackgroundColor(color)
        actionFlashOverlay.visibility = View.VISIBLE
        actionFlashOverlay.alpha = 0f

        actionFlashOverlay.animate()
            .alpha(1f)
            .setDuration(150)
            .withEndAction {
                actionFlashOverlay.animate()
                    .alpha(0f)
                    .setDuration(300)
                    .withEndAction {
                        actionFlashOverlay.visibility = View.INVISIBLE
                    }
                    .start()
            }
            .start()

        triggerHapticConfirm()
    }

    private fun executeAction(accepted: Boolean) {
        val action = if (accepted) "accept" else "reject"

        sendResultToFlutter(action)

        if (accepted) {
            val launchIntent = Intent(this, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP
                )
                putExtra("action", action)
                putExtra("callId", callId)
                putExtra("callerName", callerName)
                putExtra("callerUsername", callerUsername)
                putExtra("callerAvatarPath", callerAvatar)
                putExtra("video", video)
            }
            startActivity(launchIntent)
        }

        // تأخير إنهاء النشاط لإعطاء وقت للبث والتطبيق الرئيسي للظهور
        swipePillContainer.postDelayed({
            finishAndRemoveTask()
            IncomingCallForegroundService.stop(this@IncomingCallFullScreenActivity)
        }, 300)
    }

    private fun startPulseAnimation() {
        stopPulseAnimation()

        pulseAnimator = ValueAnimator.ofFloat(1f, 1.05f, 1f).apply {
            duration = 1600
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.RESTART
            interpolator = android.view.animation.AccelerateDecelerateInterpolator()

            addUpdateListener {
                val scale = it.animatedValue as Float
                swipeThumb.scaleX = scale
                swipeThumb.scaleY = scale
            }

            start()
        }
    }

    private fun stopPulseAnimation() {
        pulseAnimator?.cancel()
        pulseAnimator = null

        swipeThumb.scaleX = 1f
        swipeThumb.scaleY = 1f
    }

    private fun triggerHapticLight() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator?.vibrate(VibrationEffect.createOneShot(18, VibrationEffect.DEFAULT_AMPLITUDE))
        } else {
            @Suppress("DEPRECATION")
            vibrator?.vibrate(18)
        }
    }

    private fun triggerHapticConfirm() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator?.vibrate(VibrationEffect.createOneShot(35, VibrationEffect.DEFAULT_AMPLITUDE))
        } else {
            @Suppress("DEPRECATION")
            vibrator?.vibrate(35)
        }
    }

    private fun sendResultToFlutter(action: String) {
        val intent = Intent("INCOMING_CALL_ACTION")
        intent.putExtra("action", action)
        intent.putExtra("callId", callId)
        intent.putExtra("callerName", callerName)
        intent.putExtra("callerUsername", callerUsername)
        intent.putExtra("callerAvatarPath", callerAvatar)
        intent.putExtra("video", video)
        sendBroadcast(intent)
    }

    override fun onBackPressed() {
        if (!actionTriggered) {
            actionTriggered = true
            triggerActionFlash(false)
            swipePillContainer.postDelayed({
                sendResultToFlutter("reject")
                finishAndRemoveTask()
                IncomingCallForegroundService.stop(this)
            }, 250)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        stopPulseAnimation()
        springBackAnimator?.cancel()
        if (!actionTriggered) {
            IncomingCallForegroundService.stop(this)
        }
    }
}