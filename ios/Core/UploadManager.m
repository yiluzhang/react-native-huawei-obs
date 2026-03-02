//
//  UploadManager.m
//  HuaweiObs
//
//  Created by react-native-huawei-obs
//

#import "UploadManager.h"
#import "FileStreamManager.h"
#import "ObsClientHolder.h"
#import "ConcurrencyManager.h"
#import "EventEmitter.h"
#import "ErrorMapper.h"
#import <OBS/OBS.h>

#define OBSLog(tag, fmt, ...) NSLog(@"[%@] " fmt, tag, ##__VA_ARGS__)
static NSString *const TAG = @"UploadManager";

@implementation UploadParams

- (instancetype)initWithTaskId:(NSString *)taskId
                      filePath:(NSString *)filePath
                     objectKey:(NSString *)objectKey
                        bucket:(NSString *)bucket
                   contentType:(nullable NSString *)contentType
                      metadata:(nullable NSDictionary<NSString *, NSString *> *)metadata
                           acl:(nullable NSString *)acl
                  storageClass:(nullable NSString *)storageClass
                      partSize:(nullable NSNumber *)partSize
                   concurrency:(nullable NSNumber *)concurrency {
    if (self = [super init]) {
        _taskId = [taskId copy];
        _filePath = [filePath copy];
        _objectKey = [objectKey copy];
        _bucket = [bucket copy];
        _contentType = [contentType copy];
        _metadata = [metadata copy];
        _acl = [acl copy];
        _storageClass = [storageClass copy];
        _partSize = partSize;
        _concurrency = concurrency;
        _startTimeMs = [[NSDate date] timeIntervalSince1970] * 1000;
    }
    return self;
}

@end

@implementation UploadResult

- (instancetype)initWithTaskId:(NSString *)taskId
                     objectKey:(NSString *)objectKey
                        bucket:(NSString *)bucket
                         etag:(NSString *)etag
                    objectUrl:(NSString *)objectUrl
                         size:(int64_t)size
                      duration:(NSTimeInterval)duration
                      avgSpeed:(double)avgSpeed {
    if (self = [super init]) {
        _taskId = [taskId copy];
        _objectKey = [objectKey copy];
        _bucket = [bucket copy];
        _etag = [etag copy];
        _objectUrl = [objectUrl copy];
        _size = size;
        _duration = duration;
        _avgSpeed = avgSpeed;
    }
    return self;
}

@end

typedef NS_ENUM(NSInteger, UploadTaskStatus) {
    UploadTaskStatusPending,
    UploadTaskStatusUploading,
    UploadTaskStatusCompleted,
    UploadTaskStatusFailed,
    UploadTaskStatusCanceled
};

@interface PartInfo : NSObject
@property (nonatomic, assign) NSInteger partNumber;
@property (nonatomic, copy) NSString *etag;
@end

@implementation PartInfo
@end

@interface UploadTaskState : NSObject
@property (nonatomic, copy) NSString *taskId;
@property (nonatomic, strong) UploadParams *params;
@property (nonatomic, copy, nullable) NSString *uploadId;
@property (nonatomic, copy, nullable) NSString *streamId;
@property (nonatomic, strong) NSMutableArray<PartInfo *> *parts;
@property (nonatomic, copy) NSString *status;
@property (nonatomic, assign) int64_t transferredBytes;
@property (nonatomic, assign) int64_t totalBytes;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, assign) BOOL failed;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, strong) dispatch_group_t uploadGroup;
@end

@implementation UploadTaskState

- (instancetype)initWithTaskId:(NSString *)taskId params:(UploadParams *)params {
    if (self = [super init]) {
        _taskId = [taskId copy];
        _params = params;
        _parts = [NSMutableArray array];
        _status = @"PENDING";
        _transferredBytes = 0;
        _totalBytes = 0;
        _failed = NO;
        _cancelled = NO;
        _uploadGroup = dispatch_group_create();
    }
    return self;
}

