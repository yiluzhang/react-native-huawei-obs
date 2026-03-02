//
//  ErrorMapper.h
//  HuaweiObs
//
//  Created by react-native-huawei-obs
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ErrorMapper : NSObject

/// 映射异常到统一错误码
+ (NSDictionary *)mapError:(NSError *)error;

/// 判断错误码是否可重试
+ (BOOL)isRetryableErrorCode:(NSString *)code;

@end

NS_ASSUME_NONNULL_END
