/**
 * 原生模块接口类型定义
 * 定义 Native 层（iOS/Android）必须实现的接口
 */

/**
 * 文件流信息
 */
export interface FileStreamInfo {
  streamId: string;
  fileSize: number;
  mimeType?: string;
  fileName: string;
  lastModified: number;
}

/**
 * 初始化分片上传参数
 */
export interface InitiateMultipartUploadParams {
  bucket: string;
  objectKey: string;
  contentType?: string;
  metadata?: Record<string, string>;
  acl?: string;
  storageClass?: string;
}

/**
 * 初始化分片上传结果
 */
export interface InitiateMultipartUploadResult {
  uploadId: string;
}

/**
 * 上传分片参数
 */
export interface UploadPartParams {
  bucket: string;
  objectKey: string;
  uploadId: string;
  partNumber: number;
  streamId: string;
  offset: number;
  partSize: number;
  contentType?: string;
}

/**
 * 上传分片结果
 */
export interface UploadPartResult {
  etag: string;
  size: number;
}

/**
 * 完成分片上传参数
 */
export interface CompleteMultipartUploadParams {
  bucket: string;
  objectKey: string;
  uploadId: string;
  parts: Array<{ partNumber: number; etag: string }>;
}

/**
 * 完成分片上传结果
 */
export interface CompleteMultipartUploadResult {
  etag: string;
  objectUrl: string;
}

/**
 * 中止分片上传参数
 */
export interface AbortMultipartUploadParams {
  bucket: string;
  objectKey: string;
  uploadId: string;
}

/**
 * 单次上传参数
 */
export interface PutObjectParams {
  bucket: string;
  objectKey: string;
  filePath: string;
  contentType?: string;
  metadata?: Record<string, string>;
  acl?: string;
  storageClass?: string;
}

/**
 * 单次上传结果
 */
export interface PutObjectResult {
  etag: string;
  size: number;
  objectUrl: string;
}

/**
 * 下载参数
 */
export interface DownloadParams {
  bucket: string;
  objectKey: string;
  savePath: string;
  range?: string;
  versionId?: string;
  partSize?: number;
  concurrency?: number;
}

/**
 * 下载开始结果
 */
export interface DownloadStartResult {
  taskId: string;
}

/**
 * 下载状态
 */
export interface DownloadStatus {
  taskId: string;
  status: string;
  downloadedBytes: number;
  totalBytes: number;
  error?: { code: string; message: string };
}

/**
 * 删除参数
 */
export interface DeleteObjectParams {
  bucket: string;
  objectKey: string;
}

/**
 * 批量删除参数
 */
export interface DeleteMultipleObjectsParams {
  bucket: string;
  objectKeys: string[];
}

/**
 * 批量删除结果
 */
export interface DeleteMultipleObjectsResult {
  results: Array<{ objectKey: string; success: boolean; errorCode?: string }>;
}

/**
 * 凭证信息
 */
export interface Credentials {
  accessKeyId: string;
  secretAccessKey: string;
  securityToken?: string;
  expiryTime?: number;
}

/**
 * 网络类型
 */
export type NetworkType = 'WIFI' | '4G' | '3G' | '2G' | 'UNKNOWN';

/**
 * 原生模块接口
 * Native 层（iOS/Android）实现这些方法
 */
export interface NativeHuaweiObs {
  // ========== 客户端管理 ==========
  initClient(config: Record<string, any>): Promise<void>;
  updateConfig(config: Record<string, any>): Promise<void>;
  validateConfig(): Promise<boolean>;
  destroy(): Promise<void>;

  // ========== 文件流管理 ==========
  openFileStream(filePath: string): Promise<FileStreamInfo>;
  closeStream(streamId: string): Promise<void>;
  closeAllStreams(): Promise<void>;

  // ========== 上传 ==========
  upload(params: Record<string, any>): Promise<string>; // 返回 taskId
  multipartUpload(params: Record<string, any>): Promise<string>; // 返回 taskId
  pauseUpload(taskId: string): Promise<void>;
  resumeUpload(taskId: string): Promise<void>;
  cancelUpload(taskId: string): Promise<void>;

  // ========== 下载 ==========
  download(params: Record<string, any>): Promise<string>; // 返回 taskId
  cancelDownload(taskId: string): Promise<void>;

  // ========== 删除 ==========
  deleteObject(params: DeleteObjectParams): Promise<void>;
  deleteMultipleObjects(
    params: DeleteMultipleObjectsParams
  ): Promise<DeleteMultipleObjectsResult>;

  // ========== 任务管理 ==========
  getTaskStatus(taskId: string): Promise<Record<string, any> | null>;
  getAllTasks(): Promise<Array<Record<string, any>>>;
  clearCompletedTasks(): Promise<void>;

  // ========== 系统信息 ==========
  getAvailableMemory(): Promise<number>;
  getTotalMemory(): Promise<number>;
  getNetworkType(): Promise<NetworkType>;
}
