package com.huaweiobs.core;

import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.provider.OpenableColumns;
import android.webkit.MimeTypeMap;
import android.util.Log;
import com.huaweiobs.utils.OBSException;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.channels.FileChannel;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.locks.ReadWriteLock;
import java.util.concurrent.locks.ReentrantReadWriteLock;
import java.util.function.BooleanSupplier;

/**
 * 文件流管理器
 */
class FileStream {
    public final String streamId;
    public final File file;
    public final FileInputStream inputStream;
    public final long fileSize;
    public final String mimeType;
    public long position;

    public FileStream(String streamId, File file, FileInputStream inputStream, long fileSize, String mimeType) {
        this.streamId = streamId;
        this.file = file;
        this.inputStream = inputStream;
        this.fileSize = fileSize;
        this.mimeType = mimeType;
        this.position = 0L;
    }
}

/**
 * 文件流管理器
 * 负责打开、读取、关闭文件流
 */
public class FileStreamManager {
    private static final String TAG = "FileStreamManager";
    private static final long COPY_PROGRESS_INTERVAL = 10 * 1024 * 1024L; // 10MB

    /** 回调接口，用于报告 content:// URI 文件复制进度 */
    public interface CopyProgressCallback {
        void onCopyProgress(long copiedBytes, long totalBytes);
    }

    private final ConcurrentHashMap<String, FileStream> streams = new ConcurrentHashMap<>();
    private final ReadWriteLock lock = new ReentrantReadWriteLock();
    // 记录为 content:// URI 创建的临时文件，关闭流时自动删除
    private final ConcurrentHashMap<String, File> tempFiles = new ConcurrentHashMap<>();
    private final Context context;

    public FileStreamManager(Context context) {
        this.context = context;
    }

    /**
     * 打开文件流（不带复制进度回调）
     */
    public FileStreamInfo openFileStream(String filePath) throws OBSException {
        return openFileStream(filePath, null, null);
    }

    /**
     * 打开文件流，并在 content:// URI 文件复制阶段报告进度
     */
    public FileStreamInfo openFileStream(String filePath, CopyProgressCallback copyProgressCallback) throws OBSException {
        return openFileStream(filePath, copyProgressCallback, null);
    }

    /**
     * 打开文件流，带复制进度回调和取消检查
     * @param isCancelled 每 64KB 调用一次，返回 true 时中止复制
     */
    public FileStreamInfo openFileStream(String filePath, CopyProgressCallback copyProgressCallback, BooleanSupplier isCancelled) throws OBSException {
        String streamId = UUID.randomUUID().toString();
        Log.i(TAG, "[Open] filePath=" + filePath + "  streamId=" + streamId);
        String path = normalizeFilePath(filePath, streamId, copyProgressCallback, isCancelled);
        File file = new File(path);

        // 校验文件
        if (!file.exists()) {
            throw new OBSException("E_FILE_NOT_FOUND", "File not found: " + filePath, null);
        }
        if (!file.canRead()) {
            throw new OBSException("E_FILE_NOT_READABLE", "File not readable: " + filePath, null);
        }
        if (!file.isFile()) {
            throw new OBSException("E_INVALID_ARGUMENT", "Path is not a file: " + filePath, null);
        }

        FileInputStream inputStream;
        try {
            inputStream = new FileInputStream(file);
        } catch (IOException e) {
            throw new OBSException("E_FILE_OPEN_ERROR", "Failed to open file: " + e.getMessage(), e);
        }

        String mimeType = getMimeType(file.getName());
        Log.i(TAG, "[Open] resolved=" + file.getAbsolutePath()
                + "  size=" + file.length() + " bytes"
                + "  mimeType=" + mimeType);

        FileStream fileStream = new FileStream(streamId, file, inputStream, file.length(), mimeType);

        lock.writeLock().lock();
        try {
            streams.put(streamId, fileStream);
        } finally {
            lock.writeLock().unlock();
        }

        return new FileStreamInfo(streamId, file.length(), file.getName(), mimeType, file.lastModified(), file.getAbsolutePath());
    }

