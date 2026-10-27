package app.allorachat.messenger

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * FlutterFragmentActivity (not FlutterActivity) is required by local_auth
 * for the BiometricPrompt API.
 *
 * Two method channels:
 *  - "…/secure"  toggles FLAG_SECURE (screenshot/recent-apps protection).
 *  - "…/bubble"  drives the floating chat overlay ([BubbleService]).
 */
class MainActivity : FlutterFragmentActivity() {
    private val secureChannel = "app.allorachat.messenger/secure"
    private val bubbleChannel = "app.allorachat.messenger/bubble"
    private val notificationsChannel = "app.allorachat.messenger/notifications"

    companion object {
        var notificationChannelRef: MethodChannel? = null
        var activeRoomId: String? = null

        fun sendNotificationReply(roomId: String, text: String) {
            notificationChannelRef?.invokeMethod(
                "onNotificationReply",
                mapOf("roomId" to roomId, "text" to text)
            )
        }

        fun sendNotificationLike(roomId: String, eventId: String) {
            notificationChannelRef?.invokeMethod(
                "onNotificationLike",
                mapOf("roomId" to roomId, "eventId" to eventId)
            )
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        NotificationHelper.createNotificationChannel(this)
        requestAppPermissionsIfNeeded()
        handleNotificationIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        requestAppPermissionsIfNeeded()
    }

    private fun requestAppPermissionsIfNeeded() {
        val permissions = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                permissions.add(android.Manifest.permission.POST_NOTIFICATIONS)
            }
        }
        if (checkSelfPermission(android.Manifest.permission.READ_CONTACTS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            permissions.add(android.Manifest.permission.READ_CONTACTS)
        }
        if (permissions.isNotEmpty()) {
            requestPermissions(permissions.toTypedArray(), 9901)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleNotificationIntent(intent)
    }

    private fun handleNotificationIntent(intent: Intent?) {
        val roomId = intent?.getStringExtra(NotificationHelper.EXTRA_ROOM_ID)
        if (roomId != null) {
            notificationChannelRef?.invokeMethod("openRoom", mapOf("roomId" to roomId))
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, secureChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSecure" -> {
                        val secure = call.argument<Boolean>("secure") ?: false
                        runOnUiThread {
                            if (secure) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            }
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, bubbleChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasPermission" -> result.success(canDrawOverlays())
                    "requestPermission" -> {
                        if (!canDrawOverlays()) {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")
                            )
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                        }
                        result.success(true)
                    }
                    "show" -> {
                        val unread = call.argument<Int>("unread") ?: 0
                        if (canDrawOverlays()) {
                            startBubble(unread)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }
                    "updateUnread" -> {
                        val unread = call.argument<Int>("unread") ?: 0
                        if (canDrawOverlays()) startBubble(unread)
                        result.success(true)
                    }
                    "hide" -> {
                        stopService(Intent(this, BubbleService::class.java))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        val notifChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, notificationsChannel)
        notificationChannelRef = notifChannel
        notifChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "showNotification" -> {
                    val id = call.argument<Int>("id") ?: (System.currentTimeMillis() % 100000).toInt()
                    val title = call.argument<String>("title") ?: "Allora"
                    val sender = call.argument<String>("sender") ?: ""
                    val message = call.argument<String>("message") ?: ""
                    val roomId = call.argument<String>("roomId") ?: ""
                    val eventId = call.argument<String>("eventId") ?: ""
                    val brandColor = call.argument<Long>("brandColor")?.toInt() ?: 0xFF00C853.toInt()
                    val platform = call.argument<String>("platform") ?: ""
                    val rawSenderId = call.argument<String>("rawSenderId") ?: ""
                    val suggestions = call.argument<List<String>>("suggestions") ?: emptyList()
                    val avatarPath = call.argument<String>("avatarPath")
                    val imagePath = call.argument<String>("imagePath")
                    val imagePaths = call.argument<List<String>>("imagePaths") ?: emptyList()
                    val audioPath = call.argument<String>("audioPath")
                    val isSensitive = call.argument<Boolean>("isSensitive") ?: false
                    val otpCode = call.argument<String>("otpCode")
                    NotificationHelper.showNotification(
                        context = this,
                        notificationId = id,
                        title = title,
                        sender = sender,
                        message = message,
                        roomId = roomId,
                        eventId = eventId,
                        brandColor = brandColor,
                        platform = platform,
                        rawSenderId = rawSenderId,
                        suggestions = suggestions,
                        avatarPath = avatarPath,
                        imagePath = imagePath,
                        imagePaths = imagePaths,
                        audioPath = audioPath,
                        isSensitive = isSensitive,
                        otpCode = otpCode
                    )
                    result.success(true)
                }
                "getDeviceContacts" -> {
                    result.success(getDeviceContactsMap())
                }
                "cancelNotification" -> {
                    val id = call.argument<Int>("id") ?: 0
                    NotificationHelper.cancelNotification(this, id)
                    result.success(true)
                }
                "cancelAll" -> {
                    NotificationHelper.cancelAll(this)
                    result.success(true)
                }
                "setActiveRoom" -> {
                    activeRoomId = call.argument<String>("roomId")
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun getDeviceContactsMap(): Map<String, String> {
        val map = mutableMapOf<String, String>()
        if (checkSelfPermission(android.Manifest.permission.READ_CONTACTS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            return map
        }
        val uri = android.provider.ContactsContract.CommonDataKinds.Phone.CONTENT_URI
        val projection = arrayOf(
            android.provider.ContactsContract.CommonDataKinds.Phone.NUMBER,
            android.provider.ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME
        )
        try {
            contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                val numberIdx = cursor.getColumnIndex(android.provider.ContactsContract.CommonDataKinds.Phone.NUMBER)
                val nameIdx = cursor.getColumnIndex(android.provider.ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
                if (numberIdx != -1 && nameIdx != -1) {
                    while (cursor.moveToNext()) {
                        val number = cursor.getString(numberIdx) ?: continue
                        val name = cursor.getString(nameIdx) ?: continue
                        val digits = number.replace(Regex("[^0-9]"), "")
                        if (digits.length >= 7) {
                            map[digits] = name
                            if (digits.length >= 10) {
                                map[digits.takeLast(10)] = name
                            }
                            map.putIfAbsent(digits.takeLast(7), name)
                            if (digits.startsWith("0") && digits.length > 7) {
                                map[digits.drop(1)] = name
                            }
                        }
                    }
                }
            }
        } catch (_: Exception) {}
        return map
    }

    private fun canDrawOverlays(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(this)
        } else {
            true
        }
    }

    private fun startBubble(unread: Int) {
        try {
            val intent = Intent(this, BubbleService::class.java)
            intent.putExtra(BubbleService.EXTRA_UNREAD, unread)
            startService(intent)
        } catch (e: Exception) {
            // Background service-start can be restricted on newer Android;
            // degrade gracefully rather than crash.
        }
    }
}
