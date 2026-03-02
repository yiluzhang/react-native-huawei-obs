//
//  DownloadManager.m
//  HuaweiObs
//
//  Created by react-native-huawei-obs
//

#import "DownloadManager.h"
#import "EventEmitter.h"
#import "ObsClientHolder.h"
#import "ErrorMapper.h"
#import <OBS/OBS.h>

#define OBSLog(tag, fmt, ...) NSLog(@"[%@] " fmt, tag, ##__VA_ARGS__)
static NSString *const TAG = @"DownloadManager";

@implementation DownloadParams

- (instancetype)initWithTaskId:(NSString *)taskId
                     objectKey:(NSString *)objectKey
                        bucket:(NSString *)bucket
                      savePath:(NSString *)savePath
                         range:(nullable NSString *)range
                     versionId:(nullable NSString *)versionId {
    if (self = [super init]) {
        _taskId = [taskId copy];
        _objectKey = [objectKey copy];
        _bucket = [bucket copy];
        _savePath = [savePath copy];
        _range = [range copy];
        _versionId = [versionId copy];
        _startTimeMs = [[NSDate date] timeIntervalSince1970] * 1000;
    }
    return self;
}

@end

@implementation DownloadResult

- (instancetype)initWithTaskId:(NSString *)taskId
                     objectKey:(NSString *)objectKey
                      savePath:(NSString *)savePath
                          size:(int64_t)size
                         etag:(NSString *)etag
                      duration:(NSTimeInterval)duration
                      avgSpeed:(double)avgSpeed {
    if (self = [super init]) {
        _taskId = [taskId copy];
        _objectKey = [objectKey copy];
        _savePath = [savePath copy];
        _size = size;
        _etag = [etag copy];
        _duration = duration;
        _avgSpeed = avgSpeed;
    }
    return self;
}

@end

typedef NS_ENUM(NSInteger, DownloadTaskStatus) {
    DownloadTaskStatusPending,
    DownloadTaskStatusDownloading,
    DownloadTaskStatusCompleted,
    DownloadTaskStatusFailed,
    DownloadTaskStatusCanceled
};

@interface DownloadTaskState : NSObject
@property (nonatomic, copy) NSString *taskId;
@property (nonatomic, strong) DownloadParams *params;
@property (nonatomic, copy) NSString *status;
@property (nonatomic, assign) int64_t downloadedBytes;
@property (nonatomic, assign) int64_t totalBytes;
@property (nonatomic, copy) NSString *etag;
@property (nonatomic, strong) dispatch_block_t cancelBlock;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, assign) BOOL cancelled;
@end

@implementation DownloadTaskState
@end

static const NSInteger BUFFER_SIZE = 8192;
static const NSTimeInterval PROGRESS_UPDATE_INTERVAL = 0.1; // 100ms

@interface DownloadManager ()
@property (nonatomic, strong) ObsClientHolder *obsClientHolder;
@property (nonatomic, strong) EventEmitter *eventEmitter;
@property (nonatomic, strong) NSMutableDictionary<NSString *, DownloadTaskState *> *tasks;
@property (nonatomic, strong) dispatch_queue_t taskQueue;
@property (nonatomic, strong) NSLock *lock;
@end

@implementation DownloadManager

- (instancetype)initWithObsClientHolder:(ObsClientHolder *)obsClientHolder
                           eventEmitter:(EventEmitter *)eventEmitter {
    if (self = [super init]) {
        _obsClientHolder = obsClientHolder;
        _eventEmitter = eventEmitter;
        _tasks = [NSMutableDictionary dictionary];
        _taskQueue = dispatch_queue_create("com.huaweiobs.download", DISPATCH_QUEUE_CONCURRENT);
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (NSString *)startDownloadWithParams:(DownloadParams *)params {
    OBSLog(TAG, @"[StartDownload] taskId=%@  objectKey=%@  savePath=%@",
           params.taskId, params.objectKey, params.savePath);
    DownloadTaskState *taskState = [[DownloadTaskState alloc] init];
    taskState.taskId = params.taskId;
    taskState.params = params;
    taskState.status = @"PENDING";
    taskState.downloadedBytes = 0;
    taskState.totalBytes = 0;
    taskState.etag = @"";
    taskState.cancelled = NO;
    
    [self.lock lock];
    self.tasks[params.taskId] = taskState;
    [self.lock unlock];
    
    // Execute download in background
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self executeDownload:taskState];
    });
    
    return params.taskId;
}

