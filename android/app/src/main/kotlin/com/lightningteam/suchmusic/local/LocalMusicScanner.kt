package com.lightningteam.suchmusic.local

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import java.io.File

/**
 * 本地音乐扫描器。
 *
 * 两条通道：
 * 1. **MediaStore**：系统已索引的音频（mp3 / flac / m4a / wav / ogg 等），
 *    只读 `READ_MEDIA_AUDIO`（Android 13+）或 `READ_EXTERNAL_STORAGE` 即可，
 *    返回 `content://` Uri，播放器可直接读取，**无需任何额外授权**。
 * 2. **文件遍历**：`.kgm / .kgma / .vpr` 不在 MediaStore 索引内，只能按目录扫描；
 *    Android 11+ 需要「所有文件访问权限」（MANAGE_EXTERNAL_STORAGE）。
 *    未授权时扫描结果只含第 1 类，并由 UI 提示可授权解锁 KGM。
 *
 * 扫描在后台线程执行，结果回到主线程；任何异常都降级为空列表 + 错误信息，
 * 绝不把异常抛给 Flutter。
 */
class LocalMusicScanner(private val context: Context) {

    companion object {
        private const val TAG = "LocalMusicScanner"
        const val CHANNEL = "com.lightningteam.suchmusic/local_music"

        /** 音频扩展名 → MediaStore 之外需要文件遍历的加密格式。 */
        private val KGM_EXTS = setOf("kgm", "kgma", "vpr", "kgg")

        /** 常规音频扩展名（用于文件遍历时过滤）。 */
        private val AUDIO_EXTS = setOf(
            "mp3", "flac", "m4a", "aac", "wav", "ogg", "opus", "wma", "ape"
        )

        /** Android 13+ 的音频读取权限。 */
        val AUDIO_PERMISSIONS: Array<String> = if (Build.VERSION.SDK_INT >= 33) {
            arrayOf(Manifest.permission.READ_MEDIA_AUDIO)
        } else {
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
    }

    fun hasAudioPermission(): Boolean = AUDIO_PERMISSIONS.all {
        context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }

    /** 是否已授予「所有文件访问权限」（决定能否扫描 .kgm）。 */
    fun hasAllFilesAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            true // Android 10 及以下用 READ_EXTERNAL_STORAGE 即可遍历
        }

    /**
     * 扫描本地音乐（阻塞调用，必须放后台线程）。
     *
     * @return `{ tracks: List<Map>, audioPermission: Boolean, allFilesAccess: Boolean }`
     */
    fun scan(): Map<String, Any?> {
        val tracks = mutableListOf<Map<String, Any?>>()
        val seen = mutableSetOf<String>()
        val audioPerm = hasAudioPermission()
        val allFiles = hasAllFilesAccess()

        if (audioPerm) {
            try {
                scanMediaStore(tracks, seen)
            } catch (e: Throwable) {
                Log.w(TAG, "MediaStore 扫描失败: ${e.message}")
            }
        }

        if (allFiles) {
            try {
                scanFolders(tracks, seen, includeAllAudio = !audioPerm)
            } catch (e: Throwable) {
                Log.w(TAG, "目录扫描失败: ${e.message}")
            }
        }

        // 按文件名自然排序，保证每次进入顺序稳定
        tracks.sortBy { (it["name"] as? String)?.lowercase() ?: "" }
        return mapOf(
            "tracks" to tracks,
            "audioPermission" to audioPerm,
            "allFilesAccess" to allFiles,
        )
    }

    // ── MediaStore ────────────────────────────────────────────────

    private fun scanMediaStore(out: MutableList<Map<String, Any?>>, seen: MutableSet<String>) {
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.SIZE,
            MediaStore.Audio.Media.DATA,
        )
        context.contentResolver.query(
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            projection,
            "${MediaStore.Audio.Media.IS_MUSIC} != 0",
            null,
            "${MediaStore.Audio.Media.DISPLAY_NAME} ASC",
        )?.use { c ->
            val idCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val nameCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
            val titleCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val artistCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val albumCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
            val durCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
            val sizeCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.SIZE)
            val dataCol = c.getColumnIndex(MediaStore.Audio.Media.DATA)

