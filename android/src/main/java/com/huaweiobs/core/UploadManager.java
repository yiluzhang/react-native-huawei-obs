package com.huaweiobs.core;

import android.util.Log;

import com.huaweiobs.utils.EventEmitter;
import com.huaweiobs.utils.ErrorMapper;
import com.huaweiobs.utils.OBSException;
import com.obs.services.model.*;

import java.io.ByteArrayInputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Upload Manager
 * Orchestrates multipart upload operations
 */
public class UploadManager {
    private static final String TAG = "UploadManager";
    private static final long MIN_PART_SIZE = 1 * 1024 * 1024L;   // 1MB 下限
    private static final long MAX_PART_SIZE = 10 * 1024 * 1024L;  // 10MB 上限
    private static final int TARGET_PARTS = 100;                   // 目标分片数（~1% 进度粒度）
    private static final long MULTIPART_THRESHOLD = 5 * 1024 * 1024L; // 5MB：低于此用 putObject

    private final FileStreamManager fileStreamManager;
    private final ObsClientHolder obsClientHolder;
    private final ConcurrencyManager concurrencyManager;
    private final EventEmitter eventEmitter;
    private final ConcurrentHashMap<String, UploadTaskState> tasks = new ConcurrentHashMap<>();
    private final ExecutorService executorService;

    /**
     * Upload parameters
     */
    public static class UploadParams {
        public final String taskId;
        public final String filePath;
        public final String objectKey;
        public final String bucket;
        public final String contentType;
        public final Map<String, String> metadata;
        public final String acl;
        public final String storageClass;
        public final Long partSize;
        public final Integer concurrency;
        public final long startTimeMs;

        public UploadParams(String taskId, String filePath, String objectKey, String bucket,
                            String contentType, Map<String, String> metadata, String acl,
                            String storageClass, Long partSize, Integer concurrency) {
            this.taskId = taskId;
            this.filePath = filePath;
            this.objectKey = objectKey;
            this.bucket = bucket;
            this.contentType = contentType;
            this.metadata = metadata;
            this.acl = acl;
            this.storageClass = storageClass;
            this.partSize = partSize;
            this.concurrency = concurrency;
            this.startTimeMs = System.currentTimeMillis();
        }
    }

    /**
     * Upload result
     */
    public static class UploadResult {
        public final String taskId;
        public final String objectKey;
        public final String bucket;
        public final String etag;
        public final String objectUrl;
        public final long size;
        public final long duration;
        public final double avgSpeed;

        public UploadResult(String taskId, String objectKey, String bucket, String etag,
                            String objectUrl, long size, long duration, double avgSpeed) {
            this.taskId = taskId;
            this.objectKey = objectKey;
            this.bucket = bucket;
            this.etag = etag;
            this.objectUrl = objectUrl;
            this.size = size;
            this.duration = duration;
            this.avgSpeed = avgSpeed;
        }
    }

    /**
     * Part information
     */
    private static class PartInfo {
        final int partNumber;
        final String etag;

        PartInfo(int partNumber, String etag) {
            this.partNumber = partNumber;
            this.etag = etag;
        }
    }

    /**
     * Upload task state
     */
    private static class UploadTaskState {
        final String taskId;
        final UploadParams params;
        String uploadId;
        String streamId;
        final List<PartInfo> parts = new ArrayList<>();
        String status = "PENDING";
        final AtomicLong transferredBytes = new AtomicLong(0);
        long totalBytes = 0;
        Future<?> future;
        OBSException error;
        /** 取消标志，cancelUpload() 设置 true 后所有分支停止工作 */
        volatile boolean cancelled = false;
        /** 分片上传所用的子线程池，取消时需要 shutdownNow */
        volatile ExecutorService partExecutor = null;

        UploadTaskState(String taskId, UploadParams params) {
            this.taskId = taskId;
            this.params = params;
        }
    }

