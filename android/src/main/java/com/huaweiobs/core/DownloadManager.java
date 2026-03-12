package com.huaweiobs.core;

import android.util.Log;

import com.huaweiobs.utils.EventEmitter;
import com.huaweiobs.utils.ErrorMapper;
import com.huaweiobs.utils.OBSException;
import com.obs.services.model.GetObjectRequest;
import com.obs.services.model.ObsObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Download Manager
 * Manages file download operations
 */
public class DownloadManager {
    private static final String TAG ="DownloadManager";
    private static final int BUFFER_SIZE = 8192;
    private static final long PROGRESS_UPDATE_INTERVAL = 100L; // ms

    private final ObsClientHolder obsClientHolder;
    private final EventEmitter eventEmitter;
    private final ConcurrentHashMap<String, DownloadTaskState> tasks = new ConcurrentHashMap<>();
    private final ExecutorService executorService;

    /**
     * Download parameters
     */
    public static class DownloadParams {
        public final String taskId;
        public final String objectKey;
        public final String bucket;
        public final String savePath;
        public final String range;
        public final String versionId;
        public final long startTimeMs;

        public DownloadParams(String taskId, String objectKey, String bucket, String savePath,
                              String range, String versionId) {
            this.taskId = taskId;
            this.objectKey = objectKey;
            this.bucket = bucket;
            this.savePath = savePath;
            this.range = range;
            this.versionId = versionId;
            this.startTimeMs = System.currentTimeMillis();
        }
    }

    /**
     * Download result
     */
    public static class DownloadResult {
        public final String taskId;
        public final String objectKey;
        public final String savePath;
        public final long size;
        public final String etag;
        public final long duration;
        public final double avgSpeed;

        public DownloadResult(String taskId, String objectKey, String savePath,
                              long size, String etag, long duration, double avgSpeed) {
            this.taskId = taskId;
            this.objectKey = objectKey;
            this.savePath = savePath;
            this.size = size;
            this.etag = etag;
            this.duration = duration;
            this.avgSpeed = avgSpeed;
        }
    }

    /**
     * Download task state
     */
    private static class DownloadTaskState {
        final String taskId;
        final DownloadParams params;
        String status = "PENDING";
        final AtomicLong downloadedBytes = new AtomicLong(0);
        long totalBytes = 0;
        String etag = "";
        Future<?> future;
        OBSException error;

        DownloadTaskState(String taskId, DownloadParams params) {
            this.taskId = taskId;
            this.params = params;
        }
    }

    public DownloadManager(ObsClientHolder obsClientHolder, EventEmitter eventEmitter) {
        this.obsClientHolder = obsClientHolder;
        this.eventEmitter = eventEmitter;
        this.executorService = Executors.newCachedThreadPool();
    }

    /**
     * Start download
     */
    public String startDownload(DownloadParams params) {
        Log.i(TAG, "[StartDownload] taskId=" + params.taskId + "  objectKey=" + params.objectKey + "  savePath=" + params.savePath);
        DownloadTaskState taskState = new DownloadTaskState(params.taskId, params);
        tasks.put(params.taskId, taskState);

        // Execute download in background
        taskState.future = executorService.submit(() -> {
            try {
                executeDownload(taskState);
            } catch (Exception e) {
                handleDownloadError(taskState, e);
            }
        });

        return params.taskId;
    }

