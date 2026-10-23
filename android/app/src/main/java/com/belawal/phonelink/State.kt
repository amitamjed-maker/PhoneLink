package com.belawal.phonelink

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

object State {
    @Volatile var callState = "idle"
    @Volatile var number = ""
    @Volatile var name = ""
    @Volatile var clipSeq = 0
    @Volatile var clipText = ""
    @Volatile var screenOn = false

    private val notifs = ArrayList<JSONObject>()
    private var nseq = 0

    @Synchronized
    fun addNotif(app: String, title: String, text: String) {
        nseq++
        notifs.add(JSONObject().put("seq", nseq).put("app", app).put("title", title).put("text", text.take(300)))
        while (notifs.size > 20) notifs.removeAt(0)
    }

    @Synchronized
    fun notifsJson(): JSONArray {
        val a = JSONArray()
        for (o in notifs) a.put(o)
        return a
    }

    private val lock = ReentrantLock()
    private val cond = lock.newCondition()
    @Volatile var frame: ByteArray? = null
    @Volatile var frameSeq = 0L

    fun putFrame(b: ByteArray) {
        lock.withLock {
            frame = b
            frameSeq++
            cond.signalAll()
        }
    }

    fun waitFrame(after: Long, ms: Long): Long {
        lock.withLock {
            if (frameSeq <= after) cond.await(ms, TimeUnit.MILLISECONDS)
            return frameSeq
        }
    }
}

object Prefs {
    fun pin(c: Context): String {
        val p = c.getSharedPreferences("p", Context.MODE_PRIVATE)
        var v = p.getString("pin", null)
        if (v == null) {
            v = (100000 + SecureRandom().nextInt(900000)).toString()
            p.edit().putString("pin", v).apply()
        }
        return v
    }
}
