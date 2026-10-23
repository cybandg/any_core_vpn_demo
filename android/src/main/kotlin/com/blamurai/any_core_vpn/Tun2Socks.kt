package com.blamurai.any_core_vpn

import android.content.Context
import hev.htproxy.TProxyService
import java.io.File

/**
 * tun2socks bridge (Happ-style proxy mode).
 *
 * Owns the TUN file descriptor produced by VpnService and converts raw IP
 * packets into SOCKS5 sessions towards the core, which listens on loopback
 * only and has NO tun inbound.
 *
 * hev-socks5-tunnel is plain C (no Go runtime, no second process), therefore
 * it is safe to load next to libbox (main process) or next to libXray/gojni
 * (":xraycore" process).
 */
object Tun2Socks {

    private const val CONFIG_FILE = "hev-socks5-tunnel.yml"
    private const val LOG_FILE = "hev-socks5-tunnel.log"

    /** Native start is non-blocking, so "did it really come up" is polled. */
    private const val START_CHECK_ATTEMPTS = 15
    private const val START_CHECK_DELAY_MS = 100L

    @Volatile
    private var started = false

    fun isRunning(): Boolean =
        runCatching { TProxyService.TProxyIsRunning() }.getOrDefault(false)

    /** "tx=Npkts/Nbytes rx=Npkts/Nbytes" - handy for UI/debug. */
    fun stats(): String {
        val s = runCatching { TProxyService.TProxyGetStats() }.getOrNull()
        if (s == null || s.size < 4) return "unavailable"
        return "tx=${s[0]}pkts/${s[1]}b rx=${s[2]}pkts/${s[3]}b"
    }

    /**
     * @param tunFd    descriptor from VpnService.establish(); the caller keeps
     *                 ownership and MUST keep it open until [stop].
     * @param mtu      MUST equal the MTU given to VpnService.Builder.setMtu:
     *                 hev derives its internal MSS from this value.
     * @param log      main process passes PluginLogHub::emit,
     *                 ":xraycore" passes its broadcast-based log().
     */
    fun start(
        context: Context,
        tunFd: Int,
        socksAddress: String,
        socksPort: Int,
        mtu: Int,
        tunAddress: String,
        tag: String,
        log: (String) -> Unit,
    ): Boolean {
        stop(tag, log)

        return try {
            val configFile = File(context.cacheDir, CONFIG_FILE)
            val logPath = File(context.cacheDir, LOG_FILE).absolutePath

            configFile.writeText(
                buildConfig(
                    socksAddress = socksAddress,
                    socksPort = socksPort,
                    mtu = mtu,
                    tunAddress = tunAddress,
                    logPath = logPath,
                )
            )

            log("$tag tun2socks config: ${configFile.absolutePath}")
            log("$tag tun2socks target: socks5://$socksAddress:$socksPort udp=udp mtu=$mtu")

            val ok = TProxyService.TProxyStartService(configFile.absolutePath, tunFd)
            if (!ok) {
                started = false
                log("$tag tun2socks FAILED: native start returned false")
                return false
            }

            // The native call only spawns the tunnel thread; wait until it
            // actually initialises (config parsed, lwIP up).
            var alive = false
            for (i in 1..START_CHECK_ATTEMPTS) {
                if (isRunning()) {
                    alive = true
                    break
                }
                Thread.sleep(START_CHECK_DELAY_MS)
            }

            started = alive
            if (alive) {
                log("$tag tun2socks RUNNING on fd=$tunFd mtu=$mtu (${stats()})")
            } else {
                log("$tag tun2socks did not report running after " +
                    "${START_CHECK_ATTEMPTS * START_CHECK_DELAY_MS}ms, see $logPath")
            }
            alive
        } catch (t: Throwable) {
            // Typical cause: libhev-socks5-tunnel.so missing for this ABI.
            started = false
            log("$tag tun2socks error: ${t.javaClass.simpleName}: ${t.message}")
            false
        }
    }

    fun stop(tag: String, log: (String) -> Unit) {
        if (!started && !isRunning()) return
        val s = stats()
        runCatching { TProxyService.TProxyStopService() }
            .onFailure { log("$tag tun2socks stop error: ${it.message}") }
        started = false
        log("$tag tun2socks stopped ($s)")
    }

    /**
     * When an fd is supplied, tunnel.name/ipv4 are informational (VpnService
     * already configured the interface), but mtu drives hev's MSS and MUST
     * match the VpnService MTU.
     */
    private fun buildConfig(
        socksAddress: String,
        socksPort: Int,
        mtu: Int,
        tunAddress: String,
        logPath: String,
    ): String = buildString {
        append("tunnel:\n")
        append("  name: tun0\n")
        append("  mtu: $mtu\n")
        append("  multi-queue: false\n")
        append("  ipv4: $tunAddress\n")
        // 'off' = do not answer ICMP locally (real reachability semantics).
        append("  icmp: 'off'\n")
        append("\n")
        append("socks5:\n")
        append("  address: $socksAddress\n")
        append("  port: $socksPort\n")
        // 'udp' = real SOCKS5 UDP ASSOCIATE - the only mode Xray/sing-box
        // speak ('tcp' would need hev-socks5-server on the upstream side).
        append("  udp: 'udp'\n")
        append("  pipeline: false\n")
        append("  tcp-fastopen: false\n")
        append("\n")
        append("misc:\n")
        append("  task-stack-size: 24576\n")
        append("  tcp-buffer-size: 16384\n")
        append("  max-session-count: 1200\n")
        append("  connect-timeout: 10000\n")
        append("  tcp-read-write-timeout: 300000\n")
        append("  udp-read-write-timeout: 60000\n")
        append("  log-file: $logPath\n")
        append("  log-level: info\n")
    }
}