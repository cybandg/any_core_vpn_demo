package com.blamurai.any_core_vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.Context
import android.net.ConnectivityManager
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.core.app.NotificationCompat
import libXray.LibXray
import org.json.JSONObject
import java.io.File

/**
 * Xray core runner — runs in the DEDICATED ':xraycore' process.
 *
 * RULES for this process:
 *  1. System.loadLibrary("gojni") must be the FIRST native action, so
 *     libgojni owns the shared go.Seq JNI bridge (libbox's go.Seq static
 *     block would otherwise load "box" and own the bridge).
 *  2. NEVER touch io.nekohasekai.libbox.* classes here.
 *  3. NEVER use PluginLogHub here — there is no Flutter engine in this
 *     process. Logs go out via broadcasts (log()).
 *
 * libXray v26.x contract:
 *  - single entrypoint LibXray.invoke(requestJSON), apiVersion MUST be 3
 *  - configs go in payload.xrayJson as TEXT (paths are never read)
 *  - request-level "env" is IGNORED; runtime env lives in the Xray config
 *    ROOT "env" object (xray.tun.fd, xray.location.asset, ...)
 *  - Android only: LibXray.setDNS(controller, "ip:port") BEFORE runXray,
 *    LibXray.resetDNS() AFTER stopXray
 *  - testXray/pingBatch hold a lifecycle lock and REJECT an active runXray
 */
class XCoreService : VpnService() {