    /**
     * Execute download flow
     */
    private void executeDownload(DownloadTaskState taskState) throws Exception {
        DownloadParams params = taskState.params;

        try {
            // Check credentials expiry
            if (obsClientHolder.isCredentialsExpired()) {
                throw new OBSException("E_AUTH_EXPIRED", "Credentials expired");
            }

            // Create save directory
            File saveFile = new File(params.savePath);
            File parentDir = saveFile.getParentFile();
            if (parentDir != null) {
                parentDir.mkdirs();
            }

            if (saveFile.exists()) {
                saveFile.delete();
            }

            // Send downloadStart event
            taskState.status = "DOWNLOADING";
            Map<String, Object> startEvent = new HashMap<>();
            startEvent.put("taskId", params.taskId);
            startEvent.put("objectKey", params.objectKey);
            eventEmitter.emit("downloadStart", startEvent);

            // Create download request
            GetObjectRequest request = new GetObjectRequest(params.bucket, params.objectKey);
            if (params.range != null) {
                try {
                    // Parse range header format: "bytes=START-END"
                    String rangeValue = params.range.replaceFirst("^bytes=", "").trim();
                    String[] parts = rangeValue.split("-", 2);
                    if (parts.length >= 1 && !parts[0].isEmpty()) {
                        request.setRangeStart(Long.parseLong(parts[0].trim()));
                    }
                    if (parts.length >= 2 && !parts[1].isEmpty()) {
                        request.setRangeEnd(Long.parseLong(parts[1].trim()));
                    }
                } catch (NumberFormatException e) {
                    Log.w(TAG, "[Download] invalid range format: " + params.range + ", ignoring");
                }
            }
            if (params.versionId != null) {
                request.setVersionId(params.versionId);
            }

            // Execute download
            Log.d(TAG, "[Download] sending GetObject request: bucket=" + params.bucket + "  key=" + params.objectKey);
            ObsObject obsObject = obsClientHolder.getClient().getObject(request);
            taskState.totalBytes = obsObject.getMetadata().getContentLength();
            taskState.etag = obsObject.getMetadata().getEtag() != null ?
                    obsObject.getMetadata().getEtag() : "";
            Log.i(TAG, "[Download] object size=" + taskState.totalBytes + " bytes  etag=" + taskState.etag);

            // Stream to file
            InputStream inputStream = obsObject.getObjectContent();
            FileOutputStream outputStream = new FileOutputStream(saveFile);

            try {
                byte[] buffer = new byte[BUFFER_SIZE];
                long lastProgressTime = System.currentTimeMillis();
                int bytesRead;

                while ((bytesRead = inputStream.read(buffer)) != -1) {
                    outputStream.write(buffer, 0, bytesRead);
                    long downloaded = taskState.downloadedBytes.addAndGet(bytesRead);

                    // Send progress event (with throttling)
                    long now = System.currentTimeMillis();
                    if (now - lastProgressTime >= PROGRESS_UPDATE_INTERVAL) {
                        emitDownloadProgress(taskState, downloaded, false);
                        lastProgressTime = now;
                    }
                }

                outputStream.flush();

                // Send final 100% progress
                emitDownloadProgress(taskState, taskState.downloadedBytes.get(), true);

            } finally {
                try {
                    inputStream.close();
                } catch (Exception e) {
                    // Ignore close errors
                }
                try {
                    outputStream.close();
                } catch (Exception e) {
                    // Ignore close errors
                }
            }

            // Download complete
            long duration = System.currentTimeMillis() - params.startTimeMs;
            double avgSpeed = duration > 0 ? Math.round(taskState.totalBytes * 1000.0 / duration * 100.0) / 100.0 : 0.0;

            DownloadResult result = new DownloadResult(
                    params.taskId,
                    params.objectKey,
                    params.savePath,
                    taskState.totalBytes,
                    taskState.etag,
                    duration,
                    avgSpeed
            );

            taskState.status = "COMPLETED";

            // Send success event
            Map<String, Object> successEvent = new HashMap<>();
            successEvent.put("taskId", params.taskId);
            successEvent.put("objectKey", result.objectKey);
            successEvent.put("savePath", result.savePath);
            successEvent.put("size", result.size);
            successEvent.put("etag", result.etag);
            successEvent.put("duration", result.duration);
            successEvent.put("avgSpeed", result.avgSpeed);
            eventEmitter.emit("downloadSuccess", successEvent);

            // Clear throttle record
            eventEmitter.clearThrottle(params.taskId);

            Log.i(TAG, "[Download] completed: objectKey=" + params.objectKey
                    + "  size=" + taskState.totalBytes + " bytes"
                    + "  duration=" + duration + "ms"
                    + "  speed=" + String.format("%.1f", avgSpeed / 1024) + " KB/s");

        } catch (Exception e) {
            throw ErrorMapper.mapException(e);
        }
    }

