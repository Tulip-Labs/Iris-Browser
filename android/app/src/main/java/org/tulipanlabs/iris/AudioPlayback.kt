package org.tulipanlabs.iris

import android.content.Context
import android.content.Intent

/**
 * The bridge between the page that plays sound and the service that keeps
 * it playing. The model is the controller (it owns the tabs and their
 * pages); the service only reads it, so the service never touches a page
 * itself. The controller is set when the model is made and cleared when it
 * goes, so a service that outlives the browser stops itself.
 */
interface AudioController {
    /** sound is playing in a page right now */
    val playing: Boolean
    /** the playing page's title, for the notification */
    val title: String
    /** the playing page's host, for the notification */
    val host: String
    /** play the page's media again (the notification's play button) */
    fun play()
    /** pause the page's media (the notification's pause button) */
    fun pause()
    /** pause the page's media and let the service go */
    fun stop()
}

object AudioPlayback {
    var controller: AudioController? = null

    /** the service that keeps the sound playing, started while Iris is still in front */
    fun start(ctx: Context) {
        // Android 12 and newer refuse a foreground service started from the
        // background, so this is called from the activity's onPause, while
        // Iris is still visible; a start that is refused anyway is caught
        runCatching {
            ctx.startForegroundService(Intent(ctx, AudioService::class.java).setAction(AudioService.ACTION_START))
        }
    }

    /** the service goes, and its notification with it */
    fun stop(ctx: Context) {
        runCatching { ctx.stopService(Intent(ctx, AudioService::class.java)) }
    }
}
