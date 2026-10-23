package hev.htproxy;

/**
 * JNI binding for libhev-socks5-tunnel.so (2.17+/2.18.x contract).
 *
 * The native library registers its natives to this exact FQN in JNI_OnLoad
 * (FindClass(PKGNAME "/" CLSNAME) + RegisterNatives; defaults are
 * PKGNAME=hev/htproxy, CLSNAME=TProxyService). Renaming this class requires
 * rebuilding the library with different PKGNAME/CLSNAME in Application.mk.
 *
 * Notes:
 *  - TProxyStartService() is NON-BLOCKING: the JNI layer spawns its own
 *    pthread which runs hev_socks5_tunnel_main() until TProxyStopService().
 *    The returned boolean only tells whether the thread was created.
 *  - The TUN descriptor must be opened by the caller and stay OPEN for the
 *    whole session (hev never closes it).
 */
public final class TProxyService {
    private TProxyService() {
    }

    static {
        System.loadLibrary("hev-socks5-tunnel");
    }

    public static native boolean TProxyStartService(String config_path, int fd);

    public static native boolean TProxyStopService();

    public static native boolean TProxyIsRunning();

    /** [txPackets, txBytes, rxPackets, rxBytes] */
    public static native long[] TProxyGetStats();
}