import type {
  TaskType,
  TaskStatus,
  Progress,
  UploadResult,
  DownloadResult,
} from './types';
import { OBSError } from './types';

/**
 * Deferred Promise 辅助类
 */
class Deferred<T> {
  public promise: Promise<T>;
  public resolve!: (value: T) => void;
  public reject!: (reason?: any) => void;

  constructor() {
    this.promise = new Promise<T>((resolve, reject) => {
      this.resolve = resolve;
      this.reject = reject;
    });
  }
}

/**
 * 任务句柄
 * 代表一个上传或下载任务，提供控制方法和状态查询
 */
export class TaskHandle<T extends UploadResult | DownloadResult> {
  private _taskId: string;
  public readonly type: TaskType;

  /**
   * 获取任务 ID
   */
  get taskId(): string {
    return this._taskId;
  }

  private deferred: Deferred<T>;
  private listeners: {
    progress: Set<(progress: Progress) => void>;
    success: Set<(result: T) => void>;
    error: Set<(error: OBSError) => void>;
    preparing: Set<(copyProgress: number) => void>;
  };

  constructor(
    taskId: string,
    type: TaskType,
    private getStatusFn: (taskId: string) => Promise<TaskStatus | null>,
    private cancelFn?: (taskId: string) => Promise<void>
  ) {
    this._taskId = taskId;
    this.type = type;
    this.deferred = new Deferred<T>();
    this.listeners = {
      progress: new Set(),
      success: new Set(),
      error: new Set(),
      preparing: new Set(),
    };
  }

  /**
   * 内部方法：设置任务 ID（由 OBSClient 在获得原生 taskId 后调用）
   */
  _setTaskId(taskId: string): void {
    this._taskId = taskId;
  }

  /**
   * 获取任务 Promise
   * @returns Promise，任务完成时 resolve，取消或失败时 reject
   */
  promise(): Promise<T> {
    return this.deferred.promise;
  }

  /**
   * 取消任务
   */
  async cancel(): Promise<void> {
    if (!this.cancelFn) {
      throw new OBSError({
        code: 'E_NOT_IMPLEMENTED',
        message: 'Cancel function not available',
      });
    }

    await this.cancelFn(this.taskId);
  }

  /**
   * 获取当前任务状态（实时，由原生提供）
   */
  async status(): Promise<TaskStatus> {
    const status = await this.getStatusFn(this.taskId);
    if (!status) {
      throw new OBSError({
        code: 'E_TASK_NOT_FOUND',
        message: `Task ${this.taskId} not found`,
      });
    }
    return status;
  }

  /**
   * 订阅文件准备事件（上传前 content:// 文件复制进度）
   */
  onPreparing(listener: (copyProgress: number) => void): this {
    this.listeners.preparing.add(listener);
    return this;
  }

  /**
   * 订阅进度事件
   * 优先级高于全局事件监听器
   */
  onProgress(listener: (progress: Progress) => void): this {
    this.listeners.progress.add(listener as (progress: Progress) => void);
    return this;
  }

  /**
   * 订阅成功事件
   */
  onSuccess(listener: (result: T) => void): this {
    this.listeners.success.add(listener);
    return this;
  }

  /**
   * 订阅失败事件
   */
  onError(listener: (error: OBSError) => void): this {
    this.listeners.error.add(listener);
    return this;
  }

  /**
   * 移除指定监听器
   */
  off(
    type: 'progress' | 'success' | 'error',
    listener:
      | ((progress: Progress) => void)
      | ((result: T) => void)
      | ((error: OBSError) => void)
  ): this {
    if (type === 'progress') {
      this.listeners.progress.delete(listener as (progress: Progress) => void);
    } else if (type === 'success') {
      this.listeners.success.delete(listener as (result: T) => void);
    } else if (type === 'error') {
      this.listeners.error.delete(listener as (error: OBSError) => void);
    }
    return this;
  }

  /**
   * 移除所有监听器
   */
  removeAllListeners(): void {
    this.listeners.progress.clear();
    this.listeners.success.clear();
    this.listeners.error.clear();
    this.listeners.preparing.clear();
  }

  /**
   * 内部方法：触发准备事件（文件复制进度）
   */
  _emitPreparing(copyProgress: number): void {
    this.listeners.preparing.forEach((listener) => {
      try {
        listener(copyProgress);
      } catch (error) {
        console.error('Error in preparing listener:', error);
      }
    });
  }

  /**
   * 内部方法：触发进度事件
   */
  _emitProgress(progress: Progress): void {
    this.listeners.progress.forEach((listener) => {
      try {
        listener(progress);
      } catch (error) {
        console.error('Error in progress listener:', error);
      }
    });
  }

  /**
   * 内部方法：触发成功事件并 resolve Promise
   */
  _resolve(result: T): void {
    this.listeners.success.forEach((listener) => {
      try {
        listener(result);
      } catch (error) {
        console.error('Error in success listener:', error);
      }
    });
    this.deferred.resolve(result);
  }

  /**
   * 内部方法：触发失败事件并 reject Promise
   */
  _reject(error: OBSError): void {
    this.listeners.error.forEach((listener) => {
      try {
        listener(error);
      } catch (e) {
        console.error('Error in error listener:', e);
      }
    });
    this.deferred.reject(error);
  }

  /**
   * 内部方法：取消任务，仅 reject Promise，不触发 onError 回调
   */
  _cancel(error: OBSError): void {
    this.deferred.reject(error);
  }
}