@end

static const int64_t MIN_PART_SIZE = 1 * 1024 * 1024;   // 1MB 下限
static const int64_t MAX_PART_SIZE = 10 * 1024 * 1024;  // 10MB 上限
static const int TARGET_PARTS = 100;                     // 目标分片数（~1% 进度粒度）
static const int64_t MULTIPART_THRESHOLD = 5 * 1024 * 1024;  // 5MB：低于此用 putObject

@interface UploadManager ()
@property (nonatomic, strong) FileStreamManager *fileStreamManager;
@property (nonatomic, strong) ObsClientHolder *obsClientHolder;
@property (nonatomic, strong) ConcurrencyManager *concurrencyManager;
@property (nonatomic, strong) EventEmitter *eventEmitter;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UploadTaskState *> *tasks;
@property (nonatomic, strong) NSLock *lock;
@end

@implementation UploadManager

- (instancetype)initWithFileStreamManager:(FileStreamManager *)fileStreamManager
                        obsClientHolder:(ObsClientHolder *)obsClientHolder
                     concurrencyManager:(ConcurrencyManager *)concurrencyManager
                           eventEmitter:(EventEmitter *)eventEmitter {
    if (self = [super init]) {
        _fileStreamManager = fileStreamManager;
        _obsClientHolder = obsClientHolder;
        _concurrencyManager = concurrencyManager;
        _eventEmitter = eventEmitter;
        _tasks = [NSMutableDictionary dictionary];
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (NSString *)startUploadWithParams:(UploadParams *)params {
    OBSLog(TAG, @"[StartUpload] taskId=%@  objectKey=%@  filePath=%@",
           params.taskId, params.objectKey, params.filePath);
    UploadTaskState *taskState = [[UploadTaskState alloc] initWithTaskId:params.taskId params:params];
    
    [self.lock lock];
    self.tasks[params.taskId] = taskState;
    [self.lock unlock];
    
    // Execute upload in background
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self executeUpload:taskState];
    });
    
    return params.taskId;
}

