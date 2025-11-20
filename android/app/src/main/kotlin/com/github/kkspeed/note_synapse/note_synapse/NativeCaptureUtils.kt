package com.github.kkspeed.note_synapse.note_synapse

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.PixelCopy
import android.view.Window
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import kotlin.math.roundToInt

class NativeCaptureUtils(private val activity: Activity, private val channel: MethodChannel) {
    companion object {
        private const val TAG = "NativeCaptureUtils"
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "captureRegion" -> captureRegion(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun captureRegion(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.error("UNSUPPORTED", "PixelCopy is not supported on this device", null)
            return
        }

        val x = call.argument<Double>("x")!!
        val y = call.argument<Double>("y")!!
        val width = call.argument<Double>("width")!!
        val height = call.argument<Double>("height")!!
        val devicePixelRatio = call.argument<Double>("devicePixelRatio")!!

                val srcRect = Rect(

                    (x).roundToInt(),

                    (y).roundToInt(),

                    (x + width).roundToInt(),

                    (y + height).roundToInt()

                )

        try {
            val window: Window = activity.window
            val bitmap = Bitmap.createBitmap(srcRect.width(), srcRect.height(), Bitmap.Config.ARGB_8888)
            val listener = PixelCopy.OnPixelCopyFinishedListener { copyResult ->
                if (copyResult == PixelCopy.SUCCESS) {
                    val stream = ByteArrayOutputStream()
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                    result.success(stream.toByteArray())
                } else {
                    result.error("PIXEL_COPY_FAILED", "Failed to copy pixels", null)
                }
            }
            PixelCopy.request(window, srcRect, bitmap, listener, Handler(Looper.getMainLooper()))
        } catch (e: Exception) {
            Log.e(TAG, "Failed to capture region", e)
            result.error("CAPTURE_FAILED", "Failed to capture region", e.message)
        }
    }
}
