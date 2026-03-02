# react-native-huawei-obs

华为云 OBS (对象存储服务) React Native SDK。支持文件上传（自动分片）、下载、删除，提供完整的进度回调和任务控制。

## 底层 SDK 版本

| 平台 | SDK | 版本 |
|---|---|---|
| Android | [esdk-obs-android](https://github.com/huaweicloud/huaweicloud-sdk-java-obs) | 3.25.4 |
| iOS | [esdk-obs-ios](https://github.com/huaweicloud/huaweicloud-sdk-c-obs) | 3.25.6 |

## 安装

```bash
npm install react-native-huawei-obs
# 或
yarn add react-native-huawei-obs
```

### iOS

```bash
cd ios && pod install
```

## 快速开始

```typescript
import { OBSClient } from 'react-native-huawei-obs';

const client = new OBSClient({
  endpoint: 'obs.cn-north-4.myhuaweicloud.com',
  bucket: 'my-bucket',
  accessKeyId: 'your-ak',
  secretAccessKey: 'your-sk',
  securityToken: 'sts-token',       // STS 临时凭证（可选）
  tokenExpiryTime: 1700000000000,   // 过期时间戳 ms（可选）
});

// 等待初始化完成
await client.ready();
```

---

## API

### 构造函数

#### `new OBSClient(config: OBSClientConfig)`

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `endpoint` | `string` | ✅ | OBS 服务端点，如 `obs.cn-north-4.myhuaweicloud.com` |
| `bucket` | `string` | ✅ | 桶名 |
| `accessKeyId` | `string` | ✅ | 访问密钥 ID (AK) |
| `secretAccessKey` | `string` | ✅ | 访问密钥 (SK) |
| `securityToken` | `string` | - | STS 安全令牌 |
| `tokenExpiryTime` | `number` | - | 令牌过期时间戳 (ms) |
| `region` | `string` | - | 区域，如 `cn-north-4` |
| `connectionTimeout` | `number` | - | 连接超时（秒），默认 `60` |
| `socketTimeout` | `number` | - | Socket 超时（秒），默认 `60` |
| `maxErrorRetry` | `number` | - | 最大重试次数，默认 `3` |
| `isHttps` | `boolean` | - | 是否启用 HTTPS，默认 `true` |
| `pathStyle` | `boolean` | - | 使用路径样式访问，默认 `false` |
| `maxConcurrency` | `number` | - | 全局并发上限 1-10，默认 `6` |
| `defaultPartSize` | `number` | - | 默认分片大小（字节），默认自适应 |
| `customDomain` | `string` | - | 自定义域名，用于上传后 URL 拼接 |
| `keyPrefix` | `string` | - | 对象键前缀，如 `"avatar"` 或 `"chat/images"`，自动加到所有操作的 objectKey 前 |

---

### `client.ready(): Promise<void>`

等待原生客户端初始化完成。

```typescript
await client.ready();
```

---

### 上传

#### `client.upload(filePath, objectKey, options?): TaskHandle<UploadResult>`

上传文件，自动判断使用普通上传（≤5MB）或分片上传（>5MB）。

```typescript
const handle = client.upload(
  'content://...', // 或 'file:///path/to/file.mp4'
  'videos/my-video.mp4',
  {
    onPreparing: (copyProgress) => {
      // content:// 文件复制进度 (0 ~ 100 整数)
      console.log(`准备中: ${copyProgress}%`);
    },
    onStart: (taskId) => {
      console.log('上传开始, taskId:', taskId);
    },
    onProgress: (progress) => {
      console.log(`进度: ${progress.percentage}%`);
    },
    onSuccess: (result) => {
      console.log('上传成功:', result.objectUrl);
    },
    onError: (error) => {
      console.error('上传失败:', error.code, error.message);
    },
  }
);
```

**参数：**

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `filePath` | `string` | ✅ | 文件路径，支持 `file://`、`content://`、绝对路径 |
| `objectKey` | `string` | ✅ | 对象键名（OBS 中的路径） |
| `options` | `UploadOptions` | - | 上传选项 |

**`UploadOptions`：**

| 字段 | 类型 | 说明 |
|---|---|---|
| `contentType` | `string` | MIME 类型，默认根据扩展名自动识别 |
| `metadata` | `Record<string, string>` | 自定义元数据 |
| `storageClass` | `'STANDARD' \| 'WARM' \| 'COLD'` | 存储类型 |
| `acl` | `'private' \| 'public-read' \| 'public-read-write'` | ACL 权限 |
| `onPreparing` | `(copyProgress: number) => void` | 文件准备进度（content:// 复制） |
| `onStart` | `(taskId: string) => void` | 上传开始 |
| `onProgress` | `(progress: UploadProgress) => void` | 上传进度 |
| `onSuccess` | `(result: UploadResult) => void` | 上传成功 |
| `onError` | `(error: OBSError) => void` | 上传失败 |

**返回：`TaskHandle<UploadResult>`**

---

### 分片上传

#### `client.multipartUpload(filePath, objectKey, options?): TaskHandle<UploadResult>`

与 `upload` 相同，额外支持指定分片大小和并发数。

**额外 `MultipartUploadOptions`：**

| 字段 | 类型 | 说明 |
|---|---|---|
| `partSize` | `number` | 分片大小（字节），范围 5MB-5GB，默认自适应 |
| `concurrency` | `number` | 并发上传数 1-10，默认 `6` |
| `onPartComplete` | `(info: PartCompleteInfo) => void` | 分片完成回调 |
| `onPause` | `(taskId: string) => void` | 暂停回调 |
| `onResume` | `(taskId: string) => void` | 恢复回调 |
| `onCancel` | `(taskId: string) => void` | 取消回调 |

**分片自适应策略：**

| 文件大小 | 分片大小 |
|---|---|
| < 500MB | 5MB |
| ≥ 500MB | 10MB |

---

### 下载

#### `client.download(objectKey, savePath, options?): TaskHandle<DownloadResult>`

```typescript
const handle = client.download(
  'videos/my-video.mp4',
  '/path/to/save/video.mp4',
  {
    onProgress: (progress) => {
      console.log(`下载: ${progress.percentage}%`);
    },
    onSuccess: (result) => {
      console.log('下载完成:', result.savePath);
    },
    onError: (error) => {
      console.error('下载失败:', error.code);
    },
  }
);
```

**`DownloadOptions`：**

| 字段 | 类型 | 说明 |
|---|---|---|
| `range` | `string` | 下载范围，如 `"bytes=0-1023"` |
| `versionId` | `string` | 版本 ID |
| `partSize` | `number` | 分片大小（字节） |
| `concurrency` | `number` | 并发数 1-10 |
| `onProgress` | `(progress: DownloadProgress) => void` | 下载进度 |
| `onSuccess` | `(result: DownloadResult) => void` | 下载成功 |
| `onError` | `(error: OBSError) => void` | 下载失败 |

---

### 删除

#### `client.deleteObject(objectKey): Promise<void>`

```typescript
await client.deleteObject('videos/my-video.mp4');
```

#### `client.deleteObjects(objectKeys): Promise<DeleteResult[]>`

```typescript
const results = await client.deleteObjects([
  'videos/a.mp4',
  'videos/b.mp4',
]);
```

---

### 任务控制

#### `TaskHandle` 方法

```typescript
const handle = client.upload(filePath, objectKey, options);

// 取消任务
await handle.cancel();

// 等待任务完成（Promise）
const result = await handle.promise();

// 链式监听
handle
  .onPreparing((copyProgress) => { ... })
  .onProgress((progress) => { ... })
  .onSuccess((result) => { ... })
  .onError((error) => { ... });

// 移除监听
handle.removeAllListeners();
```

---

### 全局事件

```typescript
// 订阅
client.on('uploadProgress', (progress) => { ... });
client.on('uploadSuccess', (result) => { ... });
client.on('uploadError', (error) => { ... });
client.on('uploadCancel', (taskId) => { ... });

// 取消订阅
client.off('uploadProgress', listener);

// 一次性订阅
client.once('uploadSuccess', (result) => { ... });
```

**所有事件名：**

| 事件名 | 触发数据 | 说明 |
|---|---|---|
| `uploadPreparing` | `{ taskId, objectKey, copyProgress }` | 文件准备中（content:// 复制） |
| `uploadStart` | `{ taskId, objectKey, totalBytes }` | 上传开始 |
| `uploadProgress` | `UploadProgress` | 上传进度 |
| `partComplete` | `PartCompleteInfo` | 分片完成 |
| `uploadSuccess` | `UploadResult` | 上传成功 |
| `uploadError` | `OBSError` | 上传失败 |
| `uploadCancel` | `taskId: string` | 上传取消 |
| `uploadPause` | `taskId: string` | 上传暂停 |
| `uploadResume` | `taskId: string` | 上传恢复 |
| `downloadStart` | `{ taskId, objectKey, totalBytes }` | 下载开始 |
| `downloadProgress` | `DownloadProgress` | 下载进度 |
| `downloadSuccess` | `DownloadResult` | 下载成功 |
| `downloadError` | `OBSError` | 下载失败 |
| `downloadCancel` | `taskId: string` | 下载取消 |

---

### 其他方法

```typescript
// 更新配置（如刷新 STS 凭证）
await client.updateConfig({
  accessKeyId: 'new-ak',
  secretAccessKey: 'new-sk',
  securityToken: 'new-token',
  tokenExpiryTime: Date.now() + 3600000,
});

// 验证配置有效性
const isValid = await client.validateConfig();

// 获取脱敏配置
const config = client.getConfig();

// 获取所有任务
const tasks = await client.getAllTasks();

// 清除已完成任务
await client.clearCompletedTasks();

// 销毁客户端
await client.destroy();
```

---

## 回调数据结构

### `UploadProgress` — 上传进度

```typescript
{
  taskId: string;           // 任务 ID
  transferredBytes: number; // 已传输字节数
  totalBytes: number;       // 总字节数
  percentage: number;       // 进度 0 ~ 100 整数
  currentPart?: number;     // 当前分片号
  totalParts?: number;      // 总分片数
  completedParts?: number;  // 已完成分片数
  instantSpeed?: number;    // 瞬时速度（字节/秒）
  avgSpeed?: number;        // 平均速度（字节/秒）
  remainingTime?: number;   // 预计剩余时间（秒）
}
```

### `UploadResult` — 上传结果

```typescript
{
  taskId: string;      // 任务 ID
  objectKey: string;   // 对象键名
  bucket: string;      // 桶名
  etag: string;        // ETag 校验值
  versionId?: string;  // 版本 ID（桶开启版本控制时返回）
  objectUrl: string;   // 访问 URL（支持 customDomain 替换）
  size: number;        // 文件大小（字节）
  duration: number;    // 上传耗时（毫秒）
  avgSpeed: number;    // 平均速度（字节/秒）
}
```

### `DownloadProgress` — 下载进度

```typescript
{
  taskId: string;           // 任务 ID
  downloadedBytes: number;  // 已下载字节数
  totalBytes: number;       // 总字节数
  percentage: number;       // 进度 0 ~ 100 整数
  instantSpeed?: number;    // 瞬时速度（字节/秒）
  avgSpeed?: number;        // 平均速度（字节/秒）
  remainingTime?: number;   // 预计剩余时间（秒）
}
```

### `DownloadResult` — 下载结果

```typescript
{
  taskId: string;      // 任务 ID
  objectKey: string;   // 对象键名
  savePath: string;    // 本地保存路径
  size: number;        // 文件大小（字节）
  etag: string;        // ETag
  duration: number;    // 下载耗时（毫秒）
  avgSpeed: number;    // 平均速度（字节/秒）
}
```

### `DeleteResult` — 删除结果

```typescript
{
  objectKey: string;       // 对象键名
  success: boolean;        // 是否成功
  errorCode?: string;      // 错误码（失败时）
  errorMessage?: string;   // 错误信息（失败时）
  versionId?: string;      // 版本 ID
}
```

### `PartCompleteInfo` — 分片完成信息

```typescript
{
  taskId: string;         // 任务 ID
  partNumber: number;     // 分片序号
  etag: string;           // 分片 ETag
  uploadedBytes: number;  // 已上传总字节数
}
```

### `OBSError` — 错误对象

```typescript
{
  code: string;            // 错误码（见下方错误码表）
  message: string;         // 错误描述
  statusCode?: number;     // HTTP 状态码
  requestId?: string;      // 请求 ID
  hostId?: string;         // 主机 ID
  isRetryable: boolean;    // 是否可重试
}
```

---

## 错误码

### SDK 错误码

| 错误码 | 说明 |
|---|---|
| `E_UNKNOWN` | 未知错误 |
| `E_INVALID_ARGUMENT` | 参数无效 |
| `E_NOT_IMPLEMENTED` | 功能未实现 |

### 鉴权错误

| 错误码 | 说明 |
|---|---|
| `E_AUTH_INVALID_CREDENTIAL` | 凭证无效（AK/SK 错误、Token 格式错误） |
| `E_AUTH_EXPIRED` | 凭证已过期 |
| `E_AUTH_SIGN_FAILED` | 签名失败 |
| `E_AUTH_PERMISSION_DENIED` | 权限不足 |
| `E_AUTH_ACCESS_DENIED` | 访问被拒绝（OBS 服务端 AccessDenied） |
| `E_AUTH_SIGNATURE_MISMATCH` | 签名不匹配（SignatureDoesNotMatch） |

### 网络错误

| 错误码 | 说明 |
|---|---|
| `E_NETWORK_TIMEOUT` | 连接超时 |
| `E_NETWORK_ERROR` | 网络错误 |
| `E_NETWORK_UNAVAILABLE` | 网络不可用 |

### 文件错误

| 错误码 | 说明 |
|---|---|
| `E_FILE_NOT_FOUND` | 文件不存在 |
| `E_FILE_NOT_READABLE` | 文件不可读 |
| `E_FILE_WRITE_ERROR` | 文件写入失败 |

### 桶/资源错误

| 错误码 | 说明 |
|---|---|
| `E_BUCKET_NOT_FOUND` | 桶不存在（NoSuchBucket） |

### HTTP 错误

| 错误码 | 说明 |
|---|---|
| `E_HTTP_4XX` | 4xx 客户端错误 |
| `E_HTTP_5XX` | 5xx 服务端错误 |

### 流管理错误

| 错误码 | 说明 |
|---|---|
| `E_STREAM_NOT_FOUND` | 文件流不存在 |
| `E_STREAM_CLOSED` | 文件流已关闭 |
| `E_INVALID_OFFSET` | 无效的偏移量 |
| `E_READ_ERROR` | 读取错误 |

### 上传错误

| 错误码 | 说明 |
|---|---|
| `E_UPLOAD_INIT_FAILED` | 初始化分片上传失败 |
| `E_UPLOAD_PART_FAILED` | 分片上传失败 |
| `E_UPLOAD_COMPLETE_FAILED` | 完成分片上传失败 |
| `E_UPLOAD_ABORTED` | 上传已中止 |
| `E_UPLOAD_NOT_FOUND` | 上传任务不存在（NoSuchUpload） |

### 下载错误

| 错误码 | 说明 |
|---|---|
| `E_DOWNLOAD_FAILED` | 下载失败 |

### 任务错误

| 错误码 | 说明 |
|---|---|
| `E_TASK_NOT_FOUND` | 任务不存在 |
| `E_TASK_CANCELED` | 任务已取消 |
| `E_TASK_PAUSED` | 任务已暂停 |
| `E_CANCELLED` | 任务已被取消 |

### 并发错误

| 错误码 | 说明 |
|---|---|
| `E_CONCURRENCY_LIMIT_EXCEEDED` | 超过并发上限 |
| `E_MEMORY_INSUFFICIENT` | 内存不足 |

---

## 完整示例

```typescript
import { OBSClient } from 'react-native-huawei-obs';
import { pick } from '@react-native-documents/picker';

// 1. 创建客户端
const client = new OBSClient({
  endpoint: 'obs.cn-north-4.myhuaweicloud.com',
  bucket: 'my-bucket',
  accessKeyId: 'AK',
  secretAccessKey: 'SK',
  securityToken: 'STS_TOKEN',
  customDomain: 'cdn.example.com',
  keyPrefix: 'avatar', // 上传到 avatar/ 目录下
});

// 2. 等待初始化
await client.ready();

// 3. 选择并上传文件
const [file] = await pick({ type: ['*/*'] });

const handle = client.upload(file.uri, `uploads/${file.name}`, {
  onPreparing: (p) => console.log(`准备: ${p}%`),
  onProgress: (p) => console.log(`上传: ${p.percentage}%`),
  onSuccess: (r) => console.log('URL:', r.objectUrl),
  onError: (e) => console.error(e.code, e.message),
});

// 4. 可随时取消
// await handle.cancel();

// 5. 或等待完成
const result = await handle.promise();
console.log('上传完成:', result);

// 6. 销毁
await client.destroy();
```

## License

MIT