    /**
     * Emit download progress
     */
    private void emitDownloadProgress(DownloadTaskState taskState, long downloaded, boolean force) {
        int percentage = taskState.totalBytes > 0 ?
                (int)(downloaded * 100 / taskState.totalBytes) : 0;

        Map<String, Object> progressEvent = new HashMap<>();
        progressEvent.put("taskId", taskState.taskId);
        progressEvent.put("downloadedBytes", downloaded);
        progressEvent.put("totalBytes", taskState.totalBytes);
        progressEvent.put("percentage", percentage);

        eventEmitter.emitProgress(taskState.taskId, "downloadProgress", progressEvent, force);
    }

    /**
     * Handle download error
     */
    private void handleDownloadError(DownloadTaskState taskState, Throwable error) {
        OBSException obsError = ErrorMapper.mapException(error);
        taskState.error = obsError;
        taskState.status = "FAILED";
        Log.e(TAG, "[Download] failed: taskId=" + taskState.taskId + "  error=" + obsError.getMessage());

        // Send error event
        Map<String, Object> errorEvent = new HashMap<>();
        errorEvent.put("taskId", taskState.taskId);
        errorEvent.put("code", obsError.getCode());
        errorEvent.put("message", obsError.getMessage());
        errorEvent.put("isRetryable", obsError.isRetryable());
        eventEmitter.emit("downloadError", errorEvent);

        // Clear throttle record
        eventEmitter.clearThrottle(taskState.taskId);

        Log.e(TAG, "Download failed: " + taskState.taskId + ", error: " + obsError.getMessage());
    }

    /**
     * Cancel download
     */
    public void cancelDownload(String taskId) throws Exception {
        DownloadTaskState taskState = tasks.get(taskId);
        if (taskState == null) {
            Log.w(TAG, "cancelDownload: task not found (may have already completed): " + taskId);
            return;
        }

        // Cancel future
        if (taskState.future != null) {
            taskState.future.cancel(true);
        }

        taskState.status = "CANCELED";
        tasks.remove(taskId);

        // Send cancel event
        Map<String, Object> cancelEvent = new HashMap<>();
        cancelEvent.put("taskId", taskId);
        eventEmitter.emit("downloadCancel", cancelEvent);
    }

    /**
     * Cancel all downloads
     */
    public void cancelAll() {
        for (String taskId : tasks.keySet()) {
            try {
                cancelDownload(taskId);
            } catch (Exception e) {
                Log.w(TAG, "Failed to cancel task " + taskId + ": " + e.getMessage());
            }
        }
    }

    /**
     * Get task status
     */
    public Map<String, Object> getTaskStatus(String taskId) {
        DownloadTaskState taskState = tasks.get(taskId);
        if (taskState == null) {
            return null;
        }

        Map<String, Object> progress = new HashMap<>();
        progress.put("taskId", taskState.taskId);
        progress.put("downloadedBytes", taskState.downloadedBytes.get());
        progress.put("totalBytes", taskState.totalBytes);
        progress.put("percentage", taskState.totalBytes > 0 ?
                (int)(taskState.downloadedBytes.get() * 100 / taskState.totalBytes) : 0);

        Map<String, Object> status = new HashMap<>();
        status.put("taskId", taskState.taskId);
        status.put("type", "download");
        status.put("objectKey", taskState.params.objectKey);
        status.put("status", taskState.status);
        status.put("progress", progress);

        return status;
    }

    /**
     * Get all tasks
     */
    public List<Map<String, Object>> getAllTasks() {
        List<Map<String, Object>> result = new ArrayList<>();
        for (DownloadTaskState taskState : tasks.values()) {
            Map<String, Object> task = new HashMap<>();
            task.put("taskId", taskState.taskId);
            task.put("type", "download");
            task.put("objectKey", taskState.params.objectKey);
            task.put("status", taskState.status);
            result.add(task);
        }
        return result;
    }

    /**
     * Clear completed, failed, and canceled tasks
     */
    public void clearCompletedTasks() {
        tasks.entrySet().removeIf(entry -> {
            String status = entry.getValue().status;
            return "COMPLETED".equals(status) || "FAILED".equals(status) || "CANCELED".equals(status);
        });
    }

    /**
     * Cleanup resources
     */
    public void destroy() {
        executorService.shutdownNow();
        tasks.clear();
    }
}
