package com.blamurai.any_core_vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor

/**
 * "System proxy" shell (Happ/Clash-style Android systemProxy).
 *
 * Establishes a VpnService interface that has an ADDRESS but **NO ROUTES**,
 * therefore:
 *  - the OS registers a real VPN network (VPN key icon, foreground service,
 *    the user-granted VpnService permission is used),
 *  - but not a single packet is ever captured by the TUN, so the core does
 *    NOT need a tun inbound at all;
 *  - [android.net.VpnService.Builder.setHttpProxy] publishes our local
 *    listener as the SYSTEM-WIDE HTTP proxy (API 29+). ConnectivityService
 *    propagates it into LinkProperties of the VPN network, fires
 *    PROXY_CHANGE_ACTION and ActivityThread.updateHttpProxy() pushes
 *    http.proxyHost/http.proxyPort into every app process.
 *
 * The returned descriptor is never read - it only has to stay OPEN, otherwise
 * the VPN network (and the proxy with it) disappears.
 */
object ProxyShell {

    /** Hosts that must bypass the proxy (LAN / loopback / mDNS / CGNAT). */
    private val DEFAULT_BYPASS = listOf(
        "localhost",
        "*.local",
        "*.lan",
        "127.*",
        "10.*",
        "172.16.*", "172.17.*", "172.18.*", "172.19.*",
        "172.20.*", "172.21.*", "172.22.*", "172.23.*",
        "172.24.*", "172.25.*", "172.26.*", "172.27.*",
        "172.28.*", "172.29.*", "172.30.*", "172.31.*",
        "192.168.*",
        "169.254.*",
        "100.64.*", "100.65.*", "100.66.*", "100.67.*",
        "100.68.*", "100.69.*", "100.70.*", "100.71.*",
        "100.72.*", "100.73.*", "100.74.*", "100.75.*",
        "100.76.*", "100.77.*", "100.78.*", "100.79.*",
        "100.80.*", "100.81.*", "100.82.*", "100.83.*",
        "100.84.*", "100.85.*", "100.86.*", "100.87.*",
        "100.88.*", "100.89.*", "100.90.*", "100.91.*",
        "100.92.*", "100.93.*", "100.94.*", "100.95.*",
        "100.96.*", "100.97.*", "100.98.*", "100.99.*",
        "100.100.*", "100.101.*", "100.102.*", "100.103.*",
        "100.104.*", "100.105.*", "100.106.*", "100.107.*",
        "100.108.*", "100.109.*", "100.110.*", "100.111.*",
        "100.112.*", "100.113.*", "100.114.*", "100.115.*",
        "100.116.*", "100.117.*", "100.118.*", "100.119.*",
        "100.120.*", "100.121.*", "100.122.*", "100.123.*",
        "100.124.*", "100.125.*", "100.126.*", "100.127.*",
        "[::1]",
        "fe80:*",
        "fc00:*", "fd00:*",
    )

    /** True when the OS can publish a system-wide proxy for us. */
    fun isSupported(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    /**
     * @param address TUN interface address, e.g. "172.19.0.1"
     * @param prefix  TUN prefix length, e.g. 30
     * @param mtu     interface MTU (kept aligned with tunnel mode for parity)
     * @return the shell descriptor, or null when the system rejected establish()
     */
    fun establish(
        service: VpnService,
        host: String,
        port: Int,
        address: String,
        prefix: Int,
        mtu: Int,
        session: String,
        tag: String,
    ): ParcelFileDescriptor? {
        if (!isSupported()) {
            throw IllegalStateException(
                "systemProxy mode requires Android 10 (API 29) or newer"
            )
        }

        val builder = service.Builder()
            .setSession(session)
            .setMtu(if (mtu > 0) mtu else 1400)
            .setBlocking(false)

        builder.addAddress(address, prefix)

        // NO addRoute(...) ON PURPOSE: routes are what makes the OS push
        // packets into the TUN. Without them the interface exists but the
        // routing table still points at the physical network.

        // Keep our own process out of the (empty) tunnel.
        runCatching { builder.addDisallowedApplication(service.packageName) }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
            builder.setHttpProxy(
                ProxyInfo.buildDirectProxy(host, port, DEFAULT_BYPASS)
            )
        }

        val fd = builder.establish()
        if (fd == null) {
            PluginLogHub.emit("$tag PROXY SHELL: establish() returned null")
            return null
        }
        return fd
    }

    /**
     * Reads back what the OS actually published. Logged on every proxy start
     * so an OEM that ignores setHttpProxy is visible immediately instead of
     * looking like "connected but no internet".
     */
    fun reportEffectiveProxy(context: Context, tag: String, host: String, port: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        try {
            val cm = context.getSystemService(ConnectivityManager::class.java)
            val active = cm?.activeNetwork
            val caps = active?.let { cm.getNetworkCapabilities(it) }
            val proxy = cm?.defaultProxy

            val isVpnActive = caps?.hasTransport(
                android.net.NetworkCapabilities.TRANSPORT_VPN
            ) == true

            PluginLogHub.emit(
                "$tag PROXY SHELL: vpnIsActive=$isVpnActive " +
                    "systemProxy=${proxy?.host}:${proxy?.port} " +
                    "expected=$host:$port"
            )
            if (proxy == null || proxy.host != host || proxy.port != port) {
                PluginLogHub.emit(
                    "$tag PROXY SHELL WARNING: the OS did not adopt our proxy as " +
                        "the system-wide one. Apps will connect directly."
                )
            }
        } catch (t: Throwable) {
            PluginLogHub.emit("$tag PROXY SHELL report failed: ${t.message}")
        }
    }
}