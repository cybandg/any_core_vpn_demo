package com.blamurai.any_core_vpn

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

object PluginLogHub {
    private const val TAG = "AnyCoreVpn"

    private var sink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    fun setSink(eventSink: EventChannel.EventSink?) {
        sink = eventSink
    }

    // FlutterJNI is main-thread-only; cores emit from IO/Go threads.
    fun emit(message: String) {
        // Mirror to logcat FIRST: without a subscribed Flutter sink the
        // message is dropped, and startup failures are exactly what we need
        // when debugging from adb.
        android.util.Log.i(TAG, message)
        mainHandler.post {
            try {
                sink?.success(message)
            } catch (_: Exception) { /* sink detached mid-emit */
            }
        }
    }
}

/** Main-process view of the :xraycore process state (via broadcasts). */
object XBridge {
    @Volatile
    var running = false

    @Volatile
    var version: String? = null
}

class AnyCoreVpnPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler, ActivityAware, PluginRegistry.ActivityResultListener {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var context: Context? = null
    private var activity: Activity? = null
    private var pendingVpnResult: MethodChannel.Result? = null

    /** Pending native config tests, keyed by the id we generated. */
    private val pendingTests = HashMap<String, MethodChannel.Result>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingTimeouts = HashMap<String, Runnable>()

    /** Pending version request (the answer arrives via broadcast). */
    private var pendingVersionResult: MethodChannel.Result? = null
    private val versionTimeout = Runnable { completeVersionRequest(null, "timeout") }

