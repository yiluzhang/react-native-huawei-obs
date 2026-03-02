//
//  FileStreamManager.h
//  HuaweiObs
//
//  Created by react-native-huawei-obs
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FileStreamInfo : NSObject

@property (nonatomic, copy) NSString *streamId;
@property (nonatomic, assign) int64_t fileSize;
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, copy) NSString *mimeType;
@property (nonatomic, assign) NSTimeInterval lastModified;

@end

@interface FileStreamManager : NSObject

/// Copy progress callback: copiedBytes, totalBytes
typedef void (^FSCopyProgressBlock)(int64_t copiedBytes, int64_t totalBytes);

/// 打开文件流
- (FileStreamInfo *)openFileStreamWithPath:(NSString *)filePath error:(NSError **)error;

/// 打开文件流（带复制进度回调，用于 content:// / picker URI 文件复制阶段）
- (FileStreamInfo *)openFileStreamWithPath:(NSString *)filePath
                          copyProgress:(FSCopyProgressBlock _Nullable)progressBlock
                                 error:(NSError **)error;

/// 读取文件块
- (NSData *)readChunkWithStreamId:(NSString *)streamId
                           offset:(int64_t)offset
                             size:(NSInteger)size
                            error:(NSError **)error;

/// 获取文件大小
- (int64_t)getFileSizeWithStreamId:(NSString *)streamId error:(NSError **)error;

/// 关闭流
- (void)closeStreamWithId:(NSString *)streamId error:(NSError **)error;

/// 关闭所有流
- (void)closeAllStreams;

/// 检查流是否存在
- (BOOL)hasStreamWithId:(NSString *)streamId;

@end

NS_ASSUME_NONNULL_END
