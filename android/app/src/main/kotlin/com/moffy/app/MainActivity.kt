package com.moffy.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter のホスト Activity。
 * 利用統計取得の MethodChannel（[UsageStatsHandler.CHANNEL]）を配線する。
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val handler = UsageStatsHandler(applicationContext)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            UsageStatsHandler.CHANNEL,
        ).setMethodCallHandler { call, result ->
            handler.handle(call, result)
        }
    }
}