    companion object {
        const val ACTION_START = "com.blamurai.any_core_vpn.XCORE_START"
        const val ACTION_STOP = "com.blamurai.any_core_vpn.XCORE_STOP"
        const val ACTION_REPORT_STATE = "com.blamurai.any_core_vpn.XCORE_REPORT_STATE"
        const val ACTION_LOG = "com.blamurai.any_core_vpn.XCORE_LOG"
        const val ACTION_STATE = "com.blamurai.any_core_vpn.XCORE_STATE"
        const val ACTION_REPORT_VERSION = "com.blamurai.any_core_vpn.XCORE_REPORT_VERSION"
        const val ACTION_VERSION = "com.blamurai.any_core_vpn.XCORE_VERSION"
        const val ACTION_TEST_CONFIG = "com.blamurai.any_core_vpn.XCORE_TEST_CONFIG"
        const val ACTION_TEST_RESULT = "com.blamurai.any_core_vpn.XCORE_TEST_RESULT"

        private const val CHANNEL_ID = "vpn_xcore_channel"
        private const val NOTIFICATION_ID = 4041

        private const val API_VERSION = 3

        private const val ENABLE_LIBXRAY_DNS = false

        private val NATIVE_CANDIDATES = listOf("gojni", "xray", "Xray", "libXray")

        @Volatile
        var isCoreRunning = false
            private set

        @Volatile
        private var nativeLoaded = false

        /** MUST be called before ANY libXray / go.Seq usage in this process. */
        fun ensureNativeLoaded(context: Context) {
            if (nativeLoaded) return
            synchronized(this) {
                if (nativeLoaded) return

                // DIAGNOSTIC ONLY. With extractNativeLibs="false" libs are
                // mapped straight from the APK and this dir is EMPTY - that
                // is normal and must NOT gate loading.
                val nativeDir = File(context.applicationInfo.nativeLibraryDir)
                val extracted = nativeDir.listFiles()
                    ?.map { it.name }
                    ?.filter { it.startsWith("lib") && it.endsWith(".so") }
                    .orEmpty()
                android.util.Log.i(
                    "XrayCore",
                    "extracted native libs: $extracted (dir=${nativeDir.absolutePath})"
                )

                var lastError: Throwable? = null
                for (name in NATIVE_CANDIDATES) {
                    try {
                        System.loadLibrary(name) // searches APK + extracted dirs
                    } catch (t: Throwable) {
                        lastError = t
                        android.util.Log.w(
                            "XrayCore",
                            "loadLibrary($name) failed: ${t.javaClass.simpleName}: ${t.message}"
                        )
                        continue
                    }
                    android.util.Log.i(
                        "XrayCore",
                        "lib$name.so loaded, mapped from: ${nativeProviderPath(name)}"
                    )

                    // VERIFY against the loaded .so. A failed static init
                    // POISONS libXray.LibXray for the whole process (every
                    // later touch = NoClassDefFoundError), so the FULL cause
                    // chain must be logged exactly here, on first touch.
                    try {
                        Class.forName("libXray.LibXray")
                        nativeLoaded = true
                        android.util.Log.i(
                            "XrayCore",
                            "libXray.LibXray initialised against lib$name.so — owns go.Seq bridge"
                        )
                        return
                    } catch (t: Throwable) {
                        android.util.Log.e(
                            "XrayCore",
                            "LibXray class init FAILED with lib$name.so: ${describe(t)}"
                        )
                        lastError = t
                        break // poisoned class: another .so cannot help now
                    }
                }
                throw IllegalStateException(
                    "cannot initialise libXray native runtime: " +
                            describe(lastError ?: RuntimeException("no native candidate loaded")),
                    lastError
                )
            }
        }

        private fun nativeProviderPath(name: String): String {
            return runCatching {
                File("/proc/self/maps").readLines()
                    .firstOrNull { it.contains("lib$name.so") }
                    ?.substringAfterLast(' ')
                    ?.trim()
                    ?: "unknown"
            }.getOrDefault("unknown")
        }

        fun describe(t: Throwable?): String {
            if (t == null) return "null"
            val sb = StringBuilder("{${t.javaClass.simpleName}}(msg: ${t.message})")
            val seen = java.util.Collections.newSetFromMap(
                java.util.IdentityHashMap<Throwable, Boolean>()
            )
            seen.add(t)
            var c = t.cause
            var depth = 0
            while (c != null && depth < 6 && seen.add(c)) {
                sb.append(" <- {${c.javaClass.simpleName}}(msg: ${c.message})")
                c = c.cause
                depth++
            }
            if (c != null) sb.append(" <- ...")
            return sb.toString()
        }

        /** pubspec name of this plugin — prefixes all of its flutter asset keys. */
        private const val PLUGIN_PACKAGE = "any_core_vpn"

        /**
         * Copies the bundled geo databases into <filesDir>/geo so the core can
         * resolve geosite:/geoip: rules (config-root env "xray.location.asset"
         * points there; the core's own default lookup dir is /system/bin).
         *
         * SOURCE OF TRUTH: the plugin's FLUTTER assets.
         * On Android the whole Flutter asset bundle is plain APK entries under
         *   flutter_assets/packages/<plugin_name>/assets/geo/
         * readable through the plain AssetManager — NO Flutter engine needed,
         * which matters because this runs in the :xraycore process.
         * The legacy native assets dir ("geo/<name>") stays only as a fallback
         * for builds produced before the unification.
         *
         * Copy is skipped when the marker file records the same source path
         * and the on-disk size matches the asset size.
         */
        fun ensureGeoFiles(context: Context): File {
            val geoDir = File(context.filesDir, "geo")
            geoDir.mkdirs()

            for (name in listOf("geoip.dat", "geosite.dat")) {
                val target = File(geoDir, name)
                val marker = File(geoDir, "$name.src")

                val sourcePath = geoAssetPath(context, name)
                if (sourcePath == null) {
                    android.util.Log.w(
                        "XrayCore",
                        "geo asset $name not found in APK assets — " +
                                "geosite:/geoip: rules will fail to load"
                    )
                    continue
                }

                val expectedLength = assetLength(context, sourcePath)
                val upToDate = target.exists() && target.length() > 0 &&
                        marker.exists() && marker.readText() == sourcePath &&
                        (expectedLength < 0 || target.length() == expectedLength)
                if (upToDate) continue

                try {
                    context.assets.open(sourcePath).use { input ->
                        val tmp = File(geoDir, "$name.tmp")
                        tmp.outputStream().use { output -> input.copyTo(output) }
                        if (target.exists()) target.delete()
                        tmp.renameTo(target)
                    }
                    marker.writeText(sourcePath)
                    android.util.Log.i(
                        "XrayCore",
                        "geo asset ready: ${target.absolutePath} " +
                                "(${target.length()} bytes, from $sourcePath)"
                    )
                } catch (t: Throwable) {
                    android.util.Log.w(
                        "XrayCore",
                        "geo asset $name extraction failed: ${describe(t)}"
                    )
                }
            }
            return geoDir
        }

        /**
         * First APK asset path that actually exists for [name]. Plugin flutter
         * assets are keyed "packages/<pubspec name>/..." and on Android live
         * under the APK's "flutter_assets/" directory.
         */
        private fun geoAssetPath(context: Context, name: String): String? {
            val candidates = listOf(
                "flutter_assets/packages/$PLUGIN_PACKAGE/assets/geo/$name",
                "geo/$name", // legacy native assets (pre-unification builds)
            )
            for (path in candidates) {
                try {
                    context.assets.open(path).use { /* existence probe only */ }
                    return path
                } catch (_: Throwable) {
                    // not present under this path — try the next candidate
                }
            }
            return null
        }

        /** Uncompressed asset size, or -1 when the entry is compressed/unknown. */
        private fun assetLength(context: Context, path: String): Long = try {
            context.assets.openFd(path).use { it.length }
        } catch (_: Throwable) {
            -1L
        }
    }

