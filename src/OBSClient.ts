import { NativeModules, NativeEventEmitter, Platform } from 'react-native';
import { TaskHandle } from './TaskHandle';
import type {
  OBSClientConfig,
  UploadOptions,
  MultipartUploadOptions,
  DownloadOptions,
  UploadResult,
  DownloadResult,
  DeleteResult,
  TaskStatus,
  OBSEventName,
} from './types';
import { OBSError } from './types';
import { OBSErrorCode } from './types/errors';
import type { NativeHuaweiObs } from './types/native';

const LINKING_ERROR =
  `The package 'react-native-huawei-obs' doesn't seem to be linked. Make sure: \n\n` +
  Platform.select({ ios: "- You have run 'pod install'\n", default: '' }) +
  '- You rebuilt the app after installing the package\n' +
  '- You are not using Expo Go\n';

const HuaweiObsNative = NativeModules.HuaweiObs
  ? (NativeModules.HuaweiObs as NativeHuaweiObs)
  : (new Proxy(
      {},
      {
        get() {
          throw new Error(LINKING_ERROR);
        },
      }
    ) as NativeHuaweiObs);

const eventEmitter = new NativeEventEmitter(NativeModules.HuaweiObs);

/**
 * OBS 客户端类
 * 面向对象 API，支持上传、下载、删除等操作
 */
export class OBSClient {
  private config: OBSClientConfig;
  private taskHandles: Map<string, TaskHandle<any>> = new Map();
  private eventListeners: Map<OBSEventName, Set<(...args: any[]) => void>> =
    new Map();
  private nativeListeners: { remove: () => void }[] = [];
  private isDestroyed: boolean = false;
  private initPromise: Promise<void>;
  private customDomain: string | null = null;
  private keyPrefix: string | null = null;

