import React, { useState, useEffect } from 'react';
import {
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  View,
  TouchableOpacity,
  Alert,
  ActivityIndicator,
  TextInput,
  NativeModules,
  Share,
  Platform,
} from 'react-native';
import { OBSClient, TaskHandle } from 'react-native-huawei-obs';
import type { UploadResult } from 'react-native-huawei-obs';
import { pick } from '@react-native-documents/picker';
import { launchImageLibrary } from 'react-native-image-picker';
import RNFS from 'react-native-fs';

const HuaweiObsNative = NativeModules.HuaweiObs;

// 配置信息（请替换为你的实际配置）
const OBS_CONFIG = {
  endpoint: 'https://obs.cn-north-4.myhuaweicloud.com',
  bucket: 'your-bucket-name',
  accessKeyId: 'YOUR_ACCESS_KEY',
  secretAccessKey: 'YOUR_SECRET_KEY',
  customDomain: '',
  keyPrefix: '',
  timeout: 60000,
  maxRetries: 3,
  enableLog: true,
};

interface UploadTask {
  id: string;
  fileName: string;
  objectKey: string;
  progress: number;
  preparing: boolean;
  copyProgress: number;
  completedParts: number;
  totalParts: number;
  status: 'uploading' | 'success' | 'failed' | 'cancelled';
  handle: TaskHandle<UploadResult> | null;
  error?: string;
}

type OBSConfigState = {
  endpoint: string;
  bucket: string;
  accessKeyId: string;
  secretAccessKey: string;
  securityToken?: string;
  customDomain: string;
  keyPrefix: string;
  timeout: number;
  maxRetries: number;
  enableLog: boolean;
};

