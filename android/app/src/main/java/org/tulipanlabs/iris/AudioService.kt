package org.tulipanlabs.iris

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.MediaMetadata
import android.media.MediaSession
import android.media.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager

/**
 * The sound of a page, kept playing while Iris is not in front. A foreground
 * service of the mediaPlayback type: Android keeps its process alive while
 * it runs, and the screen going off or Iris leaving the screen does not stop
 * it. The page itself is what plays — the service owns no player; it only
 * holds the process, the wake lock, and the MediaSession whose notification
 * (and lock-screen card) carries the play, pause and stop controls back to
 * the page. The page's own media session is inside the engine, which Iris
 * cannot reach; this one is Iris's, driven through the controller.
 *
 * The notification is a media notification, so it is exempt from the
 * notification permission: it shows even when the permission is off, and the
 * service still runs (its notice is only in the task manager then).
 */
class AudioService : Service() {

    companion object {
        const val ACTION_START = "org.tulipanlabs.iris.audio.START"
        const val ACTION_TOGGLE = "org.tulipanlabs.iris.audio.TOGGLE"
        const val ACTION_STOP = "org.tulipanlabs.iris.audio.STOP"
        private const val NOTIFICATION_ID = 1
        private const val CHANNEL_ID = "iris-audio"
    }

    private var session: MediaSession? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val ui = Handler(Looper.getMainLooper())
    private var lastTitle = ""
    private var lastHost = ""
    private var lastPlaying = false

    /** the controls stay current while the service runs, and the service
     *  goes when the browser it serves is gone (its controller cleared) */
    private val tick = object : Runnable {
        override fun run() {
            if (AudioPlayback.controller == null) {
                stopSelf()
                return
            }
            refresh()
            ui.postDelayed(this, 2000)
        }
    }

    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Audio playing", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "The controls while a page plays audio in the background"
                },
            )
        }
        session = MediaSession(this, "Iris").apply {
            setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS)
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() {
                    AudioPlayback.controller?.play()
                    refresh()
                }

                override fun onPause() {
                    AudioPlayback.controller?.pause()
                    refresh()
                }

                override fun onStop() {
                    AudioPlayback.controller?.stop()
                }
            })
            isActive = true
        }
        // the screen going off must not stop the sound: the CPU stays up
        // while the service runs, and goes back to sleep when it stops
        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Iris:audio").apply { acquire() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_TOGGLE -> {
                val c = AudioPlayback.controller
                if (c != null) {
                    if (c.playing) c.pause() else c.play()
                }
                refresh()
            }
            ACTION_STOP -> {
                AudioPlayback.controller?.stop()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
            else -> {
                // startForeground at once: Android 12 and newer stop a
                // foreground service whose notification is late
                startForeground(NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
                ui.removeCallbacks(tick)
                ui.post(tick)
            }
        }
        // killed with the sound gone, the service stays gone: there is
        // nothing to resume, and the page is asked to play again by hand
        return START_NOT_STICKY
    }

    /** the notification and the session follow the page: its title, its
     *  host, and whether it is playing, so the controls always mean
     *  something on this page */
    private fun refresh() {
        val c = AudioPlayback.controller ?: run { stopSelf(); return }
        val playing = c.playing
        val title = c.title.ifEmpty { "Iris" }
        val host = c.host
        session?.setPlaybackState(
            PlaybackState.Builder()
                .setState(
                    if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    PlaybackState.PLAYBACK_POSITION_UNKNOWN, 1f,
                )
                .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_STOP)
                .build(),
        )
        session?.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, host)
                .putString(MediaMetadata.METADATA_KEY_ALBUM, "Iris")
                .build(),
        )
        if (title != lastTitle || host != lastHost || playing != lastPlaying) {
            lastTitle = title
            lastHost = host
            lastPlaying = playing
            val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(NOTIFICATION_ID, notification())
        }
    }

    private fun notification(): Notification {
        val c = AudioPlayback.controller
        val playing = c?.playing == true
        val title = c?.title?.ifEmpty { "Iris" } ?: "Iris"
        val host = c?.host ?: ""
        // back to the page that plays
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val toggle = PendingIntent.getService(
            this, 1,
            Intent(this, AudioService::class.java).setAction(ACTION_TOGGLE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 2,
            Intent(this, AudioService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_audio)
            .setContentTitle(title)
            .setContentText(host)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(session?.sessionToken)
                    .setShowActionsInCompactView(0, 1),
            )
            .addAction(
                Notification.Action.Builder(
                    if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                    if (playing) "Pause" else "Play", toggle,
                ).build(),
            )
            .addAction(
                Notification.Action.Builder(
                    android.R.drawable.ic_menu_close_clear_cancel, "Stop", stop,
                ).build(),
            )
        // Android 12 and newer hold a foreground service's notification for
        // up to ten seconds; the controls must be there at once
        if (Build.VERSION.SDK_INT >= 31) builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        return builder.build()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // swiped away from recents: the activity goes, and the page with
        // it, so there is no sound left to keep — the service goes too
        super.onTaskRemoved(rootIntent)
        AudioPlayback.controller?.stop()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        ui.removeCallbacks(tick)
        session?.isActive = false
        session?.release()
        session = null
        runCatching { if (wakeLock?.isHeld == true) wakeLock?.release() }
        wakeLock = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
