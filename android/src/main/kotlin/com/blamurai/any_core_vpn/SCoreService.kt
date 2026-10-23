package com.blamurai.any_core_vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.ConnectivityManager
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import androidx.core.app.NotificationCompat
import io.nekohasekai.libbox.BridgeOptions
import io.nekohasekai.libbox.BridgeSession
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.Notification as LibboxNotification
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.PlatformUser
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.ShellSession
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import org.json.JSONObject
import java.net.InetAddress
import java.net.InetSocketAddress
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * sing-box core runner — runs in the MAIN process.
 *
 * MUST NOT reference libXray anywhere: libbox.so is loaded first in this
 * process (via go.Seq's static block) and therefore owns the shared go.Seq
 * JNI bridge. Touching LibXray here would load a second Go runtime into
 * the bridge and corrupt sing-box calls.
 */
class SCoreService : VpnService(), CommandServerHandler, PlatformInterface {

    companion object {
        const val ACTION_START = "com.blamurai.any_core_vpn.SCORE_START"
        const val ACTION_STOP = "com.blamurai.any_core_vpn.SCORE_STOP"
        private const val CHANNEL_ID = "vpn_score_channel"

        @Volatile
        var coreVersion: String? = null
            private set

        fun readCoreVersion(): String? {
            if (coreVersion != null) return coreVersion
            return try {
                coreVersion = Libbox.version()
                coreVersion
            } catch (t: Throwable) {
                PluginLogHub.emit("[singbox] version() failed: ${t.message}")
                null
            }
        }

        private const val NOTIFICATION_ID = 4040

        var isServiceRunning = false
            private set
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    private var commandServer: CommandServer? = null
    private var tunFd: ParcelFileDescriptor? = null
    private var proxyShellFd: ParcelFileDescriptor? = null
    private var tunParams: HashMap<String, Any>? = null
    private var stopping = false

    private val scope = CoroutineScope(
        Dispatchers.IO + SupervisorJob() +
                CoroutineExceptionHandler { _, e ->
                    PluginLogHub.emit("UNCAUGHT in singbox coroutine: ${e.javaClass.name}: ${e.message}")
                }
    )

    // libbox's Go wrapper (service.go:226) dereferences the result WITHOUT a
    // nil check — returning null here kills the whole process (proven).
    private val unknownOwner: ConnectionOwner by lazy {
        ConnectionOwner().apply {
            setUserId(-1)
            setUserName("")
            setProcessPath("")
            setAndroidPackageNames(SimpleStringIterator(emptyList()))
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                startForeground(
                    NOTIFICATION_ID, createNotification(
                        intent.getStringExtra("title") ?: "VPN Active",
                        intent.getStringExtra("body") ?: "sing-box Running"
                    )
                )
                val config = intent.getStringExtra("config") ?: "{}"
                val mode = intent.getStringExtra("mode") ?: "tunnel"
                val socksPort = intent.getIntExtra("socksPort", 0)

                @Suppress("DEPRECATION")
                val params = intent.getSerializableExtra("tunParams") as? HashMap<String, Any>
                scope.launch { startCore(config, params, mode, socksPort) }
            }

            ACTION_STOP -> {
                stopCore(); stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    // ---------------- core startup ----------------

    private fun startCore(
        config: String,
        params: HashMap<String, Any>?,
        mode: String,
        socksPort: Int,
    ) {
        stopping = false
        try {
            tunParams = params

            PluginLogHub.emit("[singbox] setup options (mode=$mode, socksPort=$socksPort)")
            // Enable file logging so dial errors are visible via run-as
            val cfg = JSONObject(config)
            cfg.put(
                "log", JSONObject()
                    .put("level", "info")
                    .put("output", java.io.File(cacheDir, "singbox.log").absolutePath)
            )

            // Dump the exact config handed to libbox: when startOrReloadService
            // rejects it, this file is the only way to see what was rejected.
            runCatching {
                java.io.File(cacheDir, "singbox_config.json").writeText(cfg.toString(2))
            }.onFailure { PluginLogHub.emit("[singbox] config dump failed: ${it.message}") }

            val setup = SetupOptions()
            setup.basePath = filesDir.absolutePath
            setup.workingPath = cacheDir.absolutePath
            setup.tempPath = cacheDir.absolutePath
            setup.fixAndroidStack = true
            setup.logMaxLines = 300L
            setup.debug = false
            Libbox.setup(setup)
            
            readCoreVersion()
            PluginLogHub.emit("[singbox] libbox version=${coreVersion ?: "unknown"}")

            PluginLogHub.emit("[singbox] command server start")
            val server = Libbox.newCommandServer(this, this)
            server.start()
            commandServer = server

            val override = OverrideOptions()
            override.autoRedirect = false
            override.includePackage = SimpleStringIterator(
                (params?.get("includedApps") as? List<String>).orEmpty()
            )
            override.excludePackage = SimpleStringIterator(
                (params?.get("excludedApps") as? List<String>).orEmpty()
            )

            PluginLogHub.emit("[singbox] startOrReloadService (decode + start)")
            // In systemProxy mode the config has NO tun inbound, so libbox never
            // calls openTun() and never touches the VpnService device.
            commandServer?.startOrReloadService(cfg.toString(), override)
            PluginLogHub.emit("[singbox] core started OK")

            if (mode == "systemProxy") {
                startTun2Socks(params, socksPort)
            }

            isServiceRunning = true
        } catch (t: Throwable) {
            PluginLogHub.emit(
                "Fatal error starting singbox: ${t.message}\n" +
                        android.util.Log.getStackTraceString(t)
            )
            stopCore()
        }
    }

    /**
     * Happ-style proxy mode for sing-box: the core exposes loopback SOCKS5 only,
     * hev-socks5-tunnel owns the TUN.
     */
    private fun startTun2Socks(params: HashMap<String, Any>?, socksPort: Int) {
        if (socksPort <= 0) throw IllegalStateException("socksPort is required in proxy mode")

        establishProxyTun(params)
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
            tag = "[singbox]",
            log = PluginLogHub::emit,
        )
        if (!ok) throw IllegalStateException("hev-socks5-tunnel failed to start")
    }

    /**
     * Plain VpnService TUN with FULL routes (all device traffic must enter it).
     * Used only in proxy mode; in tunnel mode libbox calls openTun() instead.
     */
    private fun establishProxyTun(params: HashMap<String, Any>?) {
        runCatching { tunFd?.close() }
        tunFd = null

        val builder = Builder()
            .setSession("sing-box tun2socks")
            .setMtu((params?.get("mtu") as? Number)?.toInt() ?: 1400)

        builder.addAddress(
            params?.get("address") as? String ?: "172.19.0.1",
            (params?.get("prefix") as? Number)?.toInt() ?: 30
        )
        builder.addDisallowedApplication(packageName)

        val routes = params?.get("routes") as? List<Map<String, Any>>
        if (routes.isNullOrEmpty()) {
            builder.addRoute("0.0.0.0", 0)
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
        PluginLogHub.emit("[singbox] proxy TUN established (fd=${tunFd?.fd})")
    }

    /**
     * Route-less VPN shell + system-wide HTTP proxy (see ProxyShell).
     */
    private fun startProxyShell(params: HashMap<String, Any>?, host: String, port: Int) {
        closeProxyShell()

        val ipParts = (params?.get("address") as? String ?: "172.19.0.1").split("/")
        val address = ipParts[0]
        val prefix = (params?.get("prefix") as? Number)?.toInt() ?: 30
        val mtu = (params?.get("mtu") as? Number)?.toInt() ?: 1400

        proxyShellFd = ProxyShell.establish(
            service = this,
            host = host,
            port = port,
            address = address,
            prefix = prefix,
            mtu = mtu,
            session = "sing-box proxy",
            tag = "[singbox]",
        ) ?: throw java.io.IOException("Proxy shell establish() failed")

        PluginLogHub.emit("[singbox] proxy shell fd=${proxyShellFd?.fd} -> $host:$port")
        ProxyShell.reportEffectiveProxy(this, "[singbox]", host, port)
    }

    private fun closeProxyShell() {
        runCatching { proxyShellFd?.close() }
        proxyShellFd = null
    }

    // ---------------- libbox PlatformInterface ----------------

    override fun openTun(options: TunOptions): Int {
        val builder = Builder().setSession("sing-box TUN").setMtu(options.mtu.toInt())

        var it4 = options.inet4Address
        while (it4.hasNext()) it4.next()?.let { p -> builder.addAddress(p.address(), p.prefix()) }
        var it6 = options.inet6Address
        while (it6.hasNext()) it6.next()?.let { p -> builder.addAddress(p.address(), p.prefix()) }

        var i4 = options.inet4RouteRange
        while (i4.hasNext()) i4.next()?.let { builder.addRoute(it.address(), it.prefix()) }
        var i6 = options.inet6RouteRange
        while (i6.hasNext()) i6.next()?.let { builder.addRoute(it.address(), it.prefix()) }

        var dns = options.dnsServerAddress
        while (dns.hasNext()) dns.next()?.let { builder.addDnsServer(it) }

        var inc = options.includePackage
        while (inc.hasNext()) inc.next()?.let { if (it.isNotEmpty()) builder.addAllowedApplication(it) }
        var exc = options.excludePackage
        while (exc.hasNext()) exc.next()?.let { if (it.isNotEmpty()) builder.addDisallowedApplication(it) }

        val pfd = builder.establish() ?: throw java.io.IOException("VpnService.establish() failed")
        tunFd = pfd
        PluginLogHub.emit("[singbox] openTun: fd=${pfd.fd}")
        return pfd.fd
    }

    override fun usePlatformAutoDetectInterfaceControl() = true
    override fun autoDetectInterfaceControl(fd: Int) {
        if (!protect(fd)) throw java.io.IOException("protect(fd) failed")
    }

    override fun localDNSTransport(): LocalDNSTransport? = null
    override fun useProcFS() = false
    override fun usePlatformBridge() = false
    override fun usePlatformShell() = false
    override fun underNetworkExtension() = false
    override fun includeAllNetworks() = false
    override fun readWIFIState(): WIFIState? = null
    override fun clearDNSCache() {}
    override fun tailscaleHostname() = ""
    override fun checkPlatformShell() {}

    override fun findConnectionOwner(
        ipProtocol: Int, sourceAddress: String?, sourcePort: Int,
        destinationAddress: String?, destinationPort: Int
    ): ConnectionOwner {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val cm = getSystemService(ConnectivityManager::class.java)
                val local = InetSocketAddress(InetAddress.getByName(sourceAddress), sourcePort)
                val remote = InetSocketAddress(InetAddress.getByName(destinationAddress), destinationPort)
                val uid = cm?.getConnectionOwnerUid(ipProtocol, local, remote)
                if (uid != null && uid >= 0) {
                    val pkgs = packageManager.getPackagesForUid(uid)?.toList().orEmpty()
                    return ConnectionOwner().apply {
                        setUserId(uid)
                        setUserName("")
                        setProcessPath("")
                        setAndroidPackageNames(SimpleStringIterator(pkgs))
                    }
                }
            } catch (_: Throwable) { /* fall through to unknown owner */
            }
        }
        return unknownOwner
    }

    // ----- interface state (REQUIRED for real traffic: the monitor resolves
    // the reported interface index against THIS list) -----

    private var myInterfaceName: String = ""
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var lastReportedInterface: String = ""

    override fun registerMyInterface(name: String?) {
        myInterfaceName = name.orEmpty()
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val out = mutableListOf<io.nekohasekai.libbox.NetworkInterface>()
        val en = java.net.NetworkInterface.getNetworkInterfaces()
            ?: return ListNetworkInterfaceIterator(out)

        for (nif in en) {
            if (nif.name == myInterfaceName) continue // never report our own TUN

            val prefixes = nif.interfaceAddresses.mapNotNull { ia ->
                val ip = ia.address?.hostAddress?.substringBefore('%')
                    ?: return@mapNotNull null
                val pfx = ia.networkPrefixLength
                if (pfx < 0) return@mapNotNull null
                "$ip/$pfx"
            }

            val jname = nif.name
            val jindex = nif.index
            val jmtu = nif.mtu
            // Android hides NetworkInterface.getFlags(); rebuild IFF_* bits.
            val jflags = run {
                var f = 0
                try {
                    if (nif.isUp) f = f or 0x1
                } catch (_: Exception) {
                }
                try {
                    if (nif.isLoopback) f = f or 0x4
                } catch (_: Exception) {
                }
                try {
                    if (nif.isPointToPoint) f = f or 0x8
                } catch (_: Exception) {
                }
                try {
                    if (nif.supportsMulticast()) f = f or 0x10
                } catch (_: Exception) {
                }
                f
            }

            out += io.nekohasekai.libbox.NetworkInterface().apply {
                setName(jname)
                setIndex(jindex)
                setMTU(jmtu)
                setFlags(jflags)
                setAddresses(SimpleStringIterator(prefixes))
            }
        }
        PluginLogHub.emit("[singbox] getInterfaces: ${out.joinToString(prefix = "[", postfix = "]") { it.getName() }}")
        return ListNetworkInterfaceIterator(out)
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        val request = android.net.NetworkRequest.Builder()
            .addCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .removeCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: android.net.Network) = pushBest(listener, cm)
            override fun onLinkPropertiesChanged(network: android.net.Network, lp: android.net.LinkProperties) =
                pushBest(listener, cm)
        }
        networkCallback = cb
        cm.registerNetworkCallback(request, cb)
        pushBest(listener, cm) // first update immediately — dialing waits on it
    }

    private fun pushBest(listener: InterfaceUpdateListener, cm: ConnectivityManager) {
        try {
            var bestName: String? = null
            var bestIf: java.net.NetworkInterface? = null
            var bestScore = -1L
            var bestExpensive = false

            for (network in cm.allNetworks) {
                val nc = cm.getNetworkCapabilities(network) ?: continue
                if (nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)) continue
                if (!nc.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
                val lp = cm.getLinkProperties(network) ?: continue
                val name = lp.interfaceName ?: continue
                val jif = java.net.NetworkInterface.getByName(name) ?: continue

                val score =
                    (if (nc.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED)) 1_000_000_000L else 0L) +
                            nc.linkDownstreamBandwidthKbps
                if (score > bestScore) {
                    bestScore = score
                    bestName = name
                    bestIf = jif
                    bestExpensive = !nc.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
                }
            }

            val name = bestName ?: return
            val jif = bestIf ?: return
            if (name == lastReportedInterface) return
            lastReportedInterface = name
            listener.updateDefaultInterface(name, jif.index, bestExpensive, false)
            PluginLogHub.emit("[singbox] default interface -> $name (idx=${jif.index}, expensive=$bestExpensive)")
        } catch (t: Throwable) {
            PluginLogHub.emit("interface monitor error: ${t.message}")
        }
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener?) {
        networkCallback?.let {
            runCatching { getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(it) }
        }
        networkCallback = null
        lastReportedInterface = ""
    }

    override fun startNeighborMonitor(listener: io.nekohasekai.libbox.NeighborUpdateListener?) {}
    override fun closeNeighborMonitor(listener: io.nekohasekai.libbox.NeighborUpdateListener?) {}

    override fun sendNotification(notification: LibboxNotification?) {
        PluginLogHub.emit("core notification: ${notification?.title} ${notification?.body}")
    }

    override fun cancelNotification(tag: String?, id: Int) {
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).cancel(tag, id)
    }

    override fun createBridge(options: BridgeOptions?): BridgeSession =
        throw UnsupportedOperationException("bridge not supported")

    override fun lookupUser(name: String?): PlatformUser? = null
    override fun lookupSFTPServer() = ""
    override fun readSystemSSHHostKey() = ""
    override fun openShellSession(
        user: PlatformUser?, command: String?, args: StringIterator?,
        homeDir: String?, columns: Int, rows: Int
    ): ShellSession = throw UnsupportedOperationException("shell not supported")

    // ---------------- libbox CommandServerHandler ----------------

    override fun connectSSHAgent(): Int = -1

    // Called from a GO-side thread — never call back into libbox synchronously.
    override fun serviceStop() {
        PluginLogHub.emit("[singbox] libbox requested serviceStop (Go side)")
        mainHandler.post { stopCore(); stopSelf() }
    }

    override fun serviceReload() { /* TODO */
    }

    override fun getSystemProxyStatus(): SystemProxyStatus =
        SystemProxyStatus().apply { enabled = false; available = false }

    override fun setSystemProxyEnabled(enabled: Boolean) {}
    override fun triggerNativeCrash() {
        PluginLogHub.emit("triggerNativeCrash ignored")
    }

    override fun writeDebugMessage(message: String?) {
        PluginLogHub.emit(message ?: "")
    }

    // ---------------- teardown ----------------

    private fun stopCore() {
        if (stopping) return
        stopping = true

        // Who asked for the shutdown? Without this a teardown 2 seconds after
        // a perfectly successful start is indistinguishable from a crash.
        val caller = Throwable("stopCore").stackTrace
            .filter { it.className.startsWith("com.blamurai") }
            .take(4)
            .joinToString(" <- ") {
                "${it.className.substringAfterLast('.')}.${it.methodName}:${it.lineNumber}"
            }
            .ifEmpty { "unknown (native / libbox callback)" }
        PluginLogHub.emit(
            "[singbox] stopCore requested by: $caller " +
                    "(thread=${Thread.currentThread().name})"
        )

        // Bridge first: it is the only reader/writer of the TUN descriptor.
        Tun2Socks.stop("[singbox]", PluginLogHub::emit)
        try {
            commandServer?.let { cs ->
                runCatching { cs.closeService() }
                runCatching { cs.close() }
            }
            commandServer = null
            tunFd?.close(); tunFd = null
            isServiceRunning = false
            PluginLogHub.emit("[singbox] tunnel closed")
        } catch (e: Exception) {
            PluginLogHub.emit("Teardown error: ${e.message}")
        }
    }

    override fun onDestroy() {
        PluginLogHub.emit("[singbox] onDestroy (service instance is going away)")
        stopCore()
        scope.cancel()
        super.onDestroy()
    }

    override fun onRevoke() {
        PluginLogHub.emit("[singbox] VPN revoked by system")
        stopCore()
        stopSelf()
    }

    private fun createNotification(title: String, body: String): Notification {
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

// ---------- helpers ----------

class SimpleStringIterator(private val items: List<String>) : StringIterator {
    private var idx = 0
    override fun hasNext(): Boolean = idx < items.size
    override fun next(): String? = if (idx < items.size) items[idx++] else null
    override fun len(): Int = items.size
}

class ListNetworkInterfaceIterator(private val items: List<io.nekohasekai.libbox.NetworkInterface>) :
    NetworkInterfaceIterator {
    private var idx = 0
    override fun hasNext(): Boolean = idx < items.size
    override fun next(): io.nekohasekai.libbox.NetworkInterface? = items.getOrNull(idx++)
    fun len(): Int = items.size
}