    public UploadManager(FileStreamManager fileStreamManager, ObsClientHolder obsClientHolder,
                         ConcurrencyManager concurrencyManager, EventEmitter eventEmitter) {
        this.fileStreamManager = fileStreamManager;
        this.obsClientHolder = obsClientHolder;
        this.concurrencyManager = concurrencyManager;
        this.eventEmitter = eventEmitter;
        this.executorService = Executors.newCachedThreadPool();
    }

    /**
     * Start multipart upload
     */
    public String startUpload(UploadParams params) {
        Log.i(TAG, "[StartUpload] taskId=" + params.taskId + "  objectKey=" + params.objectKey + "  filePath=" + params.filePath);
        UploadTaskState taskState = new UploadTaskState(params.taskId, params);
        tasks.put(params.taskId, taskState);

        // Execute upload in background
        taskState.future = executorService.submit(() -> {
            try {
                executeUpload(taskState);
            } catch (Exception e) {
                // 任务已被取消时不触发 error 事件（cancelUpload 会发 uploadCancel）
                if (!taskState.cancelled) {
                    handleUploadError(taskState, e);
                }
            }
        });

        return params.taskId;
    }

    /**
     * Execute upload flow: 小文件用 putObject，大文件用分片上传
     */
    private void executeUpload(UploadTaskState taskState) throws Exception {
        UploadParams params = taskState.params;

        try {
            // 1. Check credentials expiry
            if (obsClientHolder.isCredentialsExpired()) {
                throw new OBSException("E_AUTH_EXPIRED", "Credentials expired");
            }

            // 立即发出 preparing 事件，确保 UI 有反馈（尤其对 content:// 大文件备水阶段）
            Map<String, Object> initialPreparing = new HashMap<>();
            initialPreparing.put("taskId", params.taskId);
            initialPreparing.put("objectKey", params.objectKey);
            initialPreparing.put("copyProgress", 0);
            eventEmitter.emit("uploadPreparing", initialPreparing);

            // 2. Open file stream (normalizes content:// → temp file, with copy progress callback)
            FileStreamInfo fileInfo = fileStreamManager.openFileStream(params.filePath, (copied, total) -> {
                int progress = total > 0 ? (int)(copied * 100 / total) : 0;
                Log.d(TAG, "[Preparing] copy progress=" + progress + "%");
                Map<String, Object> preparingEvent = new HashMap<>();
                preparingEvent.put("taskId", params.taskId);
                preparingEvent.put("objectKey", params.objectKey);
                preparingEvent.put("copyProgress", progress);
                eventEmitter.emit("uploadPreparing", preparingEvent);
            }, () -> taskState.cancelled);  // 协作式取消检查
            if (taskState.cancelled) return; // 复制完成后检查取消
            taskState.streamId = fileInfo.streamId;
            taskState.totalBytes = fileInfo.fileSize;

            // Send uploadStart event
            taskState.status = "UPLOADING";
            Map<String, Object> startEvent = new HashMap<>();
            startEvent.put("taskId", params.taskId);
            startEvent.put("objectKey", params.objectKey);
            startEvent.put("totalBytes", fileInfo.fileSize);
            eventEmitter.emit("uploadStart", startEvent);

            Log.i(TAG, "[Upload] taskId=" + params.taskId
                    + "  objectKey=" + params.objectKey
                    + "  fileSize=" + fileInfo.fileSize + " bytes"
                    + "  mimeType=" + fileInfo.mimeType);

            UploadResult result;
            if (taskState.cancelled) return; // 发送 start 事件后检查取消
            if (fileInfo.fileSize <= MULTIPART_THRESHOLD) {
                // 小文件直接用 putObject，避免分片上传所需的额外权限
                Log.i(TAG, "[Upload] strategy=putObject (size <= " + MULTIPART_THRESHOLD + " bytes)");
                result = executePutObject(taskState, fileInfo);
            } else {
                // 大文件用分片上传
                Log.i(TAG, "[Upload] strategy=multipart (size > " + MULTIPART_THRESHOLD + " bytes)");
                result = executeMultipartUpload(taskState, fileInfo);
            }

            // Cleanup resources
            if (taskState.cancelled) return; // 上传完成后检查取消
            fileStreamManager.closeStream(fileInfo.streamId);
            taskState.streamId = null;
            taskState.status = "COMPLETED";

            // Send success event
            Map<String, Object> successEvent = new HashMap<>();
            successEvent.put("taskId", params.taskId);
            successEvent.put("objectKey", result.objectKey);
            successEvent.put("bucket", result.bucket);
            successEvent.put("etag", result.etag);
            successEvent.put("objectUrl", result.objectUrl);
            successEvent.put("size", result.size);
            successEvent.put("duration", result.duration);
            successEvent.put("avgSpeed", result.avgSpeed);
            eventEmitter.emit("uploadSuccess", successEvent);
            eventEmitter.clearThrottle(params.taskId);

        } catch (Exception e) {
            throw ErrorMapper.mapException(e);
        }
    }

