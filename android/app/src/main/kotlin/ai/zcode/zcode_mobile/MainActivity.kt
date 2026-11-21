package ai.zcode.zcode_mobile

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Native side of the "real files on the phone" story.
 *
 * The app is a sideloaded developer tool, so it asks for All-files access
 * (Android 11+) or legacy storage permission (10 and below) and then works on
 * the user's own folders with plain java.io — no SAF document ids, which means
 * `dart:io` and the shell see exactly the same paths. That is what makes
 * `git`, `npm` and shell scripts behave like they do on a desktop.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "ai.zcode/device"
    private val storageRequest = 4711

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "info" -> result.success(info())
                        "hasStorageAccess" -> result.success(hasStorageAccess())
                        "requestStorageAccess" -> result.success(requestStorageAccess())
                        "volumes" -> result.success(volumes())
                        "freeSpace" -> result.success(
                            freeSpace(call.argument<String>("path") ?: "")
                        )
                        "openPath" -> result.success(
                            openPath(call.argument<String>("path") ?: "")
                        )
                        "termuxInstalled" -> result.success(termuxInstalled())
                        "termuxRun" -> result.success(
                            termuxRun(
                                call.argument<String>("command") ?: "",
                                call.argument<String>("cwd") ?: "",
                                call.argument<String>("outFile") ?: "",
                                call.argument<String>("exitFile") ?: ""
                            )
                        )
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("device_error", e.message ?: e.toString(), null)
                }
            }
    }

    // ------------------------------------------------------------- capability

    private fun info(): Map<String, Any> {
        val map = HashMap<String, Any>()
        map["platform"] = "android"
        map["sdk"] = Build.VERSION.SDK_INT
        map["model"] = "${Build.MANUFACTURER} ${Build.MODEL}"
        map["abis"] = Build.SUPPORTED_ABIS.joinToString(",")
        map["appData"] = filesDir.absolutePath
        map["home"] = Environment.getExternalStorageDirectory().absolutePath
        map["storageAccess"] = hasStorageAccess()
        map["termux"] = termuxInstalled()
        return map
    }

    /** True when the app may read/write arbitrary user folders. */
    private fun hasStorageAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    /**
     * Android 11+ has no runtime dialog for All-files access, only a settings
     * screen. The Dart side re-checks on resume instead of waiting here.
     */
    private fun requestStorageAccess(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            if (Environment.isExternalStorageManager()) return true
            val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
            intent.data = Uri.parse("package:$packageName")
            return try {
                startActivity(intent)
                true
            } catch (e: Exception) {
                try {
                    startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                    true
                } catch (e2: Exception) {
                    false
                }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            requestPermissions(
                arrayOf(
                    Manifest.permission.READ_EXTERNAL_STORAGE,
                    Manifest.permission.WRITE_EXTERNAL_STORAGE
                ),
                storageRequest
            )
            return true
        }
        return true
    }

    // ----------------------------------------------------------------- volumes

    private fun volumes(): List<Map<String, Any>> {
        val out = ArrayList<Map<String, Any>>()
        val primary = Environment.getExternalStorageDirectory()
        out.add(volume(primary, "内部存储", false))
        // Removable cards live next to "emulated" under /storage.
        val storage = File("/storage")
        val dirs = storage.listFiles() ?: emptyArray()
        for (d in dirs) {
            val name = d.name
            if (name == "emulated" || name == "self" || name == "enc_emulated") continue
            if (!d.isDirectory || !d.canRead()) continue
            val marker = File(d, "Android")
            if (!marker.exists() && !File(d, "LOST.DIR").exists()) continue
            out.add(volume(d, if (d.canWrite()) "SD 卡 · $name" else "存储 · $name", true))
        }
        return out
    }

    private fun volume(dir: File, label: String, removable: Boolean): Map<String, Any> {
        val map = HashMap<String, Any>()
        map["path"] = dir.absolutePath
        map["label"] = label
        map["removable"] = removable
        map["free"] = freeSpace(dir.absolutePath)
        return map
    }

    private fun freeSpace(path: String): Long {
        return try {
            val stat = StatFs(if (path.isEmpty()) filesDir.absolutePath else path)
            stat.availableBytes
        } catch (e: Exception) {
            0L
        }
    }

    /** Hands a file or folder to whatever app can display it. */
    private fun openPath(path: String): Boolean {
        if (path.isEmpty()) return false
        val file = File(path)
        if (!file.exists()) return false
        return try {
            // Always hand out a content:// uri: file:// would throw on 7+.
            val uri: Uri = FileProvider.getUriForFile(this, "$packageName.files", file)
            val intent = Intent(Intent.ACTION_VIEW)
            intent.setDataAndType(uri, if (file.isDirectory) "resource/folder" else "*/*")
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (e: Exception) {
            // No viewer installed: fall back to a chooser-free "open with" shot.
            try {
                val intent = Intent(Intent.ACTION_VIEW)
                intent.setDataAndType(Uri.fromFile(file), "*/*")
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(Intent.createChooser(intent, "打开"))
                true
            } catch (e2: Exception) {
                false
            }
        }
    }

    // ------------------------------------------------------------------ termux

    private fun termuxInstalled(): Boolean {
        return try {
            packageManager.getPackageInfo("com.termux", 0)
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Termux is the only realistic way to run node/python/git on an unrooted
     * phone: Android 10+ forbids exec from app-writable storage, but Termux
     * owns a proper prefix. We hand it a background command that writes its
     * output next to the workspace, and Dart polls for the exit marker.
     */
    private fun termuxRun(command: String, cwd: String, outFile: String, exitFile: String): Boolean {
        if (command.isEmpty() || outFile.isEmpty() || exitFile.isEmpty()) return false
        val workdir = if (cwd.isEmpty()) Environment.getExternalStorageDirectory().absolutePath else cwd
        val script = "cd ${quote(workdir)} 2>/dev/null; " +
            "{ $command ; } > ${quote(outFile)} 2>&1; " +
            "echo \$? > ${quote(exitFile)}"
        return try {
            val intent = Intent()
            intent.setClassName("com.termux", "com.termux.app.RunCommandService")
            intent.action = "com.termux.RUN_COMMAND"
            intent.putExtra(
                "com.termux.RUN_COMMAND_PATH",
                "/data/data/com.termux/files/usr/bin/bash"
            )
            intent.putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayOf("-c", script))
            intent.putExtra("com.termux.RUN_COMMAND_WORKDIR", workdir)
            intent.putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
            intent.putExtra("com.termux.RUN_COMMAND_SESSION_ACTION", "0")
            startService(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun quote(s: String): String = "'" + s.replace("'", "'\\''") + "'"
}
