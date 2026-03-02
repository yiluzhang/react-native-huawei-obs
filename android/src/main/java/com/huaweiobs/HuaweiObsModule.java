package com.huaweiobs;

import android.content.Intent;
import android.net.Uri;
import android.util.Log;
import android.webkit.MimeTypeMap;

import androidx.core.content.FileProvider;

import com.facebook.react.bridge.*;
import com.facebook.react.modules.core.DeviceEventManagerModule;
import com.huaweiobs.core.*;
import com.huaweiobs.utils.EventEmitter;
import com.huaweiobs.utils.ErrorMapper;
import com.huaweiobs.utils.OBSException;

import java.io.File;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Huawei OBS React Native Module
 * Main RN Bridge entry point, routes JS calls to managers
 */
public class HuaweiObsModule extends ReactContextBaseJavaModule implements LifecycleEventListener {
    private static final String TAG = "HuaweiObsModule";

    private ObsClientHolder obsClientHolder;
    private FileStreamManager fileStreamManager;
    private ConcurrencyManager concurrencyManager;
    private EventEmitter eventEmitter;
    private UploadManager uploadManager;
    private DownloadManager downloadManager;

    private boolean isInitialized = false;
    private final ExecutorService executorService = Executors.newCachedThreadPool();

    public HuaweiObsModule(ReactApplicationContext reactContext) {
        super(reactContext);
        reactContext.addLifecycleEventListener(this);
    }

    @Override
    public String getName() {
        return "HuaweiObs";
    }

    // ==================== Client Management ====================

    @ReactMethod
    public void initClient(ReadableMap config, Promise promise) {
        try {
            HashMap<String, Object> configMap = config.toHashMap();

            // Validate required parameters
            if (!configMap.containsKey("endpoint")) {
                throw new IllegalArgumentException("Missing endpoint");
            }
            if (!configMap.containsKey("bucket")) {
                throw new IllegalArgumentException("Missing bucket");
            }
            if (!configMap.containsKey("accessKeyId")) {
                throw new IllegalArgumentException("Missing accessKeyId");
            }
            if (!configMap.containsKey("secretAccessKey")) {
                throw new IllegalArgumentException("Missing secretAccessKey");
            }

            // Initialize managers
            obsClientHolder = new ObsClientHolder();
            fileStreamManager = new FileStreamManager(getReactApplicationContext());
            Integer maxConcurrency = configMap.containsKey("maxConcurrency") ?
                    ((Number) configMap.get("maxConcurrency")).intValue() : 6;
            concurrencyManager = new ConcurrencyManager(maxConcurrency);
            eventEmitter = new EventEmitter(getReactApplicationContext());
            uploadManager = new UploadManager(
                    fileStreamManager,
                    obsClientHolder,
                    concurrencyManager,
                    eventEmitter
            );
            downloadManager = new DownloadManager(
                    obsClientHolder,
                    eventEmitter
            );

            // Create OBS client
            obsClientHolder.createClient(configMap);

            isInitialized = true;
            promise.resolve(null);

            Log.d(TAG, "OBS client initialized successfully");

        } catch (Exception e) {
            OBSException obsError = ErrorMapper.mapException(e);
            promise.reject(obsError.getCode(), obsError.getMessage(), obsError);
        }
    }

    @ReactMethod
    public void updateConfig(ReadableMap config, Promise promise) {
        executorService.submit(() -> {
            try {
                checkInitialized();
                obsClientHolder.updateConfig(config.toHashMap());
                promise.resolve(null);
            } catch (Exception e) {
                OBSException obsError = ErrorMapper.mapException(e);
                promise.reject(obsError.getCode(), obsError.getMessage(), obsError);
            }
        });
    }

    @ReactMethod
    public void validateConfig(Promise promise) {
        executorService.submit(() -> {
            try {
                checkInitialized();
                boolean isValid = obsClientHolder.getClient() != null &&
                        !obsClientHolder.isCredentialsExpired();
                promise.resolve(isValid);
            } catch (Exception e) {
                OBSException obsError = ErrorMapper.mapException(e);
                promise.reject(obsError.getCode(), obsError.getMessage(), obsError);
            }
        });
    }

