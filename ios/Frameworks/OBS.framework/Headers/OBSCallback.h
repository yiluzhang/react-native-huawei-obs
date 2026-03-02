//
//  OBSCallBack.h
//  test
//
//  Created by ruanhanzhou on 2025/2/14.
//  Copyright © 2025 Lprison. All rights reserved.
//
#import "OBSBaseModel.h"
#ifndef OBSCallback_h
#define OBSCallback_h
@interface OBSCallback : OBSBaseEntity
@property (nonatomic, copy, nonnull) NSString * callbackUrl;
@property (nonatomic, copy, nonnull) NSString * callbackBody;
@property (nonatomic, copy, nullable) NSString * callbackHost;
@property (nonatomic, copy, nullable) NSString * callbackBodyType;
-(void) setCallbackUrl:(nonnull NSString * )callbackUrl;
-(void) setCallbackBody:(nonnull NSString * )callbackBody;
- (instancetype) initWithUrl:(nonnull NSString*) callbackUrl
                    withBody:(nonnull NSString*) callbackBody
                withBodyType:(nullable NSString*) callbackBodyType
                    withHost:(nullable NSString*) callbackHost;

/**
 获取编码后的callback
 */
-(nullable NSString*) toBase64EncodedJson;
@end
#endif /* OBSCallback_h */