- (void)executeUpload:(UploadTaskState *)taskState {
    UploadParams *params = taskState.params;
    NSError *error = nil;
    
    @try {
        // Check credentials expiry
        if ([self.obsClientHolder isCredentialsExpired]) {
            @throw [NSError errorWithDomain:@"UploadManager" code:-1
                                   userInfo:@{NSLocalizedDescriptionKey: @"Credentials expired",
                                             @"code": @"E_AUTH_EXPIRED"}];
        }
        
        // 立即发出 preparing 事件，确保 UI 有反馈
        [self.eventEmitter emitWithEventName:@"uploadPreparing"
                                     params:@{
                                         @"taskId": params.taskId,
                                         @"objectKey": params.objectKey,
                                         @"copyProgress": @(0)
                                     }];
        OBSLog(TAG, @"[Preparing] taskId=%@  objectKey=%@", params.taskId, params.objectKey);
        
        // Open file stream (with copy progress callback for content:// / picker URIs)
        FileStreamInfo *fileInfo = [self.fileStreamManager openFileStreamWithPath:params.filePath
                                                                    copyProgress:^(int64_t copiedBytes, int64_t totalBytes) {
            int progress = totalBytes > 0 ? (int)(copiedBytes * 100 / totalBytes) : 0;
            OBSLog(TAG, @"[Preparing] copy progress=%d%%", progress);
            [self.eventEmitter emitWithEventName:@"uploadPreparing"
                                         params:@{
                                             @"taskId": params.taskId,
                                             @"objectKey": params.objectKey,
                                             @"copyProgress": @(progress)
                                         }];
        } error:&error];
        if (!fileInfo) {
            @throw error;
        }
        
        taskState.streamId = fileInfo.streamId;
        taskState.totalBytes = fileInfo.fileSize;
        
        OBSLog(TAG, @"[Upload] taskId=%@  objectKey=%@  fileSize=%lld bytes  mimeType=%@",
               params.taskId, params.objectKey, fileInfo.fileSize, fileInfo.mimeType);
        
        // Send uploadStart event
        taskState.status = @"UPLOADING";
        [self.eventEmitter emitWithEventName:@"uploadStart" 
                                     params:@{
                                         @"taskId": params.taskId,
                                         @"objectKey": params.objectKey,
                                         @"totalBytes": @(fileInfo.fileSize)
                                     }];
        
        UploadResult *result;
        if (fileInfo.fileSize <= MULTIPART_THRESHOLD) {
            // 小文件直接用 putObject，避免分片上传所需的额外权限
            OBSLog(TAG, @"[Upload] strategy=putObject (size <= %lld bytes)", MULTIPART_THRESHOLD);
            result = [self executePutObjectWithTaskState:taskState fileInfo:fileInfo error:&error];
        } else {
            // 大文件用分片上传
            OBSLog(TAG, @"[Upload] strategy=multipart (size > %lld bytes)", MULTIPART_THRESHOLD);
            result = [self executeMultipartUploadWithTaskState:taskState fileInfo:fileInfo error:&error];
        }
        
        if (!result) {
            @throw error ?: [NSError errorWithDomain:@"UploadManager" code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"Upload failed"}];
        }
        
        // Cleanup
        [self.fileStreamManager closeStreamWithId:fileInfo.streamId error:nil];
        taskState.streamId = nil;
        taskState.status = @"COMPLETED";
        
        // Send success event
        [self.eventEmitter emitWithEventName:@"uploadSuccess" 
                                     params:@{
                                         @"taskId": params.taskId,
                                         @"objectKey": result.objectKey,
                                         @"bucket": result.bucket,
                                         @"etag": result.etag,
                                         @"objectUrl": result.objectUrl,
                                         @"size": @(result.size),
                                         @"duration": @(result.duration),
                                         @"avgSpeed": @(result.avgSpeed)
                                     }];
        
        [self.eventEmitter clearThrottle:params.taskId];
        
    } @catch (NSError *e) {
        // 取消时不触发 error 事件（cancelUpload 会发 uploadCancel）
        if (!taskState.cancelled) {
            [self handleUploadError:taskState error:e];
        }
    }
}

/**
 * Simple upload using putObject (for files <= 5 MB)
 */