            while (c.moveToNext()) {
                val id = c.getLong(idCol)
                val display = c.getString(nameCol) ?: "未命名"
                val uri: Uri =
                    ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
                val key = uri.toString()
                if (!seen.add(key)) continue
                val ext = display.substringAfterLast('.', "").lowercase()

                // 加密格式即使被 MediaStore 收录（部分 ROM 会索引 .kgm），
                // 也不能当普通音频直接播——必须标成 kgm 并拿到真实路径走解密。
                val isKgm = ext in KGM_EXTS
                val dataPath = if (dataCol >= 0) c.getString(dataCol) else null
                out.add(
                    mapOf(
                        "uri" to key,
                        "path" to if (isKgm && !dataPath.isNullOrBlank()) dataPath else null,
                        "name" to display.substringBeforeLast('.'),
                        "title" to (c.getString(titleCol) ?: display),
                        // 占位值（<unknown> 等）交给 Dart 侧统一归一化为「未知歌手」
                        "artist" to c.getString(artistCol),
                        "album" to c.getString(albumCol),
                        "durationMs" to if (isKgm) 0L else c.getLong(durCol),
                        "size" to c.getLong(sizeCol),
                        "ext" to ext,
                        "kind" to if (isKgm) "kgm" else "media",
                    )
                )
            }
        }
    }

    // ── 目录遍历（KGM 等） ────────────────────────────────────────

    private fun scanFolders(
        out: MutableList<Map<String, Any?>>,
        seen: MutableSet<String>,
        includeAllAudio: Boolean,
    ) {
        val root = Environment.getExternalStorageDirectory() ?: return
        // 优先扫音乐/下载与常见音乐 App 目录，避免全盘遍历拖慢首屏
        val preferred = listOf(
            "Music", "Download", "Downloads", "Documents",
            "Kugou", "kgmusic", "KuGou", "网易云音乐", "CloudMusic",
        )
        val targets = mutableListOf<File>()
        for (name in preferred) {
            val dir = File(root, name)
            if (dir.isDirectory) targets.add(dir)
        }
        if (targets.isEmpty()) targets.add(root)

        var visited = 0
        for (dir in targets) {
            walk(dir, 0, out, seen, includeAllAudio) { visited++ }
            if (visited > 60000) break // 防御性上限：异常目录结构不至于卡死
        }
    }

    private fun walk(
        dir: File,
        depth: Int,
        out: MutableList<Map<String, Any?>>,
        seen: MutableSet<String>,
        includeAllAudio: Boolean,
        onVisit: () -> Unit,
    ) {
        if (depth > 6) return
        val children = try {
            dir.listFiles() ?: return
        } catch (e: Throwable) {
            return
        }
        for (f in children) {
            onVisit()
            if (f.isDirectory) {
                if (!f.name.startsWith(".")) walk(f, depth + 1, out, seen, includeAllAudio, onVisit)
                continue
            }
            // 跳过本应用的解密缓存（含半成品 .part），避免把缓存文件当成本地歌曲
            if (f.name.endsWith(".part") || f.absolutePath.contains("local_audio_cache")) continue
            val ext = f.extension.lowercase()
            val isKgm = ext in KGM_EXTS
            if (!isKgm && !(includeAllAudio && ext in AUDIO_EXTS)) continue
            val path = f.absolutePath
            if (!seen.add(path)) continue
            out.add(
                mapOf(
                    "uri" to Uri.fromFile(f).toString(),
                    "path" to path,
                    "name" to f.nameWithoutExtension,
                    "title" to f.nameWithoutExtension,
                    // 留空：由 Dart 侧从「歌手 - 歌名」文件名解析，或回落「未知歌手」
                    "artist" to "",
                    "album" to dir.name,
                    "durationMs" to 0L,
                    "size" to f.length(),
                    "ext" to ext,
                    "kind" to if (isKgm) "kgm" else "file",
                )
            )
        }
    }
}