    private val xrayReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, i: Intent?) {
            when (i?.action) {
                XCoreService.ACTION_LOG ->
                    PluginLogHub.emit("[xray] ${i.getStringExtra("line")}")

                XCoreService.ACTION_STATE ->
                    XBridge.running = i.getBooleanExtra("running", false)
                // Empty means "this libXray build has no version method we
                // recognise" - normalise to null so Dart reports "unknown".
                XCoreService.ACTION_VERSION -> {
                    XBridge.version =
                        i.getStringExtra("version")?.takeIf { it.isNotEmpty() }
                    completeVersionRequest(XBridge.version, null)
                }

                XCoreService.ACTION_TEST_RESULT -> completePendingTest(i)
            }
        }
    }

    /** Replies to a waiting coreVersions() call exactly once. */
    private fun completeVersionRequest(version: String?, failure: String?) {
        val pending = pendingVersionResult ?: return
        pendingVersionResult = null
        mainHandler.removeCallbacks(versionTimeout)

        if (failure != null) {
            PluginLogHub.emit("xray version request failed: $failure")
        }
        pending.success(
            hashMapOf<String, String?>(
                "singbox" to SCoreService.readCoreVersion(),
                "xray" to (version ?: XBridge.version)
            )
        )
    }

    private fun completePendingTest(intent: Intent) {
        val id = intent.getStringExtra("id") ?: return
        val pending = pendingTests.remove(id) ?: return
        pendingTimeouts.remove(id)?.let { mainHandler.removeCallbacks(it) }

        val ok = intent.getBooleanExtra("ok", false)
        val error = intent.getStringExtra("error") ?: ""

        // Broadcast receivers run on the main thread, so touching the Flutter
        // Result here is safe.
        when {
            ok -> pending.success(hashMapOf("ok" to true, "skipped" to false, "error" to ""))
            error.startsWith("NOTEST:") -> pending.success(
                hashMapOf(
                    "ok" to true,
                    "skipped" to true,
                    "error" to error.removePrefix("NOTEST:")
                )
            )

            else -> pending.success(hashMapOf("ok" to false, "skipped" to false, "error" to error))
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel =
            MethodChannel(binding.binaryMessenger, "com.blamurai.any_core_vpn/methods")
        methodChannel.setMethodCallHandler(this)

        eventChannel =
            EventChannel(binding.binaryMessenger, "com.blamurai.any_core_vpn/logs")
        eventChannel.setStreamHandler(this)

        runCatching { context?.unregisterReceiver(xrayReceiver) }

        ContextCompat.registerReceiver(
            context!!, xrayReceiver,
            IntentFilter().apply {
                addAction(XCoreService.ACTION_LOG)
                addAction(XCoreService.ACTION_STATE)
                addAction(XCoreService.ACTION_VERSION)
                addAction(XCoreService.ACTION_TEST_RESULT)
            },
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepareVpn" -> {
                val act = activity
                if (act == null) {
                    result.error("NO_ACTIVITY", "Cannot request VPN permission without foreground activity", null)
                    return
                }
                val intent = VpnService.prepare(act)
                if (intent != null) {
                    pendingVpnResult = result
                    act.startActivityForResult(intent, 0x1337)
                } else {
                    result.success(true)
                }
            }

            "startVpn" -> {
                val core = call.argument<String>("core") ?: "singbox"
                val config = call.argument<String>("config") ?: ""
                // "tunnel"      = the core owns the TUN (tun inbound present).
                // "systemProxy" = NO tun inbound; hev-socks5-tunnel owns the TUN fd
                //                 and bridges device traffic into the core's
                //                 loopback SOCKS5 listener.
                val mode = call.argument<String>("mode") ?: "tunnel"
                val socksPort = call.argument<Int>("socksPort") ?: 0
                val tunParams = call.argument<HashMap<String, Any>>("tunParams")
                val title = call.argument<String>("notificationTitle") ?: "VPN"
                val body = call.argument<String>("notificationBody") ?: "Running"

                val ctx = context ?: return result.error("NO_CONTEXT", "Context is null", null)

                if (mode == "systemProxy" && socksPort <= 0) {
                    result.error("BAD_SOCKS_PORT", "systemProxy mode requires a valid socksPort", null)
                    return
                }

                // Route to the dedicated process/service for the selected core.
                val intent = if (core == "xray") {
                    Intent(ctx, XCoreService::class.java).apply {
                        action = XCoreService.ACTION_START
                    }
                } else {
                    Intent(ctx, SCoreService::class.java).apply {
                        action = SCoreService.ACTION_START
                    }
                }.apply {
                    putExtra("config", config)
                    putExtra("mode", mode)
                    putExtra("socksPort", socksPort)
                    putExtra("tunParams", tunParams)
                    putExtra("title", title)
                    putExtra("body", body)
                }
                try {
                    ctx.startService(intent)
                    result.success(true)
                } catch (e: Throwable) {
                    PluginLogHub.emit("startService failed: ${e.javaClass.simpleName}: ${e.message}")
                    result.error("START_FAILED", e.message, null)
                }
            }
            // Absolute paths of the config dumps both cores write into the app's
            // cache dir. Both services share the same data dir even though Xray
            // runs in the ":xraycore" process, so one cacheDir covers both.
            // The files may not exist yet - the caller checks that itself.
            "configPaths" -> {
                val ctx = context ?: return result.error("NO_CONTEXT", "Context is null", null)
                val cache = ctx.cacheDir.absolutePath
                result.success(
                    hashMapOf(
                        "xray" to "$cache/xray_config.json",
                        "singbox" to "$cache/singbox_config.json"
                    )
                )
            }

            "coreVersions" -> {
                val ctx = context
                val known = XBridge.version

                // Cached for the whole plugin lifetime: the version is a
                // property of the bundled libXray, it cannot change.
                if (known != null || ctx == null) {
                    result.success(
                        hashMapOf<String, String?>(
                            "singbox" to SCoreService.readCoreVersion(),
                            "xray" to known
                        )
                    )
                    return
                }
                if (pendingVersionResult != null) {
                    // Another caller is already waiting - coalesce.
                    result.success(
                        hashMapOf<String, String?>(
                            "singbox" to SCoreService.readCoreVersion(),
                            "xray" to null
                        )
                    )
                    return
                }

                // The version can only be read inside ":xraycore": touching
                // LibXray from the main process would load a second Go runtime
                // and corrupt the shared go.Seq bridge that libbox owns.
                pendingVersionResult = result
                mainHandler.postDelayed(versionTimeout, 5_000)

                runCatching {
                    ctx.startService(
                        Intent(ctx, XCoreService::class.java)
                            .setAction(XCoreService.ACTION_REPORT_VERSION)
                    )
                }.onFailure { e ->
                    completeVersionRequest(null, "${e.javaClass.simpleName}: ${e.message}")
                }
            }
            
            // Native validation through libXray testXray (authoritative:
            // core.LoadConfig + core.New, never Start). Runs in :xraycore.
            "testConfig" -> {
                val ctx = context ?: return result.error("NO_CONTEXT", "Context is null", null)
                val config = call.argument<String>("config") ?: ""
                if (config.isEmpty()) {
                    result.error("EMPTY_CONFIG", "config must not be empty", null)
                    return
                }
                val id = "test-${System.currentTimeMillis()}-${pendingTests.size}"
                pendingTests[id] = result

                // Fail closed: never leave a Flutter future hanging.
                val timeout = Runnable {
                    val pending = pendingTests.remove(id) ?: return@Runnable
                    pending.error("TEST_TIMEOUT", "core did not answer within 20s", null)
                }
                pendingTimeouts[id] = timeout
                mainHandler.postDelayed(timeout, 20_000)

                try {
                    ctx.startService(
                        Intent(ctx, XCoreService::class.java)
                            .setAction(XCoreService.ACTION_TEST_CONFIG)
                            .putExtra("id", id)
                            .putExtra("config", config)
                    )
                } catch (e: Throwable) {
                    pendingTests.remove(id)
                    pendingTimeouts.remove(id)?.let { mainHandler.removeCallbacks(it) }
                    result.error("TEST_FAILED", e.message, null)
                }
            }

            "stopVpn" -> {
                val ctx = context ?: return result.error("NO_CONTEXT", "Context is null", null)
                // Stop BOTH — each stop is an idempotent no-op on the idle core.
                ctx.startService(
                    Intent(ctx, SCoreService::class.java)
                        .setAction(SCoreService.ACTION_STOP)
                )
                ctx.startService(
                    Intent(ctx, XCoreService::class.java)
                        .setAction(XCoreService.ACTION_STOP)
                )
                result.success(null)
            }

            "isRunning" -> {
                // Refresh xray state if its process already exists (the ping is a
                // no-op if the service is down — we don't spawn it just to poll).
                if (XBridge.running) {
                    context?.startService(
                        Intent(context, XCoreService::class.java)
                            .setAction(XCoreService.ACTION_REPORT_STATE)
                    )
                }
                result.success(SCoreService.isServiceRunning || XBridge.running)
            }

            else -> result.notImplemented()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == 0x1337) {
            pendingVpnResult?.success(resultCode == Activity.RESULT_OK)
            pendingVpnResult = null
            return true
        }
        return false
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        PluginLogHub.setSink(events)
    }

    override fun onCancel(arguments: Any?) {
        PluginLogHub.setSink(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        mainHandler.removeCallbacks(versionTimeout)
        runCatching { context?.unregisterReceiver(xrayReceiver) }
        context = null
    }
}