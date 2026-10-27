package app.allorachat.messenger

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.provider.Settings
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * FlutterFragmentActivity (not FlutterActivity) is required by local_auth
 * for the BiometricPrompt API.
 *
 * Method channels:
 *  - "…/secure"    toggles FLAG_SECURE (screenshot/recent-apps protection).
 *  - "…/bubble"    drives the floating chat overlay ([BubbleService]).
 *  - "…/contacts"  fast native contacts query and permission handler.
 */
class MainActivity : FlutterFragmentActivity() {
    private val secureChannel = "app.allorachat.messenger/secure"
    private val bubbleChannel = "app.allorachat.messenger/bubble"
    private val notificationsChannel = "app.allorachat.messenger/notifications"
    private val CONTACTS_CHANNEL = "app.allorachat.messenger/contacts"
    private val CONTACTS_PERMISSION_REQ = 1001
    private var pendingContactsResult: MethodChannel.Result? = null
    private val bgExecutor = Executors.newSingleThreadExecutor()

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

        // Reusable by NotificationHelper.kt and BubbleService.kt
        fun loadPhoneContactsMap(context: Context): Map<String, String> {
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS)
                != PackageManager.PERMISSION_GRANTED
            ) {
                return emptyMap()
            }

            val map = HashMap<String, String>()
            val projection = arrayOf(
                ContactsContract.CommonDataKinds.Phone.NUMBER,
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME
            )

            try {
                context.contentResolver.query(
                    ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                    projection,
                    null,
                    null,
                    null
                )?.use { cursor ->
                    val numberIdx = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)
                    val nameIdx = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)

                    while (cursor.moveToNext()) {
                        val rawNumber = cursor.getString(numberIdx) ?: continue
                        val name = cursor.getString(nameIdx)?.trim() ?: continue
                        if (name.isEmpty()) continue

                        // Strip everything except digits (e.g. "+91 98765-43210" -> "919876543210")
                        val digits = rawNumber.replace(Regex("[^0-9]"), "")
                        if (digits.length >= 7) {
                            map[digits] = name
                            // Also index by last 10 digits so local numbers without country code match Matrix IDs
                            if (digits.length > 10) {
                                map[digits.takeLast(10)] = name
                            } else if (digits.length == 11 && digits.startsWith("0")) {
                                map[digits.substring(1)] = name
                            }
                        }
                    }
                }
            } catch (_: Exception) {}
            return map
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CONTACTS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDeviceContacts" -> {
                        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CONTACTS)
                            == PackageManager.PERMISSION_GRANTED
                        ) {
                            fetchContactsAsync(result)
                        } else {
                            pendingContactsResult = result
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.READ_CONTACTS),
                                CONTACTS_PERMISSION_REQ
                            )
                        }
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
                    fetchContactsAsync(result)
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

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == CONTACTS_PERMISSION_REQ) {
            val result = pendingContactsResult
            pendingContactsResult = null
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                if (result != null) fetchContactsAsync(result)
            } else {
                result?.success(emptyMap<String, String>())
            }
        }
    }

    private fun fetchContactsAsync(result: MethodChannel.Result) {
        bgExecutor.execute {
            val contactsMap = loadPhoneContactsMap(applicationContext)
            runOnUiThread {
                result.success(contactsMap)
            }
        }
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
