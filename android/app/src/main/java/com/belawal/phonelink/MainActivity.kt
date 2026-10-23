package com.belawal.phonelink

import android.Manifest
import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import java.net.Inet4Address
import java.net.NetworkInterface

class MainActivity : Activity() {
    private lateinit var info: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val perms = mutableListOf(
            Manifest.permission.READ_PHONE_STATE,
            Manifest.permission.READ_CALL_LOG,
            Manifest.permission.READ_CONTACTS,
            Manifest.permission.CALL_PHONE,
            Manifest.permission.ANSWER_PHONE_CALLS,
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION
        )
        if (Build.VERSION.SDK_INT >= 33) perms.add(Manifest.permission.POST_NOTIFICATIONS)
        requestPermissions(perms.toTypedArray(), 1)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 96, 48, 48)
        }
        val title = TextView(this).apply { text = "PhoneLink"; textSize = 28f }
        info = TextView(this).apply { textSize = 20f; setPadding(0, 48, 0, 48) }
        val hint = TextView(this).apply {
            text = "ম্যাকের PhoneLink অ্যাপে এই আইপি ও পিন দিন। ফোন ও ম্যাক একই ওয়াই-ফাইয়ে (বা হটস্পটে) থাকতে হবে।"
            textSize = 15f
        }
        val clipBtn = Button(this).apply {
            text = "ফোনের ক্লিপবোর্ড ম্যাকে পাঠান"
            setOnClickListener {
                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                val t = cm.primaryClip?.getItemAt(0)?.coerceToText(this@MainActivity)?.toString() ?: ""
                if (t.isNotEmpty()) {
                    State.clipText = t
                    State.clipSeq++
                    Toast.makeText(this@MainActivity, "পাঠানো হয়েছে", Toast.LENGTH_SHORT).show()
                } else {
                    Toast.makeText(this@MainActivity, "ক্লিপবোর্ড খালি", Toast.LENGTH_SHORT).show()
                }
            }
        }
        val notifBtn = Button(this).apply {
            text = "নোটিফিকেশন অ্যাক্সেস চালু করুন"
            setOnClickListener { startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) }
        }
        val screenBtn = Button(this).apply {
            text = "স্ক্রিন শেয়ার চালু করুন"
            setOnClickListener {
                val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                @Suppress("DEPRECATION")
                startActivityForResult(mpm.createScreenCaptureIntent(), 2)
            }
        }
        val screenOff = Button(this).apply {
            text = "স্ক্রিন শেয়ার বন্ধ করুন"
            setOnClickListener { stopService(Intent(this@MainActivity, ScreenService::class.java)) }
        }
        val startBtn = Button(this).apply {
            text = "সার্ভিস চালু করুন"
            setOnClickListener { startSvc() }
        }
        root.addView(title); root.addView(info); root.addView(hint)
        root.addView(clipBtn); root.addView(notifBtn)
        root.addView(screenBtn); root.addView(screenOff); root.addView(startBtn)
        setContentView(ScrollView(this).apply { addView(root) })
        startSvc()
    }

    override fun onResume() {
        super.onResume()
        info.text = "আইপি: ${localIp()}\nপিন: ${Prefs.pin(this)}"
    }

    override fun onRequestPermissionsResult(code: Int, p: Array<out String>, r: IntArray) {
        super.onRequestPermissionsResult(code, p, r)
        startSvc()
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(req: Int, res: Int, data: Intent?) {
        super.onActivityResult(req, res, data)
        if (req == 2 && res == RESULT_OK && data != null) {
            startForegroundService(
                Intent(this, ScreenService::class.java).putExtra("code", res).putExtra("data", data)
            )
        }
    }

    private fun startSvc() {
        startForegroundService(Intent(this, ConnectService::class.java))
    }

    private fun localIp(): String {
        try {
            for (ni in NetworkInterface.getNetworkInterfaces()) {
                for (a in ni.inetAddresses) {
                    if (a is Inet4Address && !a.isLoopbackAddress && a.isSiteLocalAddress) return a.hostAddress ?: ""
                }
            }
        } catch (e: Exception) { }
        return "ওয়াই-ফাই চালু করুন"
    }
}
