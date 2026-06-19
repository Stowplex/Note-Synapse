package com.github.kkspeed.note_synapse.note_synapse

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream

class MainActivity : FlutterActivity(), ScreenCaptureService.Listener {
    private val CHANNEL = "com.github.kkspeed/share"
    private val NATIVE_CAPTURE_CHANNEL = "note_synapse/native_capture"
    private val VIDEO_FRAMES_CHANNEL = "note_synapse/video_frames"
    private val SCREEN_CAPTURE_CHANNEL = "note_synapse/screen_capture"

    private val SAVE_FILE_REQUEST_CODE = 1001
    private val SCREEN_CAPTURE_REQUEST_CODE = 1002
    private var pendingResult: MethodChannel.Result? = null
    private var sourceFilePath: String? = null

    private var screenCaptureChannel: MethodChannel? = null
    private var pendingCaptureStartResult: MethodChannel.Result? = null
    private var pendingCaptureOutputPath: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSharedContent" -> {
                    val sharedData = getSharedContent()
                    result.success(sharedData)
                }
                "saveFileToExternalStorage" -> {
                    val filePath = call.argument<String>("filePath")
                    val fileName = call.argument<String>("fileName")
                    val mimeType = call.argument<String>("mimeType")

                    if (filePath != null && fileName != null && mimeType != null) {
                        saveFileToExternalStorage(filePath, fileName, mimeType, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "Missing arguments", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        val nativeCaptureChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NATIVE_CAPTURE_CHANNEL)
        NativeCaptureUtils(this, nativeCaptureChannel)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VIDEO_FRAMES_CHANNEL).setMethodCallHandler { call, result ->
            val path = call.argument<String>("path")
            if (path == null) {
                result.error("INVALID_ARGUMENTS", "Missing video path", null)
                return@setMethodCallHandler
            }
            when (call.method) {
                "getDuration" -> getVideoDuration(path, result)
                "extractFrame" -> {
                    val timeMs = call.argument<Int>("timeMs") ?: 0
                    val maxWidth = call.argument<Int>("maxWidth") ?: 0
                    extractVideoFrame(path, timeMs, maxWidth, result)
                }
                else -> result.notImplemented()
            }
        }

        val screenCapture = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, SCREEN_CAPTURE_CHANNEL)
        screenCaptureChannel = screenCapture
        ScreenCaptureService.listener = this
        screenCapture.setMethodCallHandler { call, result ->
            when (call.method) {
                // MediaProjection consent + VirtualDisplay exist from API 21;
                // the mediaProjection FGS *type* (Q+) is applied conditionally
                // in the service, so capture is supported on all minSdk targets.
                // Matches the Dart Platform.isAndroid gate (no contract drift).
                "isSupported" ->
                    result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP)
                "startCapture" -> startScreenCapture(result)
                "stopCapture" -> {
                    startService(Intent(this, ScreenCaptureService::class.java)
                        .apply { action = ScreenCaptureService.ACTION_STOP })
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        // Deliver a recording that finished while the engine was rebuilding
        // (e.g. the notification's Stop fired with the activity backgrounded).
        // Note: if the OS fully killed the process, the Dart record() completer
        // is gone and this delivery is a no-op — the recording would be lost.
        // Acceptable for now; surfacing an orphaned capture on resume is future
        // work. The common case (backgrounded, engine alive) is covered.
        ScreenCaptureService.pendingCompletedPath?.let { path ->
            screenCapture.invokeMethod("onCaptureComplete", path)
            ScreenCaptureService.pendingCompletedPath = null
        }
    }

    /// Launches the MediaProjection consent dialog. The result is wired up in
    /// onActivityResult, which starts the foreground recording service.
    private fun startScreenCapture(result: MethodChannel.Result) {
        if (pendingCaptureStartResult != null) {
            result.success(false) // a consent request is already in flight
            return
        }
        pendingCaptureStartResult = result
        pendingCaptureOutputPath =
            File(cacheDir, "screen_capture_${System.currentTimeMillis()}.mp4").absolutePath
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE)
            as MediaProjectionManager
        startActivityForResult(mpm.createScreenCaptureIntent(), SCREEN_CAPTURE_REQUEST_CODE)
    }

    override fun onScreenCaptureComplete(path: String?) {
        runOnUiThread {
            screenCaptureChannel?.invokeMethod("onCaptureComplete", path)
            ScreenCaptureService.pendingCompletedPath = null
        }
    }

    override fun onDestroy() {
        if (ScreenCaptureService.listener === this) {
            ScreenCaptureService.listener = null
        }
        super.onDestroy()
    }

    /// Reads the video duration (ms) off the main thread to avoid ANRs.
    private fun getVideoDuration(path: String, result: MethodChannel.Result) {
        Thread {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(path)
                val ms = retriever
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull() ?: 0L
                runOnUiThread { result.success(ms.toInt()) }
            } catch (e: Exception) {
                runOnUiThread { result.error("DURATION_FAILED", e.message, null) }
            } finally {
                try { retriever.release() } catch (_: Exception) {}
            }
        }.start()
    }

    /// Decodes the frame nearest [timeMs] as PNG bytes (scaled to [maxWidth] when
    /// > 0). MediaMetadataRetriever frame decode can be slow, so run off-thread.
    private fun extractVideoFrame(path: String, timeMs: Int, maxWidth: Int, result: MethodChannel.Result) {
        Thread {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(path)
                var bitmap = retriever.getFrameAtTime(
                    timeMs.toLong() * 1000L,
                    MediaMetadataRetriever.OPTION_CLOSEST
                )
                if (bitmap == null) {
                    runOnUiThread { result.success(null) }
                    return@Thread
                }
                if (maxWidth in 1 until bitmap.width) {
                    val targetHeight = (bitmap.height.toLong() * maxWidth / bitmap.width)
                        .toInt().coerceAtLeast(1)
                    bitmap = Bitmap.createScaledBitmap(bitmap, maxWidth, targetHeight, true)
                }
                val stream = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                val bytes = stream.toByteArray()
                runOnUiThread { result.success(bytes) }
            } catch (e: Exception) {
                runOnUiThread { result.error("FRAME_FAILED", e.message, null) }
            } finally {
                try { retriever.release() } catch (_: Exception) {}
            }
        }.start()
    }

    private fun saveFileToExternalStorage(filePath: String, fileName: String, mimeType: String, result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("OPERATION_IN_PROGRESS", "Another operation is in progress", null)
            return
        }

        sourceFilePath = filePath
        pendingResult = result

        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        startActivityForResult(intent, SAVE_FILE_REQUEST_CODE)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == SCREEN_CAPTURE_REQUEST_CODE) {
            val startResult = pendingCaptureStartResult
            val outputPath = pendingCaptureOutputPath
            pendingCaptureStartResult = null
            pendingCaptureOutputPath = null
            if (resultCode == RESULT_OK && data != null && outputPath != null) {
                val svc = Intent(this, ScreenCaptureService::class.java).apply {
                    action = ScreenCaptureService.ACTION_START
                    putExtra(ScreenCaptureService.EXTRA_RESULT_CODE, resultCode)
                    putExtra(ScreenCaptureService.EXTRA_DATA, data)
                    putExtra(ScreenCaptureService.EXTRA_OUTPUT_PATH, outputPath)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(svc)
                } else {
                    startService(svc)
                }
                startResult?.success(true)
            } else {
                startResult?.success(false) // user denied / cancelled consent
            }
            return
        }

        if (requestCode == SAVE_FILE_REQUEST_CODE) {
            if (resultCode == RESULT_OK && data?.data != null) {
                val uri = data.data
                val sourcePath = sourceFilePath
                
                if (uri != null && sourcePath != null) {
                    try {
                        contentResolver.openOutputStream(uri)?.use { outputStream ->
                            File(sourcePath).inputStream().use { inputStream ->
                                inputStream.copyTo(outputStream)
                            }
                        }
                        pendingResult?.success(true)
                    } catch (e: Exception) {
                        e.printStackTrace()
                        pendingResult?.error("SAVE_FAILED", "Failed to save file: ${e.message}", null)
                    }
                } else {
                    pendingResult?.error("SAVE_FAILED", "Invalid URI or source path", null)
                }
            } else {
                pendingResult?.error("CANCELLED", "User cancelled operation", null)
            }
            pendingResult = null
            sourceFilePath = null
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return

        when (intent.action) {
            Intent.ACTION_SEND -> {
                handleSendIntent(intent)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                handleSendMultipleIntent(intent)
            }
        }
    }

    private fun handleSendIntent(intent: Intent) {
        val type = intent.type
        val sharedData = mutableMapOf<String, Any>()

        when {
            type?.startsWith("text/") == true -> {
                val sharedText = intent.getStringExtra(Intent.EXTRA_TEXT)
                if (sharedText != null) {
                    sharedData["action"] = "SEND"
                    sharedData["type"] = "text/plain"
                    sharedData["text"] = sharedText
                    
                    // Check if the shared text is a URL
                    val url = extractUrl(sharedText)
                    if (url != null) {
                        sharedData["contentType"] = "url"
                        sharedData["url"] = url
                    }
                }
            }
            type?.startsWith("image/") == true -> {
                val imageUri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (imageUri != null) {
                    val filePath = copyUriToFile(imageUri, "shared_image")
                    if (filePath != null) {
                        sharedData["action"] = "SEND"
                        sharedData["type"] = type ?: "image/*"
                        sharedData["filePath"] = filePath
                        sharedData["fileName"] = getFileName(imageUri) ?: "unknown"
                    }
                }
            }
            type == "application/pdf" -> {
                val pdfUri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (pdfUri != null) {
                    val filePath = copyUriToFile(pdfUri, "shared_pdf")
                    if (filePath != null) {
                        sharedData["action"] = "SEND"
                        sharedData["type"] = type ?: "application/pdf"
                        sharedData["filePath"] = filePath
                        sharedData["fileName"] = getFileName(pdfUri) ?: "unknown"
                    }
                }
            }
        }

        if (sharedData.isNotEmpty()) {
            // Store the shared data to be retrieved by Flutter
            storeSharedData(sharedData)
        }
    }

    private fun handleSendMultipleIntent(intent: Intent) {
        val uris = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
        if (uris != null && uris.isNotEmpty()) {
            val sharedData = mutableMapOf<String, Any>()
            sharedData["action"] = "SEND_MULTIPLE"
            sharedData["type"] = "multiple"
            
            val files = mutableListOf<Map<String, String>>()
            for (uri in uris) {
                val fileName = getFileName(uri)
                val filePath = copyUriToFile(uri, "shared_${System.currentTimeMillis()}")
                if (filePath != null) {
                    files.add(mapOf(
                        "filePath" to filePath,
                        "fileName" to (fileName ?: "unknown"),
                        "type" to (contentResolver.getType(uri) ?: "unknown")
                    ))
                }
            }
            sharedData["files"] = files
            storeSharedData(sharedData)
        }
    }

    private fun copyUriToFile(uri: Uri, prefix: String): String? {
        return try {
            val inputStream: InputStream? = contentResolver.openInputStream(uri)
            if (inputStream != null) {
                val originalFileName = getFileName(uri) ?: "$prefix.${getFileExtension(uri)}"
                val uniqueFileName = generateUniqueFileName(originalFileName)
                
                // Create attachments directory if it doesn't exist
                val attachmentsDir = File(filesDir, "attachments")
                if (!attachmentsDir.exists()) {
                    attachmentsDir.mkdirs()
                }
                
                val file = File(attachmentsDir, uniqueFileName)
                val outputStream = FileOutputStream(file)
                
                inputStream.copyTo(outputStream)
                inputStream.close()
                outputStream.close()
                
                // Return absolute path to the copied file
                file.absolutePath
            } else {
                null
            }
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }

    private fun getFileName(uri: Uri): String? {
        return try {
            val cursor = contentResolver.query(uri, null, null, null, null)
            cursor?.use {
                if (it.moveToFirst()) {
                    val nameIndex = it.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    if (nameIndex >= 0) {
                        it.getString(nameIndex)
                    } else null
                } else null
            }
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }

    private fun getFileExtension(uri: Uri): String {
        val mimeType = contentResolver.getType(uri)
        return when (mimeType) {
            "image/jpeg" -> "jpg"
            "image/png" -> "png"
            "image/gif" -> "gif"
            "application/pdf" -> "pdf"
            "text/plain" -> "txt"
            else -> "bin"
        }
    }

    private fun generateUniqueFileName(originalFileName: String): String {
        val uuid = java.util.UUID.randomUUID().toString()
        val fileExtension = if (originalFileName.contains(".")) {
            ".${originalFileName.substring(originalFileName.lastIndexOf(".") + 1)}"
        } else {
            ""
        }
        val baseFileName = if (originalFileName.contains(".")) {
            originalFileName.substring(0, originalFileName.lastIndexOf("."))
        } else {
            originalFileName
        }
        return "${baseFileName}_${uuid}${fileExtension}"
    }

    private fun storeSharedData(data: Map<String, Any>) {
        // Store in shared preferences or a simple way to pass to Flutter
        // For now, we'll use a static variable (in production, use SharedPreferences)
        SharedDataHolder.sharedData = data
    }

    private fun getSharedContent(): Map<String, Any>? {
        val data = SharedDataHolder.sharedData
        SharedDataHolder.sharedData = null // Clear after retrieval
        return data
    }

    private fun extractUrl(text: String): String? {
        val trimmedText = text.trim()
        val uriPattern = Regex("^https?://[^\\s]+\$")
        
        if (uriPattern.matches(trimmedText)) {
            try {
                val uri = Uri.parse(trimmedText)
                if (uri.scheme == "http" || uri.scheme == "https") {
                    return trimmedText
                }
            } catch (e: Exception) {
                // Invalid URI
            }
        }
        
        return null
    }

    companion object {
        class SharedDataHolder {
            companion object {
                var sharedData: Map<String, Any>? = null
            }
        }
    }
}