- (void)executeDownload:(DownloadTaskState *)taskState {
    DownloadParams *params = taskState.params;
    NSError *error = nil;
    
    @try {
        // Check credentials expiry
        if ([self.obsClientHolder isCredentialsExpired]) {
            @throw [NSError errorWithDomain:@"DownloadManager" code:-1
                                   userInfo:@{NSLocalizedDescriptionKey: @"Credentials expired",
                                             @"code": @"E_AUTH_EXPIRED"}];
        }
        
        // Create save directory
        NSURL *savedURL = [NSURL fileURLWithPath:params.savePath];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSURL *dirURL = [savedURL URLByDeletingLastPathComponent];
        
        if (![fileManager fileExistsAtPath:[dirURL path]]) {
            [fileManager createDirectoryAtURL:dirURL 
                  withIntermediateDirectories:YES 
                                   attributes:nil 
                                        error:nil];
        }
        
        if ([fileManager fileExistsAtPath:params.savePath]) {
            [fileManager removeItemAtPath:params.savePath error:nil];
        }
        
        // Send downloadStart event
        taskState.status = @"DOWNLOADING";
        [self.eventEmitter emitWithEventName:@"downloadStart" 
                                     params:@{
                                         @"taskId": params.taskId,
                                         @"objectKey": params.objectKey
                                     }];
        
        // Create download request
        OBSClient *client = [self.obsClientHolder getClientWithError:&error];
        if (!client) {
            @throw error ?: [NSError errorWithDomain:@"DownloadManager" code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"OBS client not available"}];
        }
        
        OBSGetObjectToFileRequest *request = [[OBSGetObjectToFileRequest alloc]
            initWithBucketName:params.bucket
                     objectKey:params.objectKey
              downloadFilePath:params.savePath];
        if (params.range) {
            request.range = params.range;
        }
        if (params.versionId) {
            request.versionID = params.versionId;
        }
        
        // Set download progress callback
        request.downloadProgressBlock = ^(int64_t bytesWritten, int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite) {
            if (taskState.cancelled) return;
            taskState.downloadedBytes = totalBytesWritten;
            if (totalBytesExpectedToWrite > 0) {
                taskState.totalBytes = totalBytesExpectedToWrite;
            }
            [self emitDownloadProgress:taskState force:NO];
        };
        
        // Execute download
        OBSBFTask *task = [client invokeRequest:request];
        [task waitUntilFinished];
        
        if (task.error) {
            @throw task.error;
        }
        
        // Check cancellation after download completes
        if (taskState.cancelled) return;
        
        OBSGetObjectResponse *response = task.result;
        taskState.etag = response.etag ?: @"";
        
        // Get file size from downloaded file
        NSError *fileError = nil;
        NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:params.savePath error:&fileError];
        if (fileAttributes) {
            taskState.totalBytes = [fileAttributes fileSize];
            taskState.downloadedBytes = taskState.totalBytes;
        }
        
        OBSLog(TAG, @"[Download] object downloaded  size=%lld bytes  etag=%@",
               taskState.totalBytes, taskState.etag);
        
        // Send final 100% progress
        [self emitDownloadProgress:taskState force:YES];
        
        // Download complete
        NSTimeInterval duration = ([[NSDate date] timeIntervalSince1970] * 1000) - params.startTimeMs;
        double avgSpeed = duration > 0 ? (taskState.totalBytes * 1000.0) / duration : 0.0;
        
        OBSLog(TAG, @"[Download] completed  objectKey=%@  size=%lld bytes  duration=%.0fms  speed=%.1f KB/s",
               params.objectKey, taskState.totalBytes, duration, avgSpeed / 1024);
        
        taskState.status = @"COMPLETED";
        
        // Send success event
        [self.eventEmitter emitWithEventName:@"downloadSuccess" 
                                     params:@{
                                         @"taskId": params.taskId,
                                         @"objectKey": params.objectKey,
                                         @"savePath": params.savePath,
                                         @"size": @(taskState.totalBytes),
                                         @"etag": taskState.etag,
                                         @"duration": @(duration),
                                         @"avgSpeed": @(avgSpeed)
                                     }];
        
        // Clear throttle record
        [self.eventEmitter clearThrottle:params.taskId];
        
    } @catch (NSError *e) {
        if (!taskState.cancelled) {
            [self handleDownloadError:taskState error:e];
        }
    }
}

