#import "CrashAnalyzer.h"

/// Task218：崩溃识别引擎实现。纯工具类（无 UI、无网络），输入文件路径
/// 输出分型字典；展示与决策由 JavaLauncher 的裁决器消费。

/// 渲染器家族库 -> 渲染器键映射（键 = 渲染器层存储值 = dylib 文件名）。
/// 与 utils.h 的 RENDERER_NAME_* 宏族同口径；libvtestserver.dylib 是
/// VirGL 渲染器的 vtest 伴生服务端（dep_virgl 链产物），归并到
/// libOSMesaVirgl.dylib 键；libgl4es_114.dylib 是 holy gl4es 存量
///（Task212 退役迁移读到的历史形态），归并到 ZL2 键。
static NSDictionary<NSString *, NSString *> *ame218_rendererLibMap(void) {
    static NSDictionary<NSString *, NSString *> *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"libOSMesa.8.dylib"      : @"libOSMesa.8.dylib",       // zink
            @"libOSMesaVirgl.dylib"   : @"libOSMesaVirgl.dylib",    // virgl
            @"libvtestserver.dylib"   : @"libOSMesaVirgl.dylib",    // virgl 服务端伴生
            @"libMobileGL.dylib"      : @"libMobileGL.dylib",       // mg Vulkan 直连
            @"libMobileGL-gles.dylib" : @"libMobileGL.dylib",       // mg GLES 后端
            @"libmobileglues.dylib"   : @"libmobileglues.dylib",    // MobileGlues GLES/4.0
            @"libmithril.dylib"       : @"libmithril.dylib",        // mg Mithril 后端
            @"libgl4eszl2.dylib"      : @"libgl4eszl2.dylib",       // gl4es (ZL2)
            @"libgl4es_114.dylib"     : @"libgl4eszl2.dylib",       // holy gl4es 存量
            @"libtinygl4angle.dylib"  : @"libtinygl4angle.dylib",   // ANGLE
            @"libMoltenVK.dylib"      : @"libMoltenVK.dylib",       // Vulkan 直连
        };
    });
    return map;
}

/// 从帧行 "# C  [libX.dylib+0x1234]  0x..." 里提取库名；非该形态返回 nil。
static NSString *ame218_libraryInFrameLine(NSString *line) {
    NSRange ob = [line rangeOfString:@"["];
    if (ob.location == NSNotFound) return nil;
    NSRange plus = [line rangeOfString:@"+" options:0 range:NSMakeRange(ob.location, line.length - ob.location)];
    if (plus.location == NSNotFound || plus.location <= ob.location + 1) return nil;
    return [line substringWithRange:NSMakeRange(ob.location + 1, plus.location - ob.location - 1)];
}

@implementation CrashAnalyzer

+ (nullable NSString *)rendererKeyForLibraryName:(NSString *)libName {
    if (libName.length == 0) return nil;
    return ame218_rendererLibMap()[libName];
}

