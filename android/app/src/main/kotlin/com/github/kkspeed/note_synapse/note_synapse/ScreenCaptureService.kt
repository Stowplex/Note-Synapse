package com.github.kkspeed.note_synapse.note_synapse

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder

/// Foreground service that records the screen via MediaProjection.
///
/// The activity obtains the projection consent token and hands it here through
/// an ACTION_START intent. The service starts as a `mediaProjection`-typed
/// foreground service (required on Android 10+), wires a MediaRecorder to a
/// VirtualDisplay, and writes an MP4 to the path it was given. Recording is
/// finalized by an ACTION_STOP intent (the in-app button or the notification's
/// Stop action) or if the system revokes the projection. The resulting file
/// path (or null on failure) is delivered to [listener] and also cached in
/// [pendingCompletedPath] so a stop that happens while the activity is gone can
/// still be picked up when it returns.
class ScreenCaptureService : Service() {
    private var mediaProjection: MediaProjection? = null
    private var mediaRecorder: MediaRecorder? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var outputPath: String? = null
    private var recording = false
    private var stopped = false

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            // System or user revoked the projection — finalize what we have.
            stopRecording()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> handleStart(intent)
            ACTION_STOP -> stopRecording()
        }
        return START_NOT_STICKY
    }

    private fun handleStart(intent: Intent) {
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
        @Suppress("DEPRECATION")
        val data = intent.getParcelableExtra<Intent>(EXTRA_DATA)
        outputPath = intent.getStringExtra(EXTRA_OUTPUT_PATH)
        if (resultCode != Activity.RESULT_OK || data == null || outputPath == null) {
            finishWith(null)
            stopSelf()
            return
        }

        // Must be a foreground service before acquiring the projection on Q+.
        startForegroundNotification()
        try {
            val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                as MediaProjectionManager
            val projection = mpm.getMediaProjection(resultCode, data)
                ?: throw IllegalStateException("No MediaProjection")
            mediaProjection = projection
            // Android 14+ requires a registered callback before createVirtualDisplay.
            projection.registerCallback(projectionCallback, null)

            val metrics = resources.displayMetrics
            // H.264 requires even dimensions.
            val width = (metrics.widthPixels / 2) * 2
            val height = (metrics.heightPixels / 2) * 2
            val dpi = metrics.densityDpi

            val recorder = buildRecorder(width, height)
            mediaRecorder = recorder
            virtualDisplay = projection.createVirtualDisplay(
                "NoteSynapseCapture",
                width, height, dpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                recorder.surface, null, null
            )
            recorder.start()
            recording = true
        } catch (e: Exception) {
            // Setup failed — release everything and report no file.
            releaseRecorderAndProjection(stopRecorder = false)
            deleteOutputFile()
            finishWith(null)
            stopForegroundCompat()
            stopSelf()
        }
    }

    private fun buildRecorder(width: Int, height: Int): MediaRecorder {
        val recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(this)
        } else {
            @Suppress("DEPRECATION")
            MediaRecorder()
        }
        recorder.setVideoSource(MediaRecorder.VideoSource.SURFACE)
        recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        recorder.setVideoEncoder(MediaRecorder.VideoEncoder.H264)
        recorder.setVideoSize(width, height)
        recorder.setVideoFrameRate(30)
        recorder.setVideoEncodingBitRate(8 * 1024 * 1024)
        recorder.setOutputFile(outputPath)
        recorder.prepare()
        return recorder
    }

    private fun stopRecording() {
        if (stopped) return
        stopped = true
        var resultPath: String? = null
        try { virtualDisplay?.release() } catch (_: Exception) {}
        virtualDisplay = null
        if (recording) {
            try {
                mediaRecorder?.stop()
                resultPath = outputPath
            } catch (e: Exception) {
                // stop() throws if no frames were captured — no usable file.
                resultPath = null
            }
        }
        // Don't leave a zero-byte/partial file behind in cacheDir when the
        // recording produced nothing usable (stop() threw, or never started).
        if (resultPath == null) deleteOutputFile()
        releaseRecorderAndProjection(stopRecorder = false)
        finishWith(resultPath)
        stopForegroundCompat()
        stopSelf()
    }

    private fun deleteOutputFile() {
        val path = outputPath ?: return
        try {
            val f = java.io.File(path)
            if (f.exists()) f.delete()
        } catch (_: Exception) {}
    }

    private fun releaseRecorderAndProjection(stopRecorder: Boolean) {
        try {
            if (stopRecorder && recording) mediaRecorder?.stop()
        } catch (_: Exception) {}
        try { mediaRecorder?.reset() } catch (_: Exception) {}
        try { mediaRecorder?.release() } catch (_: Exception) {}
        mediaRecorder = null
        try { mediaProjection?.unregisterCallback(projectionCallback) } catch (_: Exception) {}
        try { mediaProjection?.stop() } catch (_: Exception) {}
        mediaProjection = null
        recording = false
    }

    private fun finishWith(path: String?) {
        pendingCompletedPath = path
        listener?.onScreenCaptureComplete(path)
    }

    private fun startForegroundNotification() {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Screen capture",
                    NotificationManager.IMPORTANCE_LOW
                )
            )
        }

        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val stopPending = PendingIntent.getService(
            this, 0,
            Intent(this, ScreenCaptureService::class.java).apply { action = ACTION_STOP },
            pendingFlags
        )
        val contentPending = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
            pendingFlags
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle("Recording screen")
            .setContentText("Note Synapse is capturing your screen")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .setContentIntent(contentPending)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stopPending)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    interface Listener {
        fun onScreenCaptureComplete(path: String?)
    }

    companion object {
        const val ACTION_START = "com.github.kkspeed.note_synapse.SCREEN_CAPTURE_START"
        const val ACTION_STOP = "com.github.kkspeed.note_synapse.SCREEN_CAPTURE_STOP"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_DATA = "data"
        const val EXTRA_OUTPUT_PATH = "outputPath"

        private const val CHANNEL_ID = "world_clip_screen_capture"
        private const val NOTIFICATION_ID = 8731

        /// Set by the activity to receive the finished recording path.
        @Volatile
        var listener: Listener? = null

        /// Last completed path, cached so a stop that happens while the activity
        /// is gone can still be delivered once it (and the channel) return.
        @Volatile
        var pendingCompletedPath: String? = null
    }
}
