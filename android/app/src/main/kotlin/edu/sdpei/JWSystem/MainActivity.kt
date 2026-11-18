package edu.sdpei.JWSystem

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 前台服务的通知通道必须在这里就建好。
        //
        // 教训：Dart 侧用 flutter_local_notifications 建通道是「尽力而为」——
        // resolvePlatformSpecificImplementation 一旦返回 null，?. 会静默跳过，
        // 既不建通道也不抛异常。随后 startForeground() 拿着一个不存在的
        // channel 发通知，系统判 invalid channel for service notification，
        // 抛 CannotPostForegroundServiceNotificationException 直接把进程带走。
        // 放到 Activity.onCreate 里是原生调用，没有插件注册时序问题。
        ensureKqAutoChannel()
    }

    /** 建出考勤守护前台服务要用的通知通道（幂等，已存在则不动）。 */
    private fun ensureKqAutoChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            // 前台服务通知的通道重要性必须是 LOW，不能是 NONE。
            val channel = NotificationChannel(
                KQ_AUTO_CHANNEL_ID,
                "考勤守护",
                NotificationManager.IMPORTANCE_LOW,
            )
            channel.description = "常驻通知栏，保证后台签到不被系统回收"
            channel.setShowBadge(false)
            manager.createNotificationChannel(channel)
        } catch (_: Exception) {
            // 建通道失败不该拦住 App 启动；真出问题时服务启动会自己报错。
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "edu.sdpei.JWSystem/widget_permission",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getWidgetPermissionStatus" -> result.success(readWidgetPermissionStatus())
                "openAutostartSettings" -> result.success(openAutostartSettings())
                else -> result.notImplemented()
            }
        }
    }

    private fun readWidgetPermissionStatus(): Map<String, Any> {
        val sdkInt = Build.VERSION.SDK_INT
        val exactAlarmRequired = sdkInt >= Build.VERSION_CODES.S
        val canScheduleExactAlarms = if (exactAlarmRequired) {
            val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
            alarmManager.canScheduleExactAlarms()
        } else {
            true
        }

        val notificationRequired = sdkInt >= Build.VERSION_CODES.TIRAMISU
        val notificationGranted = if (notificationRequired) {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }

        val manufacturer = Build.MANUFACTURER.lowercase()
        val brand = Build.BRAND.lowercase()
        val isXiaomiFamily = manufacturer.contains("xiaomi") ||
            brand.contains("xiaomi") ||
            brand.contains("redmi") ||
            brand.contains("poco")

        return mapOf(
            "canScheduleExactAlarms" to canScheduleExactAlarms,
            "exactAlarmRequired" to exactAlarmRequired,
            "notificationGranted" to notificationGranted,
            "notificationRequired" to notificationRequired,
            "isXiaomiFamily" to isXiaomiFamily,
            "sdkInt" to sdkInt,
        )
    }

    private fun openAutostartSettings(): Boolean {
        val intents = listOf(
            Intent().apply {
                component = ComponentName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.autostart.AutoStartManagementActivity",
                )
            },
            Intent().apply {
                component = ComponentName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.permissions.PermissionsEditorActivity",
                )
                putExtra("extra_pkgname", packageName)
            },
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = android.net.Uri.fromParts("package", packageName, null)
            },
        )

        for (intent in intents) {
            try {
                startActivity(intent)
                return true
            } catch (_: Exception) {
                // Try next fallback.
            }
        }
        return false
    }

    companion object {
        /** 与 Dart 侧 kqAutoChannelId 必须保持一致。 */
        private const val KQ_AUTO_CHANNEL_ID = "kq_auto_channel"
    }
}