  /**
   * 创建 OBS 客户端实例
   * @param config OBS 配置
   */
  constructor(config: OBSClientConfig) {
    this.config = { ...config };
    if (config.customDomain) {
      // 统一去掉协议前缀和末尾斜杠，运行时加 https://
      this.customDomain = config.customDomain
        .replace(/^https?:\/\//, '')
        .replace(/\/$/, '');
    }
    if (config.keyPrefix) {
      // 去掉首尾斜杠，运行时自动添加 "/"
      this.keyPrefix = config.keyPrefix.replace(/^\/+/, '').replace(/\/+$/, '');
    }
    this.setupNativeListeners();
    this.initPromise = this.initializeClient();
  }

  /**
   * 等待原生客户端初始化完成
   * 在调用 upload/download 等操作前可先 await 此方法
   */
  ready(): Promise<void> {
    return this.initPromise;
  }

  /**
   * 为 objectKey 添加配置的前缀
   */
  private prefixKey(objectKey: string): string {
    return this.keyPrefix ? `${this.keyPrefix}/${objectKey}` : objectKey;
  }

  /**
   * 初始化原生客户端
   */
  private async initializeClient(): Promise<void> {
    try {
      await HuaweiObsNative.initClient(this.config as any);
    } catch (error: any) {
      throw this.mapNativeError(error);
    }
  }

  /**
   * 设置原生事件监听器
   */
  private setupNativeListeners(): void {
    // 上传事件
    this.nativeListeners.push(
      eventEmitter.addListener('uploadPreparing', (event) => {
        const handle = this.taskHandles.get(event.taskId);
        if (handle) {
          handle._emitPreparing(event.copyProgress ?? 0);
        }
        this.emit('uploadPreparing', event);
      })
    );

    this.nativeListeners.push(
      eventEmitter.addListener('uploadStart', (event) => {
        this.emit('uploadStart', event);
      })
    );

    this.nativeListeners.push(
      eventEmitter.addListener('uploadProgress', (event) => {
        const handle = this.taskHandles.get(event.taskId);
        if (handle) {
          handle._emitProgress(event);
        }
        this.emit('uploadProgress', event);
      })
    );

    this.nativeListeners.push(
      eventEmitter.addListener('uploadSuccess', (event) => {
        // 如果配置了自定义域名，替换 objectUrl
        const result = { ...event };
        if (this.customDomain && result.objectKey) {
          result.objectUrl = `https://${this.customDomain}/${result.objectKey}`;
        }
        const handle = this.taskHandles.get(result.taskId);
        if (handle) {
          handle._resolve(result);
          this.taskHandles.delete(result.taskId);
        }
        this.emit('uploadSuccess', result);
      })
    );

    this.nativeListeners.push(
      eventEmitter.addListener('uploadError', (event) => {
        const handle = this.taskHandles.get(event.taskId);
        const error = new OBSError({
          code: event.code,
          message: event.message,
          isRetryable: event.isRetryable ?? false,
        });
        if (handle) {
          handle._reject(error);
          this.taskHandles.delete(event.taskId);
        }
        this.emit('uploadError', error);
      })
    );

    this.nativeListeners.push(
      eventEmitter.addListener('uploadCancel', (event) => {
        const handle = this.taskHandles.get(event.taskId);
        if (handle) {
          handle._cancel(
            new OBSError({
              code: OBSErrorCode.TASK_CANCELED,
              message: 'Upload cancelled',
            })
          );
        }
        this.taskHandles.delete(event.taskId);
        this.emit('uploadCancel', event.taskId);
      })
    );

    // 下载事件
    this.nativeListeners.push(
      eventEmitter.addListener('downloadStart', (event) => {
        this.emit('downloadStart', event);
      })
    );

    this.nativeListeners.push(
      eventEmitter.addListener('downloadProgress', (event) => {
        const handle = this.taskHandles.get(event.taskId);
        if (handle) {
          handle._emitProgress(event);
        }
        this.emit('downloadProgress', event);
      })
    );

    this.nativeListeners.push(
      eventEmitter.addListener('downloadSuccess', (event) => {
        const handle = this.taskHandles.get(event.taskId);
        if (handle) {
          handle._resolve(event);
          this.taskHandles.delete(event.taskId);
        }
        this.emit('downloadSuccess', event);
      })
    );

    this.nativeListeners.push(
      eventEmitter.addListener('downloadError', (event) => {
        const handle = this.taskHandles.get(event.taskId);
        const error = new OBSError({
          code: event.code,
          message: event.message,
          isRetryable: event.isRetryable ?? false,
        });
        if (handle) {
          handle._reject(error);
          this.taskHandles.delete(event.taskId);
        }
        this.emit('downloadError', error);
      })
    );

    this.nativeListeners.push(
      eventEmitter.addListener('downloadCancel', (event) => {
        const handle = this.taskHandles.get(event.taskId);
        if (handle) {
          handle._cancel(
            new OBSError({
              code: OBSErrorCode.TASK_CANCELED,
              message: 'Download cancelled',
            })
          );
        }
        this.taskHandles.delete(event.taskId);
        this.emit('downloadCancel', event.taskId);
      })
    );
  }

  /**
   * 上传文件（自动判断普通/分片上传）
   */
  upload(
    filePath: string,
    objectKey: string,
    options?: UploadOptions
  ): TaskHandle<UploadResult> {
    this.checkNotDestroyed();

    const handle = new TaskHandle<UploadResult>(
      '', // taskId 由 native 返回
      'upload',
      async (taskId) => this.getTaskStatus(taskId),
      (taskId) => this.cancelUpload(taskId)
    );

    // 预先注册回调，避免事件在回调注册前触发导致丢失
    if (options?.onPreparing) {
      handle.onPreparing(options.onPreparing);
    }
    if (options?.onProgress) {
      handle.onProgress(options.onProgress as any);
    }
    if (options?.onSuccess) {
      handle.onSuccess(options.onSuccess);
    }
    if (options?.onError) {
      handle.onError(options.onError);
    }

    // 调用原生方法
    (async () => {
      try {
        // 等待原生客户端初始化完成
        await this.initPromise;

        const taskId = await HuaweiObsNative.upload({
          filePath,
          objectKey: this.prefixKey(objectKey),
          bucket: this.config.bucket,
          contentType: options?.contentType,
          metadata: options?.metadata,
          acl: options?.acl,
          storageClass: options?.storageClass,
        } as any);

        // 更新 taskId
        handle._setTaskId(taskId);

        // 保存 handle
        this.taskHandles.set(taskId, handle);

        // 触发回调
        options?.onStart?.(taskId);
      } catch (error: any) {
        const mappedError = this.mapNativeError(error);
        handle._reject(mappedError);
      }
    })();

    return handle;
  }

  /**
   * 分片上传文件
   */
  multipartUpload(
    filePath: string,
    objectKey: string,
    options?: MultipartUploadOptions
  ): TaskHandle<UploadResult> {
    this.checkNotDestroyed();

    const handle = new TaskHandle<UploadResult>(
      '',
      'upload',
      async (taskId) => this.getTaskStatus(taskId),
      (taskId) => this.cancelUpload(taskId)
    );

    // 预先注册回调
    if (options?.onPreparing) {
      handle.onPreparing(options.onPreparing);
    }
    if (options?.onProgress) {
      handle.onProgress(options.onProgress as any);
    }
    if (options?.onSuccess) {
      handle.onSuccess(options.onSuccess);
    }
    if (options?.onError) {
      handle.onError(options.onError);
    }

    (async () => {
      try {
        // 等待原生客户端初始化完成
        await this.initPromise;

        const taskId = await HuaweiObsNative.multipartUpload({
          filePath,
          objectKey: this.prefixKey(objectKey),
          bucket: this.config.bucket,
          contentType: options?.contentType,
          metadata: options?.metadata,
          acl: options?.acl,
          storageClass: options?.storageClass,
          partSize: options?.partSize,
          concurrency: options?.concurrency,
        } as any);

        handle._setTaskId(taskId);
        this.taskHandles.set(taskId, handle);

        options?.onStart?.(taskId);
      } catch (error: any) {
        const mappedError = this.mapNativeError(error);
        handle._reject(mappedError);
      }
    })();

    return handle;
  }

  /**
   * 下载文件
   */
  download(
    objectKey: string,
    savePath: string,
    options?: DownloadOptions
  ): TaskHandle<DownloadResult> {
    this.checkNotDestroyed();

    const handle = new TaskHandle<DownloadResult>(
      '',
      'download',
      async (taskId) => this.getTaskStatus(taskId),
      (taskId) => this.cancelDownload(taskId)
    );

    // 预先注册回调
    if (options?.onProgress) {
      handle.onProgress(options.onProgress as any);
    }
    if (options?.onSuccess) {
      handle.onSuccess(options.onSuccess);
    }
    if (options?.onError) {
      handle.onError(options.onError);
    }

    (async () => {
      try {
        // 等待原生客户端初始化完成
        await this.initPromise;

        const taskId = await HuaweiObsNative.download({
          objectKey: this.prefixKey(objectKey),
          bucket: this.config.bucket,
          savePath,
          range: options?.range,
          versionId: options?.versionId,
          partSize: options?.partSize,
          concurrency: options?.concurrency,
        } as any);

        handle._setTaskId(taskId);
        this.taskHandles.set(taskId, handle);
      } catch (error: any) {
        const mappedError = this.mapNativeError(error);
        handle._reject(mappedError);
      }
    })();

    return handle;
  }

  /**
   * 删除对象
   */
  async deleteObject(objectKey: string): Promise<void> {
    this.checkNotDestroyed();
    try {
      await HuaweiObsNative.deleteObject({
        bucket: this.config.bucket,
        objectKey: this.prefixKey(objectKey),
      });
    } catch (error: any) {
      throw this.mapNativeError(error);
    }
  }

  /**
   * 批量删除对象
   */
  async deleteObjects(objectKeys: string[]): Promise<DeleteResult[]> {
    this.checkNotDestroyed();
    try {
      const results = await HuaweiObsNative.deleteMultipleObjects({
        bucket: this.config.bucket,
        objectKeys: objectKeys.map((k) => this.prefixKey(k)),
      });
      return results as any as DeleteResult[];
    } catch (error: any) {
      throw this.mapNativeError(error);
    }
  }

  /**
   * 取消上传
   */
  private async cancelUpload(taskId: string): Promise<void> {
    if (!taskId) {
      return; // taskId not yet set (cancel called before native upload started)
    }
    try {
      await HuaweiObsNative.cancelUpload(taskId);
      // 不在此处删除 handle：等待原生 uploadCancel 事件触发后统一清理并 reject promise
    } catch (error: any) {
      throw this.mapNativeError(error);
    }
  }

  /**
   * 取消下载
   */
  private async cancelDownload(taskId: string): Promise<void> {
    if (!taskId) {
      return; // taskId not yet set (cancel called before native download started)
    }
    try {
      await HuaweiObsNative.cancelDownload(taskId);
      // 不在此处删除 handle：等待原生 downloadCancel 事件触发后统一清理并 reject promise
    } catch (error: any) {
      throw this.mapNativeError(error);
    }
  }

  /**
   * 获取任务状态
   */
  async getTaskStatus(taskId: string): Promise<TaskStatus | null> {
    this.checkNotDestroyed();
    try {
      const status = await HuaweiObsNative.getTaskStatus(taskId);
      return status as TaskStatus | null;
    } catch {
      return null;
    }
  }

  /**
   * 获取所有任务
   */
  async getAllTasks(): Promise<TaskStatus[]> {
    this.checkNotDestroyed();
    try {
      const tasks = await HuaweiObsNative.getAllTasks();
      return tasks as TaskStatus[];
    } catch (error: any) {
      throw this.mapNativeError(error);
    }
  }

  /**
   * 清除已完成的任务
   */
  async clearCompletedTasks(): Promise<void> {
    this.checkNotDestroyed();
    try {
      await HuaweiObsNative.clearCompletedTasks();
    } catch (error: any) {
      throw this.mapNativeError(error);
    }
  }

  /**
   * 更新配置
   */
  async updateConfig(config: Partial<OBSClientConfig>): Promise<void> {
    this.checkNotDestroyed();
    try {
      await HuaweiObsNative.updateConfig(config as any);
      this.config = { ...this.config, ...config };
      if ('customDomain' in config) {
        this.customDomain = config.customDomain
          ? config.customDomain.replace(/^https?:\/\//, '').replace(/\/$/, '')
          : null;
      }
      if ('keyPrefix' in config) {
        this.keyPrefix = config.keyPrefix
          ? config.keyPrefix.replace(/^\/+/, '').replace(/\/+$/, '')
          : null;
      }
    } catch (error: any) {
      throw this.mapNativeError(error);
    }
  }

  /**
   * 获取当前配置（脱敏）
   */
  getConfig(): Readonly<OBSClientConfig> {
    const safeCopy = { ...this.config };
    // 脱敏：隐藏敏感信息
    if (safeCopy.secretAccessKey) {
      safeCopy.secretAccessKey = '***';
    }
    if (safeCopy.securityToken) {
      safeCopy.securityToken = '***';
    }
    return Object.freeze(safeCopy);
  }

  /**
   * 验证配置有效性
   */
  async validateConfig(): Promise<boolean> {
    this.checkNotDestroyed();
    try {
      return await HuaweiObsNative.validateConfig();
    } catch (error: any) {
      return false;
    }
  }

  /**
   * 订阅事件
   */
  on(eventName: OBSEventName, listener: (...args: any[]) => void): this {
    if (!this.eventListeners.has(eventName)) {
      this.eventListeners.set(eventName, new Set());
    }
    this.eventListeners.get(eventName)!.add(listener);
    return this;
  }

  /**
   * 取消订阅事件
   */
  off(eventName: OBSEventName, listener?: (...args: any[]) => void): this {
    if (!listener) {
      this.eventListeners.delete(eventName);
    } else {
      this.eventListeners.get(eventName)?.delete(listener);
    }
    return this;
  }

  /**
   * 订阅一次性事件
   */
  once(eventName: OBSEventName, listener: (...args: any[]) => void): this {
    const onceListener = (...args: any[]) => {
      listener(...args);
      this.off(eventName, onceListener);
    };
    return this.on(eventName, onceListener);
  }

  /**
   * 移除所有事件监听器
   */
  removeAllListeners(eventName?: OBSEventName): this {
    if (eventName) {
      this.eventListeners.delete(eventName);
    } else {
      this.eventListeners.clear();
    }
    return this;
  }

  /**
   * 销毁客户端
   */
  async destroy(): Promise<void> {
    if (this.isDestroyed) return;

    try {
      // 移除所有事件监听器
      this.nativeListeners.forEach((listener) => listener.remove());
      this.nativeListeners = [];
      this.eventListeners.clear();

      // reject 所有未完成的任务句柄，防止 promise 永久挂起
      const destroyError = new OBSError({
        code: OBSErrorCode.UNKNOWN,
        message: 'OBS client has been destroyed',
      });
      this.taskHandles.forEach((handle) => handle._cancel(destroyError));
      this.taskHandles.clear();

      // 销毁原生客户端
      await HuaweiObsNative.destroy();

      this.isDestroyed = true;
    } catch (error: any) {
      throw this.mapNativeError(error);
    }
  }

  /**
   * 检查是否已销毁
   */
  isClientDestroyed(): boolean {
    return this.isDestroyed;
  }

  /**
   * 内部方法：发射事件
   */
  private emit(eventName: string, data: any): void {
    const listeners = this.eventListeners.get(eventName as OBSEventName);
    if (listeners) {
      listeners.forEach((listener) => {
        try {
          listener(data);
        } catch (error) {
          console.error(`Error in event listener for ${eventName}:`, error);
        }
      });
    }
  }

  /**
   * 映射原生错误
   */
  private mapNativeError(error: any): OBSError {
    if (error instanceof OBSError) {
      return error;
    }

    return new OBSError({
      code: error.code || OBSErrorCode.UNKNOWN,
      message: error.message || 'Unknown error',
      statusCode: error.statusCode,
      requestId: error.requestId,
      hostId: error.hostId,
      isRetryable: error.isRetryable ?? false,
      rawError: error,
    });
  }

  /**
   * 检查客户端未销毁
   */
  private checkNotDestroyed(): void {
    if (this.isDestroyed) {
      throw new OBSError({
        code: OBSErrorCode.UNKNOWN,
        message: 'OBS client has been destroyed',
      });
    }
  }
}
