package local.tvextend.tv

import android.app.Activity
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.TextView
import java.net.Inet4Address
import java.net.NetworkInterface

class MainActivity : Activity(), SurfaceHolder.Callback, StreamServer.Listener {
    private lateinit var overlay: View
    private lateinit var title: TextView
    private lateinit var address: TextView
    private lateinit var detail: TextView
    private var server: StreamServer? = null
    private var advertiser: ServiceAdvertiser? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(R.layout.activity_main)
        hideSystemBars()

        overlay = findViewById(R.id.overlay)
        title = findViewById(R.id.title)
        address = findViewById(R.id.address)
        detail = findViewById(R.id.detail)

        val video = findViewById<SurfaceView>(R.id.video)
        // The TV's UI runs at 1280×720 but the panel is 1920×1080: ask for a full-resolution
        // video surface so the picture isn't downscaled.
        video.holder.setFixedSize(VIDEO_WIDTH, VIDEO_HEIGHT)
        video.holder.addCallback(this)
    }

    // MARK: Surface lifecycle — the server runs only while there's a surface to draw on.

    override fun surfaceCreated(holder: SurfaceHolder) {
        val name = deviceName()
        server = StreamServer(holder.surface, name, this).also { it.start() }
        advertiser = ServiceAdvertiser(this, name).also { it.start() }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        advertiser?.stop()
        advertiser = null
        server?.stop()
        server = null
    }

    // MARK: StreamServer.Listener (called from background threads)

    override fun onWaiting() = runOnUiThread {
        showOverlay(getString(R.string.waiting), "${localAddress()}:${Protocol.PORT}", getString(R.string.hint))
    }

    override fun onConnected(peer: String) = runOnUiThread {
        showOverlay("Connected", peer, "Waiting for video…")
    }

    override fun onFirstFrame() = runOnUiThread {
        overlay.visibility = View.GONE
    }

    override fun onDisconnected(reason: String) = runOnUiThread {
        showOverlay(getString(R.string.waiting), "${localAddress()}:${Protocol.PORT}", reason)
    }

    // MARK: Helpers

    private fun showOverlay(titleText: String, addressText: String, detailText: String) {
        title.text = titleText
        address.text = addressText
        detail.text = detailText
        overlay.visibility = View.VISIBLE
    }

    private fun hideSystemBars() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.let {
                it.hide(WindowInsets.Type.systemBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        }
    }

    private fun deviceName(): String =
        Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME) ?: Build.MODEL

    /** The TV's IPv4 address on the local network, preferring Ethernet, then Wi-Fi. */
    private fun localAddress(): String {
        val candidates = NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
            .filter { it.isUp && !it.isLoopback }
            .sortedBy { if (it.name.startsWith("eth")) 0 else if (it.name.startsWith("wlan")) 1 else 2 }
        return candidates
            .flatMap { it.inetAddresses.toList() }
            .firstOrNull { it is Inet4Address && it.isSiteLocalAddress }
            ?.hostAddress
            ?: "no network"
    }

    private companion object {
        const val VIDEO_WIDTH = 1920
        const val VIDEO_HEIGHT = 1080
    }
}
