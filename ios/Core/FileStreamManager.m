//
//  FileStreamManager.m
//  HuaweiObs
//
//  Created by react-native-huawei-obs
//

#import "FileStreamManager.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#define OBSLog(tag, fmt, ...) NSLog(@"[%@] " fmt, tag, ##__VA_ARGS__)
static NSString *const TAG = @"FileStreamManager";

@implementation FileStreamInfo
@end

@interface FileStreamManager ()

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSFileHandle *> *openStreams;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *tempStreamPaths;
@property (nonatomic, strong) NSLock *lock;

@end

@implementation FileStreamManager

- (instancetype)init {
    if (self = [super init]) {
        _openStreams = [NSMutableDictionary dictionary];
        _tempStreamPaths = [NSMutableDictionary dictionary];
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (FileStreamInfo *)openFileStreamWithPath:(NSString *)filePath error:(NSError **)error {
    return [self openFileStreamWithPath:filePath copyProgress:nil error:error];
}

- (FileStreamInfo *)openFileStreamWithPath:(NSString *)filePath
                          copyProgress:(FSCopyProgressBlock _Nullable)progressBlock
                                 error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isTemporary = NO;

    OBSLog(TAG, @"[Open] filePath=%@", filePath);

    NSString *resolvedPath = [self resolveReadablePathFromInput:filePath
                                                    isTemporary:&isTemporary
                                                  progressBlock:progressBlock
                                                          error:error];
    if (!resolvedPath) {
        return nil;
    }
    
    // Check if readable
    if (![fileManager isReadableFileAtPath:resolvedPath]) {
        if (error) {
            *error = [NSError errorWithDomain:@"FileStreamManager" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"File not readable",
                                               @"code": @"E_FILE_NOT_READABLE"}];
        }
        return nil;
    }
    
    // Open file handle
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:resolvedPath];
    if (!fileHandle) {
        if (error) {
            *error = [NSError errorWithDomain:@"FileStreamManager" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to open file",
                                               @"code": @"E_FILE_OPEN_FAILED"}];
        }
        return nil;
    }
    
    // Generate streamId
    NSString *streamId = [[NSUUID UUID] UUIDString];
    
    [self.lock lock];
    self.openStreams[streamId] = fileHandle;
    if (isTemporary) {
        self.tempStreamPaths[streamId] = resolvedPath;
    }
    [self.lock unlock];
    
    // Get file info
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:resolvedPath error:nil];
    NSNumber *fileSize = attributes[NSFileSize];
    NSDate *modificationDate = attributes[NSFileModificationDate];
    
    FileStreamInfo *info = [[FileStreamInfo alloc] init];
    info.streamId = streamId;
    info.fileSize = [fileSize longLongValue];
    info.fileName = [resolvedPath lastPathComponent];
    info.mimeType = [self mimeTypeForPath:resolvedPath];
    info.lastModified = [modificationDate timeIntervalSince1970] * 1000;
    
    OBSLog(TAG, @"[Open] streamId=%@  size=%lld bytes  mimeType=%@",
           streamId, info.fileSize, info.mimeType);
    
    return info;
}

- (NSData *)readChunkWithStreamId:(NSString *)streamId
                           offset:(int64_t)offset
                             size:(NSInteger)size
                            error:(NSError **)error {
    [self.lock lock];
    NSFileHandle *fileHandle = self.openStreams[streamId];
    [self.lock unlock];
    
    if (!fileHandle) {
        if (error) {
            *error = [NSError errorWithDomain:@"FileStreamManager" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Stream not found",
                                               @"code": @"E_STREAM_NOT_FOUND"}];
        }
        return nil;
    }
    
    @synchronized (fileHandle) {
        if (@available(iOS 13.0, *)) {
            // Get file size for validation
            unsigned long long fileSize = 0;
            NSError *seekError = nil;
            BOOL seekSuccess = [fileHandle seekToEndReturningOffset:&fileSize error:&seekError];
            if (!seekSuccess || offset < 0 || offset >= fileSize) {
                if (error) {
                    *error = [NSError errorWithDomain:@"FileStreamManager" code:-1
                                             userInfo:@{NSLocalizedDescriptionKey: @"Invalid offset",
                                                       @"code": @"E_INVALID_OFFSET"}];
                }
                return nil;
            }
            
            // Seek to offset
            [fileHandle seekToOffset:offset error:nil];
            
            // Read data
            NSData *data = [fileHandle readDataUpToLength:size error:nil];
            return data ?: [NSData data];
            
        } else {
            // iOS 13 below
            [fileHandle seekToFileOffset:offset];
            NSData *data = [fileHandle readDataOfLength:size];
            return data;
        }
    }
}

- (int64_t)getFileSizeWithStreamId:(NSString *)streamId error:(NSError **)error {
    [self.lock lock];
    NSFileHandle *fileHandle = self.openStreams[streamId];
    [self.lock unlock];
    
    if (!fileHandle) {
        if (error) {
            *error = [NSError errorWithDomain:@"FileStreamManager" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Stream not found",
                                               @"code": @"E_STREAM_NOT_FOUND"}];
        }
        return -1;
    }
    
    if (@available(iOS 13.0, *)) {
        unsigned long long size = [fileHandle seekToEndReturningOffset:nil error:nil];
        return (int64_t)size;
    } else {
        unsigned long long size = [fileHandle seekToEndOfFile];
        return (int64_t)size;
    }
}

