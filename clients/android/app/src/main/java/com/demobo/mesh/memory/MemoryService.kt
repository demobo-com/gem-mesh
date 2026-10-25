package com.demobo.mesh.memory

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.demobo.mesh.MainActivity

/**
 * Holds the app in the foreground while the memory server runs, so Android does not freeze it in the background and
 * the Mac's mirror can still pull and push on :9401 (PROTOCOL §4). It serves nothing itself: the server lives in
 * ChatViewModel, and this only keeps a quiet notification up while it does.
 */
class MemoryService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Memory sync", NotificationManager.IMPORTANCE_MIN))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setContentTitle("Memory is on this phone")
            .setContentText(intent?.getStringExtra(EXTRA_NOTE) ?: "Your Mac can sync while Gem Mesh is in the background")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        ServiceCompat.startForeground(this, ID, n,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0)
        return START_NOT_STICKY     // the server dies with the app's process, so there is nothing to restart
    }

    companion object {
        private const val CHANNEL = "memory"
        private const val ID = 9401
        private const val EXTRA_NOTE = "note"

        fun start(context: Context, note: String) = runCatching {
            ContextCompat.startForegroundService(context, Intent(context, MemoryService::class.java).putExtra(EXTRA_NOTE, note))
        }

        fun stop(context: Context) = context.stopService(Intent(context, MemoryService::class.java))
    }
}
