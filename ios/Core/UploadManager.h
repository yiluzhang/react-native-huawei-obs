//
//  UploadManager.h
//  HuaweiObs
//
//  Created by react-native-huawei-obs
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface UploadParams : NSObject

@property (nonatomic, copy) NSString *taskId;
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, copy) NSString *objectKey;
@property (nonatomic, copy) NSString *bucket;
@property (nonatomic, copy, nullable) NSString *contentType;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *metadata;
@property (nonatomic, copy, nullable) NSString *acl;
@property (nonatomic, copy, nullable) NSString *storageClass;
@property (nonatomic, strong, nullable) NSNumber *partSize;
@property (nonatomic, strong, nullable) NSNumber *concurrency;
@property (nonatomic, assign) NSTimeInterval startTimeMs;

- (instancetype)initWithTaskId:(NSString *)taskId
                      filePath:(NSString *)filePath
                     objectKey:(NSString *)objectKey
                        bucket:(NSString *)bucket
                   contentType:(nullable NSString *)contentType
                      metadata:(nullable NSDictionary<NSString *, NSString *> *)metadata
                           acl:(nullable NSString *)acl
                  storageClass:(nullable NSString *)storageClass
                      partSize:(nullable NSNumber *)partSize
                   concurrency:(nullable NSNumber *)concurrency;

@end

@interface UploadResult : NSObject

@property (nonatomic, copy) NSString *taskId;
@property (nonatomic, copy) NSString *objectKey;
@property (nonatomic, copy) NSString *bucket;
@property (nonatomic, copy) NSString *etag;
@property (nonatomic, copy) NSString *objectUrl;
@property (nonatomic, assign) int64_t size;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign) double avgSpeed;

- (instancetype)initWithTaskId:(NSString *)taskId
                     objectKey:(NSString *)objectKey
                        bucket:(NSString *)bucket
                         etag:(NSString *)etag
                    objectUrl:(NSString *)objectUrl
                         size:(int64_t)size
                      duration:(NSTimeInterval)duration
                      avgSpeed:(double)avgSpeed;

@end

@class EventEmitter, ObsClientHolder, ConcurrencyManager, FileStreamManager;

@interface UploadManager : NSObject

- (instancetype)initWithFileStreamManager:(FileStreamManager *)fileStreamManager
                        obsClientHolder:(ObsClientHolder *)obsClientHolder
                     concurrencyManager:(ConcurrencyManager *)concurrencyManager
                           eventEmitter:(EventEmitter *)eventEmitter;

/// Start multipart upload
- (NSString *)startUploadWithParams:(UploadParams *)params;

/// Cancel upload
- (void)cancelUploadWithTaskId:(NSString *)taskId error:(NSError **)error;

/// Cancel all uploads
- (void)cancelAll;

/// Get task status
- (nullable NSDictionary *)getTaskStatusWithTaskId:(NSString *)taskId;

/// Get all tasks
- (NSArray<NSDictionary *> *)getAllTasks;

/// Clear completed/failed/canceled tasks
- (void)clearCompletedTasks;

/// Cleanup resources
- (void)destroy;

@end

NS_ASSUME_NONNULL_END
