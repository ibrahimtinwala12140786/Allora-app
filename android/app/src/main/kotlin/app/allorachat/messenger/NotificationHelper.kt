package app.allorachat.messenger

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.app.RemoteInput
import androidx.core.content.FileProvider
import androidx.core.graphics.drawable.IconCompat
import java.io.File
import java.util.concurrent.ConcurrentHashMap

object AudioNotificationPlayer {
    private var mediaPlayer: MediaPlayer? = null
    var activeAudioPath: String? = null
    var activeNotificationId: Int? = null

    fun play(context: Context, audioPath: String, notificationId: Int) {
        stop(context)
        try {
            val player = MediaPlayer().apply {
                setDataSource(audioPath)
                setOnCompletionListener {
                    stop(context)
                }
                prepare()
                start()
            }
            mediaPlayer = player
            activeAudioPath = audioPath
            activeNotificationId = notificationId
            NotificationHelper.updateAudioPlayingState(context, notificationId, isPlaying = true)
        } catch (e: Exception) {
            e.printStackTrace()
            stop(context)
        }
    }

    fun pause(context: Context, notificationId: Int) {
        stop(context)
    }

    fun stop(context: Context? = null) {
        val notifId = activeNotificationId
        try {
            mediaPlayer?.stop()
            mediaPlayer?.release()
        } catch (_: Exception) {}
        mediaPlayer = null
        activeAudioPath = null
        activeNotificationId = null
        if (context != null && notifId != null) {
            NotificationHelper.updateAudioPlayingState(context, notifId, isPlaying = false)
        }
    }
}

data class ActiveNotificationData(
    val notificationId: Int,
    val title: String,
    val sender: String,
    val message: String,
    val roomId: String,
    val eventId: String,
    val brandColor: Int,
    val platform: String,
    val rawSenderId: String,
    val suggestions: List<String>,
    val avatarPath: String?,
    val imagePath: String?,
    val imagePaths: List<String>,
    val audioPath: String?,
    val isSensitive: Boolean = false,
    val otpCode: String? = null
)

object NotificationHelper {
    const val CHANNEL_ID = "allora_messages_channel"
    const val CHANNEL_NAME = "Allora Messages"

    const val ACTION_REPLY = "app.allorachat.messenger.REPLY"
    const val ACTION_QUICK_REPLY = "app.allorachat.messenger.QUICK_REPLY"
    const val ACTION_LIKE = "app.allorachat.messenger.LIKE"
    const val ACTION_PLAY_AUDIO = "app.allorachat.messenger.PLAY_AUDIO"
    const val ACTION_PAUSE_AUDIO = "app.allorachat.messenger.PAUSE_AUDIO"
    const val ACTION_COPY_OTP = "app.allorachat.messenger.COPY_OTP"

    const val EXTRA_ROOM_ID = "extra_room_id"
    const val EXTRA_EVENT_ID = "extra_event_id"
    const val EXTRA_NOTIFICATION_ID = "extra_notification_id"
    const val EXTRA_REPLY_TEXT = "extra_reply_text"
    const val EXTRA_AUDIO_PATH = "extra_audio_path"
    const val EXTRA_OTP_CODE = "extra_otp_code"
    const val KEY_TEXT_REPLY = "key_text_reply"

    private val activeNotifications = ConcurrentHashMap<Int, ActiveNotificationData>()