    /**
     * Simple upload using putObject (for files ≤ 5 MB)
     */
    private UploadResult executePutObject(UploadTaskState taskState, FileStreamInfo fileInfo) throws Exception {
        UploadParams params = taskState.params;
        long startTime = params.startTimeMs;

        try {
            java.io.File file = new java.io.File(fileInfo.resolvedPath);

            PutObjectRequest request = new PutObjectRequest(params.bucket, params.objectKey, file);

            // Set content type
            ObjectMetadata metadata = new ObjectMetadata();
            if (params.contentType != null) {
                metadata.setContentType(params.contentType);
            } else {
                metadata.setContentType(fileInfo.mimeType);
            }
            // Custom metadata
            if (params.metadata != null) {
                for (Map.Entry<String, String> entry : params.metadata.entrySet()) {
                    metadata.addUserMetadata(entry.getKey(), entry.getValue());
                }
            }
            request.setMetadata(metadata);

            Log.d(TAG, "[PutObject] sending request: bucket=" + params.bucket + "  key=" + params.objectKey);
            PutObjectResult response = obsClientHolder.getClient().putObject(request);

            long duration = System.currentTimeMillis() - startTime;
            double avgSpeed = duration > 0 ? (fileInfo.fileSize * 1000.0 / duration) : 0;
            Log.i(TAG, "[PutObject] done: etag=" + response.getEtag()
                    + "  duration=" + duration + "ms"
                    + "  speed=" + String.format("%.1f", avgSpeed / 1024) + " KB/s");

            // Emit 100% progress
            Map<String, Object> progressEvent = new HashMap<>();
            progressEvent.put("taskId", params.taskId);
            progressEvent.put("transferredBytes", fileInfo.fileSize);
            progressEvent.put("totalBytes", fileInfo.fileSize);
            progressEvent.put("percentage", 100);
            eventEmitter.emitProgress(params.taskId, "uploadProgress", progressEvent, false);

            String objectUrl = response.getObjectUrl();
            if (objectUrl == null) {
                String encodedKey;
                try {
                    encodedKey = java.net.URLEncoder.encode(params.objectKey, "UTF-8").replace("+", "%20");
                } catch (Exception e) {
                    encodedKey = params.objectKey;
                }
                objectUrl = "https://" + params.bucket + "." + obsClientHolder.getConfig().getOrDefault("endpoint", "") + "/" + encodedKey;
            }

            return new UploadResult(
                    params.taskId, params.objectKey, params.bucket,
                    response.getEtag(), objectUrl,
                    fileInfo.fileSize, duration, avgSpeed
            );
        } catch (Exception e) {
            OBSException obsError = ErrorMapper.mapException(e);
            throw new OBSException("E_UPLOAD_FAILED",
                    "Failed to upload object: " + obsError.getMessage(), obsError);
        }
    }