- (void)closeStreamWithId:(NSString *)streamId error:(NSError **)error {
    OBSLog(TAG, @"[Close] streamId=%@", streamId);
    [self.lock lock];
    NSFileHandle *fileHandle = self.openStreams[streamId];
    NSString *tempFilePath = self.tempStreamPaths[streamId];
    [self.openStreams removeObjectForKey:streamId];
    [self.tempStreamPaths removeObjectForKey:streamId];
    [self.lock unlock];
    
    if (!fileHandle) {
        if (error) {
            *error = [NSError errorWithDomain:@"FileStreamManager" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Stream not found",
                                               @"code": @"E_STREAM_NOT_FOUND"}];
        }
        return;
    }
    
    // 确保文件句柄被正确关闭
    NSError *closeError = nil;
    if (@available(iOS 13.0, *)) {
        [fileHandle closeAndReturnError:&closeError];
    } else {
        [fileHandle closeFile];
    }

    // 删除临时文件（如果有）
    if (tempFilePath) {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSError *deleteError = nil;
        BOOL deleted = [fileManager removeItemAtPath:tempFilePath error:&deleteError];
        if (!deleted && deleteError) {
            // 如果文件已被删除，忽略"找不到文件"错误
            if (deleteError.code != NSFileNoSuchFileError) {
                OBSLog(TAG, @"[Close] Failed to delete temp file: %@", deleteError.localizedDescription);
                // 不将删除错误传递给调用者，因为主要操作（关闭流）已完成
            }
        } else if (deleted) {
            OBSLog(TAG, @"[Close] Deleted temp file: %@", tempFilePath);
        }
    }
}

- (void)closeAllStreams {
    OBSLog(TAG, @"[CloseAll] closing %lu stream(s)", (unsigned long)self.openStreams.count);
    [self.lock lock];
    NSDictionary *streams = [self.openStreams copy];
    NSDictionary *tempPaths = [self.tempStreamPaths copy];
    [self.openStreams removeAllObjects];
    [self.tempStreamPaths removeAllObjects];
    [self.lock unlock];
    
    // 关闭所有文件句柄
    for (NSFileHandle *fileHandle in streams.allValues) {
        if (@available(iOS 13.0, *)) {
            NSError *closeError = nil;
            [fileHandle closeAndReturnError:&closeError];
            if (closeError) {
                OBSLog(TAG, @"[CloseAll] Error closing file handle: %@", closeError.localizedDescription);
            }
        } else {
            [fileHandle closeFile];
        }
    }

    // 删除所有临时文件
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *tempFilePath in tempPaths.allValues) {
        NSError *deleteError = nil;
        BOOL deleted = [fileManager removeItemAtPath:tempFilePath error:&deleteError];
        if (!deleted && deleteError) {
            // 如果文件已被删除，忽略"找不到文件"错误
            if (deleteError.code != NSFileNoSuchFileError) {
                OBSLog(TAG, @"[CloseAll] Failed to delete temp file %@: %@", tempFilePath, deleteError.localizedDescription);
            }
        } else if (deleted) {
            OBSLog(TAG, @"[CloseAll] Deleted temp file: %@", tempFilePath);
        }
    }
}

- (BOOL)hasStreamWithId:(NSString *)streamId {
    [self.lock lock];
    BOOL exists = self.openStreams[streamId] != nil;
    [self.lock unlock];
    return exists;
}

- (NSString *)mimeTypeForPath:(NSString *)path {
    if (@available(iOS 14.0, *)) {
        NSString *fileExtension = [path pathExtension];
        UTType *type = [UTType typeWithFilenameExtension:fileExtension];
        if (type && type.preferredMIMEType) {
            return type.preferredMIMEType;
        }
    }
    return @"application/octet-stream";
}

- (NSString *)resolveReadablePathFromInput:(NSString *)inputPath
                               isTemporary:(BOOL *)isTemporary
                             progressBlock:(FSCopyProgressBlock _Nullable)progressBlock
                                     error:(NSError **)error {
    if (isTemporary) {
        *isTemporary = NO;
    }

    if (!inputPath || inputPath.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"FileStreamManager" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid file path",
                                               @"code": @"E_INVALID_PATH"}];
        }
        return nil;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *trimmedPath = [inputPath stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if ([fileManager fileExistsAtPath:trimmedPath]) {
        return trimmedPath;
    }

    NSString *decodedPath = [trimmedPath stringByRemovingPercentEncoding];
    if (decodedPath && [fileManager fileExistsAtPath:decodedPath]) {
        return decodedPath;
    }

    NSURL *url = [NSURL URLWithString:trimmedPath];
    if (url && url.isFileURL) {
        NSString *urlPath = url.path;
        if (urlPath && [fileManager fileExistsAtPath:urlPath]) {
            return urlPath;
        }

        NSString *decodedUrlPath = [urlPath stringByRemovingPercentEncoding];
        if (decodedUrlPath && [fileManager fileExistsAtPath:decodedUrlPath]) {
            return decodedUrlPath;
        }
    }

    if (url && url.scheme.length > 0) {
        NSString *tempPath = [self materializeURLToTemporaryFile:url progressBlock:progressBlock error:error];
        if (tempPath) {
            if (isTemporary) {
                *isTemporary = YES;
            }
            return tempPath;
        }
        return nil;
    }

    if (error) {
        *error = [NSError errorWithDomain:@"FileStreamManager" code:-1
                                 userInfo:@{NSLocalizedDescriptionKey: @"File not found",
                                           @"code": @"E_FILE_NOT_FOUND"}];
    }
    return nil;
}