    @ReactMethod
    public void destroy(Promise promise) {
        try {
            if (isInitialized) {
                uploadManager.cancelAll();
                downloadManager.cancelAll();
                fileStreamManager.closeAllStreams();
                obsClientHolder.closeClient();
                // 不关闭 executorService —— CachedThreadPool 线程空闲 60s 后自动回收
                // shutdownNow 会导致后续所有 submit 抛 RejectedExecutionException
                isInitialized = false;
            }
            promise.resolve(null);
        } catch (Exception e) {
            OBSException obsError = ErrorMapper.mapException(e);
            promise.reject(obsError.getCode(), obsError.getMessage(), obsError);
        }
    }

    // ==================== File Stream Management ====================

    @ReactMethod
    public void openFileStream(String filePath, Promise promise) {
        try {
            checkInitialized();
            FileStreamInfo fileInfo = fileStreamManager.openFileStream(filePath);

            WritableMap result = Arguments.createMap();
            result.putString("streamId", fileInfo.streamId);
            result.putDouble("fileSize", (double) fileInfo.fileSize);
            result.putString("fileName", fileInfo.fileName);
            result.putString("mimeType", fileInfo.mimeType);
            result.putDouble("lastModified", (double) fileInfo.lastModified);

            promise.resolve(result);
        } catch (Exception e) {
            OBSException obsError = ErrorMapper.mapException(e);
            promise.reject(obsError.getCode(), obsError.getMessage(), obsError);
        }
    }

    @ReactMethod
    public void closeStream(String streamId, Promise promise) {
        try {
            checkInitialized();
            fileStreamManager.closeStream(streamId);
            promise.resolve(null);
        } catch (Exception e) {
            OBSException obsError = ErrorMapper.mapException(e);
            promise.reject(obsError.getCode(), obsError.getMessage(), obsError);
        }
    }

    @ReactMethod
    public void closeAllStreams(Promise promise) {
        try {
            checkInitialized();
            fileStreamManager.closeAllStreams();
            promise.resolve(null);
        } catch (Exception e) {
            OBSException obsError = ErrorMapper.mapException(e);
            promise.reject(obsError.getCode(), obsError.getMessage(), obsError);
        }
    }

    // ==================== Upload ====================

    @ReactMethod
    public void upload(ReadableMap params, Promise promise) {
        multipartUpload(params, promise);
    }

    @ReactMethod
    public void multipartUpload(ReadableMap params, Promise promise) {
        try {
            checkInitialized();

            HashMap<String, Object> paramsMap = params.toHashMap();
            String taskId = UUID.randomUUID().toString();

            String filePath = (String) paramsMap.get("filePath");
            if (filePath == null) {
                throw new IllegalArgumentException("Missing filePath");
            }

            String objectKey = (String) paramsMap.get("objectKey");
            if (objectKey == null) {
                throw new IllegalArgumentException("Missing objectKey");
            }

            String bucket = (String) paramsMap.get("bucket");
            if (bucket == null) {
                throw new IllegalArgumentException("Missing bucket");
            }

            String contentType = (String) paramsMap.get("contentType");
            String acl = (String) paramsMap.get("acl");
            String storageClass = (String) paramsMap.get("storageClass");

            Long partSize = null;
            if (paramsMap.containsKey("partSize")) {
                partSize = ((Number) paramsMap.get("partSize")).longValue();
            }

            Integer concurrency = null;
            if (paramsMap.containsKey("concurrency")) {
                concurrency = ((Number) paramsMap.get("concurrency")).intValue();
            }

            Map<String, String> metadata = null;
            if (paramsMap.containsKey("metadata")) {
                @SuppressWarnings("unchecked")
                Map<Object, Object> metadataObj = (Map<Object, Object>) paramsMap.get("metadata");
                if (metadataObj != null) {
                    metadata = new HashMap<>();
                    for (Map.Entry<Object, Object> entry : metadataObj.entrySet()) {
                        metadata.put(entry.getKey().toString(), entry.getValue().toString());
                    }
                }
            }

            UploadManager.UploadParams uploadParams = new UploadManager.UploadParams(
                    taskId,
                    filePath,
                    objectKey,
                    bucket,
                    contentType,
                    metadata,
                    acl,
                    storageClass,
                    partSize,
                    concurrency
            );

            uploadManager.startUpload(uploadParams);
            promise.resolve(taskId);

        } catch (Exception e) {
            OBSException obsError = ErrorMapper.mapException(e);
            promise.reject(obsError.getCode(), obsError.getMessage(), obsError);
        }
    }

