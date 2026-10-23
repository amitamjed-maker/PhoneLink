package com.belawal.phonelink

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.util.DisplayMetrics
import android.view.WindowManager
import java.io.ByteArrayOutputStream

class ScreenService : Service() {
    private var mp: MediaProjection? = null
    private var vd: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var thread: HandlerThread? = null
    private var last = 0L

    override fun onBind(i: Intent?): IBinder? = null

    @Suppress("DEPRECATION")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(NotificationChannel("pl", "PhoneLink", NotificationManager.IMPORTANCE_LOW))
        val n: Notification = Notification.Builder(this, "pl")
            .setContentTitle("স্ক্রিন শেয়ার চলছে")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .build()
        startForeground(2, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)

        val code = intent?.getIntExtra("code", 0) ?: 0
        val data = intent?.getParcelableExtra<Intent>("data")
        if (data == null) { stopSelf(); return START_NOT_STICKY }

        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val proj = mpm.getMediaProjection(code, data)
        mp = proj
        proj.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() { stopSelf() }
        }, Handler(Looper.getMainLooper()))

        val dm = DisplayMetrics()
        (getSystemService(Context.WINDOW_SERVICE) as WindowManager).defaultDisplay.getRealMetrics(dm)
        val w = 540
        val h = ((dm.heightPixels.toFloat() / dm.widthPixels) * w).toInt() / 2 * 2

        val t = HandlerThread("cap").also { it.start() }
        thread = t
        val r = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        reader = r
        r.setOnImageAvailableListener({ ir -> onImage(ir, w, h) }, Handler(t.looper))
        vd = proj.createVirtualDisplay(
            "PhoneLink", w, h, dm.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, r.surface, null, null
        )
        State.screenOn = true
        return START_NOT_STICKY
    }

    private fun onImage(r: ImageReader, w: Int, h: Int) {
        val img = try { r.acquireLatestImage() } catch (e: Exception) { null } ?: return
        try {
            val now = System.currentTimeMillis()
            if (now - last < 130) return
            last = now
            val p = img.planes[0]
            val rowPad = p.rowStride - p.pixelStride * w
            val bm = Bitmap.createBitmap(w + rowPad / p.pixelStride, h, Bitmap.Config.ARGB_8888)
            bm.copyPixelsFromBuffer(p.buffer)
            val crop = Bitmap.createBitmap(bm, 0, 0, w, h)
            val bos = ByteArrayOutputStream()
            crop.compress(Bitmap.CompressFormat.JPEG, 55, bos)
            State.putFrame(bos.toByteArray())
        } catch (e: Exception) {
        } finally {
            img.close()
        }
    }

    override fun onDestroy() {
        State.screenOn = false
        State.frame = null
        try { vd?.release() } catch (e: Exception) { }
        try { reader?.close() } catch (e: Exception) { }
        try { mp?.stop() } catch (e: Exception) { }
        thread?.quitSafely()
        super.onDestroy()
    }
}