- (UploadResult *)executePutObjectWithTaskState:(UploadTaskState *)taskState
                                       fileInfo:(FileStreamInfo *)fileInfo
                                          error:(NSError **)error {
    UploadParams *params = taskState.params;
    
    // Read entire file data
    NSData *data = [self.fileStreamManager readChunkWithStreamId:fileInfo.streamId
                                                         offset:0
                                                           size:(NSInteger)fileInfo.fileSize
                                                          error:error];
    if (!data) return nil;
    
    OBSClient *client = [self.obsClientHolder getClientWithError:error];
    if (!client) return nil;
    
    OBSPutObjectWithDataRequest *request = [[OBSPutObjectWithDataRequest alloc]
        initWithBucketName:params.bucket
                 objectKey:params.objectKey
                uploadData:data];
    
    // Set content type
    if (params.contentType) {
        request.customContentType = params.contentType;
    } else if (fileInfo.mimeType) {
        request.customContentType = fileInfo.mimeType;
    }
    
    // Set metadata
    if (params.metadata) {
        request.metaDataDict = params.metadata;
    }
    
    // Set ACL policy
    if (params.acl) {
        request.objectACLPolicy = [params.acl intValue];
    }
    
    // Set storage class
    if (params.storageClass) {
        request.storageClass = [params.storageClass intValue];
    }
    
    OBSLog(TAG, @"[PutObject] sending request: bucket=%@  key=%@", params.bucket, params.objectKey);
    OBSBFTask *task = [client invokeRequest:request];
    [task waitUntilFinished];
    
    if (task.error) {
        if (error) *error = task.error;
        return nil;
    }
    
    OBSPutObjectResponse *response = task.result;
    
    NSTimeInterval duration = ([[NSDate date] timeIntervalSince1970] * 1000) - params.startTimeMs;
    double avgSpeed = duration > 0 ? (fileInfo.fileSize * 1000.0) / duration : 0.0;
    OBSLog(TAG, @"[PutObject] done: etag=%@  duration=%.0fms  speed=%.1f KB/s",
           response.etag, duration, avgSpeed / 1024);
    
    // Emit 100% progress
    [self.eventEmitter emitProgressWithTaskId:params.taskId
                                   eventName:@"uploadProgress"
                                      params:@{
                                          @"taskId": params.taskId,
                                          @"transferredBytes": @(fileInfo.fileSize),
                                          @"totalBytes": @(fileInfo.fileSize),
                                          @"percentage": @(100),
                                          @"progress": @(100)
                                      }
                                       force:YES];
    
    // Construct object URL
    NSString *endpoint = [[self.obsClientHolder getEndpoint] ?: @"" stringByReplacingOccurrencesOfString:@"https://" withString:@""];
    endpoint = [endpoint stringByReplacingOccurrencesOfString:@"http://" withString:@""];
    NSString *encodedObjectKey = [params.objectKey stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *objectUrl = [NSString stringWithFormat:@"https://%@.%@/%@", params.bucket, endpoint, encodedObjectKey];
    
    return [[UploadResult alloc]
        initWithTaskId:params.taskId
             objectKey:params.objectKey
                bucket:params.bucket
                 etag:response.etag ?: @""
            objectUrl:objectUrl
                 size:fileInfo.fileSize
              duration:duration
              avgSpeed:avgSpeed];
}

/**
 * Multipart upload (for files > 5 MB)
 */
- (UploadResult *)executeMultipartUploadWithTaskState:(UploadTaskState *)taskState
                                             fileInfo:(FileStreamInfo *)fileInfo
                                                error:(NSError **)error {
    UploadParams *params = taskState.params;
    
    // Select part size
    int64_t partSize = params.partSize ? [params.partSize longLongValue] :
                      [self selectPartSize:fileInfo.fileSize];
    int totalParts = (int)((fileInfo.fileSize + partSize - 1) / partSize);
    
    OBSLog(TAG, @"[Multipart] objectKey=%@  fileSize=%lld  partSize=%lld  totalParts=%d",
           params.objectKey, fileInfo.fileSize, partSize, totalParts);
    
    // Initiate multipart upload
    NSString *uploadId = [self initiateMultipartUploadWithParams:params
                                                        mimeType:fileInfo.mimeType
                                                           error:error];
    if (!uploadId) return nil;
    taskState.uploadId = uploadId;
    
    // Calculate actual concurrency
    int concurrency = params.concurrency ? [params.concurrency intValue] : 6;
    int actualConcurrency = [self.concurrencyManager calculateConcurrencyWithPartSizeMB:(int)(partSize / (1024 * 1024))
                                                                      configConcurrency:concurrency];
    OBSLog(TAG, @"[Multipart] concurrency=%d", actualConcurrency);
    
    // Upload parts concurrently
    [self uploadPartsWithTaskState:taskState
                          fileInfo:fileInfo
                          partSize:partSize
                         totalParts:totalParts
                        concurrency:actualConcurrency];
    
    // Check if cancelled
    if (taskState.cancelled) return nil;
    
    // Check if any part failed
    if (taskState.failed) {
        // Abort multipart upload to clean up server-side resources
        [self abortMultipartUploadWithTaskState:taskState];
        if (error) *error = taskState.error;
        return nil;
    }
    
    // Complete multipart upload
    return [self completeMultipartUploadWithTaskState:taskState error:error];
}

- (void)abortMultipartUploadWithTaskState:(UploadTaskState *)taskState {
    if (!taskState.uploadId) return;
    OBSClient *client = [self.obsClientHolder getClientWithError:nil];
    if (client) {
        OBSAbortMultipartUploadRequest *request = [[OBSAbortMultipartUploadRequest alloc]
            initWithBucketName:taskState.params.bucket
                     objectKey:taskState.params.objectKey
                      uploadID:taskState.uploadId];
        OBSBFTask *task = [client invokeRequest:request];
        [task waitUntilFinished];
        OBSLog(TAG, @"[Multipart] aborted uploadId=%@", taskState.uploadId);
    }
}

- (NSString *)initiateMultipartUploadWithParams:(UploadParams *)params 
                                      mimeType:(NSString *)mimeType 
                                         error:(NSError **)error {
    OBSClient *client = [self.obsClientHolder getClientWithError:error];
    if (!client) return nil;
    
    OBSInitiateMultipartUploadRequest *request = [[OBSInitiateMultipartUploadRequest alloc]
        initWithBucketName:params.bucket objectKey:params.objectKey];
    
    // Set content type
    if (params.contentType || mimeType) {
        request.customContentType = params.contentType ?: mimeType;
    }
    
    // Set metadata dictionary
    if (params.metadata) {
        request.metaDataDict = params.metadata;
    }
    
    // Set ACL policy
    if (params.acl) {
        request.objectACLPolicy = [params.acl intValue];
    }
    
    // Set storage class
    if (params.storageClass) {
        request.storageClass = [params.storageClass intValue];
    }
    
    // Invoke request and wait for completion (synchronous)
    OBSBFTask *task = [client invokeRequest:request];
    [task waitUntilFinished];
    
    if (task.error) {
        if (error) {
            *error = task.error;
        }
        return nil;
    }
    
    OBSInitiateMultipartUploadResponse *response = task.result;
    if (!response.uploadID) {
        if (error) {
            *error = [NSError errorWithDomain:@"UploadManager" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to get uploadID"}];
        }
        return nil;
    }
    
    OBSLog(TAG, @"[Multipart] uploadID=%@", response.uploadID);
    return response.uploadID;
}

- (void)uploadPartsWithTaskState:(UploadTaskState *)taskState 
                        fileInfo:(FileStreamInfo *)fileInfo 
                        partSize:(int64_t)partSize 
                       totalParts:(int)totalParts 
                      concurrency:(int)concurrency {
    dispatch_queue_t uploadQueue = dispatch_queue_create("com.huaweiobs.upload", DISPATCH_QUEUE_CONCURRENT);
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(concurrency);
    
    for (int partNumber = 1; partNumber <= totalParts; partNumber++) {
        if (taskState.failed || taskState.cancelled) break;
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
        
        dispatch_async(uploadQueue, ^{
            @try {
                [self uploadSinglePartWithTaskState:taskState 
                                           fileInfo:fileInfo 
                                        partNumber:partNumber 
                                          partSize:partSize 
                                       totalParts:totalParts];
            } @catch (NSError *e) {
                // Part upload error handled internally
                taskState.error = e;
                taskState.failed = YES;
            } @finally {
                dispatch_semaphore_signal(semaphore);
            }
        });
    }
    
    // Wait for all parts to complete
    dispatch_barrier_sync(uploadQueue, ^{});
}

- (void)uploadSinglePartWithTaskState:(UploadTaskState *)taskState 
                              fileInfo:(FileStreamInfo *)fileInfo 
                           partNumber:(int)partNumber 
                             partSize:(int64_t)partSize 
                            totalParts:(int)totalParts {
    if (taskState.failed || taskState.cancelled) return;
    UploadParams *params = taskState.params;
    NSError *error = nil;
    
    @try {
        int64_t offset = (partNumber - 1) * partSize;
        int currentPartSize = (int)MIN(partSize, fileInfo.fileSize - offset);
        
        // Read part data
        NSData *data = [self.fileStreamManager readChunkWithStreamId:fileInfo.streamId 
                                                              offset:offset 
                                                                size:currentPartSize 
                                                               error:&error];
        if (!data) {
            @throw error ?: [NSError errorWithDomain:@"UploadManager" code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"Failed to read chunk"}];
        }
        
        // Upload part
        OBSClient *client = [self.obsClientHolder getClientWithError:&error];
        if (!client) {
            @throw error;
        }
        
        OBSUploadPartWithDataRequest *request = [[OBSUploadPartWithDataRequest alloc]
            initWithBucketName:params.bucket
                     objectkey:params.objectKey
                    partNumber:@(partNumber)
                      uploadID:taskState.uploadId
                    uploadData:data];
        
        OBSBFTask *task = [client invokeRequest:request];
        [task waitUntilFinished];
        
        if (task.error) {
            @throw task.error;
        }
        
        OBSUploadPartResponse *response = task.result;
        
        if (!response.etag) {
            @throw [NSError errorWithDomain:@"UploadManager" code:-1
                                   userInfo:@{NSLocalizedDescriptionKey: @"Failed to get ETag"}];
        }
        
        // Save part info
        PartInfo *partInfo = [[PartInfo alloc] init];
        partInfo.partNumber = partNumber;
        partInfo.etag = response.etag;
        
        @synchronized (taskState.parts) {
            [taskState.parts addObject:partInfo];
        }
        
        // Update transferred bytes (thread-safe)
        int64_t transferredBytes = 0;
        NSInteger completedParts = 0;
        @synchronized (taskState) {
            taskState.transferredBytes += [data length];
            transferredBytes = taskState.transferredBytes;
        }
        @synchronized (taskState.parts) {
            completedParts = taskState.parts.count;
        }
        
         OBSLog(TAG, @"[Part] %d/%d  size=%lu  etag=%@  transferred=%lld/%lld",
               partNumber, totalParts, (unsigned long)[data length],
             response.etag, transferredBytes, taskState.totalBytes);
        
        // Send partComplete event
        [self.eventEmitter emitWithEventName:@"partComplete" 
                                     params:@{
                                         @"taskId": params.taskId,
                                         @"partNumber": @(partNumber),
                                         @"etag": response.etag,
                                         @"uploadedBytes": @(transferredBytes)
                                     }];
        
        // Send progress event (force emit accurate value after part completion)
        NSInteger percentage = taskState.totalBytes > 0 ? (NSInteger)(transferredBytes * 100 / taskState.totalBytes) : 0;
        [self.eventEmitter emitProgressWithTaskId:params.taskId 
                                       eventName:@"uploadProgress" 
                                          params:@{
                                              @"taskId": params.taskId,
                                              @"transferredBytes": @(transferredBytes),
                                              @"totalBytes": @(taskState.totalBytes),
                                              @"percentage": @(percentage),
                                              @"progress": @(percentage),
                                              @"currentPart": @(partNumber),
                                              @"totalParts": @(totalParts),
                                              @"completedParts": @(completedParts)
                                          } 
                                           force:YES];
        
    } @catch (NSError *e) {
        taskState.error = e;
        taskState.failed = YES;
    }
}

- (UploadResult *)completeMultipartUploadWithTaskState:(UploadTaskState *)taskState
                                                error:(NSError **)error {
    UploadParams *params = taskState.params;
    
    // Sort parts by part number
    NSArray *sortedParts = [taskState.parts sortedArrayUsingComparator:^NSComparisonResult(PartInfo *a, PartInfo *b) {
        return [@(a.partNumber) compare:@(b.partNumber)];
    }];
    
    // Create part list for complete request
    NSMutableArray<OBSPart*> *partsList = [NSMutableArray array];
    for (PartInfo *partInfo in sortedParts) {
        OBSPart *part = [[OBSPart alloc] initWithPartNumber:@(partInfo.partNumber) etag:partInfo.etag];
        [partsList addObject:part];
    }
    
    // Complete upload
    OBSClient *client = [self.obsClientHolder getClientWithError:error];
    if (!client) return nil;
    
    OBSCompleteMultipartUploadRequest *request = [[OBSCompleteMultipartUploadRequest alloc]
        initWithBucketName:params.bucket
                 objectKey:params.objectKey
                  uploadID:taskState.uploadId];
    request.partsList = partsList;
    
    OBSLog(TAG, @"[Multipart] completing upload  parts=%lu  uploadId=%@",
           (unsigned long)sortedParts.count, taskState.uploadId);
    
    OBSBFTask *task = [client invokeRequest:request];
    [task waitUntilFinished];
    
    if (task.error) {
        if (error) {
            *error = task.error;
        }
        return nil;
    }
    
    OBSCompleteMultipartUploadResponse *response = task.result;
    
    NSTimeInterval duration = ([[NSDate date] timeIntervalSince1970] * 1000) - params.startTimeMs;
    double avgSpeed = duration > 0 ? (taskState.totalBytes * 1000.0) / duration : 0.0;
    OBSLog(TAG, @"[Multipart] complete done  etag=%@  duration=%.0fms  speed=%.1f KB/s",
           response.etag, duration, avgSpeed / 1024);
    
    // Construct object URL using actual endpoint
    NSString *endpoint = [[self.obsClientHolder getEndpoint] ?: @"" stringByReplacingOccurrencesOfString:@"https://" withString:@""];
    endpoint = [endpoint stringByReplacingOccurrencesOfString:@"http://" withString:@""];
    
    UploadResult *result = [[UploadResult alloc]
        initWithTaskId:params.taskId 
             objectKey:params.objectKey 
                bucket:params.bucket 
                 etag:response.etag ?: @"" 
            objectUrl:[NSString stringWithFormat:@"https://%@.%@/%@", params.bucket, endpoint, [params.objectKey stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]]]
                 size:taskState.totalBytes 
              duration:duration 
              avgSpeed:avgSpeed];
    
    return result;
}