- (void)emitDownloadProgress:(DownloadTaskState *)taskState force:(BOOL)force {
    double percentage = taskState.totalBytes > 0 ? 
        (taskState.downloadedBytes * 100.0 / taskState.totalBytes) : 0.0;
    
    NSDictionary *params = @{
        @"taskId": taskState.taskId,
        @"downloadedBytes": @(taskState.downloadedBytes),
        @"totalBytes": @(taskState.totalBytes),
        @"percentage": @((NSInteger)percentage)
    };
    
    [self.eventEmitter emitProgressWithTaskId:taskState.taskId
                                   eventName:@"downloadProgress"
                                      params:params
                                       force:force];
}

- (void)handleDownloadError:(DownloadTaskState *)taskState error:(NSError *)error {
    NSDictionary *obsError = [ErrorMapper mapError:error];
    taskState.error = error;
    taskState.status = @"FAILED";
    
    OBSLog(TAG, @"[Download] failed  taskId=%@  error=%@", taskState.taskId, obsError[@"message"]);
    
    // Send error event
    [self.eventEmitter emitWithEventName:@"downloadError" 
                                 params:@{
                                     @"taskId": taskState.taskId,
                                     @"code": obsError[@"code"],
                                     @"message": obsError[@"message"],
                                     @"isRetryable": obsError[@"isRetryable"]
                                 }];
    
    // Clear throttle record
    [self.eventEmitter clearThrottle:taskState.taskId];
}

- (void)cancelDownloadWithTaskId:(NSString *)taskId error:(NSError **)error {
    [self.lock lock];
    DownloadTaskState *taskState = self.tasks[taskId];
    [self.lock unlock];
    
    if (!taskState) {
        if (error) {
            *error = [NSError errorWithDomain:@"DownloadManager" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Task not found: %@", taskId]}];
        }
        return;
    }
    
    taskState.cancelled = YES;
    taskState.status = @"CANCELED";
    [self.lock lock];
    [self.tasks removeObjectForKey:taskId];
    [self.lock unlock];
    
    // Send cancel event
    [self.eventEmitter emitWithEventName:@"downloadCancel" 
                                 params:@{@"taskId": taskId}];
}

- (void)cancelAll {
    [self.lock lock];
    NSArray *taskIds = [self.tasks.allKeys copy];
    [self.lock unlock];
    
    for (NSString *taskId in taskIds) {
        [self cancelDownloadWithTaskId:taskId error:nil];
    }
}

- (nullable NSDictionary *)getTaskStatusWithTaskId:(NSString *)taskId {
    [self.lock lock];
    DownloadTaskState *taskState = self.tasks[taskId];
    [self.lock unlock];
    
    if (!taskState) {
        return nil;
    }
    
    double percentage = taskState.totalBytes > 0 ? 
        (taskState.downloadedBytes * 100.0 / taskState.totalBytes) : 0.0;
    
    NSDictionary *progress = @{
        @"taskId": taskState.taskId,
        @"downloadedBytes": @(taskState.downloadedBytes),
        @"totalBytes": @(taskState.totalBytes),
        @"percentage": @((NSInteger)percentage)
    };
    
    NSDictionary *status = @{
        @"taskId": taskState.taskId,
        @"type": @"download",
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
    for (DownloadTaskState *taskState in taskStates) {
        NSDictionary *task = @{
            @"taskId": taskState.taskId,
            @"type": @"download",
            @"objectKey": taskState.params.objectKey,
            @"status": taskState.status
        };
        [result addObject:task];
    }
    return result;
}

- (void)clearCompletedTasks {
    [self.lock lock];
    NSMutableArray *keysToRemove = [NSMutableArray array];
    for (NSString *taskId in self.tasks) {
        DownloadTaskState *taskState = self.tasks[taskId];
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
