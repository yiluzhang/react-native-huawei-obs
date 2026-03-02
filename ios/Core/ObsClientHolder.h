//
//  ObsClientHolder.h
//  HuaweiObs
//
//  Created by react-native-huawei-obs
//

#import <Foundation/Foundation.h>

@class OBSClient;

NS_ASSUME_NONNULL_BEGIN

@interface ObsClientHolder : NSObject

/// 创建 OBS 客户端
- (void)createClientWithConfig:(NSDictionary *)config error:(NSError **)error;

/// 更新客户端配置
- (void)updateConfig:(NSDictionary *)config error:(NSError **)error;

/// 获取客户端实例
- (OBSClient *)getClientWithError:(NSError **)error;

/// 获取当前 endpoint
- (nullable NSString *)getEndpoint;

/// 获取当前配置
- (nullable NSDictionary *)getCurrentConfig;

/// 检查凭证是否过期
- (BOOL)isCredentialsExpired;

/// 关闭客户端
- (void)closeClient;

@end

NS_ASSUME_NONNULL_END
