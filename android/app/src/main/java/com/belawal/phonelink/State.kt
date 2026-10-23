package com.belawal.phonelink

import android.content.Context
import java.security.SecureRandom

object State {
    @Volatile var callState = "idle"
    @Volatile var number = ""
    @Volatile var name = ""
    @Volatile var clipSeq = 0
    @Volatile var clipText = ""
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
