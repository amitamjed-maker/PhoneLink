package com.belawal.phonelink

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

class NotifListener : NotificationListenerService() {
    override fun onNotificationPosted(sbn: StatusBarNotification) {
        try {
            if (sbn.packageName == packageName) return
            val n = sbn.notification
            if ((n.flags and Notification.FLAG_ONGOING_EVENT) != 0) return
            if ((n.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return
            if (n.category == Notification.CATEGORY_CALL) return
            val e = n.extras
            val title = e.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
            val text = (e.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: e.getCharSequence(Notification.EXTRA_TEXT))?.toString() ?: ""
            if (title.isEmpty() && text.isEmpty()) return
            val app = try {
                packageManager.getApplicationLabel(packageManager.getApplicationInfo(sbn.packageName, 0)).toString()
            } catch (x: Exception) { sbn.packageName }
            State.addNotif(app, title, text)
        } catch (x: Exception) { }
    }
}
