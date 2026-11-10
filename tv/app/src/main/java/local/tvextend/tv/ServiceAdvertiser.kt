package local.tvextend.tv

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Announces this TV on the local network over Bonjour / mDNS (`_tvextend._tcp`), so the
 * Mac app can list it by name instead of asking for an IP address.
 *
 * The service name gets a " (TV Extend)" suffix because Android 14 refuses a second service
 * with the same name as one the TV already advertises (its own remote-control service uses
 * the TV's name). The plain name goes in the TXT record as `name`, which the Mac displays.
 * If registration fails anyway, it retries a few times.
 */
class ServiceAdvertiser(context: Context, private val name: String) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private var listener: NsdManager.RegistrationListener? = null
    private var active = false
    private var attempts = 0

    fun start() {
        if (active) return
        active = true
        attempts = 0
        register()
    }

    fun stop() {
        active = false
        handler.removeCallbacksAndMessages(null)
        val registration = listener ?: return
        listener = null
        try {
            nsd.unregisterService(registration)
        } catch (_: IllegalArgumentException) {
            // Registration never completed.
        }
    }

    private fun register() {
        attempts++
        val info = NsdServiceInfo().apply {
            serviceName = "$name$NAME_SUFFIX"
            serviceType = SERVICE_TYPE
            port = Protocol.PORT
            setAttribute("name", name)
            setAttribute("v", Protocol.VERSION.toString())
        }
        val registration = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.i(TAG, "advertising as \"${info.serviceName}\"")
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "registration failed (error $errorCode, attempt $attempts)")
                handler.post {
                    if (listener === this) listener = null
                    if (active && attempts < MAX_ATTEMPTS) {
                        handler.postDelayed({ if (active && listener == null) register() }, RETRY_DELAY_MS)
                    }
                }
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) {
                Log.i(TAG, "stopped advertising")
            }

            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "unregistration failed: $errorCode")
            }
        }
        listener = registration
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, registration)
    }

    private companion object {
        const val TAG = "TVExtend/Advertiser"
        const val SERVICE_TYPE = "_tvextend._tcp"
        const val NAME_SUFFIX = " (TV Extend)"
        const val MAX_ATTEMPTS = 10
        const val RETRY_DELAY_MS = 3000L
    }
}
