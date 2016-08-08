//
//  MTAppFluencyMonitor.m
//  MTAppFluencyMonitorDemo
//
//  Created by suxinde on 16/8/5.
//  Copyright © 2016年 com.su. All rights reserved.
//

#import "XDAppFluencyMonitor.h"

#import <libkern/OSAtomic.h>
#import <execinfo.h>

#include <stdio.h>
#include <stdlib.h>
#include <execinfo.h>

#import "KSDynamicLinker.h"
#import "KSBacktrace.h"


static NSString *const kMTAppFluencyLogFilesDirectory = @"MTAppFluencyLogFilesDirectory";

static dispatch_queue_t mt_fluency_monitor_queue() {
    static dispatch_queue_t mt_fluency_monitor_queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mt_fluency_monitor_queue = dispatch_queue_create("com.meitu.diary.mt_fluency_monitor_queue", NULL);
    });
    return mt_fluency_monitor_queue;
}


@interface XDAppFluencyMonitor (LogsDirectory)

- (NSString *)logsDirectory;

@end

@implementation XDAppFluencyMonitor (LogsDirectory)

- (NSString *)logsDirectory
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    
    NSString *logsDirectory = [documentsDirectory stringByAppendingPathComponent:kMTAppFluencyLogFilesDirectory];
    
    NSFileManager* fileManager = [NSFileManager defaultManager];
    
    // 该用户的目录是否存在，若不存在则创建相应的目录
    BOOL isDirectory = NO;
    BOOL isExisting = [fileManager fileExistsAtPath:logsDirectory isDirectory:&isDirectory];
    
    if (!(isExisting && isDirectory)) {
        BOOL createDirectory = [fileManager createDirectoryAtPath:logsDirectory
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
        if (!createDirectory) {
            NSLog(@"卡顿监听Log文件目录创建失败");
        }
    }
    
    return logsDirectory;

}

@end

@interface XDAppFluencyMonitor () {
@private
    NSInteger _timeoutCount;
    CFRunLoopObserverRef _runLoopObserver;
    NSMutableArray *_callStacks;
}

@property (nonatomic, strong) dispatch_semaphore_t semaphore;
@property (nonatomic, assign) CFRunLoopActivity runLoopActivity;

@end

@implementation XDAppFluencyMonitor

static void runLoopObserverCallBack(CFRunLoopObserverRef observer,
                                    CFRunLoopActivity activity,
                                    void* info)
{
    XDAppFluencyMonitor *appFluencyMonitor = (__bridge XDAppFluencyMonitor*)info;
    appFluencyMonitor.runLoopActivity = activity;
    dispatch_semaphore_signal(appFluencyMonitor.semaphore);
}

+ (instancetype)sharedInstance
{
    static id __sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        __sharedInstance = [[[self class] alloc] init];
    });
    return __sharedInstance;
}

- (void)dealloc
{
    @autoreleasepool {
        [_callStacks removeAllObjects];
        _callStacks = nil;
    }
    [self stopMonitoring];
}

- (instancetype)init {
    if (self = [super init]) {
        _callStacks = [[NSMutableArray alloc] initWithCapacity:0];
    }
    return self;
}

- (void)logcallStacks {
    void* callstack[128];
    int frames = backtrace(callstack, 128);
    char **strs = backtrace_symbols(callstack, frames);
    int i;
    [_callStacks removeAllObjects];
    for ( i = 0 ; i < frames ; i++ ){
        [_callStacks addObject:[NSString stringWithUTF8String:strs[i]]];
    }
    free(strs);
    
    NSLog(@"%@", _callStacks);
}

