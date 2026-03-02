/**
 * 错误码枚举
 */
export enum OBSErrorCode {
  // ========== 通用 ==========
  UNKNOWN = 'E_UNKNOWN',
  INVALID_ARGUMENT = 'E_INVALID_ARGUMENT',
  NOT_IMPLEMENTED = 'E_NOT_IMPLEMENTED',

  // ========== 鉴权 ==========
  AUTH_INVALID_CREDENTIAL = 'E_AUTH_INVALID_CREDENTIAL',
  AUTH_EXPIRED = 'E_AUTH_EXPIRED',
  AUTH_SIGN_FAILED = 'E_AUTH_SIGN_FAILED',
  AUTH_PERMISSION_DENIED = 'E_AUTH_PERMISSION_DENIED',

  // ========== 网络 ==========
  NETWORK_TIMEOUT = 'E_NETWORK_TIMEOUT',
  NETWORK_ERROR = 'E_NETWORK_ERROR',
  NETWORK_UNAVAILABLE = 'E_NETWORK_UNAVAILABLE',

  // ========== HTTP ==========
  HTTP_4XX = 'E_HTTP_4XX',
  HTTP_5XX = 'E_HTTP_5XX',

  // ========== 文件操作 ==========
  FILE_NOT_FOUND = 'E_FILE_NOT_FOUND',
  FILE_NOT_READABLE = 'E_FILE_NOT_READABLE',
  FILE_WRITE_ERROR = 'E_FILE_WRITE_ERROR',

  // ========== 流管理 ==========
  STREAM_NOT_FOUND = 'E_STREAM_NOT_FOUND',
  STREAM_CLOSED = 'E_STREAM_CLOSED',
  INVALID_OFFSET = 'E_INVALID_OFFSET',
  READ_ERROR = 'E_READ_ERROR',

  // ========== 上传 ==========
  UPLOAD_INIT_FAILED = 'E_UPLOAD_INIT_FAILED',
  UPLOAD_PART_FAILED = 'E_UPLOAD_PART_FAILED',
  UPLOAD_COMPLETE_FAILED = 'E_UPLOAD_COMPLETE_FAILED',
  UPLOAD_ABORTED = 'E_UPLOAD_ABORTED',
  UPLOAD_NOT_FOUND = 'E_UPLOAD_NOT_FOUND',

  // ========== 下载 ==========
  DOWNLOAD_FAILED = 'E_DOWNLOAD_FAILED',

  // ========== 任务 ==========
  TASK_NOT_FOUND = 'E_TASK_NOT_FOUND',
  TASK_CANCELED = 'E_TASK_CANCELED',
  TASK_PAUSED = 'E_TASK_PAUSED',

  // ========== 并发 ==========
  CONCURRENCY_LIMIT_EXCEEDED = 'E_CONCURRENCY_LIMIT_EXCEEDED',
  MEMORY_INSUFFICIENT = 'E_MEMORY_INSUFFICIENT',
}

/**
 * OBS 错误码映射
 * OBS 服务端返回的错误码 -> SDK 错误码
 */
export const OBS_ERROR_CODE_MAP: Record<string, OBSErrorCode> = {
  // 认证错误
  InvalidAccessKeyId: OBSErrorCode.AUTH_INVALID_CREDENTIAL,
  InvalidSecretAccessKey: OBSErrorCode.AUTH_INVALID_CREDENTIAL,
  AccessDenied: OBSErrorCode.AUTH_PERMISSION_DENIED,
  TokenExpired: OBSErrorCode.AUTH_EXPIRED,
  RequestTimeTooSkewed: OBSErrorCode.AUTH_EXPIRED,
  InvalidToken: OBSErrorCode.AUTH_INVALID_CREDENTIAL,

  // 资源不存在
  NoSuchBucket: OBSErrorCode.INVALID_ARGUMENT,
  NoSuchKey: OBSErrorCode.FILE_NOT_FOUND,
  NoSuchUpload: OBSErrorCode.UPLOAD_NOT_FOUND,

  // 网络相关
  RequestTimeout: OBSErrorCode.NETWORK_TIMEOUT,
  ServiceUnavailable: OBSErrorCode.HTTP_5XX,
  InternalError: OBSErrorCode.HTTP_5XX,
};

/**
 * HTTP 状态码映射
 */
export const HTTP_STATUS_ERROR_MAP: Record<number, OBSErrorCode> = {
  400: OBSErrorCode.INVALID_ARGUMENT,
  401: OBSErrorCode.AUTH_INVALID_CREDENTIAL,
  403: OBSErrorCode.AUTH_PERMISSION_DENIED,
  404: OBSErrorCode.FILE_NOT_FOUND,
  408: OBSErrorCode.NETWORK_TIMEOUT,
  429: OBSErrorCode.CONCURRENCY_LIMIT_EXCEEDED,
  500: OBSErrorCode.HTTP_5XX,
  502: OBSErrorCode.HTTP_5XX,
  503: OBSErrorCode.HTTP_5XX,
  504: OBSErrorCode.NETWORK_TIMEOUT,
};

/**
 * 判断错误是否可重试
 */
export function isRetryableError(code: OBSErrorCode): boolean {
  const retryableCodes = [
    OBSErrorCode.NETWORK_TIMEOUT,
    OBSErrorCode.NETWORK_ERROR,
    OBSErrorCode.HTTP_5XX,
    OBSErrorCode.UPLOAD_PART_FAILED,
  ];
  return retryableCodes.includes(code);
}
