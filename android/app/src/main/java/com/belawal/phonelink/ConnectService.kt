package com.belawal.phonelink

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.ContactsContract
import android.provider.MediaStore
import android.telecom.TelecomManager
import android.telephony.TelephonyManager
import fi.iki.elonen.NanoHTTPD
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class ConnectService : Service() {
    private var server: Server? = null

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            val st = i.getStringExtra(TelephonyManager.EXTRA_STATE) ?: return
            @Suppress("DEPRECATION")
            val num = i.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)
            when (st) {
                TelephonyManager.EXTRA_STATE_RINGING -> {
                    State.callState = "ringing"
                    if (!num.isNullOrEmpty()) {
                        State.number = num
                        State.name = lookup(c, num)
                    }
                }
                TelephonyManager.EXTRA_STATE_OFFHOOK -> State.callState = "offhook"
                else -> {
                    State.callState = "idle"
                    State.number = ""
                    State.name = ""
                }
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(NotificationChannel("pl", "PhoneLink", NotificationManager.IMPORTANCE_LOW))
        val n: Notification = Notification.Builder(this, "pl")
            .setContentTitle("PhoneLink চালু আছে")
            .setSmallIcon(android.R.drawable.ic_menu_call)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED) {
                type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
            }
            try {
                startForeground(1, n, type)
            } catch (e: Exception) {
                startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            }
        } else {
            startForeground(1, n)
        }

        if (server == null) {
            try {
                server = Server(this).also { it.start(NanoHTTPD.SOCKET_READ_TIMEOUT, false) }
            } catch (e: Exception) { }
            val f = IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED)
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(receiver, f, Context.RECEIVER_EXPORTED)
            else registerReceiver(receiver, f)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        server?.stop()
        server = null
        try { unregisterReceiver(receiver) } catch (e: Exception) { }
        super.onDestroy()
    }

    companion object {
        fun lookup(c: Context, n: String): String = try {
            val u = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(n))
            c.contentResolver.query(u, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) ?: "" else ""
            } ?: ""
        } catch (e: Exception) { "" }
    }
}

class Server(private val ctx: Context) : NanoHTTPD(8765) {
    private val main = Handler(Looper.getMainLooper())

    override fun serve(s: IHTTPSession): Response {
        val pin = s.headers["x-pin"] ?: ""
        if (pin != Prefs.pin(ctx)) return json(Response.Status.UNAUTHORIZED, JSONObject().put("error", "pin"))
        return try {
            route(s)
        } catch (e: Exception) {
            json(Response.Status.INTERNAL_ERROR, JSONObject().put("error", e.message ?: "error"))
        }
    }

    private fun json(st: Response.IStatus, o: JSONObject): Response =
        newFixedLengthResponse(st, "application/json; charset=utf-8", o.toString())

    private fun ok(): Response = json(Response.Status.OK, JSONObject().put("ok", true))

    private fun stateJson(): JSONObject {
        val bi = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val lvl = bi?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = bi?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val st = bi?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val charging = st == BatteryManager.BATTERY_STATUS_CHARGING || st == BatteryManager.BATTERY_STATUS_FULL
        return JSONObject()
            .put("call", State.callState)
            .put("number", State.number)
            .put("name", State.name)
            .put("clipSeq", State.clipSeq)
            .put("clipText", State.clipText)
            .put("battery", if (lvl >= 0 && scale > 0) lvl * 100 / scale else -1)
            .put("charging", charging)
            .put("screen", State.screenOn)
            .put("notifs", State.notifsJson())
    }

    @SuppressLint("MissingPermission")
    private fun location(): JSONObject {
        val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val best = AtomicReference<Location?>(null)
        val latch = CountDownLatch(1)
        if (Build.VERSION.SDK_INT >= 30) {
            for (p in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
                try {
                    if (!lm.isProviderEnabled(p)) continue
                    lm.getCurrentLocation(p, null, ctx.mainExecutor) { l ->
                        if (l != null) {
                            synchronized(best) {
                                val c = best.get()
                                if (c == null || l.accuracy < c.accuracy) best.set(l)
                            }
                            latch.countDown()
                        }
                    }
                } catch (e: Exception) { }
            }
            latch.await(8, TimeUnit.SECONDS)
        }
        if (best.get() == null) {
            for (p in lm.getProviders(true)) {
                val l = try { lm.getLastKnownLocation(p) } catch (e: Exception) { null }
                val c = best.get()
                if (l != null && (c == null || l.time > c.time)) best.set(l)
            }
        }
        val b = best.get() ?: return JSONObject().put("error", "no location")
        return JSONObject().put("lat", b.latitude).put("lon", b.longitude).put("acc", b.accuracy.toInt())
    }

    @SuppressLint("MissingPermission")
    private fun route(s: IHTTPSession): Response {
        val tm = ctx.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        when (s.uri) {
            "/state" -> return json(Response.Status.OK, stateJson())
            "/dial" -> {
                val number = s.parms["number"] ?: return json(Response.Status.BAD_REQUEST, JSONObject().put("error", "number"))
                State.number = number
                State.name = ConnectService.lookup(ctx, number)
                tm.placeCall(Uri.fromParts("tel", number, null), Bundle())
                return ok()
            }
            "/answer" -> { tm.acceptRingingCall(); return ok() }
            "/reject" -> { tm.endCall(); return ok() }
            "/clip" -> {
                val text = String(readBody(s), Charsets.UTF_8)
                main.post {
                    val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    cm.setPrimaryClip(ClipData.newPlainText("mac", text))
                }
                return ok()
            }
            "/location" -> {
                val o = location()
                return json(if (o.has("error")) Response.Status.INTERNAL_ERROR else Response.Status.OK, o)
            }
            "/frame" -> {
                if (!State.screenOn) return json(Response.Status.CONFLICT, JSONObject().put("error", "off"))
                val after = (s.parms["after"] ?: "0").toLong()
                val seq = State.waitFrame(after, 1500)
                val f = State.frame
                if (seq <= after || f == null) return newFixedLengthResponse(Response.Status.NO_CONTENT, "text/plain", "")
                val r = newFixedLengthResponse(Response.Status.OK, "image/jpeg", ByteArrayInputStream(f), f.size.toLong())
                r.addHeader("X-Seq", seq.toString())
                return r
            }
            "/file" -> {
                val name = (s.parms["name"] ?: "file").replace(Regex("[\\\\/:*?\"<>|]"), "_")
                val len = (s.headers["content-length"] ?: "0").toLong()
                val v = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, name)
                    put(MediaStore.Downloads.RELATIVE_PATH, "Download/PhoneLink")
                }
                val uri = ctx.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, v)
                    ?: throw Exception("save failed")
                ctx.contentResolver.openOutputStream(uri)!!.use { out ->
                    val buf = ByteArray(65536)
                    var left = len
                    while (left > 0) {
                        val r = s.inputStream.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
                        if (r < 0) break
                        out.write(buf, 0, r)
                        left -= r
                    }
                }
                return ok()
            }
        }
        return json(Response.Status.NOT_FOUND, JSONObject().put("error", "not found"))
    }

    private fun readBody(s: IHTTPSession): ByteArray {
        val len = (s.headers["content-length"] ?: "0").toInt()
        val buf = ByteArray(len)
        var off = 0
        while (off < len) {
            val r = s.inputStream.read(buf, off, len - off)
            if (r < 0) break
            off += r
        }
        return buf
    }
}