+ (NSDictionary *)analyzeHsErrFile:(NSString *)path {
    if (path.length == 0) return @{};
    // 64KB 上限：hs_err 头部（信号行 / Problematic frame / 前排 native
    // frames）必然落在文件前部；避免重型整合包时代的巨型 hs_err 全量读。
    NSFileHandle *ame218_handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!ame218_handle) return @{};
    NSData *ame218_chunk = [ame218_handle readDataOfLength:64 * 1024];
    [ame218_handle closeFile];
    NSString *ame218_text = [[NSString alloc] initWithData:ame218_chunk
                                                  encoding:NSUTF8StringEncoding];
    if (ame218_text.length == 0) return @{};

    NSArray<NSString *> *ame218_lines = [ame218_text componentsSeparatedByString:@"\n"];

    NSMutableDictionary *ame218_out = [NSMutableDictionary dictionary];
    ame218_out[@"signal"] = @"(unknown)";
    ame218_out[@"isOOM"] = @NO;

    BOOL ame218_pendingProblematic = NO;
    BOOL ame218_inNativeFrames = NO;
    NSMutableArray<NSString *> *ame218_nativeLibs = [NSMutableArray array];

    for (NSString *ame218_raw in ame218_lines) {
        NSString *ame218_line = [ame218_raw stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];

        // --- OOM 分型（判断脚本口径：Task106/109 装机取证沿用的头部判读）---
        if ([ame218_line hasPrefix:@"# There is insufficient memory for the Java Runtime Environment to continue"]) {
            ame218_out[@"isOOM"] = @YES;
        }
        // OpenJDK 25 起的紧凑 OOM 头形态（26.x 会话实测族）
        if ([ame218_line hasPrefix:@"# Out of Memory Error"] ||
            [ame218_line hasPrefix:@"# java.lang.OutOfMemoryError"]) {
            ame218_out[@"isOOM"] = @YES;
        }

        // --- 信号行：# SIGSEGV (0xb) at pc=0x... ---
        if ([ame218_line hasPrefix:@"# SIG"] && ame218_line.length > 5) {
            NSRange ame218_sp = [ame218_line rangeOfString:@" "];
            if (ame218_sp.location != NSNotFound && ame218_sp.location > 2) {
                ame218_out[@"signal"] = [ame218_line substringWithRange:
                    NSMakeRange(2, ame218_sp.location - 2)];
            }
        }

        // --- Problematic frame 行（其后的第一个非空帧行即摘要）---
        if ([ame218_line hasPrefix:@"# Problematic frame:"]) {
            ame218_pendingProblematic = YES;
            continue;
        }
        if (ame218_pendingProblematic) {
            if (ame218_line.length > 2) {
                ame218_out[@"problematicFrame"] =
                    [ame218_line substringFromIndex:2];   // 去掉 "# " 前缀
            }
            ame218_pendingProblematic = NO;
        }

        // --- Native frames 区：逐帧收集库名（前 40 条足够归因）---
        if ([ame218_line hasPrefix:@"# Native frames:"]) {
            ame218_inNativeFrames = YES;
            continue;
        }
        if (ame218_inNativeFrames) {
            // 帧行形态 "# C  [libX.dylib+0x4970] ..."：第三字符是帧类型
            //（C/V/J/j/v）；"# Java frames:" 及其它 "# xxx:" 段落头结束帧区。
            if ([ame218_line hasPrefix:@"# Java frames:"]) {
                ame218_inNativeFrames = NO;
            } else {
                BOOL ame218_isFrame = [ame218_line hasPrefix:@"# C"] ||
                                      [ame218_line hasPrefix:@"# V"] ||
                                      [ame218_line hasPrefix:@"# J"] ||
                                      [ame218_line hasPrefix:@"# j"] ||
                                      [ame218_line hasPrefix:@"# v"];
                if (ame218_isFrame && ame218_nativeLibs.count < 40) {
                    NSString *ame218_lib = ame218_libraryInFrameLine(ame218_line);
                    if (ame218_lib.length > 0) {
                        [ame218_nativeLibs addObject:ame218_lib];
                    }
                } else if (!ame218_isFrame && ame218_line.length > 2 &&
                           [ame218_line hasSuffix:@":"]) {
                    ame218_inNativeFrames = NO;
                }
            }
        }
    }

    if (ame218_nativeLibs.count > 0) {
        ame218_out[@"nativeFrames"] = [ame218_nativeLibs componentsJoinedByString:@", "];
    }

    // --- 渲染器归因：Problematic frame 的库优先，其次 native 帧序 ---
    // OOM 不归因（内存不足不是渲染器的锅）。
    if (![ame218_out[@"isOOM"] boolValue]) {
        NSString *ame218_blamed = nil;
        if (ame218_out[@"problematicFrame"]) {
            NSString *ame218_lib = ame218_libraryInFrameLine(ame218_out[@"problematicFrame"]);
            ame218_blamed = [self rendererKeyForLibraryName:ame218_lib];
        }
        if (!ame218_blamed) {
            for (NSString *ame218_lib in ame218_nativeLibs) {
                NSString *ame218_key = [self rendererKeyForLibraryName:ame218_lib];
                if (ame218_key) {
                    ame218_blamed = ame218_key;
                    break;
                }
            }
        }
        if (ame218_blamed) {
            ame218_out[@"blamedRenderer"] = ame218_blamed;
        }
    }

    return ame218_out;
}

@end