    /**
     * Multipart upload (for files > 5 MB)
     */
    private UploadResult executeMultipartUpload(UploadTaskState taskState, FileStreamInfo fileInfo) throws Exception {
        UploadParams params = taskState.params;

        // 3. Select part size
        long partSize = params.partSize != null ? params.partSize : selectPartSize(fileInfo.fileSize);
        int totalParts = (int) ((fileInfo.fileSize + partSize - 1) / partSize);

        Log.i(TAG, "[Multipart] objectKey=" + params.objectKey
                + "  fileSize=" + fileInfo.fileSize
                + "  partSize=" + partSize
                + "  totalParts=" + totalParts);

        // 4. Initiate multipart upload
        String uploadId = initiateMultipartUpload(params, fileInfo.mimeType);
        taskState.uploadId = uploadId;

        // 5. Calculate actual concurrency
        int actualConcurrency = concurrencyManager.calculateConcurrency(
                (int) (partSize / (1024 * 1024)),
                params.concurrency != null ? params.concurrency : 6
        );
        Log.i(TAG, "[Multipart] concurrency=" + actualConcurrency);

        // 6. Upload parts concurrently
        uploadParts(taskState, fileInfo, partSize, totalParts, actualConcurrency);

        // 分片上传完成后检查取消
        if (taskState.cancelled) {
            Log.i(TAG, "[Multipart] cancelled after uploadParts, skipping completeMultipartUpload");
            return null; // executeUpload 中 cancelled 检查会处理 null
        }

        // 7. Complete multipart upload
        return completeMultipartUpload(taskState);
    }

    /**
     * Initiate multipart upload
     */
    private String initiateMultipartUpload(UploadParams params, String contentType) throws Exception {
        try {
            InitiateMultipartUploadRequest request = new InitiateMultipartUploadRequest(
                    params.bucket, params.objectKey);
            
            // Set metadata
            if (params.metadata != null) {
                for (Map.Entry<String, String> entry : params.metadata.entrySet()) {
                    request.getMetadata().addUserMetadata(entry.getKey(), entry.getValue());
                }
            }

            InitiateMultipartUploadResult response = obsClientHolder.getClient().initiateMultipartUpload(request);
            String uploadId = response.getUploadId();
            if (uploadId == null) {
                throw new OBSException("E_UPLOAD_INIT_FAILED", "Failed to get uploadId");
            }
            Log.i(TAG, "[Multipart] uploadId=" + uploadId);
            return uploadId;

        } catch (Exception e) {
            OBSException obsError = ErrorMapper.mapException(e);
            throw new OBSException("E_UPLOAD_INIT_FAILED",
                    "Failed to initiate multipart upload: " + obsError.getMessage(), obsError);
        }
    }

