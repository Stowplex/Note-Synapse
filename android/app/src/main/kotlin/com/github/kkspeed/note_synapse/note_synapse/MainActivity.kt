package com.github.kkspeed.note_synapse.note_synapse

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream

class MainActivity : FlutterActivity() {
    private val CHANNEL = "note_synapse/share"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSharedContent" -> {
                    val sharedData = getSharedContent()
                    result.success(sharedData)
                }
                else -> result.notImplemented()
            }
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
                val fileName = getFileName(uri) ?: "$prefix.${getFileExtension(uri)}"
                val file = File(filesDir, fileName)
                val outputStream = FileOutputStream(file)
                
                inputStream.copyTo(outputStream)
                inputStream.close()
                outputStream.close()
                
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

    companion object {
        class SharedDataHolder {
            companion object {
                var sharedData: Map<String, Any>? = null
            }
        }
    }
}
