//
//  MTAppFluencyMonitor.h
//  MTAppFluencyMonitorDemo
//
//  Created by suxinde on 16/8/5.
//  Copyright © 2016年 com.su. All rights reserved.
//

#import <Foundation/Foundation.h>

/**
 *  基于NSRunLoop监听主线程卡顿工具类
 */
@interface XDAppFluencyMonitor : NSObject

+ (instancetype)sharedInstance;

/**
 *  开启监听
 */
- (void)startMonitoring;

- (void)stopMonitoring;

@end