- (void)handleUploadError:(UploadTaskState *)taskState error:(NSError *)error {
    NSDictionary *obsError = [ErrorMapper mapError:error];
    taskState.error = error;
    taskState.status = @"FAILED";
    
    OBSLog(TAG, @"[Upload] failed  taskId=%@  error=%@", taskState.taskId, obsError[@"message"]);
    
    // Abort multipart upload to clean up server-side resources
    [self abortMultipartUploadWithTaskState:taskState];
    
    // Cleanup
    if (taskState.streamId) {
        [self.fileStreamManager closeStreamWithId:taskState.streamId error:nil];
        taskState.streamId = nil;
    }
    
    // Send error event
    [self.eventEmitter emitWithEventName:@"uploadError" 
                                 params:@{
                                     @"taskId": taskState.taskId,
                                     @"code": obsError[@"code"],
                                     @"message": obsError[@"message"],
                                     @"isRetryable": obsError[@"isRetryable"]
                                 }];
    
    [self.eventEmitter clearThrottle:taskState.taskId];
}

- (void)cancelUploadWithTaskId:(NSString *)taskId error:(NSError **)error {
    [self.lock lock];
    UploadTaskState *taskState = self.tasks[taskId];
    [self.lock unlock];
    
    if (!taskState) {
        if (error) {
            *error = [NSError errorWithDomain:@"UploadManager" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Task not found: %@", taskId]}];
        }
        return;
    }
    
    // Mark as cancelled before aborting
    taskState.status = @"CANCELED";
    taskState.cancelled = YES;
    
    // Abort multipart upload
    if (taskState.uploadId) {
        OBSClient *client = [self.obsClientHolder getClientWithError:nil];
        if (client) {
            OBSAbortMultipartUploadRequest *request = [[OBSAbortMultipartUploadRequest alloc]
                initWithBucketName:taskState.params.bucket
                         objectKey:taskState.params.objectKey
                          uploadID:taskState.uploadId];
            OBSBFTask *task = [client invokeRequest:request];
            [task waitUntilFinished];
        }
    }
    
    // Cleanup
    if (taskState.streamId) {
        [self.fileStreamManager closeStreamWithId:taskState.streamId error:nil];
        taskState.streamId = nil;
    }
    
    [self.lock lock];
    [self.tasks removeObjectForKey:taskId];
    [self.lock unlock];
    
    // Send cancel event
    [self.eventEmitter emitWithEventName:@"uploadCancel" 
                                 params:@{@"taskId": taskId}];
}

- (void)cancelAll {
    [self.lock lock];
    NSArray *taskIds = [self.tasks.allKeys copy];
    [self.lock unlock];
    
    for (NSString *taskId in taskIds) {
        [self cancelUploadWithTaskId:taskId error:nil];
    }
}

- (nullable NSDictionary *)getTaskStatusWithTaskId:(NSString *)taskId {
    [self.lock lock];
    UploadTaskState *taskState = self.tasks[taskId];
    [self.lock unlock];
    
    if (!taskState) {
        return nil;
    }
    
    NSInteger percentage = taskState.totalBytes > 0 ? 
        (NSInteger)(taskState.transferredBytes * 100 / taskState.totalBytes) : 0;
    
    NSDictionary *progress = @{
        @"taskId": taskState.taskId,
        @"transferredBytes": @(taskState.transferredBytes),
        @"totalBytes": @(taskState.totalBytes),
        @"percentage": @(percentage),
        @"progress": @(percentage),
        @"completedParts": @(taskState.parts.count)
    };
    
    NSDictionary *status = @{
        @"taskId": taskState.taskId,
        @"type": @"upload",
        @"objectKey": taskState.params.objectKey,
        @"status": taskState.status,
        @"progress": progress
    };
    
    return status;
}

- (NSArray<NSDictionary *> *)getAllTasks {
    [self.lock lock];
    NSArray *taskStates = [self.tasks.allValues copy];
    [self.lock unlock];
    
    NSMutableArray *result = [NSMutableArray array];
    for (UploadTaskState *taskState in taskStates) {
        NSDictionary *task = @{
            @"taskId": taskState.taskId,
            @"type": @"upload",
            @"objectKey": taskState.params.objectKey,
            @"status": taskState.status
        };
        [result addObject:task];
    }
    return result;
}

- (int64_t)selectPartSize:(int64_t)fileSize {
    // 目标 ~100 个分片，进度粒度 ~1%，分片大小限制在 [1MB, 10MB]
    int64_t selected = fileSize / TARGET_PARTS;
    if (selected < MIN_PART_SIZE) {
        selected = MIN_PART_SIZE;
    } else if (selected > MAX_PART_SIZE) {
        selected = MAX_PART_SIZE;
    }
    OBSLog(TAG, @"[PartSize] fileSize=%lld  -> partSize=%lld  (~%d parts)",
           fileSize, selected, (int)((fileSize + selected - 1) / selected));
    return selected;
}

- (void)clearCompletedTasks {
    [self.lock lock];
    NSMutableArray *keysToRemove = [NSMutableArray array];
    for (NSString *taskId in self.tasks) {
        UploadTaskState *taskState = self.tasks[taskId];
        if ([taskState.status isEqualToString:@"COMPLETED"] ||
            [taskState.status isEqualToString:@"FAILED"] ||
            [taskState.status isEqualToString:@"CANCELED"]) {
            [keysToRemove addObject:taskId];
        }
    }
    [self.tasks removeObjectsForKeys:keysToRemove];
    [self.lock unlock];
}

- (void)destroy {
    [self cancelAll];
    [self.lock lock];
    [self.tasks removeAllObjects];
    [self.lock unlock];
}

@end
