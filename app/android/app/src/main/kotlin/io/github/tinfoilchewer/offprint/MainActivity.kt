package io.github.tinfoilchewer.offprint

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Joins the SELPHY's own Wi-Fi network (Android 10+) and binds the app's
 * sockets to it, so printing works with no router and the phone keeps its
 * normal internet connection for every other app.
 */
class MainActivity : FlutterActivity() {
    private var callback: ConnectivityManager.NetworkCallback? = null

    private val connectivity: ConnectivityManager
        get() = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "offprint/wifi").setMethodCallHandler { call, result ->
            when (call.method) {
                "connect" -> connect(
                    call.argument<String>("ssid") ?: "",
                    call.argument<String>("password") ?: "",
                    call.argument<Boolean>("wpa3") ?: false,
                    result,
                )
                "disconnect" -> {
                    releasePrinterNetwork()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun connect(ssid: String, password: String, wpa3: Boolean, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("unsupported", "Joining the printer's network needs Android 10 or newer. Connect to $ssid in Wi-Fi settings instead.", null)
            return
        }
        releasePrinterNetwork()
        val spec = WifiNetworkSpecifier.Builder().setSsid(ssid).apply {
            if (wpa3) setWpa3Passphrase(password) else setWpa2Passphrase(password)
        }.build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(spec)
            .build()
        val main = Handler(Looper.getMainLooper())
        var answered = false
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                connectivity.bindProcessToNetwork(network)
                main.post { if (!answered) { answered = true; result.success(true) } }
            }

            override fun onUnavailable() {
                main.post { if (!answered) { answered = true; result.error("unavailable", "Could not join $ssid. Is the printer showing its QR code?", null) } }
            }

            override fun onLost(network: Network) {
                connectivity.bindProcessToNetwork(null)
            }
        }
        callback = cb
        connectivity.requestNetwork(request, cb, 60_000)
    }

    private fun releasePrinterNetwork() {
        connectivity.bindProcessToNetwork(null)
        callback?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
        callback = null
    }

    override fun onDestroy() {
        releasePrinterNetwork()
        super.onDestroy()
    }
}
