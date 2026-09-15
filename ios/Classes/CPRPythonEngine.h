#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^CPRPythonEventHandler)(NSDictionary<NSString *, id> *event);

@interface CPRPythonEngine : NSObject

@property(nonatomic, copy, nullable) CPRPythonEventHandler eventHandler;
@property(nonatomic, copy, nullable) BOOL (^interruptionHandler)(int64_t jobId);

- (BOOL)initializeWithPythonHome:(NSString *)pythonHome error:(NSError **)error;
- (NSDictionary<NSString *, id> *)executeJob:(int64_t)jobId
                                    sessionId:(int64_t)sessionId
                                     evaluate:(BOOL)evaluate
                                       source:(NSString *)source
                                     filename:(NSString *)filename
                                    arguments:(NSArray<NSString *> *)arguments
                              workingDirectory:(NSString *)workingDirectory
                                  projectPath:(nullable NSString *)projectPath;
- (void)interruptJob:(int64_t)jobId;
- (void)destroySession:(int64_t)sessionId;
- (void)completeHostCall:(int64_t)callId
              resultJson:(nullable NSString *)resultJson
                   error:(nullable NSString *)error;
- (NSDictionary<NSString *, id> *)runtimeInfo;
- (void)dispose;

@end

NS_ASSUME_NONNULL_END