    @ReactMethod
    public void pauseUpload(String taskId, Promise promise) {
        promise.reject("E_NOT_IMPLEMENTED", "Pause upload not implemented");
    }

    @ReactMethod
    public void resumeUpload(String taskId, Promise promise) {
        promise.reject("E_NOT_IMPLEMENTED", "Resume upload not implemented");
    }

    @ReactMethod
    public void cancelUpload(String taskId, Promise promise) {
        try {
            checkInitialized();
            uploadManager.cancelUpload(taskId);
            promise.resolve(null);
        } catch (Exception e) {
            OBSException obsError = ErrorMapper.mapException(e);
            promise.reject(obsError.getCode(), obsError.getMessage(), obsError);
        }
    }

    // ==================== Download ====================

    @ReactMethod
    public void download(ReadableMap params, Promise promise) {
        try {
            checkInitialized();

            HashMap<String, Object> paramsMap = params.toHashMap();
            String taskId = UUID.randomUUID().toString();

            String objectKey = (String) paramsMap.get("objectKey");
            if (objectKey == null) {
                throw new IllegalArgumentException("Missing objectKey");
            }

            String bucket = (String) paramsMap.get("bucket");
            if (bucket == null) {
                throw new IllegalArgumentException("Missing bucket");
            }

            String savePath = (String) paramsMap.get("savePath");
            if (savePath == null) {
                throw new IllegalArgumentException("Missing savePath");
            }

            String range = (String) paramsMap.get("range");
            String versionId = (String) paramsMap.get("versionId");

            DownloadManager.DownloadParams downloadParams = new DownloadManager.DownloadParams(
                    taskId,
                    objectKey,
                    bucket,
                    savePath,
                    range,
                    versionId
            );

            downloadManager.startDownload(downloadParams);
            promise.resolve(taskId);

        } catch (Exception e) {
            OBSException obsError = ErrorMapper.mapException(e);
            promise.reject(obsError.getCode(), obsError.getMessage(), obsError);
        }
    }

    @ReactMethod
    public void cancelDownload(String taskId, Promise promise) {
        try {
            checkInitialized();
            downloadManager.cancelDownload(taskId);
            promise.resolve(null);
        } catch (Exception e) {
            OBSException obsError = ErrorMapper.mapException(e);
            promise.reject(obsError.getCode(), obsError.getMessage(), obsError);
        }
    }

    // ==================== Delete ====================

    @ReactMethod
    public void deleteObject(ReadableMap params, Promise promise) {
        executorService.submit(() -> {
            try {
                checkInitialized();

                HashMap<String, Object> paramsMap = params.toHashMap();
                String bucket = (String) paramsMap.get("bucket");
                if (bucket == null) {
                    throw new IllegalArgumentException("Missing required parameter: bucket");
                }

                String objectKey = (String) paramsMap.get("objectKey");
                if (objectKey == null) {
                    throw new IllegalArgumentException("Missing required parameter: objectKey");
                }

                Log.i(TAG, "[DeleteObject] bucket=" + bucket + " objectKey=" + objectKey);
                obsClientHolder.getClient().deleteObject(bucket, objectKey);
                
                WritableMap result = Arguments.createMap();
                result.putString("bucket", bucket);
                result.putString("objectKey", objectKey);
                
                Log.i(TAG, "[DeleteObject] Success");
                promise.resolve(result);

            } catch (Exception e) {
                OBSException obsError = ErrorMapper.mapException(e);
                if (e instanceof com.obs.services.exception.ObsException) {
                    com.obs.services.exception.ObsException obsEx = (com.obs.services.exception.ObsException) e;
                    Log.e(TAG, "[DeleteObject] Failed - errorCode: " + obsEx.getErrorCode()
                        + ", responseCode: " + obsEx.getResponseCode()
                        + ", message: " + obsEx.getErrorMessage());
                } else {
                    Log.e(TAG, "[DeleteObject] Failed: " + e.getMessage());
                }
                promise.reject(obsError.getCode(), obsError.getMessage(), obsError);
            }
        });
    }