    private var tunFd: ParcelFileDescriptor? = null
    private var proxyShellFd: ParcelFileDescriptor? = null

    /**
     * Socket-protect controller handed to LibXray.setDNS. gomobile bridges a
     * Java object to the Go controller interface by matching a public
     * `protect(long): boolean` method (Go int arrives as Java long).
     */
    private val socketController = object : libXray.DialerController {
        override fun protectFd(fd: Long): Boolean = this@XCoreService.protect(fd.toInt())
    }

    private fun log(msg: String) {
        android.util.Log.i("XrayCore", msg)
        sendBroadcast(Intent(ACTION_LOG).setPackage(packageName).putExtra("line", msg))
    }

    private fun reportState(running: Boolean) {
        isCoreRunning = running
        sendBroadcast(Intent(ACTION_STATE).setPackage(packageName).putExtra("running", running))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                if (isCoreRunning) stopCore() // idempotent re-START = clean slate
                startForeground(
                    NOTIFICATION_ID, buildNotification(
                        intent.getStringExtra("title") ?: "VPN Active",
                        intent.getStringExtra("body") ?: "Xray Running"
                    )
                )
                val config = intent.getStringExtra("config") ?: "{}"
                val mode = intent.getStringExtra("mode") ?: "tunnel"
                val socksPort = intent.getIntExtra("socksPort", 0)

                @Suppress("DEPRECATION")
                val params = intent.getSerializableExtra("tunParams") as? HashMap<String, Any>
                Thread { startCore(config, params, mode, socksPort) }.start()
            }

            ACTION_STOP -> {
                stopCore(); stopSelf()
            }

