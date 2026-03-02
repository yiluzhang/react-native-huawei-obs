package com.huaweiobs.utils;

/**
 * OBS 自定义异常
 */
public class OBSException extends Exception {
    private final String code;
    private Integer statusCode;
    private String requestId;
    private String hostId;
    private boolean isRetryable;

    public OBSException(String code, String message) {
        this(code, message, null);
    }

    public OBSException(String code, String message, Throwable cause) {
        super(message, cause);
        this.code = code;
        this.isRetryable = false;
    }

    public String getCode() {
        return code;
    }

    public Integer getStatusCode() {
        return statusCode;
    }

    public void setStatusCode(Integer statusCode) {
        this.statusCode = statusCode;
    }

    public String getRequestId() {
        return requestId;
    }

    public void setRequestId(String requestId) {
        this.requestId = requestId;
    }

    public String getHostId() {
        return hostId;
    }

    public void setHostId(String hostId) {
        this.hostId = hostId;
    }

    public boolean isRetryable() {
        return isRetryable;
    }

    public void setRetryable(boolean retryable) {
        isRetryable = retryable;
    }
}
