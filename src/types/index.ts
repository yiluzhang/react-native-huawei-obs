/**
 * OBS 客户端配置
 */
export interface OBSClientConfig {
  // ========== 基础配置 ==========
  /** OBS 服务端点，例如: obs.cn-north-4.myhuaweicloud.com */
  endpoint: string;

  /** 桶名 */
  bucket: string;

  /** 区域（用于签名），例如: cn-north-4 */
  region?: string;

  // ========== 认证配置 ==========
  /** 访问密钥 ID (AK) */
  accessKeyId: string;

  /** 访问密钥 (SK) */
  secretAccessKey: string;

  /** 安全令牌（STS 临时凭证） */
  securityToken?: string;

  /** 令牌过期时间（时间戳 ms） */
  tokenExpiryTime?: number;

  // ========== 网络配置 ==========
  /** 连接超时（秒），默认 60 */
  connectionTimeout?: number;

  /** Socket 超时（秒），默认 60 */
  socketTimeout?: number;

  /** 最大重试次数，默认 3 */
  maxErrorRetry?: number;

  /** 是否启用 HTTPS，默认 true */
  isHttps?: boolean;

  /** 使用路径样式访问，默认 false（虚拟样式） */
  pathStyle?: boolean;

  // ========== 并发与分片 ==========
  /** 全局并发上限，默认 6，范围 1-10 */
  maxConcurrency?: number;

  /** 默认分片大小（字节），默认自适应 */
  defaultPartSize?: number;

  /**
   * 自定义域名，用于拼接上传成功后的访问链接
   * 例如: cdn.example.com 或 https://cdn.example.com
   * 设置后 UploadResult.objectUrl 将使用此域名替换 OBS 默认域名
   */
  customDomain?: string;

  /**
   * 对象键前缀，用于区分不同业务模块
   * 例如: "avatar" 或 "chat/images"
   * 设置后所有 upload/download/delete 的 objectKey 会自动加上 "{keyPrefix}/" 前缀
   * 末尾的 "/" 会自动处理，无需手动添加
   */
  keyPrefix?: string;
}

/**
 * 上传选项
 */
export interface UploadOptions {
  /** 内容类型（MIME） */
  contentType?: string;

  /** 对象元数据（自定义头，key 格式：x-obs-meta-xxx） */
  metadata?: Record<string, string>;

  /** 存储类型 */
  storageClass?: StorageClass;

  /** ACL 权限 */
  acl?: ACL;

  /** 进度回调（优先级高于全局事件） */
  onProgress?: (progress: UploadProgress) => void;

  /** 准备回调（上传前 content:// 文件复制进度，整数 0-100） */
  onPreparing?: (copyProgress: number) => void;

  /** 开始回调 */
  onStart?: (taskId: string) => void;

  /** 成功回调 */
  onSuccess?: (result: UploadResult) => void;

  /** 失败回调 */
  onError?: (error: OBSError) => void;
}

/**
 * 分片上传选项
 */
export interface MultipartUploadOptions extends UploadOptions {
  /** 分片大小（字节），5MB-5GB，默认自适应 */
  partSize?: number;

  /** 并发数，范围 1-10，受全局并发约束 */
  concurrency?: number;

  /** 取消回调 */
  onCancel?: (taskId: string) => void;
}

/**
 * 下载选项
 */
export interface DownloadOptions {
  /** 下载范围 (Range header)，例如: "bytes=0-1023" */
  range?: string;

  /** 版本 ID */
  versionId?: string;

  /** 分片大小（字节），默认 9MB */
  partSize?: number;

  /** 并发数，范围 1-10 */
  concurrency?: number;

  /** 进度回调 */
  onProgress?: (progress: DownloadProgress) => void;

  /** 成功回调 */
  onSuccess?: (result: DownloadResult) => void;

  /** 失败回调 */
  onError?: (error: OBSError) => void;
}

/**
 * 任务状态
 */
export interface TaskStatus {
  taskId: string;
  type: TaskType;
  objectKey: string;
  status: TaskStatusEnum;
  progress: UploadProgress | DownloadProgress;
  error?: OBSError;
  createdAt: number;
  updatedAt: number;
}

/**
 * 上传进度
 */
export interface UploadProgress {
  taskId: string;
  transferredBytes: number;
  totalBytes: number;
  /** 进度百分比，整数 0-100 */
  percentage: number;
  currentPart?: number;
  totalParts?: number;
  completedParts?: number;
  instantSpeed?: number;
  avgSpeed?: number;
  remainingTime?: number;
}

/**
 * 下载进度
 */
export interface DownloadProgress {
  taskId: string;
  downloadedBytes: number;
  totalBytes: number;
  /** 进度百分比，整数 0-100 */
  percentage: number;
  instantSpeed?: number;
  avgSpeed?: number;
  remainingTime?: number;
}

/**
 * 上传结果
 */
export interface UploadResult {
  taskId: string;
  objectKey: string;
  bucket: string;
  etag: string;
  versionId?: string;
  objectUrl: string;
  size: number;
  duration: number;
  avgSpeed: number;
}

/**
 * 下载结果
 */
export interface DownloadResult {
  taskId: string;
  objectKey: string;
  savePath: string;
  size: number;
  etag: string;
  duration: number;
  avgSpeed: number;
}

/**
 * 删除结果
 */
export interface DeleteResult {
  objectKey: string;
  success: boolean;
  errorCode?: string;
  errorMessage?: string;
  versionId?: string;
}

/**
 * OBS 错误
 */
export class OBSError extends Error {
  code: string;
  message: string;
  statusCode?: number;
  requestId?: string;
  hostId?: string;
  isRetryable: boolean;
  rawError?: any;

  constructor(params: {
    code: string;
    message: string;
    statusCode?: number;
    requestId?: string;
    hostId?: string;
    isRetryable?: boolean;
    rawError?: any;
  }) {
    super(params.message);
    this.name = 'OBSError';
    this.code = params.code;
    this.message = params.message;
    this.statusCode = params.statusCode;
    this.requestId = params.requestId;
    this.hostId = params.hostId;
    this.isRetryable = params.isRetryable ?? false;
    this.rawError = params.rawError;
  }
}

/**
 * 任务类型
 */
export type TaskType = 'upload' | 'download';

/**
 * 任务状态枚举
 */
export enum TaskStatusEnum {
  PENDING = 'PENDING',
  UPLOADING = 'UPLOADING',
  DOWNLOADING = 'DOWNLOADING',
  PAUSED = 'PAUSED',
  COMPLETED = 'COMPLETED',
  CANCELED = 'CANCELED',
  FAILED = 'FAILED',
}

/**
 * 存储类型
 */
export enum StorageClass {
  STANDARD = 'STANDARD',
  WARM = 'WARM',
  COLD = 'COLD',
}

/**
 * ACL 权限
 */
export enum ACL {
  PRIVATE = 'private',
  PUBLIC_READ = 'public-read',
  PUBLIC_READ_WRITE = 'public-read-write',
}

/**
 * 事件名称
 */
export type OBSEventName =
  | 'uploadPreparing'
  | 'uploadStart'
  | 'uploadProgress'
  | 'uploadCancel'
  | 'uploadSuccess'
  | 'uploadError'
  | 'downloadStart'
  | 'downloadProgress'
  | 'downloadCancel'
  | 'downloadSuccess'
  | 'downloadError';

/**
 * 进度类型
 */
export type Progress = UploadProgress | DownloadProgress;
