package com.huaweiobs.utils;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.WritableArray;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.modules.core.DeviceEventManagerModule;
import android.util.Log;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * 事件发射器
 * 负责向 React Native JS 层发送事件
 * 支持节流以避免事件过于频繁
 */
public class EventEmitter {
    private static final String TAG = "EventEmitter";
    private static final long THROTTLE_MS = 100L; // 节流时间：100ms

    private final ReactApplicationContext reactContext;
    private final Map<String, Long> lastEmitTime = new ConcurrentHashMap<>();
    private final Map<String, Number> lastProgress = new ConcurrentHashMap<>();

    public EventEmitter(ReactApplicationContext reactContext) {
        this.reactContext = reactContext;
    }

    /**
     * 发送事件到 JS
     */
    public void emit(String eventName, Map<String, Object> params) {
        try {
            WritableMap eventParams = mapToWritableMap(params);
            reactContext
                .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter.class)
                .emit(eventName, eventParams);
            
            Log.d(TAG, "Emitted event: " + eventName);
        } catch (Exception e) {
            Log.e(TAG, "Failed to emit event " + eventName + ": " + e.getMessage());
        }
    }

    /**
     * 发送进度事件（带节流）
     */
    public void emitProgress(String taskId, String eventName, Map<String, Object> params, boolean force) {
        long now = System.currentTimeMillis();
        Long lastTime = lastEmitTime.get(taskId);
        
        if (lastTime == null) {
            lastTime = 0L;
        }

        Object progress = params.get("percentage");
        Number lastProg = lastProgress.get(taskId);

        // Monotonic guard: never emit lower progress (prevents regression from concurrent callbacks)
        if (!force && progress instanceof Number && lastProg != null
                && ((Number) progress).doubleValue() < lastProg.doubleValue()) {
            return;
        }

        // 检查是否需要节流 (100ms + 1% threshold)
        if (!force && (now - lastTime) < THROTTLE_MS) {
            if (progress instanceof Number && lastProg != null) {
                double diff = ((Number) progress).doubleValue() - lastProg.doubleValue();
                if (diff < 1) {
                    return;
                }
            } else {
                return;
            }
        }

        lastEmitTime.put(taskId, now);
        if (progress instanceof Number) {
            lastProgress.put(taskId, (Number) progress);
        }
        emit(eventName, params);
    }

    /**
     * 清除任务的节流记录
     */
    public void clearThrottle(String taskId) {
        lastEmitTime.remove(taskId);
        lastProgress.remove(taskId);
    }

    /**
     * Map 转 WritableMap
     */
    private WritableMap mapToWritableMap(Map<String, Object> map) {
        WritableMap writableMap = Arguments.createMap();
        
        for (Map.Entry<String, Object> entry : map.entrySet()) {
            String key = entry.getKey();
            Object value = entry.getValue();
            
            if (value == null) {
                writableMap.putNull(key);
            } else if (value instanceof String) {
                writableMap.putString(key, (String) value);
            } else if (value instanceof Integer) {
                writableMap.putInt(key, (Integer) value);
            } else if (value instanceof Long) {
                writableMap.putDouble(key, ((Long) value).doubleValue());
            } else if (value instanceof Double) {
                writableMap.putDouble(key, (Double) value);
            } else if (value instanceof Float) {
                writableMap.putDouble(key, ((Float) value).doubleValue());
            } else if (value instanceof Boolean) {
                writableMap.putBoolean(key, (Boolean) value);
            } else if (value instanceof Map) {
                @SuppressWarnings("unchecked")
                Map<String, Object> nestedMap = (Map<String, Object>) value;
                writableMap.putMap(key, mapToWritableMap(nestedMap));
            } else if (value instanceof List) {
                WritableArray array = Arguments.createArray();
                List<?> list = (List<?>) value;
                for (Object item : list) {
                    if (item instanceof String) {
                        array.pushString((String) item);
                    } else if (item instanceof Integer) {
                        array.pushInt((Integer) item);
                    } else if (item instanceof Long) {
                        array.pushDouble(((Long) item).doubleValue());
                    } else if (item instanceof Double) {
                        array.pushDouble((Double) item);
                    } else if (item instanceof Boolean) {
                        array.pushBoolean((Boolean) item);
                    } else {
                        array.pushNull();
                    }
                }
                writableMap.putArray(key, array);
            } else {
                writableMap.putString(key, value.toString());
            }
        }
        return writableMap;
    }
}