- (NSString *)materializeURLToTemporaryFile:(NSURL *)url progressBlock:(FSCopyProgressBlock _Nullable)progressBlock error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL hasSecurityScope = [url startAccessingSecurityScopedResource];

    @try {
        NSString *cacheDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"HuaweiObsUploadCache"];
        [fileManager createDirectoryAtPath:cacheDir withIntermediateDirectories:YES attributes:nil error:nil];

        // 保留原始文件名，但添加时间戳前缀以避免冲突
        NSString *originalFileName = [url lastPathComponent];
        if (!originalFileName || originalFileName.length == 0) {
            // 如果无法获取原始文件名，使用UUID + 扩展名
            NSString *extension = url.pathExtension ?: @"";
            NSString *fileName = [[NSUUID UUID] UUIDString];
            if (extension.length > 0) {
                fileName = [fileName stringByAppendingFormat:@".%@", extension];
            }
            originalFileName = fileName;
        }
        
        // 添加时间戳前缀以确保唯一性，格式: timestamp_originalname
        NSTimeInterval timestamp = [[NSDate date] timeIntervalSince1970] * 1000;
        NSString *fileName = [NSString stringWithFormat:@"%.0f_%@", timestamp, originalFileName];
        NSString *tempPath = [cacheDir stringByAppendingPathComponent:fileName];

        NSInputStream *inputStream = [NSInputStream inputStreamWithURL:url];
        NSOutputStream *outputStream = [NSOutputStream outputStreamToFileAtPath:tempPath append:NO];

        if (!inputStream || !outputStream) {
            if (error) {
                *error = [NSError errorWithDomain:@"FileStreamManager" code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to access selected file",
                                                   @"code": @"E_FILE_OPEN_FAILED"}];
            }
            return nil;
        }

        [inputStream open];
        [outputStream open];

        // Get file size for progress reporting
        int64_t totalSize = 0;
        if (progressBlock) {
            NSNumber *fileSizeValue = nil;
            [url getResourceValue:&fileSizeValue forKey:NSURLFileSizeKey error:nil];
            totalSize = [fileSizeValue longLongValue];
        }

        uint8_t buffer[64 * 1024];
        NSInteger bytesRead = 0;
        int64_t copiedBytes = 0;
        while ((bytesRead = [inputStream read:buffer maxLength:sizeof(buffer)]) > 0) {
            NSInteger totalWritten = 0;
            while (totalWritten < bytesRead) {
                NSInteger written = [outputStream write:buffer + totalWritten maxLength:bytesRead - totalWritten];
                if (written <= 0) {
                    [inputStream close];
                    [outputStream close];
                    // 清理失败的临时文件
                    NSError *deleteError = nil;
                    [fileManager removeItemAtPath:tempPath error:&deleteError];
                    if (deleteError && deleteError.code != NSFileNoSuchFileError) {
                        OBSLog(TAG, @"[Materialize] Failed to delete failed temp file: %@", deleteError.localizedDescription);
                    }
                    if (error) {
                        *error = [NSError errorWithDomain:@"FileStreamManager" code:-1
                                                 userInfo:@{NSLocalizedDescriptionKey: @"Failed to copy selected file",
                                                           @"code": @"E_FILE_COPY_FAILED"}];
                    }
                    return nil;
                }
                totalWritten += written;
            }
            copiedBytes += bytesRead;
            if (progressBlock && totalSize > 0) {
                progressBlock(copiedBytes, totalSize);
            }
        }

        [inputStream close];
        [outputStream close];

        if (bytesRead < 0) {
            // 清理失败的临时文件
            NSError *deleteError = nil;
            [fileManager removeItemAtPath:tempPath error:&deleteError];
            if (deleteError && deleteError.code != NSFileNoSuchFileError) {
                OBSLog(TAG, @"[Materialize] Failed to delete failed temp file: %@", deleteError.localizedDescription);
            }
            if (error) {
                *error = inputStream.streamError ?: [NSError errorWithDomain:@"FileStreamManager"
                                                                         code:-1
                                                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to read selected file",
                                                                               @"code": @"E_FILE_READ_FAILED"}];
            }
            return nil;
        }

        return tempPath;

    } @finally {
        if (hasSecurityScope) {
            [url stopAccessingSecurityScopedResource];
        }
    }
}

- (void)dealloc {
    [self closeAllStreams];
}

@end