            ACTION_REPORT_STATE -> reportState(isCoreRunning)
            // Version + validation are safe ONLY here: this process owns
            // libgojni, so touching LibXray does not corrupt the shared go.Seq
            // bridge that libbox uses in the main process.
            ACTION_REPORT_VERSION -> reportVersion()
            ACTION_TEST_CONFIG -> {
                val id = intent.getStringExtra("id") ?: ""
                val config = intent.getStringExtra("config") ?: "{}"
                Thread { testConfig(id, config) }.start()
            }
        }
        return START_NOT_STICKY
    }

    // ---------------------------------------------------------------- version

    private fun reportVersion() {
        val version = readXrayVersion()
        sendBroadcast(
            Intent(ACTION_VERSION)
                .setPackage(packageName)
                .putExtra("version", version)
        )
        if (!isCoreRunning) {
            stopSelf()
        }
    }

    private fun readXrayVersion(): String {
        try {
            ensureNativeLoaded(this)
        } catch (t: Throwable) {
            log("version probe: native/class init failed: ${describe(t)}")
            return ""
        }

        // 1) Direct gomobile bindings. The v26.x AAR does NOT export them
        //    (invoke-only); transitional builds did — reflection degrades to
        //    null and we fall through to the structured entrypoint.
        for (name in listOf("xrayVersion", "version")) {
            val value = callNoArgString(name) ?: continue
            val parsed = parseVersionPayload(value)
            if (parsed.isNotEmpty()) {
                log("xray version: $parsed (LibXray.$name())")
                return parsed
            }
        }

        // 2) Structured entrypoint:
        //    request  = {"apiVersion":3,"method":"xrayVersion"}
        //    response = {"success":true,"data":{"version":"26.7.28"},"error":""}
        for (apiVersion in listOf(3, 1)) {
            try {
                val request = JSONObject()
                    .put("apiVersion", apiVersion)
                    .put("method", "xrayVersion")
                val response = JSONObject(LibXray.invoke(request.toString()))
                if (!response.optBoolean("success", false)) {
                    log("version probe: apiVersion=$apiVersion rejected (${response.optString("error")})")
                    continue
                }
                val parsed = extractVersion(response.opt("data"))
                if (parsed.isNotEmpty()) {
                    log("xray version: $parsed (invoke apiVersion=$apiVersion)")
                    return parsed
                }
                log("version probe: apiVersion=$apiVersion succeeded but carried no version data")
            } catch (t: Throwable) {
                log("version probe failed (apiVersion=$apiVersion): ${describe(t)}")
            }
        }

        log("xray version unavailable from this libXray build")
        return ""
    }

    private fun callNoArgString(name: String): String? = try {
        LibXray::class.java.getMethod(name).invoke(null) as? String
    } catch (_: Throwable) {
        null
    }

    /** Accepts base64 CallResponse, plain JSON (envelope or bare object), or a bare string. */
    private fun parseVersionPayload(raw: String?): String {
        val text = raw?.trim().orEmpty()
        if (text.isEmpty()) return ""

        if (text.startsWith("{")) {
            val obj = JSONObject(text)
            return extractVersion(obj.opt("data") ?: obj)
        }

        try {
            val decoded = String(
                android.util.Base64.decode(text, android.util.Base64.DEFAULT)
            ).trim()
            if (decoded.startsWith("{")) {
                val obj = JSONObject(decoded)
                return extractVersion(obj.opt("data") ?: obj)
            }
            if (decoded.isNotEmpty()) return decoded
        } catch (_: Throwable) {
            // Not base64 - fall through to the raw value.
        }
        return text
    }

    /**
     * Pulls the version string out of any known shape:
     *  - {"version":"26.10.10"}        (Invoke data object - the real case)
     *  - {"data":{"version":"..."}}    (nested envelope, defensive)
     *  - {"data":"26.10.10"}           (old CallResponse with string data)
     *  - "26.10.10"                    (bare JSON string)
     */
    private fun extractVersion(node: Any?): String {
        return when (node) {
            is JSONObject -> {
                val direct = node.opt("version")
                (if (direct is String) direct.trim() else "")
                    .ifEmpty { extractVersion(node.opt("data")) }
            }

            null, JSONObject.NULL -> ""
            else -> node.toString().trim()
        }
    }

    // ------------------------------------------------------------- testConfig

    private fun testConfig(requestId: String, configJson: String) {
        var ok = false
        var error = ""
        try {
            ensureNativeLoaded(this)

            // libXray holds a process-wide lifecycle lock: testXray is
            // REJECTED while a managed runXray instance is active. Report
            // skipped instead of a confusing core error.
            if (isCoreRunning) {
                sendTestResult(
                    requestId, ok = true,
                    error = "NOTEST:xray core is running, testXray is rejected while runXray is active"
                )
                return
            }

            val cfg = JSONObject(configJson)
            cfg.put("log", JSONObject().put("loglevel", "warning"))

            val hadTun = stripTunInbounds(cfg)

            val inbounds = cfg.optJSONArray("inbounds")
            if (inbounds == null || inbounds.length() == 0) {
                sendTestResult(
                    requestId, ok = true, error =
                        if (hadTun) "NOTEST:tun-only config, tun cannot be built " +
                                "without a live fd" else "NOTEST:no inbounds to test"
                )
                return
            }

            // Needed by BOTH contracts: the new one reads payload.xrayJson,
            // transitional builds (apiVersion 1) read payload.configPath.
            val file = File(cacheDir, "xray_test_config.json")
            file.writeText(cfg.toString())

            error = invokeTest(cfg.toString(), file.absolutePath)
            ok = error.isEmpty()
        } catch (t: Throwable) {
            error = "NOTEST:${describe(t)}"
        }

        log(
            "testConfig($requestId): ok=$ok" +
                    if (error.isNotEmpty()) " error=$error" else ""
        )
        sendTestResult(requestId, ok, error)
    }

    /** Removes every tun inbound; returns true if any was removed. */
    private fun stripTunInbounds(cfg: JSONObject): Boolean {
        val inbounds = cfg.optJSONArray("inbounds") ?: return false
        val kept = org.json.JSONArray()
        var removed = false
        for (i in 0 until inbounds.length()) {
            val ib = inbounds.optJSONObject(i) ?: continue
            if (ib.optString("protocol") == "tun") {
                removed = true
                continue
            }
            kept.put(ib)
        }
        if (removed) cfg.put("inbounds", kept)
        return removed
    }

    private fun sendTestResult(requestId: String, ok: Boolean, error: String) {
        sendBroadcast(
            Intent(ACTION_TEST_RESULT)
                .setPackage(packageName)
                .putExtra("id", requestId)
                .putExtra("ok", ok)
                .putExtra("error", error)
        )
    }

    /**
     * Runs testXray through every envelope dialect this lib build might speak:
     *  - current contract:      apiVersion 3, payload.xrayJson  (config TEXT)
     *  - transitional contract: apiVersion 1, payload.configPath (file path)
     *
     * Feedback rules:
     *  - success                    -> "" (empty error)
     *  - core rejected the CONFIG   -> return the message verbatim, stop probing
     *  - contract/lifecycle problem -> log + try the next candidate
     *  - all candidates failed      -> NOTEST with a full probe report
     */
    private fun invokeTest(configJson: String, configPath: String): String {
        val candidates = listOf(
            Triple(3, "xrayJson", configJson),
            Triple(1, "configPath", configPath),
            Triple(1, "xrayJson", configJson),
            Triple(3, "configPath", configPath),
        )
        val probeReport = StringBuilder()

        for ((apiVersion, key, value) in candidates) {
            val probeName = "apiVersion=$apiVersion payload.$key"
            try {
                val request = JSONObject()
                    .put("apiVersion", apiVersion)
                    .put("method", "testXray")
                    .put("payload", JSONObject().put(key, value))

                val response = JSONObject(LibXray.invoke(request.toString()))

                if (response.optBoolean("success", false)) {
                    log("testXray: config VALID via $probeName")
                    return ""
                }

                val message = response.optString("error")
                if (message.isEmpty()) {
                    log("testXray probe $probeName: failure with empty error, trying next")
                    probeReport.append("[$probeName: failure with empty error] ")
                    continue
                }

                if (isContractError(message)) {
                    // The lib does not speak this envelope dialect — NOT a config problem.
                    log("testXray probe $probeName: contract mismatch: $message")
                    probeReport.append("[$probeName: contract: $message] ")
                    continue
                }

                // A REAL core error: config was parsed and rejected. Authoritative.
                log("testXray probe $probeName: config INVALID: $message")
                return message
            } catch (t: Throwable) {
                val detail = "${describe(t)}"
                log("testXray probe $probeName threw: $detail")
                probeReport.append("[$probeName: $detail] ")
            }
        }

        return "NOTEST:testXray unavailable in this libXray build. Probes: $probeReport"
    }

    /**
     * runXray across the two envelope dialects libXray has spoken:
     *  - current:      apiVersion 3, payload.xrayJson   (config TEXT)
     *  - transitional: apiVersion 1, payload.configPath (file path)
     * The config file MUST already be written to cache (startCore does that),
     * so both dialects are servable. Tries newest contract first.
     */
    private fun invokeRunXray(cfg: JSONObject, configFile: File): JSONObject {
        val candidates = listOf(
            Triple(3, "xrayJson", cfg.toString()),
            Triple(1, "configPath", configFile.absolutePath),
        )
        var lastContractError = "no candidate tried"

        for ((apiVersion, key, value) in candidates) {
            val probeName = "apiVersion=$apiVersion payload.$key"
            val request = JSONObject()
                .put("apiVersion", apiVersion)
                .put("method", "runXray")
                .put("payload", JSONObject().put(key, value))

            val response = try {
                JSONObject(LibXray.invoke(request.toString()))
            } catch (t: Throwable) {
                lastContractError = "${describe(t)}"
                log("runXray probe $probeName threw: $lastContractError")
                continue
            }

            if (response.optBoolean("success", false)) {
                log("runXray accepted via $probeName")
                return response
            }

            val message = response.optString("error")
            if (isContractError(message)) {
                lastContractError = message
                log("runXray probe $probeName: contract mismatch: $message")
                continue
            }

            // Real core error: config was parsed and rejected. Authoritative —
            // do NOT retry under another dialect, the config is the problem.
            log("runXray rejected config ($probeName): $message")
            return response
        }

        return JSONObject()
            .put("success", false)
            .put("error", "no runXray envelope accepted by this libXray build: $lastContractError")
    }

    /**
     * True when the failure describes the REQUEST/LIFECYCLE, not the config:
     * unsupported apiVersion/method/payload, malformed request, size limit,
     * or a lifecycle-lock rejection.
     */
    private fun isContractError(message: String): Boolean {
        val m = message.lowercase()
        val contractMarkers = listOf(
            "apiversion",
            "api version",
            "unsupported method",
            "unknown method",
            "invalid method",
            "unsupported payload",
            "unknown payload",
            "invalid payload",
            "missing payload",
            "xrayjson is required",
            "malformed request",
            "invalid request",
            "size limit",
            "too large",
            "lifecycle",
            "already running",
            "active instance",
            "instance is active",
        )
        return contractMarkers.any { m.contains(it) }
    }

    // -------------------------------------------------------------- startCore

    private fun startCore(
        configJson: String,
        params: HashMap<String, Any>?,
        mode: String,
        socksPort: Int,
    ) {
        try {
            ensureNativeLoaded(this) // xray's own .so BEFORE anything else native here

            val cfg = JSONObject(configJson)
            val isProxy = mode == "systemProxy"
            var fd: Int? = null

            if (isProxy) {
                // ---- Happ-style proxy mode ----
                // Xray owns NO TUN: it only listens on loopback SOCKS5/HTTP.
                // The TUN fd is handed to hev-socks5-tunnel AFTER the listeners
                // are up (see below), so the bridge never dials a dead port.
                val inbounds = cfg.optJSONArray("inbounds")
                if (inbounds != null) {
                    val kept = org.json.JSONArray()
                    for (i in 0 until inbounds.length()) {
                        val ib = inbounds.optJSONObject(i) ?: continue
                        if (ib.optString("protocol") == "tun") continue
                        kept.put(ib)
                    }
                    cfg.put("inbounds", kept)
                    if (kept.length() == 0) {
                        throw IllegalStateException(
                            "proxy mode requires at least one socks/http inbound"
                        )
                    }
                }
                log("proxy mode: Xray TUN disabled, SOCKS5 on 127.0.0.1:$socksPort")
            } else {
                // ---- tunnel mode: establish TUN and hand the fd to Xray ----
                establishTun(params)
                val tunFdValue = tunFd?.fd
                    ?: throw IllegalStateException("TUN establish failed")
                fd = tunFdValue
                val actualMtu = (params?.get("mtu") as? Number)?.toInt() ?: 1400

                // ---- patch the tun inbound natively ----
                //  - name = "tun0": REQUIRED (netlink is forbidden to Android apps).
                //  - autoOutboundsInterface: MUST stay UNSET (netlink EPERM).
                //  - mtu: unified with the VpnService builder MTU.
                val inbounds = cfg.optJSONArray("inbounds")
                var patchedTun = false
                if (inbounds != null) {
                    for (i in 0 until inbounds.length()) {
                        val ib = inbounds.optJSONObject(i) ?: continue
                        if (ib.optString("protocol") == "tun") {
                            val s = ib.optJSONObject("settings")
                                ?: JSONObject().also { ib.put("settings", it) }
                            s.put("name", "tun0")
                            s.put("mtu", actualMtu)
                            patchedTun = true
                        }
                    }
                }
                if (!patchedTun) log("WARNING: no tun inbound in config — device traffic cannot be routed")
            }

            // ---- Xray file logs (access/error) for on-device triage ----
            cfg.put(
                "log", JSONObject()
                    .put("loglevel", "info")
                    .put("access", File(cacheDir, "xray_access.log").absolutePath)
                    .put("error", File(cacheDir, "xray_error.log").absolutePath)
            )

            // ---- geo databases for geosite:/geoip: rules ----
            // Must happen BEFORE the env block below: it only publishes
            // xray.location.asset when <filesDir>/geo actually exists.
            val geoDir = ensureGeoFiles(this)

            // ---- config ROOT env ----
            //  - xray.tun.fd:          delivers the TUN descriptor (tunnel mode)
            //  - xray.location.asset:  geoip/geosite directory
            //  - xray.conf.geoloader:  "memconservative" streams the .dat and
            //                          unmarshals ONLY the requested lists. The
            //                          default "standard" reads the whole file
            //                          into RAM (~20 MB heap peak for a single
            //                          category) — unacceptable on 2 GB devices.
            //  - xray.conf.geositeMatcher: "succinct" keeps the domain matcher
            //                          compact instead of the naive structure.
            // Unknown keys are silently ignored by the core, so this is safe
            // even if a future build renames them.
            val envObj = JSONObject()
            if (fd != null) envObj.put("xray.tun.fd", fd.toString())
            if (geoDir.isDirectory) {
                envObj.put("xray.location.asset", geoDir.absolutePath)
                envObj.put("xray.conf.geoloader", "memconservative")
                envObj.put("xray.conf.geositeMatcher", "succinct")
            }
            cfg.remove("env")
            if (envObj.length() > 0) cfg.put("env", envObj)

            // Written BEFORE invoke: serves the debug dump ("configPaths") and
            // the transitional apiVersion-1 configPath contract.
            val configFile = File(cacheDir, "xray_config.json")
            configFile.writeText(cfg.toString())
            log("config written: ${configFile.absolutePath} (mode=$mode, fd=$fd, geo=${geoDir.isDirectory})")

            // NOTE: LibXray.setDNS is intentionally NOT called here - see
            // ENABLE_LIBXRAY_DNS. Socket protection comes from the per-app TUN
            // exclusion in establishTun(), DNS correctness from the config.

            // ---- dual-contract start: apiVersion 3 first, then 1 ----
            val response = invokeRunXray(cfg, configFile)
            if (!response.optBoolean("success", false)) {
                throw IllegalStateException("runXray failed: ${response.optString("error")}")
            }

            if (isProxy) {
                // Listeners are up -> now take the TUN and bridge it into SOCKS5.
                startTun2Socks(params, socksPort)
            }

            reportState(true)
            log("Xray core started (mode=$mode)")
        } catch (t: Throwable) {
            log(
                "Fatal error starting Xray: ${describe(t)}\n" +
                        android.util.Log.getStackTraceString(t)
            )
            reportState(false)
            stopCore()
            runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
            stopSelf()
        }
    }

    /**
     * First usable DNS server from tunParams as an "ip:port" endpoint
     * (setDNS refuses hostnames and bare IPs without a port).
     * NOTE: bare IPv6 without brackets is not handled — pass IPv4 or
     * "[2001:4860:4860::8888]:53"-style strings from Dart.
     */
    private fun pickDnsEndpoint(params: HashMap<String, Any>?): String {
        val servers = params?.get("dnsServers") as? List<String>
        for (raw in servers.orEmpty()) {
            val s = raw.trim()
            if (s.isEmpty()) continue
            return when {
                s.startsWith("[") -> if (s.contains("]:")) s else "$s:53"
                s.contains(":") -> s              // already ip:port
                else -> "$s:53"
            }
        }
        return "1.1.1.1:53"
    }

    /**
     * Establishes the TUN (FULL routes: all device traffic must land in it) and
     * passes the descriptor to hev-socks5-tunnel. Xray itself never sees the fd.
     */
    private fun startTun2Socks(params: HashMap<String, Any>?, socksPort: Int) {
        if (socksPort <= 0) throw IllegalStateException("socksPort is required in proxy mode")

        establishTun(params)
        val fd = tunFd?.fd ?: throw IllegalStateException("TUN establish failed for tun2socks")
        val mtu = (params?.get("mtu") as? Number)?.toInt() ?: 1400
        val address = (params?.get("address") as? String ?: "172.19.0.1").split("/")[0]

        val ok = Tun2Socks.start(
            context = this,
            tunFd = fd,
            socksAddress = "127.0.0.1",
            socksPort = socksPort,
            mtu = mtu,
            tunAddress = address,
            tag = "[xray]",
            log = ::log,
        )
        if (!ok) throw IllegalStateException("hev-socks5-tunnel failed to start")
    }

    /**
     * Route-less VPN shell + system-wide HTTP proxy.
     * Same mechanism as ProxyShell, but logged through broadcasts because there
     * is no Flutter engine in the :xraycore process.
     */
    private fun startProxyShell(params: HashMap<String, Any>?, host: String, port: Int) {
        closeProxyShell()

        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.Q) {
            throw IllegalStateException("systemProxy mode requires Android 10 (API 29) or newer")
        }

        val address = (params?.get("address") as? String ?: "172.19.0.1").split("/")[0]
        val prefix = (params?.get("prefix") as? Number)?.toInt() ?: 30
        val mtu = (params?.get("mtu") as? Number)?.toInt() ?: 1400

        val builder = Builder()
            .setSession("UniversalVpnProxy")
            .setMtu(mtu)
            .setBlocking(false)

        builder.addAddress(address, prefix)
        // NO addRoute(...) ON PURPOSE — routes are what captures traffic into the
        // TUN. Without them the interface exists but nothing is redirected.
        runCatching { builder.addDisallowedApplication(packageName) }
        builder.setMetered(false)
        builder.setHttpProxy(android.net.ProxyInfo.buildDirectProxy(host, port))

        proxyShellFd = builder.establish()
            ?: throw IllegalStateException("Proxy shell establish() failed")

        log("proxy shell fd=${proxyShellFd?.fd} -> system proxy $host:$port")

        // Self-check: did the OS actually adopt our proxy as the system-wide one?
        runCatching {
            val cm = getSystemService(ConnectivityManager::class.java)
            val active = cm?.activeNetwork
            val isVpn = active?.let {
                cm.getNetworkCapabilities(it)?.hasTransport(
                    android.net.NetworkCapabilities.TRANSPORT_VPN
                )
            } == true
            val p = cm?.defaultProxy
            log("proxy shell check: vpnIsActive=$isVpn systemProxy=${p?.host}:${p?.port}")
            if (p == null || p.host != host || p.port != port) {
                log("proxy shell WARNING: OS did not adopt our proxy system-wide")
            }
        }
    }

    private fun closeProxyShell() {
        runCatching { proxyShellFd?.close() }
        proxyShellFd = null
    }

    /**
     * Best underlying (non-VPN) interface name.
     * Written as a plain loop ON PURPOSE: NetworkCapabilities is nullable and
     * Kotlin cannot smart-cast inside `?.takeIf {}` chains (compile errors
     * "Unresolved reference 'hasTransport'" etc.).
     */
    private fun defaultInterfaceName(): String {
        return try {
            val cm = getSystemService(ConnectivityManager::class.java)
                ?: return "wlan0"
            var bestName: String? = null
            var bestScore = -1L
            for (network in cm.allNetworks) {
                val nc: android.net.NetworkCapabilities =
                    cm.getNetworkCapabilities(network) ?: continue
                if (nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)) continue
                if (!nc.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
                val lp = cm.getLinkProperties(network) ?: continue
                val name: String = lp.interfaceName ?: continue
                val score =
                    (if (nc.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED)) 1_000_000_000L else 0L) +
                            nc.linkDownstreamBandwidthKbps
                if (score > bestScore) {
                    bestScore = score
                    bestName = name
                }
            }
            bestName ?: "wlan0"
        } catch (_: Exception) {
            "wlan0"
        }
    }

    private fun stopCore() {
        // Bridge first: it is the only reader/writer of the TUN descriptor.
        Tun2Socks.stop("[xray]", ::log)
        try {
            if (isCoreRunning) {
                ensureNativeLoaded(this)
                // Dual dialect, same as runXray: this build speaks apiVersion 1.
                for (apiVersion in listOf(3, 1)) {
                    val stop = JSONObject()
                        .put("apiVersion", apiVersion)
                        .put("method", "stopXray")
                        .put("payload", JSONObject())
                    val resp = JSONObject(LibXray.invoke(stop.toString()))
                    log("Xray stop (apiVersion=$apiVersion): $resp")
                    if (resp.optBoolean("success", false)) break
                    if (!isContractError(resp.optString("error"))) break
                }
            }
        } catch (t: Throwable) {
            log("Xray stop error: ${describe(t)}")
        } finally {
            // NOTE: LibXray.resetDNS is intentionally NOT called - same native
            // abort hazard as setDNS (see ENABLE_LIBXRAY_DNS).
            runCatching { tunFd?.close() }
            tunFd = null
            reportState(false)
        }
    }

    /** resetDNS must not trigger class loading when native was never ready. */
    private fun nativeLoadedSafe(): Boolean = runCatching {
        ensureNativeLoaded(this); true
    }.getOrDefault(false)


    private fun establishTun(params: HashMap<String, Any>?) {
        val builder = Builder()
            .setSession("UniversalVpnTunnel")
            .setMtu((params?.get("mtu") as? Number)?.toInt() ?: 1400)
        builder.addAddress(
            params?.get("address") as? String ?: "172.19.0.1",
            (params?.get("prefix") as? Number)?.toInt() ?: 30
        )
        builder.addDisallowedApplication(packageName)
        val routes = params?.get("routes") as? List<Map<String, Any>>
        if (routes.isNullOrEmpty()) {
            builder.addRoute("0.0.0.0", 0) // full-tunnel default
            builder.addRoute("::", 0)
        } else routes.forEach {
            builder.addRoute(
                it["address"] as? String ?: "0.0.0.0",
                (it["prefix"] as? Number)?.toInt() ?: 0
            )
        }
        val dns = params?.get("dnsServers") as? List<String>
        if (dns.isNullOrEmpty()) builder.addDnsServer("1.1.1.1")
        else dns.forEach { builder.addDnsServer(it) }

        (params?.get("includedApps") as? List<String>)?.forEach {
            if (it.isNotEmpty()) builder.addAllowedApplication(it)
        }
        (params?.get("excludedApps") as? List<String>)?.forEach {
            if (it.isNotEmpty()) builder.addDisallowedApplication(it)
        }
        tunFd = builder.establish()
        log("TUN established (FD: ${tunFd?.fd})")
    }

    override fun onRevoke() {
        log("VPN revoked by system") // NOT PluginLogHub — no Flutter engine in this process
        stopCore()
        stopSelf()
    }

    override fun onDestroy() {
        stopCore(); super.onDestroy()
    }

    private fun buildNotification(title: String, body: String): Notification {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "VPN Status", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: Intent()
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title).setContentText(body)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE))
            .setOngoing(true).build()
    }
}