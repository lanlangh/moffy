package com.moffy.app

import android.app.AppOpsManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.os.Process
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Calendar

/**
 * 利用統計（UsageStatsManager）取得の MethodChannel ハンドラ。
 *
 * チャネル名・メソッド名・引数キーは Dart 側 [AndroidUsageProvider] と厳密一致させる
 * （ARCHITECTURE §4-3）。
 *
 * 用語:
 *  - PACKAGE_USAGE_STATS: 特別権限（appop）。ユーザーがOS設定「使用状況へのアクセス」で
 *    手動ONする必要がある。AppOpsManager で許可状態を確認する。
 *  - queryUsageStats(INTERVAL_*, begin, end): 期間内のアプリ別フォアグラウンド時間を返す。
 *    同一パッケージが複数 UsageStats に分かれることがあるため合算する。
 */
class UsageStatsHandler(private val context: Context) {

    companion object {
        const val CHANNEL = "com.moffy/usage_stats"
    }

    /** MethodChannel から呼ばれるエントリポイント。 */
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkPermission" -> result.success(permissionStatus())
            "openUsageAccessSettings" -> {
                openUsageAccessSettings()
                result.success(null)
            }
            "queryDailyUsage" -> queryDailyUsage(call, result)
            "queryRangeUsage" -> queryRangeUsage(call, result)
            else -> result.notImplemented()
        }
    }

    /** 'granted' / 'denied'。恒久拒否の厳密判定は難しいため MVP は二値。 */
    private fun permissionStatus(): String {
        return if (hasUsagePermission()) "granted" else "denied"
    }

    @Suppress("DEPRECATION")
    private fun hasUsagePermission(): Boolean {
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        // unsafeCheckOpNoThrow は API 29+。それ未満は checkOpNoThrow（deprecated）で代替。
        val mode = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                context.packageName,
            )
        } else {
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                context.packageName,
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun openUsageAccessSettings() {
        val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
    }

    /** 引数 {beginMs,endMs,packages} -> {pkg:minutes}。権限なしは error('no_permission')。 */
    private fun queryDailyUsage(call: MethodCall, result: MethodChannel.Result) {
        if (!hasUsagePermission()) {
            result.error("no_permission", "PACKAGE_USAGE_STATS が許可されていません", null)
            return
        }
        val beginMs = call.argument<Number>("beginMs")?.toLong()
        val endMs = call.argument<Number>("endMs")?.toLong()
        @Suppress("UNCHECKED_CAST")
        val packages = call.argument<List<String>>("packages") ?: emptyList()
        if (beginMs == null || endMs == null) {
            result.error("platform_error", "beginMs/endMs が不正です", null)
            return
        }
        try {
            val usage = aggregate(beginMs, endMs, packages)
            result.success(usage)
        } catch (e: Exception) {
            result.error("platform_error", e.message, null)
        }
    }

    /**
     * 引数 {startMs,endMs,packages} -> [{dateMs:.., usage:{pkg:minutes}}, ...]（日別）。
     * 基準値計算（直近N日 / S11）用。日ごとに 0:00〜23:59 で区切って集計する。
     */
    private fun queryRangeUsage(call: MethodCall, result: MethodChannel.Result) {
        if (!hasUsagePermission()) {
            result.error("no_permission", "PACKAGE_USAGE_STATS が許可されていません", null)
            return
        }
        val startMs = call.argument<Number>("startMs")?.toLong()
        val endMs = call.argument<Number>("endMs")?.toLong()
        @Suppress("UNCHECKED_CAST")
        val packages = call.argument<List<String>>("packages") ?: emptyList()
        if (startMs == null || endMs == null) {
            result.error("platform_error", "startMs/endMs が不正です", null)
            return
        }
        try {
            val days = ArrayList<Map<String, Any>>()
            val cal = Calendar.getInstance().apply {
                timeInMillis = startMs
                set(Calendar.HOUR_OF_DAY, 0)
                set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }
            while (cal.timeInMillis <= endMs) {
                val dayBegin = cal.timeInMillis
                val dayEnd = dayBegin + DAY_MS - 1
                val usage = aggregate(dayBegin, dayEnd, packages)
                // 取得できた日のみ含める（欠損日は除外 / S11）。
                if (usage.isNotEmpty()) {
                    days.add(mapOf("dateMs" to dayBegin, "usage" to usage))
                }
                cal.add(Calendar.DAY_OF_YEAR, 1)
            }
            result.success(days)
        } catch (e: Exception) {
            result.error("platform_error", e.message, null)
        }
    }

    /**
     * 指定期間の対象パッケージ別 利用「分」を集計する。
     * totalTimeInForeground(ms) をパッケージごとに合算し /1000/60 で分換算。
     */
    private fun aggregate(
        beginMs: Long,
        endMs: Long,
        packages: List<String>,
    ): Map<String, Int> {
        val usm = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val whitelist = packages.toHashSet()
        // INTERVAL_BEST: OSが最適な粒度を選ぶ。PoCで INTERVAL_DAILY と比較検証する（§4-4）。
        val stats = usm.queryUsageStats(
            UsageStatsManager.INTERVAL_BEST,
            beginMs,
            endMs,
        ) ?: return emptyMap()

        val millisByPkg = HashMap<String, Long>()
        for (s in stats) {
            if (whitelist.isNotEmpty() && !whitelist.contains(s.packageName)) continue
            // 同一パッケージが複数 UsageStats に分かれることがあるため合算。
            millisByPkg[s.packageName] =
                (millisByPkg[s.packageName] ?: 0L) + s.totalTimeInForeground
        }
        val out = HashMap<String, Int>()
        for ((pkg, ms) in millisByPkg) {
            val minutes = (ms / 1000 / 60).toInt()
            if (minutes > 0) out[pkg] = minutes
        }
        return out
    }

    private val DAY_MS = 24L * 60 * 60 * 1000
}