export default function App() {
  const [client, setClient] = useState<OBSClient | null>(null);
  const [uploadTasks, setUploadTasks] = useState<UploadTask[]>([]);
  const [isInitializing, setIsInitializing] = useState(true);
  const [uploadedFiles, setUploadedFiles] = useState<
    Array<{
      fileName: string;
      objectKey: string;
      downloadProgress: number;
      downloadStatus: 'idle' | 'downloading' | 'success' | 'failed';
      downloadPath?: string;
    }>
  >([]);
  const [config, setConfig] = useState<OBSConfigState>({
    endpoint: OBS_CONFIG.endpoint,
    bucket: OBS_CONFIG.bucket,
    accessKeyId: OBS_CONFIG.accessKeyId,
    secretAccessKey: OBS_CONFIG.secretAccessKey,
    securityToken: '',
    customDomain: OBS_CONFIG.customDomain,
    keyPrefix: OBS_CONFIG.keyPrefix,
    timeout: OBS_CONFIG.timeout,
    maxRetries: OBS_CONFIG.maxRetries,
    enableLog: OBS_CONFIG.enableLog,
  });
  const [jsonInput, setJsonInput] = useState('');
  const taskCountRef = React.useRef(0);

  useEffect(() => {
    let currentClient: OBSClient | null = null;

    const init = async () => {
      try {
        const applyConfig = config;
        const obsClient = new OBSClient({
          endpoint: applyConfig.endpoint,
          bucket: applyConfig.bucket,
          accessKeyId: applyConfig.accessKeyId,
          secretAccessKey: applyConfig.secretAccessKey,
          securityToken: applyConfig.securityToken || undefined,
          customDomain: applyConfig.customDomain || undefined,
          connectionTimeout: applyConfig.timeout,
          socketTimeout: applyConfig.timeout,
          maxErrorRetry: applyConfig.maxRetries,
        });

        // 等待原生客户端初始化完成后再暴露给 UI
        await obsClient.ready();

        currentClient = obsClient;
        setClient(obsClient);
        console.log('OBS 客户端初始化成功');
      } catch (error: unknown) {
        const message = error instanceof Error ? error.message : '未知错误';
        Alert.alert('初始化失败', message);
        console.error('初始化失败:', error);
      } finally {
        setIsInitializing(false);
      }
    };

    init();

    return () => {
      currentClient?.destroy();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const initializeClient = async (nextConfig?: OBSConfigState) => {
    try {
      const applyConfig = nextConfig ?? config;

      const obsClient = new OBSClient({
        endpoint: applyConfig.endpoint,
        bucket: applyConfig.bucket,
        accessKeyId: applyConfig.accessKeyId,
        secretAccessKey: applyConfig.secretAccessKey,
        securityToken: applyConfig.securityToken || undefined,
        customDomain: applyConfig.customDomain || undefined,
        connectionTimeout: applyConfig.timeout,
        socketTimeout: applyConfig.timeout,
        maxErrorRetry: applyConfig.maxRetries,
      });

      // 等待原生客户端初始化完成后再暴露给 UI
      await obsClient.ready();

      setClient(obsClient);
      console.log('OBS 客户端初始化成功');
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : '未知错误';
      Alert.alert('初始化失败', message);
      console.error('初始化失败:', error);
    } finally {
      setIsInitializing(false);
    }
  };

  const parseAndApplyJson = async () => {
    let parsed: Record<string, unknown>;
    try {
      parsed = JSON.parse(jsonInput.trim());
    } catch {
      Alert.alert('JSON 格式错误', '请检查输入的 JSON 是否合法');
      return;
    }
    const str = (key: string, fallback = '') =>
      typeof parsed[key] === 'string'
        ? (parsed[key] as string).trim()
        : fallback;
    const num = (key: string, fallback: number) =>
      typeof parsed[key] === 'number' ? (parsed[key] as number) : fallback;

    const next: OBSConfigState = {
      endpoint: str('endpoint', config.endpoint),
      bucket: str('bucket', config.bucket),
      accessKeyId: str('accessKeyId', config.accessKeyId),
      secretAccessKey: str('secretAccessKey', config.secretAccessKey),
      securityToken: str('securityToken', ''),
      customDomain: str('customDomain', config.customDomain),
      keyPrefix: str('keyPrefix', config.keyPrefix),
      timeout: num('timeout', config.timeout),
      maxRetries: num('maxRetries', config.maxRetries),
      enableLog:
        typeof parsed.enableLog === 'boolean'
          ? (parsed.enableLog as boolean)
          : config.enableLog,
    };

    if (
      !next.endpoint ||
      !next.bucket ||
      !next.accessKeyId ||
      !next.secretAccessKey
    ) {
      Alert.alert(
        '配置不完整',
        '请确保 JSON 中包含 endpoint、bucket、accessKeyId、secretAccessKey'
      );
      return;
    }

    setConfig(next);
    setIsInitializing(true);
    await client?.destroy();
    await initializeClient(next);
  };

  const pickAndUploadFile = async () => {
    if (!client) {
      Alert.alert('错误', '客户端未初始化');
      return;
    }

    try {
      // 选择文件
      const results = await pick({});

      if (!results || results.length === 0) {
        return;
      }

      const result = results[0];
      let fileName = result.name || '';
      const filePath = result.uri;

      // 如果 DocumentPicker 没有返回文件名，从原生层获取
      if (!fileName && HuaweiObsNative && HuaweiObsNative.openFileStream) {
        try {
          const fileInfo = await HuaweiObsNative.openFileStream(filePath);
          fileName = fileInfo.fileName || 'unknown';
          // 关闭该文件流，因为我们只是为了获取文件名
          await HuaweiObsNative.closeStream(fileInfo.streamId).catch(() => {});
        } catch (err) {
          console.warn('获取文件名失败，使用默认名称', err);
          fileName = 'unknown';
        }
      } else if (!fileName) {
        fileName = 'unknown';
      }

      // 拼接 key 前缀：去掉末尾斜杠，避免双斜杠
      const prefix = config.keyPrefix.replace(/\/$/, '');
      const objectKey = prefix
        ? `${prefix}/${Date.now()}_${fileName}`
        : `${Date.now()}_${fileName}`;

      // 创建任务（使用递增计数器避免重复 ID）
      const taskId = `task_${++taskCountRef.current}`;
      const task: UploadTask = {
        id: taskId,
        fileName,
        objectKey,
        progress: 0,
        preparing: true,
        copyProgress: 0,
        completedParts: 0,
        totalParts: 0,
        status: 'uploading',
        handle: null,
      };

      setUploadTasks((prev) => [...prev, task]);

      // 开始上传
      const handle = client.upload(filePath, objectKey, {
        contentType: result.type || 'application/octet-stream',
        onPreparing: (copyProgress) => {
          setUploadTasks((prev) =>
            prev.map((t) =>
              t.id === taskId ? { ...t, preparing: true, copyProgress } : t
            )
          );
        },
        onProgress: (progress) => {
          setUploadTasks((prev) =>
            prev.map((t) =>
              t.id === taskId
                ? {
                    ...t,
                    preparing: false,
                    progress: progress.percentage,
                    completedParts: progress.completedParts ?? t.completedParts,
                    totalParts: progress.totalParts ?? t.totalParts,
                  }
                : t
            )
          );
        },
        onSuccess: (uploadResult) => {
          console.log('上传成功:', uploadResult);
          setUploadTasks((prev) =>
            prev.map((t) =>
              t.id === taskId ? { ...t, status: 'success' as const } : t
            )
          );
          // 记录已上传的文件
          setUploadedFiles((prev) => [
            ...prev,
            {
              fileName,
              objectKey,
              downloadProgress: 0,
              downloadStatus: 'idle',
            },
          ]);
          Alert.alert(
            '上传成功',
            `文件: ${fileName}\n链接: ${uploadResult.objectUrl}`
          );
        },
        onError: (error) => {
          console.error('上传失败:', error);
          setUploadTasks((prev) =>
            prev.map((t) =>
              t.id === taskId
                ? {
                    ...t,
                    status: 'failed' as const,
                    error: error.message,
                  }
                : t
            )
          );
          Alert.alert('失败', `${fileName} 上传失败: ${error.message}`);
        },
      });

      task.handle = handle;
    } catch (error: unknown) {
      // 用户取消或其他错误
      const message = error instanceof Error ? error.message : '文件选择失败';
      Alert.alert('错误', message);
    }
  };

  const pickMediaAndUpload = async () => {
    if (!client) {
      Alert.alert('错误', '客户端未初始化');
      return;
    }

    try {
      const response = await launchImageLibrary({
        mediaType: 'mixed',
        selectionLimit: 1,
      });

      if (
        response.didCancel ||
        !response.assets ||
        response.assets.length === 0
      ) {
        return;
      }

      const asset = response.assets[0]!;
      const filePath = asset.uri!;
      const fileName = asset.fileName || `media_${Date.now()}`;

      const prefix = config.keyPrefix.replace(/\/$/, '');
      const objectKey = prefix
        ? `${prefix}/${Date.now()}_${fileName}`
        : `${Date.now()}_${fileName}`;

      const taskId = `task_${++taskCountRef.current}`;
      const task: UploadTask = {
        id: taskId,
        fileName,
        objectKey,
        progress: 0,
        preparing: true,
        copyProgress: 0,
        completedParts: 0,
        totalParts: 0,
        status: 'uploading',
        handle: null,
      };

      setUploadTasks((prev) => [...prev, task]);

      const handle = client.upload(filePath, objectKey, {
        contentType: asset.type || 'application/octet-stream',
        onPreparing: (copyProgress) => {
          console.log(`[准备中] ${fileName}: ${copyProgress}%`);
          setUploadTasks((prev) =>
            prev.map((t) =>
              t.id === taskId ? { ...t, preparing: true, copyProgress } : t
            )
          );
        },
        onProgress: (progress) => {
          setUploadTasks((prev) =>
            prev.map((t) =>
              t.id === taskId
                ? {
                    ...t,
                    preparing: false,
                    progress: progress.percentage,
                    completedParts: progress.completedParts ?? t.completedParts,
                    totalParts: progress.totalParts ?? t.totalParts,
                  }
                : t
            )
          );
        },
        onSuccess: (uploadResult) => {
          console.log('上传成功:', uploadResult);
          setUploadTasks((prev) =>
            prev.map((t) =>
              t.id === taskId ? { ...t, status: 'success' as const } : t
            )
          );
          setUploadedFiles((prev) => [
            ...prev,
            {
              fileName,
              objectKey,
              downloadProgress: 0,
              downloadStatus: 'idle',
            },
          ]);
          Alert.alert(
            '上传成功',
            `文件: ${fileName}\n链接: ${uploadResult.objectUrl}`
          );
        },
        onError: (error) => {
          console.error('上传失败:', error);
          setUploadTasks((prev) =>
            prev.map((t) =>
              t.id === taskId
                ? { ...t, status: 'failed' as const, error: error.message }
                : t
            )
          );
          Alert.alert('失败', `${fileName} 上传失败: ${error.message}`);
        },
      });

      task.handle = handle;
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : '媒体选择失败';
      Alert.alert('错误', message);
    }
  };

  const cancelUpload = async (task: UploadTask) => {
    if (task.handle) {
      try {
        await task.handle.cancel();
        setUploadTasks((prev) =>
          prev.map((t) =>
            t.id === task.id ? { ...t, status: 'cancelled' as const } : t
          )
        );
      } catch (error: unknown) {
        const message = error instanceof Error ? error.message : '取消失败';
        Alert.alert('取消失败', message);
      }
    }
  };

  const downloadFileByKey = async (objectKey: string, fileName: string) => {
    if (!client) {
      Alert.alert('错误', '客户端未初始化');
      return;
    }

    // 更新状态为下载中
    setUploadedFiles((prev) =>
      prev.map((f) =>
        f.objectKey === objectKey
          ? {
              ...f,
              downloadStatus: 'downloading' as const,
              downloadProgress: 0,
              downloadPath: undefined,
            }
          : f
      )
    );

    try {
      const savePath = `${RNFS.DocumentDirectoryPath}/${Date.now()}_${fileName}`;

      const handle = client.download(objectKey, savePath, {
        onProgress: (progress) => {
          setUploadedFiles((prev) =>
            prev.map((f) =>
              f.objectKey === objectKey
                ? { ...f, downloadProgress: progress.percentage }
                : f
            )
          );
        },
        onSuccess: (result) => {
          setUploadedFiles((prev) =>
            prev.map((f) =>
              f.objectKey === objectKey
                ? {
                    ...f,
                    downloadStatus: 'success' as const,
                    downloadProgress: 100,
                    downloadPath: result.savePath,
                  }
                : f
            )
          );
          Alert.alert(
            '下载成功',
            `文件: ${fileName}\n保存至: ${result.savePath}`
          );
        },
        onError: (error) => {
          setUploadedFiles((prev) =>
            prev.map((f) =>
              f.objectKey === objectKey
                ? { ...f, downloadStatus: 'failed' as const }
                : f
            )
          );
          Alert.alert('下载失败', error.message);
        },
      });

      await handle.promise();
    } catch (error: unknown) {
      setUploadedFiles((prev) =>
        prev.map((f) =>
          f.objectKey === objectKey
            ? { ...f, downloadStatus: 'failed' as const }
            : f
        )
      );
      const message = error instanceof Error ? error.message : '下载失败';
      Alert.alert('下载失败', message);
    }
  };

  const openFile = async (filePath: string, _fileName: string) => {
    try {
      if (Platform.OS === 'ios') {
        const fileUrl = filePath.startsWith('file://')
          ? filePath
          : `file://${filePath}`;
        await Share.share({ url: fileUrl });
      } else {
        await HuaweiObsNative.openFile(filePath);
      }
    } catch {
      // 用户取消或打开失败
    }
  };

  const deleteFile = async (file: { fileName: string; objectKey: string }) => {
    if (!client) {
      Alert.alert('错误', '客户端未初始化');
      return;
    }

    Alert.alert('确认删除', `是否删除: ${file.fileName}?`, [
      { text: '取消' },
      {
        text: '删除',
        style: 'destructive',
        onPress: async () => {
          try {
            await client.deleteObject(file.objectKey);
            setUploadedFiles((prev) =>
              prev.filter((f) => f.objectKey !== file.objectKey)
            );
            Alert.alert('成功', '文件已删除');
          } catch (error: unknown) {
            const message = error instanceof Error ? error.message : '删除失败';
            Alert.alert('删除失败', message);
          }
        },
      },
    ]);
  };

  const getTaskStatusColor = (status: UploadTask['status']) => {
    switch (status) {
      case 'uploading':
        return '#007AFF';
      case 'success':
        return '#34C759';
      case 'failed':
        return '#FF3B30';
      case 'cancelled':
        return '#8E8E93';
    }
  };

  if (isInitializing) {
    return (
      <SafeAreaView style={styles.container}>
        <ActivityIndicator size="large" />
        <Text style={styles.loadingText}>初始化中...</Text>
      </SafeAreaView>
    );
  }

  if (!client) {
    return (
      <SafeAreaView style={styles.container}>
        <Text style={styles.errorText}>客户端初始化失败</Text>
      </SafeAreaView>
    );
  }

  return (
    <SafeAreaView style={styles.container}>
      <ScrollView
        style={styles.scrollView}
        contentContainerStyle={styles.scrollContent}
      >
        <View style={styles.configCard}>
          <Text style={styles.sectionTitle}>配置 AK/SK</Text>
          <Text style={styles.inputLabel}>粘贴 JSON 配置</Text>
          <TextInput
            style={[styles.input, styles.jsonInput]}
            value={jsonInput}
            onChangeText={setJsonInput}
            placeholder={`{\n  "endpoint": "obs.cn-north-4.myhuaweicloud.com",\n  "bucket": "your-bucket",\n  "accessKeyId": "AK...",\n  "secretAccessKey": "SK...",\n  "securityToken": "",\n  "customDomain": "",\n  "keyPrefix": "",\n  "timeout": 60000,\n  "maxRetries": 3\n}`}
            autoCapitalize="none"
            autoCorrect={false}
            multiline
            numberOfLines={8}
            textAlignVertical="top"
          />
          {config.endpoint !== OBS_CONFIG.endpoint && (
            <View style={styles.configSummary}>
              <Text style={styles.configSummaryText} numberOfLines={1}>
                Endpoint: {config.endpoint}
              </Text>
              <Text style={styles.configSummaryText} numberOfLines={1}>
                Bucket: {config.bucket}
              </Text>
              <Text style={styles.configSummaryText} numberOfLines={1}>
                AK: {config.accessKeyId.slice(0, 6)}...
              </Text>
              {!!config.securityToken && (
                <Text style={styles.configSummaryText} numberOfLines={1}>
                  STS Token: 已设置
                </Text>
              )}
              {!!config.customDomain && (
                <Text style={styles.configSummaryText} numberOfLines={1}>
                  域名: {config.customDomain}
                </Text>
              )}
              {!!config.keyPrefix && (
                <Text style={styles.configSummaryText} numberOfLines={1}>
                  Key 前缀: {config.keyPrefix}
                </Text>
              )}
            </View>
          )}
          <TouchableOpacity
            style={[styles.button, styles.applyButton]}
            onPress={parseAndApplyJson}
            disabled={isInitializing || !jsonInput.trim()}
          >
            <Text style={styles.buttonText}>
              {isInitializing ? '初始化中...' : '解析并初始化'}
            </Text>
          </TouchableOpacity>
        </View>

        <View style={styles.buttonGroup}>
          <TouchableOpacity
            style={[styles.button, styles.mediaButton]}
            onPress={pickMediaAndUpload}
          >
            <Text style={styles.buttonText}>选择媒体上传</Text>
          </TouchableOpacity>
          <TouchableOpacity style={styles.button} onPress={pickAndUploadFile}>
            <Text style={styles.buttonText}>选择文件上传</Text>
          </TouchableOpacity>
        </View>

        <Text style={styles.sectionTitle}>上传任务</Text>
        {uploadTasks.length === 0 ? (
          <Text style={styles.emptyText}>暂无上传任务</Text>
        ) : (
          uploadTasks.map((task) => (
            <View key={task.id} style={styles.taskItem}>
              <View style={styles.taskHeader}>
                <Text style={styles.taskName} numberOfLines={1}>
                  {task.fileName}
                </Text>
                <Text
                  style={[
                    styles.taskStatus,
                    { color: getTaskStatusColor(task.status) },
                  ]}
                >
                  {task.status === 'uploading'
                    ? task.preparing
                      ? `准备中 ${task.copyProgress}%`
                      : `${task.progress}%`
                    : task.status === 'success'
                      ? '完成'
                      : task.status === 'failed'
                        ? '失败'
                        : '已取消'}
                </Text>
              </View>

              {task.status === 'uploading' &&
                !task.preparing &&
                task.totalParts > 0 && (
                  <Text style={styles.taskDetail}>
                    分片 {task.completedParts}/{task.totalParts}
                  </Text>
                )}

              {task.status === 'uploading' && (
                <>
                  <View style={styles.progressBar}>
                    <View
                      style={[
                        styles.progressFill,
                        { width: `${task.progress}%` },
                      ]}
                    />
                  </View>
                  <TouchableOpacity
                    style={styles.cancelButton}
                    onPress={() => cancelUpload(task)}
                  >
                    <Text style={styles.cancelButtonText}>取消</Text>
                  </TouchableOpacity>
                </>
              )}

              {task.status === 'failed' && task.error && (
                <Text style={styles.errorText} numberOfLines={2}>
                  {task.error}
                </Text>
              )}
            </View>
          ))
        )}

        <View style={styles.uploadedSection}>
          <Text style={styles.sectionTitle}>
            已上传文件 ({uploadedFiles.length})
          </Text>
          {uploadedFiles.length === 0 ? (
            <Text style={styles.emptyText}>暂无已上传文件</Text>
          ) : (
            <View style={styles.uploadedFilesList}>
              {uploadedFiles.map((file, index) => (
                <View
                  key={`${file.objectKey}-${index}`}
                  style={styles.uploadedFileItem}
                >
                  <View style={styles.uploadedFileContent}>
                    <Text style={styles.uploadedFileName} numberOfLines={1}>
                      {file.fileName}
                    </Text>
                    <Text style={styles.uploadedFileKey} numberOfLines={1}>
                      {file.objectKey}
                    </Text>
                    {file.downloadStatus === 'downloading' && (
                      <View style={styles.downloadProgressBar}>
                        <View
                          style={[
                            styles.downloadProgressFill,
                            { width: `${file.downloadProgress}%` },
                          ]}
                        />
                        <Text style={styles.downloadProgressText}>
                          {file.downloadProgress}%
                        </Text>
                      </View>
                    )}
                    {file.downloadStatus === 'success' && file.downloadPath && (
                      <TouchableOpacity
                        onPress={() =>
                          openFile(file.downloadPath!, file.fileName)
                        }
                      >
                        <Text
                          style={styles.downloadSuccessText}
                          numberOfLines={1}
                        >
                          ✓ 已保存: {file.downloadPath.split('/').pop()}
                        </Text>
                      </TouchableOpacity>
                    )}
                    {file.downloadStatus === 'failed' && (
                      <Text style={styles.downloadFailText}>✗ 下载失败</Text>
                    )}
                  </View>
                  <View style={styles.fileActions}>
                    {file.downloadStatus === 'success' && file.downloadPath && (
                      <TouchableOpacity
                        style={[styles.fileActionButton, styles.openButton]}
                        onPress={() =>
                          openFile(file.downloadPath!, file.fileName)
                        }
                      >
                        <Text style={styles.fileActionButtonText}>打开</Text>
                      </TouchableOpacity>
                    )}
                    <TouchableOpacity
                      style={[
                        styles.fileActionButton,
                        styles.downloadButton,
                        file.downloadStatus === 'downloading' &&
                          styles.disabledButton,
                      ]}
                      disabled={file.downloadStatus === 'downloading'}
                      onPress={() =>
                        downloadFileByKey(file.objectKey, file.fileName)
                      }
                    >
                      <Text style={styles.fileActionButtonText}>
                        {file.downloadStatus === 'success' ? '重下' : '下载'}
                      </Text>
                    </TouchableOpacity>
                    <TouchableOpacity
                      style={[styles.fileActionButton, styles.deleteFileButton]}
                      onPress={() => deleteFile(file)}
                    >
                      <Text style={styles.fileActionButtonText}>删除</Text>
                    </TouchableOpacity>
                  </View>
                </View>
              ))}
            </View>
          )}
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    paddingVertical: 24,
    backgroundColor: '#F5F5F5',
  },
  scrollView: {
    flex: 1,
  },
  scrollContent: {
    padding: 16,
  },
  configCard: {
    backgroundColor: '#FFFFFF',
    padding: 16,
    borderRadius: 12,
    marginBottom: 16,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.08,
    shadowRadius: 6,
    elevation: 2,
  },
  inputLabel: {
    fontSize: 12,
    fontWeight: '600',
    color: '#6D6D72',
    marginTop: 8,
    marginBottom: 6,
  },
  input: {
    backgroundColor: '#F2F2F7',
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 10,
    fontSize: 14,
    color: '#111111',
  },
  jsonInput: {
    minHeight: 180,
    fontFamily: 'Courier',
    fontSize: 12,
  },
  configSummary: {
    backgroundColor: '#F2F2F7',
    borderRadius: 8,
    padding: 10,
    marginTop: 8,
  },
  configSummaryText: {
    fontSize: 12,
    color: '#3A3A3C',
    marginBottom: 2,
  },
  loadingText: {
    marginTop: 10,
    fontSize: 16,
    textAlign: 'center',
  },
  errorText: {
    color: '#FF3B30',
    fontSize: 14,
    marginTop: 4,
  },
  buttonGroup: {
    marginBottom: 20,
  },
  button: {
    backgroundColor: '#007AFF',
    padding: 16,
    borderRadius: 8,
    marginBottom: 12,
  },
  applyButton: {
    marginTop: 12,
  },
  buttonText: {
    color: '#FFFFFF',
    fontSize: 16,
    fontWeight: '600',
    textAlign: 'center',
  },
  sectionTitle: {
    fontSize: 18,
    fontWeight: '600',
    marginBottom: 12,
  },
  emptyText: {
    textAlign: 'center',
    color: '#8E8E93',
    fontSize: 14,
    marginTop: 20,
  },
  taskItem: {
    backgroundColor: '#FFFFFF',
    padding: 16,
    borderRadius: 8,
    marginBottom: 12,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.1,
    shadowRadius: 4,
    elevation: 2,
  },
  taskHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 8,
  },
  taskName: {
    fontSize: 16,
    fontWeight: '500',
    flex: 1,
    marginRight: 8,
  },
  taskStatus: {
    fontSize: 14,
    fontWeight: '600',
  },
  taskDetail: {
    fontSize: 12,
    color: '#8E8E93',
    marginBottom: 6,
  },
  progressBar: {
    height: 4,
    backgroundColor: '#E5E5EA',
    borderRadius: 2,
    marginBottom: 8,
    overflow: 'hidden',
  },
  progressFill: {
    height: '100%',
    backgroundColor: '#007AFF',
  },
  cancelButton: {
    alignSelf: 'flex-end',
    paddingVertical: 4,
    paddingHorizontal: 12,
  },
  cancelButtonText: {
    color: '#FF3B30',
    fontSize: 14,
    fontWeight: '500',
  },
  uploadedFilesList: {
    backgroundColor: '#FFFFFF',
    borderRadius: 8,
    overflow: 'hidden',
  },
  uploadedFileItem: {
    paddingVertical: 12,
    paddingHorizontal: 16,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#E5E5EA',
  },
  uploadedFileContent: {
    marginBottom: 8,
  },
  uploadedFileName: {
    fontSize: 15,
    fontWeight: '500',
    color: '#111111',
    marginBottom: 4,
  },
  uploadedFileKey: {
    fontSize: 12,
    color: '#8E8E93',
  },
  fileActions: {
    flexDirection: 'row',
    gap: 8,
  },
  fileActionButton: {
    flex: 1,
    paddingVertical: 8,
    borderRadius: 6,
    alignItems: 'center' as const,
  },
  fileActionButtonText: {
    color: '#FFFFFF',
    fontSize: 13,
    fontWeight: '600',
  },
  downloadButton: {
    backgroundColor: '#34C759',
  },
  openButton: {
    backgroundColor: '#007AFF',
  },
  deleteFileButton: {
    backgroundColor: '#FF3B30',
  },
  disabledButton: {
    opacity: 0.6,
  },
  downloadProgressBar: {
    height: 4,
    backgroundColor: '#E5E5EA',
    borderRadius: 2,
    marginTop: 8,
    overflow: 'hidden' as const,
    position: 'relative' as const,
  },
  downloadProgressFill: {
    height: '100%' as unknown as number,
    backgroundColor: '#34C759',
    borderRadius: 2,
  },
  downloadProgressText: {
    position: 'absolute' as const,
    right: 0,
    top: -16,
    fontSize: 11,
    color: '#34C759',
    fontWeight: '600',
  },
  downloadSuccessText: {
    fontSize: 11,
    color: '#34C759',
    marginTop: 4,
  },
  downloadFailText: {
    fontSize: 11,
    color: '#FF3B30',
    marginTop: 4,
  },
  mediaButton: {
    backgroundColor: '#5856D6',
    marginTop: 8,
  },
  uploadedSection: {
    marginTop: 20,
  },
});