    /**
     * Upload parts concurrently
     */
    private void uploadParts(UploadTaskState taskState, FileStreamInfo fileInfo,
                             long partSize, int totalParts, int concurrency) throws Exception {
        List<Future<Void>> futures = new ArrayList<>();
        ExecutorService partExecutor = Executors.newFixedThreadPool(concurrency);
        // 存到 taskState，cancelUpload 可以直接 shutdownNow
        taskState.partExecutor = partExecutor;

        try {
            for (int partNumber = 1; partNumber <= totalParts; partNumber++) {
                if (taskState.cancelled) break;
                final int currentPart = partNumber;
                try {
                    Future<Void> future = partExecutor.submit(() -> {
                        uploadSinglePart(taskState, fileInfo, currentPart, partSize, totalParts);
                        return null;
                    });
                    futures.add(future);
                } catch (java.util.concurrent.RejectedExecutionException e) {
                    // executor 已被 cancelUpload shutdownNow，停止提交
                    break;
                }
            }

            // Wait for all parts to complete
            for (Future<Void> future : futures) {
                try {
                    future.get();
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return; // 主线程被中断（cancel(true)），直接退出
                } catch (java.util.concurrent.CancellationException e) {
                    if (taskState.cancelled) return; // 正常取消，直接返回
                    throw e;
                } catch (java.util.concurrent.ExecutionException e) {
                    if (taskState.cancelled) return; // 取消期间的异常，忽略
                    Throwable cause = e.getCause();
                    if (cause instanceof Exception) throw (Exception) cause;
                    throw e;
                }
            }

        } finally {
            taskState.partExecutor = null;
            partExecutor.shutdown(); // 不用 shutdownNow，避免中断线程破坏 OBS SDK 连接池
            try {
                partExecutor.awaitTermination(30, TimeUnit.SECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
    }

    /**
     * Upload single part
     */
    private void uploadSinglePart(UploadTaskState taskState, FileStreamInfo fileInfo,
                                   int partNumber, long partSize, int totalParts) throws Exception {
        if (taskState.cancelled) return; // 取消后不再发新分片
        UploadParams params = taskState.params;
        long offset = (partNumber - 1) * partSize;
        int currentPartSize = (int) Math.min(partSize, fileInfo.fileSize - offset);

        try {
            // Read part data
            if (taskState.cancelled) return;
            byte[] data = fileStreamManager.readChunk(fileInfo.streamId, offset, currentPartSize);

            // Upload part
            if (taskState.cancelled) return;
            UploadPartRequest request = new UploadPartRequest(
                    params.bucket,
                    params.objectKey,
                    (long) data.length,
                    new ByteArrayInputStream(data)
            );
            request.setPartNumber(partNumber);
            request.setUploadId(taskState.uploadId);

            UploadPartResult response = obsClientHolder.getClient().uploadPart(request);
            String etag = response.getEtag();
            if (etag == null) {
                throw new OBSException("E_UPLOAD_PART_FAILED",
                        "Failed to get etag for part " + partNumber);
            }

            // Save part info
            synchronized (taskState.parts) {
                taskState.parts.add(new PartInfo(partNumber, etag));
            }

            // Update transferred bytes
            long transferred = taskState.transferredBytes.addAndGet(data.length);

            // Send partComplete event
            Map<String, Object> partEvent = new HashMap<>();
            partEvent.put("taskId", params.taskId);
            partEvent.put("partNumber", partNumber);
            partEvent.put("etag", etag);
            partEvent.put("uploadedBytes", transferred);
            eventEmitter.emit("partComplete", partEvent);

            // Force emit accurate progress after part completion
            int percentage = taskState.totalBytes > 0 ? (int)(transferred * 100 / taskState.totalBytes) : 0;
            Map<String, Object> progressEvent = new HashMap<>();
            progressEvent.put("taskId", params.taskId);
            progressEvent.put("transferredBytes", transferred);
            progressEvent.put("totalBytes", taskState.totalBytes);
            progressEvent.put("percentage", percentage);
            progressEvent.put("currentPart", partNumber);
            progressEvent.put("totalParts", totalParts);
            progressEvent.put("completedParts", taskState.parts.size());
            eventEmitter.emitProgress(params.taskId, "uploadProgress", progressEvent, true);

            Log.d(TAG, "[Part] " + partNumber + "/" + totalParts
                    + "  size=" + data.length
                    + "  etag=" + etag
                    + "  transferred=" + transferred + "/" + taskState.totalBytes);

        } catch (Exception e) {
            OBSException obsError = ErrorMapper.mapException(e);
            OBSException partError = new OBSException("E_UPLOAD_PART_FAILED",
                    "Failed to upload part " + partNumber + ": " + obsError.getMessage(), obsError);
            partError.setRetryable(obsError.isRetryable());
            throw partError;
        }
    }

    /**
     * Complete multipart upload
     */
    private UploadResult completeMultipartUpload(UploadTaskState taskState) throws Exception {
        try {
            UploadParams params = taskState.params;

            // Sort parts by part number
            List<PartInfo> sortedParts = new ArrayList<>(taskState.parts);
            sortedParts.sort((a, b) -> Integer.compare(a.partNumber, b.partNumber));

            // Create PartEtag list
            List<PartEtag> partEtags = new ArrayList<>();
            for (PartInfo part : sortedParts) {
                partEtags.add(new PartEtag(part.etag, part.partNumber));
            }

            CompleteMultipartUploadRequest request = new CompleteMultipartUploadRequest(
                    params.bucket,
                    params.objectKey,
                    taskState.uploadId,
                    partEtags
            );

            Log.i(TAG, "[Multipart] completing upload, parts=" + sortedParts.size() + "  uploadId=" + taskState.uploadId);
            CompleteMultipartUploadResult response = obsClientHolder.getClient().completeMultipartUpload(request);
            long duration = System.currentTimeMillis() - params.startTimeMs;
            double avgSpeed = duration > 0 ? (taskState.totalBytes * 1000.0) / duration : 0.0;
            Log.i(TAG, "[Multipart] complete done: etag=" + response.getEtag()
                    + "  duration=" + duration + "ms"
                    + "  speed=" + String.format("%.1f", avgSpeed / 1024) + " KB/s");

            // Construct object URL using actual endpoint
            String endpoint = obsClientHolder.getConfig().getOrDefault("endpoint", "").toString();
            endpoint = endpoint.replaceFirst("^https?://", "");
            String encodedKey;
            try {
                encodedKey = java.net.URLEncoder.encode(params.objectKey, "UTF-8").replace("+", "%20");
            } catch (Exception e) {
                encodedKey = params.objectKey;
            }
            String objectUrl = "https://" + params.bucket + "." + endpoint + "/" + encodedKey;

            return new UploadResult(
                    params.taskId,
                    params.objectKey,
                    params.bucket,
                    response.getEtag() != null ? response.getEtag() : "",
                    objectUrl,
                    taskState.totalBytes,
                    duration,
                    avgSpeed
            );

        } catch (Exception e) {
            OBSException obsError = ErrorMapper.mapException(e);
            throw new OBSException("E_UPLOAD_COMPLETE_FAILED",
                    "Failed to complete multipart upload: " + obsError.getMessage(), obsError);
        }
    }

    /**
     * Handle upload error
     */
    private void handleUploadError(UploadTaskState taskState, Throwable error) {
        OBSException obsError = ErrorMapper.mapException(error);
        taskState.error = obsError;
        taskState.status = "FAILED";

        // Abort multipart upload to clean up server-side resources
        if (taskState.uploadId != null) {
            final String bucket = taskState.params.bucket;
            final String objectKey = taskState.params.objectKey;
            final String uploadId = taskState.uploadId;
            executorService.submit(() -> {
                try {
                    AbortMultipartUploadRequest request = new AbortMultipartUploadRequest(
                            bucket, objectKey, uploadId);
                    obsClientHolder.getClient().abortMultipartUpload(request);
                    Log.i(TAG, "Aborted multipart upload on error: " + uploadId);
                } catch (Exception e) {
                    Log.w(TAG, "Failed to abort multipart upload on error: " + e.getMessage());
                }
            });
        }

        // Cleanup resources
        if (taskState.streamId != null) {
            try {
                fileStreamManager.closeStream(taskState.streamId);
            } catch (Exception e) {
                // Ignore cleanup errors
            }
            taskState.streamId = null;
        }

        // Send error event
        Map<String, Object> errorEvent = new HashMap<>();
        errorEvent.put("taskId", taskState.taskId);
        errorEvent.put("code", obsError.getCode());
        errorEvent.put("message", obsError.getMessage());
        errorEvent.put("isRetryable", obsError.isRetryable());
        eventEmitter.emit("uploadError", errorEvent);

        // Clear throttle record
        eventEmitter.clearThrottle(taskState.taskId);

        Log.e(TAG, "Upload failed: " + taskState.taskId + ", error: " + obsError.getMessage());
    }

    /**
     * Cancel upload
     */
    public void cancelUpload(String taskId) throws Exception {
        UploadTaskState taskState = tasks.get(taskId);
        if (taskState == null) {
            Log.w(TAG, "cancelUpload: task not found (may have already completed): " + taskId);
            return;
        }

        // 先置取消标志，让正在运行的分片子任务主动退出
        taskState.cancelled = true;
        taskState.status = "CANCELED";

        // shutdown 分片子线程池（不用 shutdownNow，避免中断线程破坏 OBS SDK 连接池）
        if (taskState.partExecutor != null) {
            taskState.partExecutor.shutdown();
        }

        // 不调用 future.cancel(true)，避免线程中断传播到 OBS SDK 内部线程池

        // Abort multipart upload (异步执行，不阻塞调用线程)
        if (taskState.uploadId != null) {
            final String bucket = taskState.params.bucket;
            final String objectKey = taskState.params.objectKey;
            final String uploadId = taskState.uploadId;
            executorService.submit(() -> {
                try {
                    AbortMultipartUploadRequest request = new AbortMultipartUploadRequest(
                            bucket, objectKey, uploadId);
                    obsClientHolder.getClient().abortMultipartUpload(request);
                    Log.i(TAG, "Aborted multipart upload: " + uploadId);
                } catch (Exception e) {
                    Log.w(TAG, "Failed to abort multipart upload: " + e.getMessage());
                }
            });
        }

        // Cleanup resources (异步执行，不阻塞调用线程)
        if (taskState.streamId != null) {
            final String streamId = taskState.streamId;
            executorService.submit(() -> {
                try {
                    fileStreamManager.closeStream(streamId);
                } catch (Exception e) {
                    // Ignore cleanup errors
                }
            });
        }

        taskState.status = "CANCELED";
        tasks.remove(taskId);

        // Send cancel event
        Map<String, Object> cancelEvent = new HashMap<>();
        cancelEvent.put("taskId", taskId);
        eventEmitter.emit("uploadCancel", cancelEvent);
    }

    /**
     * Cancel all uploads
     */
    public void cancelAll() {
        for (String taskId : tasks.keySet()) {
            try {
                cancelUpload(taskId);
            } catch (Exception e) {
                Log.w(TAG, "Failed to cancel task " + taskId + ": " + e.getMessage());
            }
        }
    }

    /**
     * Get task status
     */
    public Map<String, Object> getTaskStatus(String taskId) {
        UploadTaskState taskState = tasks.get(taskId);
        if (taskState == null) {
            return null;
        }

        Map<String, Object> progress = new HashMap<>();
        progress.put("taskId", taskState.taskId);
        progress.put("transferredBytes", taskState.transferredBytes.get());
        progress.put("totalBytes", taskState.totalBytes);
        progress.put("percentage", taskState.totalBytes > 0 ?
                (int)(taskState.transferredBytes.get() * 100 / taskState.totalBytes) : 0);
        progress.put("completedParts", taskState.parts.size());

        Map<String, Object> status = new HashMap<>();
        status.put("taskId", taskState.taskId);
        status.put("type", "upload");
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
        for (UploadTaskState taskState : tasks.values()) {
            Map<String, Object> task = new HashMap<>();
            task.put("taskId", taskState.taskId);
            task.put("type", "upload");
            task.put("objectKey", taskState.params.objectKey);
            task.put("status", taskState.status);
            result.add(task);
        }
        return result;
    }

    /**
     * Select part size based on file size
     */
    private long selectPartSize(long fileSize) {
        // 目标 ~100 个分片，进度粒度 ~1%，分片大小限制在 [1MB, 10MB]
        long selected = fileSize / TARGET_PARTS;
        if (selected < MIN_PART_SIZE) {
            selected = MIN_PART_SIZE;
        } else if (selected > MAX_PART_SIZE) {
            selected = MAX_PART_SIZE;
        }
        Log.d(TAG, "[PartSize] fileSize=" + fileSize + "  -> partSize=" + selected
                + "  (~" + ((fileSize + selected - 1) / selected) + " parts)");
        return selected;
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
