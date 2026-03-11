package org.meshutility.app

import android.content.Intent
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val settingsChannel = "org.meshutility.app/settings"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, settingsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openBluetoothSettings" -> {
                        var opened = false
                        val intents = mutableListOf<Intent>()

                        // Prefer Bluetooth panel on Android 10+; this avoids some OEM/OOSP
                        // crashes in the dedicated Bluetooth settings page.
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            intents.add(Intent("android.settings.panel.action.BLUETOOTH"))
                        }
                        intents.add(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                        intents.add(Intent(Settings.ACTION_WIRELESS_SETTINGS))
                        intents.add(Intent(Settings.ACTION_SETTINGS))

                        for (intent in intents) {
                            try {
                                startActivity(intent)
                                opened = true
                                break
                            } catch (_: Throwable) {
                                // Try next fallback settings target.
                            }
                        }

                        result.success(opened)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