    /**
     * 读取分片数据
     */
    public byte[] readChunk(String streamId, long offset, int chunkSize) throws OBSException {
        lock.readLock().lock();
        FileStream stream;
        try {
            stream = streams.get(streamId);
            if (stream == null) {
                throw new OBSException("E_STREAM_NOT_FOUND", "Stream not found: " + streamId, null);
            }
        } finally {
            lock.readLock().unlock();
        }

        // 校验偏移
        if (offset < 0 || offset > stream.fileSize) {
            throw new OBSException(
                "E_INVALID_OFFSET",
                "Invalid offset: " + offset + " (file size: " + stream.fileSize + ")",
                null
            );
        }

        // 计算实际读取大小
        int actualSize = (int) Math.min(chunkSize, stream.fileSize - offset);
        if (actualSize <= 0) {
            throw new OBSException("E_READ_ERROR", "No data to read at offset " + offset, null);
        }

        try {
            synchronized (stream) {
                // 如果偏移与当前位置不匹配，重新定位
                if (offset != stream.position) {
                    FileChannel channel = stream.inputStream.getChannel();
                    channel.position(offset);
                    stream.position = offset;
                }

                byte[] buffer = new byte[actualSize];
                int totalRead = 0;

                while (totalRead < actualSize) {
                    int bytesRead = stream.inputStream.read(buffer, totalRead, actualSize - totalRead);
                    if (bytesRead == -1) {
                        break;
                    }
                    totalRead += bytesRead;
                }

                stream.position += totalRead;

                if (totalRead == 0 && actualSize > 0) {
                    throw new OBSException("E_READ_ERROR", "Failed to read data from stream", null);
                }

                if (totalRead < actualSize) {
                    byte[] result = new byte[totalRead];
                    System.arraycopy(buffer, 0, result, 0, totalRead);
                    return result;
                }

                return buffer;
            }
        } catch (OBSException e) {
            throw e;
        } catch (Exception e) {
            throw new OBSException("E_READ_ERROR", "Failed to read chunk: " + e.getMessage(), e);
        }
    }

    /**
     * 获取文件大小
     */
    public long getFileSize(String streamId) throws OBSException {
        lock.readLock().lock();
        try {
            FileStream stream = streams.get(streamId);
            if (stream == null) {
                throw new OBSException("E_STREAM_NOT_FOUND", "Stream not found: " + streamId, null);
            }
            return stream.fileSize;
        } finally {
            lock.readLock().unlock();
        }
    }

    /**
     * 关闭流
     */
    public void closeStream(String streamId) {
        Log.d(TAG, "[Close] streamId=" + streamId);
        lock.writeLock().lock();
        try {
            FileStream stream = streams.remove(streamId);
            if (stream != null) {
                try {
                    stream.inputStream.close();
                } catch (IOException e) {
                    // 忽略关闭错误
                }
            }
        } finally {
            lock.writeLock().unlock();
        }
        // 删除 content:// URI 对应的临时文件
        File temp = tempFiles.remove(streamId);
        if (temp != null && temp.exists()) {
            //noinspection ResultOfMethodCallIgnored
            boolean deleted = temp.delete();
            Log.d(TAG, "[Close] temp file deleted=" + deleted + "  path=" + temp.getAbsolutePath());
        }
    }

    /**
     * 关闭所有流
     */
    public void closeAllStreams() {
        Log.i(TAG, "[CloseAll] closing " + streams.size() + " stream(s)");
        lock.writeLock().lock();
        try {
            for (FileStream stream : streams.values()) {
                try {
                    stream.inputStream.close();
                } catch (IOException e) {
                    // 忽略关闭错误
                }
            }
            streams.clear();
        } finally {
            lock.writeLock().unlock();
        }
        // 删除所有临时文件
        for (File temp : tempFiles.values()) {
            if (temp.exists()) {
                //noinspection ResultOfMethodCallIgnored
                temp.delete();
            }
        }
        tempFiles.clear();
    }

    /**
     * 规范化文件路径：将 file:// / content:// URI 转换为绝对路径
     * content:// URI 会通过 ContentResolver 复制为临时文件，streamId 用于事后清理
     */
    private String normalizeFilePath(String filePath) throws OBSException {
        return normalizeFilePath(filePath, null, null, null);
    }

    private String normalizeFilePath(String filePath, String streamId) throws OBSException {
        return normalizeFilePath(filePath, streamId, null, null);
    }

