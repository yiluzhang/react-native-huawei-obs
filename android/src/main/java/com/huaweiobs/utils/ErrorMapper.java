package com.huaweiobs.utils;

import com.obs.services.exception.ObsException;

import java.io.IOException;
import java.net.SocketTimeoutException;
import java.net.UnknownHostException;
import java.util.Arrays;
import java.util.List;

/**
 * 错误映射器
 * 将 OBS SDK 异常映射为统一的错误码
 */
public class ErrorMapper {

    /**
     * 映射异常到 OBS 错误
     */
    public static OBSException mapException(Throwable e) {
        if (e instanceof OBSException) {
            return (OBSException) e;
        } else if (e instanceof ObsException) {
            return mapObsException((ObsException) e);
        } else if (e instanceof SocketTimeoutException) {
            OBSException exception = new OBSException(
                "E_NETWORK_TIMEOUT",
                "Network timeout: " + e.getMessage(),
                e
            );
            exception.setRetryable(true);
            return exception;
        } else if (e instanceof UnknownHostException) {
            OBSException exception = new OBSException(
                "E_NETWORK_UNAVAILABLE",
                "Network unavailable: " + e.getMessage(),
                e
            );
            exception.setRetryable(true);
            return exception;
        } else if (e instanceof IOException) {
            OBSException exception = new OBSException(
                "E_NETWORK_ERROR",
                "Network error: " + e.getMessage(),
                e
            );
            exception.setRetryable(true);
            return exception;
        } else if (e instanceof IllegalArgumentException) {
            return new OBSException(
                "E_INVALID_ARGUMENT",
                e.getMessage() != null ? e.getMessage() : "Invalid argument",
                e
            );
        } else {
            return new OBSException(
                "E_UNKNOWN",
                e.getMessage() != null ? e.getMessage() : "Unknown error",
                e
            );
        }
    }

    /**
     * 映射 OBS 官方 SDK 异常
     */
    private static OBSException mapObsException(ObsException e) {
        String errorCode = e.getErrorCode();
        int responseCode = e.getResponseCode();
        String message = e.getErrorMessage() != null ? e.getErrorMessage() : 
                        (e.getMessage() != null ? e.getMessage() : "Unknown OBS error");

        String sdkCode;

        // 认证错误
        if ("InvalidAccessKeyId".equals(errorCode) || "InvalidSecretAccessKey".equals(errorCode)) {
            sdkCode = "E_AUTH_INVALID_CREDENTIAL";
        } else if ("AccessDenied".equals(errorCode)) {
            sdkCode = "E_AUTH_ACCESS_DENIED";
        } else if ("SignatureDoesNotMatch".equals(errorCode)) {
            sdkCode = "E_AUTH_SIGNATURE_MISMATCH";
        } else if ("TokenExpired".equals(errorCode) || "RequestTimeTooSkewed".equals(errorCode)
                || "SecurityTokenExpired".equals(errorCode)) {
            sdkCode = "E_AUTH_EXPIRED";
        } else if ("InvalidToken".equals(errorCode) || "AuthFailure".equals(errorCode)
                || "SecurityTokenMalformed".equals(errorCode) || "InvalidStsAccessKeyId".equals(errorCode)) {
            sdkCode = "E_AUTH_INVALID_CREDENTIAL";
        }
        // 资源不存在
        else if ("NoSuchBucket".equals(errorCode)) {
            sdkCode = "E_BUCKET_NOT_FOUND";
        } else if ("NoSuchKey".equals(errorCode)) {
            sdkCode = "E_FILE_NOT_FOUND";
        } else if ("NoSuchUpload".equals(errorCode)) {
            sdkCode = "E_UPLOAD_NOT_FOUND";
        }
        // 网络相关
        else if ("RequestTimeout".equals(errorCode)) {
            sdkCode = "E_NETWORK_TIMEOUT";
        } else if ("ServiceUnavailable".equals(errorCode)) {
            sdkCode = "E_HTTP_5XX";
        } else if ("InternalError".equals(errorCode)) {
            sdkCode = "E_HTTP_5XX";
        }
        // 根据 HTTP 状态码映射
        else if (responseCode >= 500) {
            sdkCode = "E_HTTP_5XX";
        } else if (responseCode == 429) {
            sdkCode = "E_CONCURRENCY_LIMIT_EXCEEDED";
        } else if (responseCode == 408) {
            sdkCode = "E_NETWORK_TIMEOUT";
        } else if (responseCode == 404) {
            sdkCode = "E_FILE_NOT_FOUND";
        } else if (responseCode == 403) {
            sdkCode = "E_AUTH_ACCESS_DENIED";
        } else if (responseCode == 401) {
            sdkCode = "E_AUTH_INVALID_CREDENTIAL";
        } else if (responseCode >= 400) {
            sdkCode = "E_HTTP_4XX";
        } else {
            sdkCode = "E_UNKNOWN";
        }

        // 在消息中加入 OBS 错误码前缀，方便调试
        String fullMessage = errorCode != null && !errorCode.isEmpty()
            ? "[" + errorCode + "] " + message
            : message;

        OBSException exception = new OBSException(sdkCode, fullMessage, e);
        exception.setStatusCode(responseCode);
        exception.setRequestId(e.getErrorRequestId());
        exception.setHostId(e.getErrorHostId());
        exception.setRetryable(isRetryableErrorCode(sdkCode));
        return exception;
    }

    /**
     * 判断错误是否可重试
     */
    private static boolean isRetryableErrorCode(String code) {
        List<String> retryableCodes = Arrays.asList(
            "E_NETWORK_TIMEOUT",
            "E_NETWORK_ERROR",
            "E_NETWORK_UNAVAILABLE",
            "E_HTTP_5XX",
            "E_UPLOAD_PART_FAILED"
        );
        return retryableCodes.contains(code);
    }
}
