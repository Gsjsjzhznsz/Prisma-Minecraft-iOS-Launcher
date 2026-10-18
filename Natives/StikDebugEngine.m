//
//  StikDebugEngine.m
//  Amethyst
//
//  ★ Task291（PocketJ 对标移植 · 内置 JIT 第一阶段）：实现见头文件注释。
//  移植自 EricoEC/PocketJLauncher v1.4 Natives/stikdebug/StikDebugEngine.m
//  （AGPL-3.0，与 LICENSE.md 兼容；上游 StikDebug 同为 AGPL-3.0）。
//  与上游差异：i18n 走本仓 localize 四表；路径语义一致
//  （App Support/Pairing 权威副本 + Documents 用户落地副本）；FFI 隧道
//  主体（idevice.h / libidevice_ffi.a / 进程内附加协议）不入第一阶段，
//  待 appex helper 构建路径落成后随第二阶段回归。
//

#import "StikDebugEngine.h"
#import "utils.h"

#import <arpa/inet.h>
#import <sys/socket.h>
#import <unistd.h>

static NSString *const kAme291StikDebugErrorDomain = @"Prisma.StikDebug";

@implementation StikDebugEngine

+ (instancetype)sharedEngine {
    static StikDebugEngine *engine;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ engine = [StikDebugEngine new]; });
    return engine;
}

- (NSString *)pairingFilePath {
    NSURL *support = [NSFileManager.defaultManager
        URLForDirectory:NSApplicationSupportDirectory
               inDomain:NSUserDomainMask
      appropriateForURL:nil
                 create:YES
                  error:nil];
    NSURL *directory = [support URLByAppendingPathComponent:@"Pairing"
                                                isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    return [[directory URLByAppendingPathComponent:@"pairingFile.plist"] path];
}

- (NSString *)documentsPairingFilePath {
    NSURL *documents = [NSFileManager.defaultManager
        URLForDirectory:NSDocumentDirectory
               inDomain:NSUserDomainMask
      appropriateForURL:nil
                 create:YES
                  error:nil];
    return [[documents URLByAppendingPathComponent:@"pairingFile.plist"] path];
}

/// 配对数据合法性：非空 + 可解析为 plist 字典（PocketJ 同口径）
- (BOOL)ame291_validatePairingData:(NSData *)data error:(NSError **)error {
    if (data.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:kAme291StikDebugErrorDomain code:-30
                userInfo:@{NSLocalizedDescriptionKey: localize(@"ame291.jit.pairing_empty", nil)}];
        }
        return NO;
    }
    NSError *plistError = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:nil error:&plistError];
    if (![plist isKindOfClass:NSDictionary.class]) {
        if (error) {
            *error = plistError ?: [NSError errorWithDomain:kAme291StikDebugErrorDomain code:-31
                userInfo:@{NSLocalizedDescriptionKey: localize(@"ame291.jit.pairing_invalid", nil)}];
        }
        return NO;
    }
    return YES;
}

- (BOOL)ame291_writePairingData:(NSData *)data error:(NSError **)error {
    if (![self ame291_validatePairingData:data error:error]) return NO;
    if (![data writeToFile:self.pairingFilePath options:NSDataWritingAtomic error:error]) return NO;
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600}
                                   ofItemAtPath:self.pairingFilePath error:nil];
    return YES;
}

- (BOOL)synchronizePairingFileFromDocuments:(NSError **)error {
    NSString *source = self.documentsPairingFilePath;
    if (![NSFileManager.defaultManager fileExistsAtPath:source]) return self.hasPairingFile;
    NSData *data = [NSData dataWithContentsOfFile:source options:0 error:error];
    if (![self ame291_validatePairingData:data error:error]) return NO;
    NSData *current = [NSData dataWithContentsOfFile:self.pairingFilePath];
    if ([current isEqualToData:data]) return YES;
    return [self ame291_writePairingData:data error:error];
}

- (BOOL)hasPairingFile {
    return [NSFileManager.defaultManager fileExistsAtPath:self.pairingFilePath];
}

- (BOOL)importPairingFileAtURL:(NSURL *)URL error:(NSError **)error {
    BOOL accessing = [URL startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:URL options:0 error:error];
    if (accessing) [URL stopAccessingSecurityScopedResource];
    if (![self ame291_writePairingData:data error:error]) return NO;
    if (![data writeToFile:self.documentsPairingFilePath
                   options:NSDataWritingAtomic error:error]) return NO;
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600}
                                   ofItemAtPath:self.documentsPairingFilePath error:nil];
    return YES;
}

- (BOOL)deletePairingFile:(NSError **)error {
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *path in @[self.pairingFilePath, self.documentsPairingFilePath]) {
        if ([manager fileExistsAtPath:path] && ![manager removeItemAtPath:path error:error]) return NO;
    }
    return YES;
}

- (NSURL *)exportablePairingFileURL:(NSError **)error {
    if (![self synchronizePairingFileFromDocuments:error] && !self.hasPairingFile) return nil;
    NSData *data = [NSData dataWithContentsOfFile:self.pairingFilePath options:0 error:error];
    if (![self ame291_validatePairingData:data error:error]) return nil;
    if (![data writeToFile:self.documentsPairingFilePath
                   options:NSDataWritingAtomic error:error]) return nil;
    return [NSURL fileURLWithPath:self.documentsPairingFilePath];
}

- (void)checkLocalDevVPNWithCompletion:(void (^)(BOOL connected))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int descriptor = socket(AF_INET, SOCK_STREAM, 0);
        BOOL connected = NO;
        if (descriptor >= 0) {
            struct timeval timeout = {.tv_sec = 0, .tv_usec = 600000};
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
            struct sockaddr_in address = {0};
            address.sin_family = AF_INET;
            address.sin_port = htons(49152);
            if (inet_pton(AF_INET, "10.7.0.1", &address.sin_addr) == 1) {
                connected = connect(descriptor, (const struct sockaddr *)&address,
                                    sizeof(address)) == 0;
            }
            close(descriptor);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(connected);
        });
    });
}

@end