    @ReactMethod
    public void deleteMultipleObjects(ReadableMap params, Promise promise) {
        executorService.submit(() -> {
            try {
                checkInitialized();

                HashMap<String, Object> paramsMap = params.toHashMap();
                String bucket = (String) paramsMap.get("bucket");
                if (bucket == null) {
                    throw new IllegalArgumentException("Missing bucket");
                }

                @SuppressWarnings("unchecked")
                List<String> objectKeys = (List<String>) paramsMap.get("objectKeys");
                if (objectKeys == null) {
                    throw new IllegalArgumentException("Missing objectKeys");
                }

                WritableArray resultArray = Arguments.createArray();

                for (String objectKey : objectKeys) {
                    WritableMap resultMap = Arguments.createMap();
                    resultMap.putString("objectKey", objectKey);

                    try {
                        obsClientHolder.getClient().deleteObject(bucket, objectKey);
                        resultMap.putBoolean("success", true);
                    } catch (Exception e) {
                        OBSException obsError = ErrorMapper.mapException(e);
                        resultMap.putBoolean("success", false);
                        resultMap.putString("errorCode", obsError.getCode());
                    }

                    resultArray.pushMap(resultMap);
                }

                promise.resolve(resultArray);

            } catch (Exception e) {
                OBSException obsError = ErrorMapper.mapException(e);
                promise.reject(obsError.getCode(), obsError.getMessage(), obsError);
            }
        });
    }

    // ==================== Task Management ====================

    @ReactMethod
    public void getTaskStatus(String taskId, Promise promise) {
        try {
            checkInitialized();

            Map<String, Object> uploadStatus = uploadManager.getTaskStatus(taskId);
            Map<String, Object> downloadStatus = downloadManager.getTaskStatus(taskId);

            Map<String, Object> status = uploadStatus != null ? uploadStatus : downloadStatus;

            if (status != null) {
                WritableMap result = mapToWritableMap(status);
                promise.resolve(result);
            } else {
                promise.resolve(null);
            }

        } catch (Exception e) {
            OBSException obsError = ErrorMapper.mapException(e);
            promise.reject(obsError.getCode(), obsError.getMessage(), obsError);
        }
    }

    @ReactMethod
    public void getAllTasks(Promise promise) {
        try {
            checkInitialized();

            List<Map<String, Object>> uploadTasks = uploadManager.getAllTasks();
            List<Map<String, Object>> downloadTasks = downloadManager.getAllTasks();

            WritableArray resultArray = Arguments.createArray();

            for (Map<String, Object> task : uploadTasks) {
                WritableMap taskMap = Arguments.createMap();
                taskMap.putString("taskId", (String) task.get("taskId"));
                taskMap.putString("type", (String) task.get("type"));
                taskMap.putString("objectKey", (String) task.get("objectKey"));
                taskMap.putString("status", (String) task.get("status"));
                resultArray.pushMap(taskMap);
            }

            for (Map<String, Object> task : downloadTasks) {
                WritableMap taskMap = Arguments.createMap();
                taskMap.putString("taskId", (String) task.get("taskId"));
                taskMap.putString("type", (String) task.get("type"));
                taskMap.putString("objectKey", (String) task.get("objectKey"));
                taskMap.putString("status", (String) task.get("status"));
                resultArray.pushMap(taskMap);
            }

            promise.resolve(resultArray);

        } catch (Exception e) {
            OBSException obsError = ErrorMapper.mapException(e);
            promise.reject(obsError.getCode(), obsError.getMessage(), obsError);
        }
    }

    @ReactMethod
    public void clearCompletedTasks(Promise promise) {
        try {
            checkInitialized();
            uploadManager.clearCompletedTasks();
            downloadManager.clearCompletedTasks();
            promise.resolve(null);
        } catch (Exception e) {
            OBSException obsError = ErrorMapper.mapException(e);
            promise.reject(obsError.getCode(), obsError.getMessage(), obsError);
        }
    }

    // ==================== System Info ====================