- (void)startMonitoring
{
    // 已经有runloopObserver在监听时直接返回，不重复创建runloopObserver监听
    if (_runLoopObserver) {
        return;
    }
    
    //  创建信号量
    self.semaphore = dispatch_semaphore_create(0);
    
    // 注册RunLoop的状态监听
    /*
    typedef struct {
        CFIndex	version;
        void *	info;
        const void *(*retain)(const void *info);
        void	(*release)(const void *info);
        CFStringRef	(*copyDescription)(const void *info);
    } CFRunLoopObserverContext;
    */
    CFRunLoopObserverContext context = {
        0,
        (__bridge void*)self,
        NULL,
        NULL
    };
    
    _runLoopObserver = CFRunLoopObserverCreate(kCFAllocatorDefault,
                                               kCFRunLoopAllActivities,
                                               YES,
                                               0,
                                               &runLoopObserverCallBack,
                                               &context);
    CFRunLoopAddObserver(CFRunLoopGetMain(),
                         _runLoopObserver,
                         kCFRunLoopCommonModes);
    
    // 在子线程监控时长
    dispatch_async(mt_fluency_monitor_queue(), ^{
        while (YES)
        {
            // 假定连续5次超时50ms认为卡顿(也包含了单次超时250ms)
            long st = dispatch_semaphore_wait(self.semaphore, dispatch_time(DISPATCH_TIME_NOW, 50*NSEC_PER_MSEC));
            if (st != 0) {
                if (!_runLoopObserver) {
                    _timeoutCount = 0;
                    self.semaphore = 0;
                    self.runLoopActivity = 0;
                    return;
                }
                
                if (self.runLoopActivity == kCFRunLoopBeforeSources ||
                    self.runLoopActivity == kCFRunLoopAfterWaiting)
                {
                    if (++_timeoutCount < 5)
                        continue;
                    
                    [self handleCallbacksStackForMainThreadStucked];
                    
                }
            }
             _timeoutCount = 0;
        }
    });
    
}


//void my_backtrace2()
//{
//    void *buffer[100] = { NULL };
//    char **trace = NULL;
//    int size = backtrace(buffer, 100);
//    trace = backtrace_symbols(buffer, size);
//    if (NULL == trace) {
//        return;
//    }
//    
//    size_t name_size = 100;
//    char *name = (char*)malloc(name_size);
//    for (int i = 0; i < size; ++i) {
//        char *begin_name = 0;
//        char *begin_offset = 0;
//        char *end_offset = 0;
//        for (char *p = trace[i]; *p; ++p) { // 利用了符号信息的格式
//            if (*p == '(') { // 左括号
//                begin_name = p;
//            }
//            else if (*p == '+' && begin_name) { // 地址偏移符号
//                begin_offset = p;
//            }
//            else if (*p == ')' && begin_offset) { // 右括号
//                end_offset = p;
//                break;
//            }
//        }
//        if (begin_name && begin_offset && end_offset ) {
//            *begin_name++ = '\0';
//            *begin_offset++ = '\0';
//            *end_offset = '\0';
//            int status = -4; // 0 -1 -2 -3
////            char *ret = abi::__cxa_demangle(begin_name, name, &name_size, &status);
////            if (0 == status) {
////                name = ret;
////                printf("%s:%s+%s\n", trace[i], name, begin_offset);
////            }
////            else {
////                printf("%s:%s()+%s\n", trace[i], begin_name, begin_offset);
////            }
//        }
//        else {
//            printf("%s\n", trace[i]);
//        }
//    }
//    free(name);
//    free(trace);
//    printf("----------done----------\n");
//}

- (void)logCallStacks
{
    void *callStack[128];
    int frames = backtrace(callStack, 128);
    char **strs = backtrace_symbols(callStack, frames);
    int i;
    NSMutableArray *backtrace = [NSMutableArray arrayWithCapacity:frames];
    for (i = 0; i < frames; i++) {
        [backtrace addObject:[NSString stringWithUTF8String:strs[i]]];
    }
    free(strs);
    NSLog(@"=============:\n %@ \n", backtrace);
}


 // TODO: 对callback调用栈信息做处理
- (void)handleCallbacksStackForMainThreadStucked
{
    // 打印Log，并将Log信息保存到本地Log.db文件
    dispatch_async(dispatch_get_main_queue(), ^{
       //NSLog(@"%@", [NSThread callStackSymbols]);
         [self logCallStacks];
        
        uintptr_t* backtraceBuffer = {0};
        mach_port_t thread_id = mach_thread_self();
        
        uintptr_t address =
        ksbt_backtracePthread(thread_id,
                              backtraceBuffer,
                              100);
        
        
        
        
    });
    
//    [self logcallStacks];
}




- (void)stopMonitoring
{
    if (!_runLoopObserver)
        return;
    
    CFRunLoopRemoveObserver(CFRunLoopGetMain(), _runLoopObserver, kCFRunLoopCommonModes);
    CFRelease(_runLoopObserver);
    _runLoopObserver = NULL;
}








@end