    fun createNotificationChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val importance = NotificationManager.IMPORTANCE_HIGH
            val channel = NotificationChannel(CHANNEL_ID, CHANNEL_NAME, importance).apply {
                description = "Incoming message notifications with direct reply"
                enableLights(true)
                enableVibration(true)
                setShowBadge(true)
            }
            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }

    fun updateAudioPlayingState(context: Context, notificationId: Int, isPlaying: Boolean) {
        val data = activeNotifications[notificationId] ?: return
        showNotification(
            context = context,
            notificationId = data.notificationId,
            title = data.title,
            sender = data.sender,
            message = data.message,
            roomId = data.roomId,
            eventId = data.eventId,
            brandColor = data.brandColor,
            platform = data.platform,
            rawSenderId = data.rawSenderId,
            suggestions = data.suggestions,
            avatarPath = data.avatarPath,
            imagePath = data.imagePath,
            imagePaths = data.imagePaths,
            audioPath = data.audioPath,
            isAudioPlaying = isPlaying,
            isSensitive = data.isSensitive,
            otpCode = data.otpCode
        )
    }

    fun showNotification(
        context: Context,
        notificationId: Int,
        title: String,
        sender: String,
        message: String,
        roomId: String,
        eventId: String,
        brandColor: Int,
        platform: String = "",
        rawSenderId: String = "",
        suggestions: List<String> = emptyList(),
        avatarPath: String? = null,
        imagePath: String? = null,
        imagePaths: List<String> = emptyList(),
        audioPath: String? = null,
        isAudioPlaying: Boolean = false,
        isSensitive: Boolean = false,
        otpCode: String? = null
    ) {
        createNotificationChannel(context)

        // Cache active notification data for audio play/pause updates
        activeNotifications[notificationId] = ActiveNotificationData(
            notificationId, title, sender, message, roomId, eventId,
            brandColor, platform, rawSenderId, suggestions,
            avatarPath, imagePath, imagePaths, audioPath, isSensitive, otpCode
        )

        // Priority 1: Check device contacts by rawSenderId, sender, or roomId
        val deviceContactName = resolveDeviceContactName(context, rawSenderId)
            ?: resolveDeviceContactName(context, sender)
            ?: resolveDeviceContactName(context, roomId)
        val finalSender = if (!deviceContactName.isNullOrBlank()) deviceContactName else sender

        // Tap notification -> open MainActivity
        val tapIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_ROOM_ID, roomId)
        }
        val tapPendingIntent = PendingIntent.getActivity(
            context,
            notificationId,
            tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        )

        // Direct Reply RemoteInput
        val remoteInput = RemoteInput.Builder(KEY_TEXT_REPLY)
            .setLabel("Reply to $finalSender...")
            .build()

        val replyIntent = Intent(context, NotificationActionReceiver::class.java).apply {
            action = ACTION_REPLY
            putExtra(EXTRA_ROOM_ID, roomId)
            putExtra(EXTRA_NOTIFICATION_ID, notificationId)
            putExtra("sender", finalSender)
            putExtra("title", title)
        }
        val replyPendingIntent = PendingIntent.getBroadcast(
            context,
            notificationId * 10 + 1,
            replyIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
        )

        val replyAction = NotificationCompat.Action.Builder(
            android.R.drawable.ic_menu_send,
            "Reply",
            replyPendingIntent
        ).addRemoteInput(remoteInput).build()

        // Quick Like Action
        val likeIntent = Intent(context, NotificationActionReceiver::class.java).apply {
            action = ACTION_LIKE
            putExtra(EXTRA_ROOM_ID, roomId)
            putExtra(EXTRA_EVENT_ID, eventId)
            putExtra(EXTRA_NOTIFICATION_ID, notificationId)
        }
        val likePendingIntent = PendingIntent.getBroadcast(
            context,
            notificationId * 10 + 2,
            likeIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        )

        val likeAction = NotificationCompat.Action.Builder(
            android.R.drawable.btn_star,
            "👍 Like",
            likePendingIntent
        ).build()

        // 1. Resolve Platform with comprehensive fallback detection
        val resolvedPlatform = when {
            platform.isNotBlank() -> platform.lowercase().trim()
            rawSenderId.contains("whatsapp") || rawSenderId.contains("wa_") || rawSenderId.contains("s.whatsapp.net") -> "whatsapp"
            rawSenderId.contains("telegram") || rawSenderId.contains("tg_") -> "telegram"
            rawSenderId.contains("instagram") || rawSenderId.contains("ig_") -> "instagram"
            rawSenderId.contains("facebook") || rawSenderId.contains("messenger") || rawSenderId.contains("fb_") -> "messenger"
            rawSenderId.contains("discord") -> "discord"
            rawSenderId.contains("slack") -> "slack"
            rawSenderId.contains("twitter") || rawSenderId.contains("x_") -> "x"
            roomId.contains("whatsapp") || roomId.contains("_wa_") -> "whatsapp"
            roomId.contains("telegram") || roomId.contains("_tg_") -> "telegram"
            title.lowercase().contains("whatsapp") -> "whatsapp"
            title.lowercase().contains("telegram") -> "telegram"
            title.lowercase().contains("instagram") -> "instagram"
            else -> ""
        }

        // 2. Resolve Sender Avatar: Social profile pic -> Device contact photo -> Modern initials (NEVER Allora logo)
        val senderAvatar = getSenderAvatarBitmap(context, avatarPath, finalSender, rawSenderId, resolvedPlatform)
        val senderIcon = IconCompat.createWithBitmap(senderAvatar)

        val meUser = Person.Builder()
            .setName("Me")
            .setKey("me_user")
            .build()

        val senderPerson = Person.Builder()
            .setName(finalSender)
            .setIcon(senderIcon)
            .setKey(rawSenderId.ifBlank { finalSender })
            .build()

        // 3. Resolve Platform Small Icon Badge (drawn at bottom-right corner of avatar)
        val smallIconRes = getPlatformSmallIcon(resolvedPlatform)

        // 4. Resolve Platform Large Icon (displayed on right-hand side - ONE official logo)
        val platformLogo = getPlatformLargeIcon(context, resolvedPlatform)

        // 5. Resolve Image / Multi-image WhatsApp style collage
        val allImages = if (imagePaths.isNotEmpty()) imagePaths else listOfNotNull(imagePath)
        val previewCollage = if (allImages.isNotEmpty()) {
            createWhatsAppStyleCollage(context, allImages)
        } else null

        // 6. Construct MessagingStyle message
        val messageText = if (allImages.isNotEmpty() && message.startsWith("📷")) {
            if (allImages.size > 1) "${allImages.size} photos" else message
        } else message

        val messageObj = NotificationCompat.MessagingStyle.Message(
            messageText,
            System.currentTimeMillis(),
            senderPerson
        )

        // Attach image to message via FileProvider if present
        if (previewCollage != null) {
            try {
                val imgFile = File(context.cacheDir, "notif_img_${notificationId}.jpg")
                imgFile.outputStream().use { out ->
                    previewCollage.compress(Bitmap.CompressFormat.JPEG, 92, out)
                }
                val contentUri = FileProvider.getUriForFile(
                    context,
                    "${context.packageName}.fileprovider",
                    imgFile
                )
                messageObj.setData("image/jpeg", contentUri)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }

        val messagingStyle = NotificationCompat.MessagingStyle(meUser)
            .setConversationTitle(null)
            .setGroupConversation(false)
            .addMessage(messageObj)

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_allora) // Allora icon displayed in top status bar
            .setLargeIcon(platformLogo) // Official social media logo on the right side of notification
            .setStyle(messagingStyle)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setColor(brandColor)
            .setColorized(false)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setAllowSystemGeneratedContextualActions(false)
            .setContentIntent(tapPendingIntent)

        // Playable Voice Note action for audio messages
        if (!audioPath.isNullOrBlank() && File(audioPath).exists()) {
            val audioIntent = Intent(context, NotificationActionReceiver::class.java).apply {
                action = if (isAudioPlaying) ACTION_PAUSE_AUDIO else ACTION_PLAY_AUDIO
                putExtra(EXTRA_AUDIO_PATH, audioPath)
                putExtra(EXTRA_NOTIFICATION_ID, notificationId)
                putExtra(EXTRA_ROOM_ID, roomId)
            }
            val audioPendingIntent = PendingIntent.getBroadcast(
                context,
                notificationId * 10 + 9,
                audioIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
            )
            val audioAction = NotificationCompat.Action.Builder(
                if (isAudioPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                if (isAudioPlaying) "⏸ Pause Voice Note" else "▶ Play Voice Note",
                audioPendingIntent
            ).build()
            builder.addAction(audioAction)
        }

        if (!otpCode.isNullOrBlank()) {
            // Direct "Copy OTP" Action Button - one tap to copy code to clipboard
            val copyIntent = Intent(context, NotificationActionReceiver::class.java).apply {
                action = ACTION_COPY_OTP
                putExtra(EXTRA_OTP_CODE, otpCode)
                putExtra(EXTRA_NOTIFICATION_ID, notificationId)
                putExtra(EXTRA_ROOM_ID, roomId)
            }
            val copyPendingIntent = PendingIntent.getBroadcast(
                context,
                notificationId * 10 + 8,
                copyIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
            )
            val copyAction = NotificationCompat.Action.Builder(
                android.R.drawable.ic_menu_save,
                "📋 Copy $otpCode",
                copyPendingIntent
            )
            .setContextual(false)
            .build()
            builder.addAction(copyAction)
        } else if (!isSensitive) {
            builder.addAction(replyAction)

            // Add AI suggestion pills (up to 3) without system outline box
            for ((index, suggestion) in suggestions.take(3).withIndex()) {
                val quickIntent = Intent(context, NotificationActionReceiver::class.java).apply {
                    action = ACTION_QUICK_REPLY
                    putExtra(EXTRA_ROOM_ID, roomId)
                    putExtra(EXTRA_NOTIFICATION_ID, notificationId)
                    putExtra(EXTRA_REPLY_TEXT, suggestion)
                    putExtra("sender", finalSender)
                    putExtra("title", title)
                }
                val quickPendingIntent = PendingIntent.getBroadcast(
                    context,
                    notificationId * 10 + 3 + index,
                    quickIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
                )
                val suggestionAction = NotificationCompat.Action.Builder(
                    0,
                    suggestion,
                    quickPendingIntent
                )
                .setContextual(false)
                .build()
                builder.addAction(suggestionAction)
            }

            builder.addAction(likeAction)
        }

        try {
            NotificationManagerCompat.from(context).notify(notificationId, builder.build())
        } catch (_: SecurityException) {
            // Post notification permission not granted
        }
    }

    /**
     * Maps the platform string to its corresponding small icon resource.
     * This icon is automatically stamped by Android at the bottom-right corner
     * of the sender's circular avatar, exactly matching WhatsApp's layout.
     */
    fun getPlatformSmallIcon(platform: String): Int {
        return when (platform.lowercase().trim()) {
            "whatsapp" -> R.drawable.ic_stat_whatsapp
            "telegram" -> R.drawable.ic_stat_telegram
            "instagram" -> R.drawable.ic_stat_instagram
            "messenger", "facebook" -> R.drawable.ic_stat_messenger
            "discord" -> R.drawable.ic_stat_discord
            "slack" -> R.drawable.ic_stat_slack
            "x", "twitter" -> R.drawable.ic_stat_x
            else -> R.drawable.ic_stat_allora
        }
    }

    /**
     * Resolves the circular sender avatar:
     * 1. Downloaded social media profile photo (from WhatsApp, Telegram, Instagram, etc.)
     * 2. Device address book contact photo
     * 3. Allora app profile image fallback
     * 4. Modern gradient initials avatar
     */
    fun getSenderAvatarBitmap(
        context: Context,
        avatarPath: String?,
        senderName: String,
        rawSenderId: String,
        platform: String = ""
    ): Bitmap {
        val density = context.resources.displayMetrics.density
        val sizePx = (72 * density).toInt()

        // 1. Downloaded profile photo from social network (the sender's actual profile image)
        if (!avatarPath.isNullOrBlank()) {
            try {
                val f = File(avatarPath)
                if (f.exists() && f.length() > 0) {
                    val raw = BitmapFactory.decodeFile(f.absolutePath)
                    if (raw != null) {
                        return toCircularBitmap(raw, sizePx)
                    }
                }
            } catch (_: Exception) {}
        }

        // 2. Device contact address book photo
        val contactPhoto = getDeviceContactPhoto(context, rawSenderId)
            ?: getDeviceContactPhoto(context, senderName)
        if (contactPhoto != null) {
            return toCircularBitmap(contactPhoto, sizePx)
        }

        // 3. Official account platform logo (only when no personal profile image exists)
        if (platform.isNotBlank()) {
            val lowerSender = senderName.lowercase().trim()
            if (lowerSender == platform.lowercase() ||
                lowerSender == "${platform.lowercase()} official" ||
                rawSenderId.contains("777000") ||
                rawSenderId.contains("0@s.whatsapp.net")) {
                val officialLogo = getPlatformLargeIcon(context, platform)
                if (officialLogo != null) {
                    return toCircularBitmap(officialLogo, sizePx)
                }
            }
        }

        // 4. Fallback: Modern gradient initials avatar with first letter of senderName (NEVER the Allora app icon!)
        return createFallbackInitialsAvatar(context, senderName, sizePx)
    }

    fun toCircularBitmap(src: Bitmap, sizePx: Int): Bitmap {
        val output = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        val radius = sizePx / 2f

        val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
        val scaled = Bitmap.createScaledBitmap(src, sizePx, sizePx, true)
        paint.shader = BitmapShader(scaled, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        canvas.drawCircle(radius, radius, radius, paint)
        return output
    }

    private fun createFallbackInitialsAvatar(context: Context, name: String, sizePx: Int): Bitmap {
        val avatarBitmap = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(avatarBitmap)
        val (color1, color2) = getAvatarGradientColors(name)
        val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = LinearGradient(
                0f, 0f, sizePx.toFloat(), sizePx.toFloat(),
                color1, color2,
                Shader.TileMode.CLAMP
            )
        }
        val radius = sizePx / 2f
        canvas.drawCircle(radius, radius, radius, bgPaint)

        val initial = getInitial(name)
        val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = sizePx * 0.44f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            textAlign = Paint.Align.CENTER
        }
        val textBounds = Rect()
        textPaint.getTextBounds(initial, 0, initial.length, textBounds)
        val yOffset = radius - textBounds.exactCenterY()
        canvas.drawText(initial, radius, yOffset, textPaint)
        return avatarBitmap
    }

    /**
     * Generates a WhatsApp-style multi-image collage or single preview bitmap.
     */
    fun createWhatsAppStyleCollage(context: Context, imagePaths: List<String>): Bitmap? {
        val validPaths = imagePaths.filter { File(it).exists() }
        if (validPaths.isEmpty()) return null

        val density = context.resources.displayMetrics.density
        val totalWidth = (340 * density).toInt()
        val totalHeight = (180 * density).toInt()
        val cornerRadius = 12f * density
        val divider = (3f * density).toInt()

        val collageBitmap = Bitmap.createBitmap(totalWidth, totalHeight, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(collageBitmap)

        fun decodeAndCrop(path: String, w: Int, h: Int): Bitmap? {
            return try {
                val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(path, opts)
                var inSampleSize = 1
                while ((opts.outWidth / inSampleSize) > w * 2 || (opts.outHeight / inSampleSize) > h * 2) {
                    inSampleSize *= 2
                }
                val realOpts = BitmapFactory.Options().apply { inSampleSize = inSampleSize }
                val bmp = BitmapFactory.decodeFile(path, realOpts) ?: return null

                val srcW = bmp.width
                val srcH = bmp.height
                val targetRatio = w.toFloat() / h.toFloat()
                val srcRatio = srcW.toFloat() / srcH.toFloat()

                val (cropW, cropH) = if (srcRatio > targetRatio) {
                    Pair((srcH * targetRatio).toInt(), srcH)
                } else {
                    Pair(srcW, (srcW / targetRatio).toInt())
                }
                val cropX = (srcW - cropW) / 2
                val cropY = (srcH - cropH) / 2
                val cropped = Bitmap.createBitmap(bmp, cropX, cropY, cropW, cropH)
                Bitmap.createScaledBitmap(cropped, w, h, true)
            } catch (_: Exception) {
                null
            }
        }

        when (validPaths.size) {
            1 -> {
                val b = decodeAndCrop(validPaths[0], totalWidth, totalHeight) ?: return null
                canvas.drawBitmap(b, 0f, 0f, null)
            }
            2 -> {
                val halfW = (totalWidth - divider) / 2
                val b1 = decodeAndCrop(validPaths[0], halfW, totalHeight)
                val b2 = decodeAndCrop(validPaths[1], halfW, totalHeight)
                if (b1 != null) canvas.drawBitmap(b1, 0f, 0f, null)
                if (b2 != null) canvas.drawBitmap(b2, (halfW + divider).toFloat(), 0f, null)
            }
            3 -> {
                val halfW = (totalWidth - divider) / 2
                val halfH = (totalHeight - divider) / 2
                val b1 = decodeAndCrop(validPaths[0], halfW, totalHeight)
                val b2 = decodeAndCrop(validPaths[1], halfW, halfH)
                val b3 = decodeAndCrop(validPaths[2], halfW, halfH)
                if (b1 != null) canvas.drawBitmap(b1, 0f, 0f, null)
                if (b2 != null) canvas.drawBitmap(b2, (halfW + divider).toFloat(), 0f, null)
                if (b3 != null) canvas.drawBitmap(b3, (halfW + divider).toFloat(), (halfH + divider).toFloat(), null)
            }
            else -> {
                val halfW = (totalWidth - divider) / 2
                val halfH = (totalHeight - divider) / 2
                val b1 = decodeAndCrop(validPaths[0], halfW, halfH)
                val b2 = decodeAndCrop(validPaths[1], halfW, halfH)
                val b3 = decodeAndCrop(validPaths[2], halfW, halfH)
                val b4 = decodeAndCrop(validPaths[3], halfW, halfH)
                if (b1 != null) canvas.drawBitmap(b1, 0f, 0f, null)
                if (b2 != null) canvas.drawBitmap(b2, (halfW + divider).toFloat(), 0f, null)
                if (b3 != null) canvas.drawBitmap(b3, 0f, (halfH + divider).toFloat(), null)
                if (b4 != null) {
                    canvas.drawBitmap(b4, (halfW + divider).toFloat(), (halfH + divider).toFloat(), null)
                    if (validPaths.size > 4) {
                        val scrimPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                            color = Color.parseColor("#99000000")
                        }
                        val r = RectF(
                            (halfW + divider).toFloat(),
                            (halfH + divider).toFloat(),
                            totalWidth.toFloat(),
                            totalHeight.toFloat()
                        )
                        canvas.drawRect(r, scrimPaint)

                        val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                            color = Color.WHITE
                            textSize = 20f * density
                            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                            textAlign = Paint.Align.CENTER
                        }
                        val countText = "+${validPaths.size - 3}"
                        val bounds = Rect()
                        textPaint.getTextBounds(countText, 0, countText.length, bounds)
                        val textY = r.centerY() - bounds.exactCenterY()
                        canvas.drawText(countText, r.centerX(), textY, textPaint)
                    }
                }
            }
        }

        val rounded = Bitmap.createBitmap(totalWidth, totalHeight, Bitmap.Config.ARGB_8888)
        val roundCanvas = Canvas(rounded)
        val roundPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        val rect = RectF(0f, 0f, totalWidth.toFloat(), totalHeight.toFloat())
        roundCanvas.drawRoundRect(rect, cornerRadius, cornerRadius, roundPaint)
        roundPaint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
        roundCanvas.drawBitmap(collageBitmap, 0f, 0f, roundPaint)
        return rounded
    }

    fun getPlatformLargeIcon(context: Context, platform: String): Bitmap? {
        val resId = when (platform.lowercase().trim()) {
            "whatsapp" -> R.drawable.ic_stat_whatsapp
            "telegram" -> R.drawable.ic_stat_telegram
            "instagram" -> R.drawable.ic_stat_instagram
            "messenger", "facebook" -> R.drawable.ic_stat_messenger
            "discord" -> R.drawable.ic_stat_discord
            "slack" -> R.drawable.ic_stat_slack
            "x", "twitter" -> R.drawable.ic_stat_x
            else -> null
        }
        if (resId != null) {
            try {
                val bmp = BitmapFactory.decodeResource(context.resources, resId)
                if (bmp != null) return bmp
            } catch (_: Exception) {}
        }

        val assetName = when (platform.lowercase().trim()) {
            "whatsapp" -> "whatsapp.png"
            "telegram" -> "telegram.png"
            "instagram" -> "instagram.png"
            "messenger", "facebook" -> "messenger.png"
            "discord" -> "discord.png"
            "slack" -> "slack.png"
            "x", "twitter" -> "x.png"
            else -> null
        } ?: return null

        return try {
            context.assets.open("flutter_assets/assets/images/$assetName").use { inputStream ->
                BitmapFactory.decodeStream(inputStream)
            }
        } catch (_: Exception) {
            null
        }
    }

    fun resolveDeviceContactName(context: Context, input: String): String? {
        if (input.isBlank()) return null
        if (context.checkSelfPermission(android.Manifest.permission.READ_CONTACTS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            return null
        }
        val digits = input.replace(Regex("[^0-9]"), "")
        if (digits.length < 7) return null

        val candidates = mutableListOf<String>()
        candidates.add(digits)
        if (digits.length >= 10) {
            candidates.add(digits.takeLast(10))
        }
        if (digits.startsWith("0") && digits.length > 7) {
            candidates.drop(1)
        }

        for (candidate in candidates) {
            try {
                val uri = Uri.withAppendedPath(
                    ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                    Uri.encode(candidate)
                )
                val projection = arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME)
                context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val nameIndex = cursor.getColumnIndex(ContactsContract.PhoneLookup.DISPLAY_NAME)
                        if (nameIndex != -1) {
                            val name = cursor.getString(nameIndex)
                            if (!name.isNullOrBlank()) {
                                return name
                            }
                        }
                    }
                }
            } catch (_: Exception) {}
        }
        return null
    }

    fun getDeviceContactPhoto(context: Context, input: String): Bitmap? {
        if (input.isBlank()) return null
        if (context.checkSelfPermission(android.Manifest.permission.READ_CONTACTS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            return null
        }
        val digits = input.replace(Regex("[^0-9]"), "")
        if (digits.length < 7) return null

        val candidates = listOf(
            digits,
            if (digits.length > 10) digits.takeLast(10) else null
        ).filterNotNull().distinct()

        for (candidate in candidates) {
            try {
                val uri = Uri.withAppendedPath(
                    ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                    Uri.encode(candidate)
                )
                val projection = arrayOf(
                    ContactsContract.PhoneLookup._ID,
                    ContactsContract.PhoneLookup.PHOTO_URI
                )
                context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val photoIdx = cursor.getColumnIndex(ContactsContract.PhoneLookup.PHOTO_URI)
                        if (photoIdx != -1) {
                            val photoUriStr = cursor.getString(photoIdx)
                            if (!photoUriStr.isNullOrBlank()) {
                                val photoUri = Uri.parse(photoUriStr)
                                context.contentResolver.openInputStream(photoUri)?.use { stream ->
                                    return BitmapFactory.decodeStream(stream)
                                }
                            }
                        }
                        val idIdx = cursor.getColumnIndex(ContactsContract.PhoneLookup._ID)
                        if (idIdx != -1) {
                            val contactId = cursor.getLong(idIdx)
                            val contactUri = ContentUris.withAppendedId(ContactsContract.Contacts.CONTENT_URI, contactId)
                            ContactsContract.Contacts.openContactPhotoInputStream(context.contentResolver, contactUri, true)?.use { stream ->
                                return BitmapFactory.decodeStream(stream)
                            }
                        }
                    }
                }
            } catch (_: Exception) {}
        }
        return null
    }

    private fun getAvatarGradientColors(name: String): Pair<Int, Int> {
        val palette = listOf(
            Pair(0xFF3A6FF8.toInt(), 0xFF1E40AF.toInt()), // Blue
            Pair(0xFF7C5CFC.toInt(), 0xFF5B21B6.toInt()), // Purple
            Pair(0xFF00A3AD.toInt(), 0xFF0E7490.toInt()), // Teal
            Pair(0xFFE45794.toInt(), 0xFFBE185D.toInt()), // Pink
            Pair(0xFFE8930C.toInt(), 0xFFB45309.toInt()), // Amber
            Pair(0xFF1FA45B.toInt(), 0xFF15803D.toInt()), // Green
            Pair(0xFFDB5C5C.toInt(), 0xFFB91C1C.toInt()), // Red
            Pair(0xFF5C7CDB.toInt(), 0xFF3730A3.toInt())  // Indigo
        )
        var hash = 0
        for (char in name) {
            hash = (hash * 31 + char.code) and 0x7FFFFFFF
        }
        return palette[hash % palette.size]
    }

    private fun getInitial(name: String): String {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return "?"
        val firstChar = trimmed.first()
        return if (firstChar.isLetterOrDigit()) firstChar.uppercase() else "?"
    }

    fun updateNotificationReplied(context: Context, notificationId: Int, replyText: String) {
        val repliedNotification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.launcher_icon)
            .setContentTitle("Sent")
            .setContentText("You: $replyText")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setAutoCancel(true)
            .setTimeoutAfter(3000)
            .build()

        try {
            NotificationManagerCompat.from(context).notify(notificationId, repliedNotification)
        } catch (_: Exception) {}
    }

    fun cancelNotification(context: Context, notificationId: Int) {
        AudioNotificationPlayer.stop(context)
        activeNotifications.remove(notificationId)
        try {
            NotificationManagerCompat.from(context).cancel(notificationId)
        } catch (_: Exception) {}
    }

    fun cancelAll(context: Context) {
        AudioNotificationPlayer.stop(context)
        activeNotifications.clear()
        try {
            NotificationManagerCompat.from(context).cancelAll()
        } catch (_: Exception) {}
    }
}