    private String normalizeFilePath(String filePath, String streamId, CopyProgressCallback callback, BooleanSupplier isCancelled) throws OBSException {
        if (filePath.startsWith("file://")) {
            try {
                // 兼容 URL 编码（如空格编码为 %20）
                return java.net.URLDecoder.decode(filePath.substring(7), "UTF-8");
            } catch (java.io.UnsupportedEncodingException e) {
                return filePath.substring(7);
            }
        } else if (filePath.startsWith("content://")) {
            // 通过 ContentResolver 将 content URI 数据复制到应用缓存目录
            Log.i(TAG, "[Normalize] content:// URI detected, copying to temp file");
            Uri uri = Uri.parse(filePath);
            String fileName = resolveContentUriFileName(uri);
            // 提前查询文件总大小，用于进度计算
            long totalSize = resolveContentUriSize(uri);
            Log.i(TAG, "[Normalize] content URI totalSize=" + totalSize + " bytes");
            File tempDir = new File(context.getCacheDir(), "obs_upload_tmp");
            //noinspection ResultOfMethodCallIgnored
            tempDir.mkdirs();
            File tempFile = new File(tempDir, UUID.randomUUID().toString() + "_" + fileName);
            Log.d(TAG, "[Normalize] tempFile=" + tempFile.getAbsolutePath());
            long copyBytes = 0;
            long lastCallbackBytes = 0;
            try (
                InputStream in = context.getContentResolver().openInputStream(uri);
                FileOutputStream out = new FileOutputStream(tempFile)
            ) {
                if (in == null) {
                    throw new OBSException("E_FILE_NOT_FOUND",
                        "Cannot open content URI: " + filePath, null);
                }
                byte[] buf = new byte[65536]; // 64KB buffer for faster copy
                int len;
                while ((len = in.read(buf)) != -1) {
                    // 协作式取消检查（不使用线程中断，避免破坏 OBS SDK 连接池）
                    if (isCancelled != null && isCancelled.getAsBoolean()) {
                        throw new OBSException("E_CANCELLED", "Upload cancelled during file copy", null);
                    }
                    out.write(buf, 0, len);
                    copyBytes += len;
                    // 每 10MB 汇报一次复制进度
                    if (callback != null && totalSize > 0
                            && (copyBytes - lastCallbackBytes >= COPY_PROGRESS_INTERVAL)) {
                        callback.onCopyProgress(copyBytes, totalSize);
                        lastCallbackBytes = copyBytes;
                    }
                }
            } catch (OBSException e) {
                tempFile.delete();
                throw e;
            } catch (Exception e) {
                tempFile.delete();
                throw new OBSException("E_FILE_OPEN_ERROR",
                    "Failed to read content URI: " + e.getMessage(), e);
            }
            // 最终进度（100%）
            if (callback != null) {
                callback.onCopyProgress(copyBytes, Math.max(copyBytes, totalSize));
            }
            Log.i(TAG, "[Normalize] content:// copy done, bytes=" + copyBytes);
            if (streamId != null) {
                tempFiles.put(streamId, tempFile);
            }
            return tempFile.getAbsolutePath();
        } else {
            return filePath;
        }
    }

    /** 查询 content:// URI 声明的文件大小 */
    private long resolveContentUriSize(Uri uri) {
        try (Cursor cursor = context.getContentResolver()
                .query(uri, new String[]{OpenableColumns.SIZE}, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                int idx = cursor.getColumnIndex(OpenableColumns.SIZE);
                if (idx >= 0) return cursor.getLong(idx);
            }
        } catch (Exception ignored) {}
        return 0;
    }

    /**
     * 从 content:// URI 查询文件名
     */
    private String resolveContentUriFileName(Uri uri) {
        String result = null;
        try (Cursor cursor = context.getContentResolver()
                .query(uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                int idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (idx >= 0) result = cursor.getString(idx);
            }
        } catch (Exception ignored) {}
        if (result == null) {
            String path = uri.getPath();
            result = (path != null && path.contains("/"))
                ? path.substring(path.lastIndexOf('/') + 1)
                : "upload_file";
        }
        return result;
    }

    /**
     * 获取文件 MIME 类型
     */
    private String getMimeType(String fileName) {
        String extension = "";
        int lastDot = fileName.lastIndexOf('.');
        if (lastDot > 0 && lastDot < fileName.length() - 1) {
            extension = fileName.substring(lastDot + 1).toLowerCase();
        }

        String mimeType = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension);
        return mimeType != null ? mimeType : "application/octet-stream";
    }
}
