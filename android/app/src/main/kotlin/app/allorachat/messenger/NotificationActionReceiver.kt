package app.allorachat.messenger

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.RemoteInput

class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        val roomId = intent.getStringExtra(NotificationHelper.EXTRA_ROOM_ID) ?: return
        val notificationId = intent.getIntExtra(NotificationHelper.EXTRA_NOTIFICATION_ID, 0)

        when (action) {
            NotificationHelper.ACTION_REPLY -> {
                val remoteInput = RemoteInput.getResultsFromIntent(intent)
                val replyText = remoteInput?.getCharSequence(NotificationHelper.KEY_TEXT_REPLY)?.toString() ?: return

                MainActivity.sendNotificationReply(roomId, replyText)
                NotificationHelper.updateNotificationReplied(context, notificationId, replyText)
            }
            NotificationHelper.ACTION_QUICK_REPLY -> {
                val text = intent.getStringExtra(NotificationHelper.EXTRA_REPLY_TEXT) ?: return
                MainActivity.sendNotificationReply(roomId, text)
                NotificationHelper.updateNotificationReplied(context, notificationId, text)
            }
            NotificationHelper.ACTION_LIKE -> {
                val eventId = intent.getStringExtra(NotificationHelper.EXTRA_EVENT_ID) ?: ""
                MainActivity.sendNotificationLike(roomId, eventId)
                NotificationHelper.cancelNotification(context, notificationId)
            }
            NotificationHelper.ACTION_PLAY_AUDIO -> {
                val audioPath = intent.getStringExtra(NotificationHelper.EXTRA_AUDIO_PATH) ?: return
                AudioNotificationPlayer.play(context, audioPath, notificationId)
            }
            NotificationHelper.ACTION_PAUSE_AUDIO -> {
                AudioNotificationPlayer.pause(context, notificationId)
            }
            NotificationHelper.ACTION_COPY_OTP -> {
                val otpCode = intent.getStringExtra(NotificationHelper.EXTRA_OTP_CODE) ?: return
                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? android.content.ClipboardManager
                if (clipboard != null) {
                    val clip = android.content.ClipData.newPlainText("OTP Code", otpCode)
                    clipboard.setPrimaryClip(clip)
                }
                android.widget.Toast.makeText(context, "Copied $otpCode to clipboard", android.widget.Toast.LENGTH_SHORT).show()
                NotificationHelper.cancelNotification(context, notificationId)
            }
        }
    }
}