    @ReactMethod
    public void getAvailableMemory(Promise promise) {
        try {
            checkInitialized();
            long availableMemory = concurrencyManager.getAvailableMemoryMB();
            promise.resolve((double) availableMemory);
        } catch (Exception e) {
            OBSException obsError = ErrorMapper.mapException(e);
            promise.reject(obsError.getCode(), obsError.getMessage(), obsError);
        }
    }

    @ReactMethod
    public void getTotalMemory(Promise promise) {
        try {
            checkInitialized();
            long totalMemory = concurrencyManager.getTotalMemoryMB();
            promise.resolve((double) totalMemory);
        } catch (Exception e) {
            OBSException obsError = ErrorMapper.mapException(e);
            promise.reject(obsError.getCode(), obsError.getMessage(), obsError);
        }
    }

    @ReactMethod
    public void getNetworkType(Promise promise) {
        // Simplified implementation
        promise.resolve("UNKNOWN");
    }

    // ==================== File Utilities ====================

    @ReactMethod
    public void openFile(String filePath, Promise promise) {
        try {
            // Strip file:// prefix if present
            if (filePath.startsWith("file://")) {
                filePath = filePath.substring(7);
            }

            File file = new File(filePath);
            if (!file.exists()) {
                promise.reject("E_FILE_NOT_FOUND", "File not found: " + filePath);
                return;
            }

            ReactApplicationContext context = getReactApplicationContext();
            String authority = context.getPackageName() + ".fileprovider";
            Uri contentUri = FileProvider.getUriForFile(context, authority, file);

            // Detect MIME type from file extension
            String mimeType = "*/*";
            String extension = MimeTypeMap.getFileExtensionFromUrl(Uri.fromFile(file).toString());
            if (extension != null) {
                String detectedType = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension.toLowerCase());
                if (detectedType != null) {
                    mimeType = detectedType;
                }
            }

            Intent intent = new Intent(Intent.ACTION_VIEW);
            intent.setDataAndType(contentUri, mimeType);
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);

            context.startActivity(intent);
            promise.resolve(null);
        } catch (Exception e) {
            Log.e(TAG, "Failed to open file: " + e.getMessage(), e);
            promise.reject("E_OPEN_FILE_FAILED", "Failed to open file: " + e.getMessage(), e);
        }
    }

    // ==================== Lifecycle ====================

    @Override
    public void onHostResume() {
        // App resumed
    }

    @Override
    public void onHostPause() {
        // App paused
        Log.w(TAG, "App paused, upload tasks will continue in current session");
    }

    @Override
    public void onHostDestroy() {
        // App destroyed, cancel all tasks
        Log.d(TAG, "App destroyed, canceling all tasks");

        try {
            if (isInitialized) {
                uploadManager.cancelAll();
                downloadManager.cancelAll();
                fileStreamManager.closeAllStreams();
                obsClientHolder.closeClient();
                // 不关闭 executorService —— 热重载后模块实例被复用，shutdown 会导致后续操作全部失败
                isInitialized = false;
            }
        } catch (Exception e) {
            Log.e(TAG, "Error during cleanup: " + e.getMessage());
        }
    }

    // ==================== Helper Methods ====================

    private void checkInitialized() throws OBSException {
        if (!isInitialized) {
            throw new OBSException("E_UNKNOWN", "OBS client not initialized. Call initClient first.");
        }
    }

    private WritableMap mapToWritableMap(Map<String, Object> map) {
        WritableMap result = Arguments.createMap();
        for (Map.Entry<String, Object> entry : map.entrySet()) {
            Object value = entry.getValue();
            String key = entry.getKey();

            if (value == null) {
                result.putNull(key);
            } else if (value instanceof String) {
                result.putString(key, (String) value);
            } else if (value instanceof Integer) {
                result.putInt(key, (Integer) value);
            } else if (value instanceof Long) {
                result.putDouble(key, ((Long) value).doubleValue());
            } else if (value instanceof Double) {
                result.putDouble(key, (Double) value);
            } else if (value instanceof Boolean) {
                result.putBoolean(key, (Boolean) value);
            } else if (value instanceof Map) {
                @SuppressWarnings("unchecked")
                Map<String, Object> nestedMap = (Map<String, Object>) value;
                result.putMap(key, mapToWritableMap(nestedMap));
            }
        }
        return result;
    }
}
