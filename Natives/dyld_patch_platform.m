#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonCrypto.h>
#include <libgen.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <sys/stat.h>
#include <pthread.h>
#include <unistd.h>

#include "ame107_codesign.h"

// dyld_get_active_platform() 声明于 <mach-o/dyld.h>，但其带
// __API_AVAILABLE(macos(12.0), ios(15.0)) 可用性标注——本工程部署目标更低，
// 直接 include 会在老目标上触发可用性错误。沿用 Task106 前的裸 extern 声明
// （跳过可用性检查，运行时符号自 iOS 15 起存在，本设备 iPadOS 27 无虞）。
// Task107 重写时该声明曾被意外丢失——CI（clang C99+，隐式函数声明为
// error）在 dyld_patch_platform.m:84 响亮失败，本行即为其修复。
extern int dyld_get_active_platform();

// Task 107：重标签后的 ad-hoc 重签名，取代 Task106 的签名中和。
//
// Task106 中和（LC_CODE_SIGNATURE → LC_SOURCE_VERSION + blob 清零）的实测教训：
// 本设备（iPadOS 27 / dyld4）对 dlopen 镜像强制要求“存在代码签名 blob”
// （ce43a34 双会话 JNA libjnidispatch 均报 "missing code signature in
// <C34856C0-A4B7-32C6-9ACE-D2166123DD04>"，该 UUID 与 jna-5.13.0.jar 内
// darwin-aarch64/libjnidispatch.jnilib 的 LC_UUID 逐字一致）；但对该
// blob 的哈希校验宽松（调试态侧载进程）——“ad-hoc 签名 + 平台重标签
// （页 0 哈希失效）”自始至终可加载。中和把库变成“无签名”，恰恰触发了
// 唯一致命的形态。26.3 会话 MacosUtil.disableCloseWindowMenuItem →
// ca.weblite.objc.Runtime → JNA 链上无降级，直接 NoClassDefFoundError。
//
// 正解：重标签后重算 [0, dataoff) 的 SHA-256 页哈希，构建全新 ad-hoc
// CodeDirectory SuperBlob 原位替换。产出在任何接受 ad-hoc 的策略下合法
// （严格优于历史上被容忍的“失效哈希 ad-hoc”）。实现见 ame107_codesign.h
// （纯 C，SHA-256 后端函数指针注入，本地 harness 可用 OpenSSL 走同一份代码）。
static const char *kAme107Identifier = "amethyst-retag";

static void ame107_cc_sha256(const uint8_t *data, size_t len, uint8_t out[32]) {
    CC_SHA256(data, (CC_LONG)len, out);
}

// 取证日志封顶（沿用 Task106 blocked-dlopen 的 3 次封顶惯例）。
// 成功与告警分桶：防成功日志挤掉更重要的告警取证。
static void ame107_log_ok3(const char *msg, const char *path) {
    static int s_ok = 0;
    if (s_ok < 3) {
        s_ok++;
        NSLog(@"[Prisma] Task107: %s (%s)", msg, path);
    }
}

static void ame107_log_warn3(const char *msg, const char *path) {
    static int s_warn = 0;
    if (s_warn < 3) {
        s_warn++;
        NSLog(@"[Prisma] Task107: %s (%s)", msg, path);
    }
}

// Rewrite an LC_(LOAD|WEAK)_DYLIB install name in place. The replacement must
// fit in the original load command's string buffer.
static void PLRewriteDylibName(struct dylib_command *dylib, const char *newName) {
    char *dylibName = (void *)dylib + dylib->dylib.name.offset;
    size_t bufLen = dylib->cmdsize - dylib->dylib.name.offset;
    size_t nameLen = strlen(newName);
    if (nameLen + 1 > bufLen) return;
    memcpy(dylibName, newName, nameLen + 1);
    memset(dylibName + nameLen + 1, 0, bufLen - nameLen - 1);
}

// 切片上下文：文件级缓冲（读入-改写-写回），thin 切片允许整体增长。
typedef struct {
    uint8_t    *data;        // 文件缓冲
    size_t      size;        // 缓冲有效长度（增长后同步更新）
    BOOL        canGrow;     // 仅 thin（切片==整文件）可增长
    uint32_t    sliceOffset; // 切片在文件中的绝对偏移（thin=0）
    uint32_t    sliceSize;   // 切片原始长度
    const char *path;
} ame107_slice_ctx;

static BOOL PLPatchMachOPlatformForSlice(struct mach_header_64 *header, ame107_slice_ctx *ctx) {
    uint8_t *imageHeaderPtr = (uint8_t*)header + sizeof(struct mach_header_64);
    BOOL retagged = NO;
    struct linkedit_data_command *sigCmd = NULL;
    struct segment_command_64 *linkedit = NULL;

    struct load_command *command = (struct load_command *)imageHeaderPtr;
    for(int i = 0; i < header->ncmds; i++) {
        if (command->cmdsize == 0) break; // 畸形防御：零尺寸会导致死循环
        if (command->cmd == LC_BUILD_VERSION) {
            struct build_version_command *buildver = (struct build_version_command *)command;
            int activePlatform = dyld_get_active_platform();
            if (buildver->platform == activePlatform) return NO; // it is already set, stop
            buildver->platform = activePlatform; // set to current platform
            retagged = YES;
        } else if (command->cmd == LC_LOAD_DYLIB || command->cmd == LC_LOAD_WEAK_DYLIB) {
            struct dylib_command *dylib = (struct dylib_command *)command;
            char *dylibName = (void *)dylib + dylib->dylib.name.offset;
            char *verPtr = strstr(dylibName, "/Versions/");
            if (verPtr) {
                // Remove "/Versions/X"
                int lastComponentLen = strlen(dylibName) - (verPtr - dylibName) - 11;
                memmove(verPtr, verPtr + 11, lastComponentLen);
                verPtr[lastComponentLen] = '\0';
            }
            // Redirect macOS-only umbrella frameworks to iOS equivalents.
            // Cocoa/AppKit don't exist on iOS, which makes dlopen fail even
            // after the platform retag above. libjcocoa (java-objc-bridge,
            // pulled in by Minecraft's MacosUtil) links Cocoa but only uses
            // Foundation symbols eagerly; everything AppKit is resolved at
            // runtime via objc_getClass, whose nil results are harmless.
            // UIKit exists on iOS and its path has the exact same length as
            // the stripped Cocoa path, so it always fits in place.
            if (strstr(dylibName, "Cocoa.framework") || strstr(dylibName, "AppKit.framework")) {
                PLRewriteDylibName(dylib, "/System/Library/Frameworks/UIKit.framework/UIKit");
            }
        } else if (command->cmd == LC_CODE_SIGNATURE) {
            // Task 107：记录签名命令——重标签后页 0 哈希必然失效，
            // 需重建 ad-hoc 签名（Task106 的“中和为无签名”在本机
            // dyld4 下会被 "missing code signature" 硬拒，JNA 实锤）。
            sigCmd = (struct linkedit_data_command *)command;
        } else if (command->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)command;
            if (seg->segname[0] == '_' && strncmp(seg->segname, "__LINKEDIT", 16) == 0) {
                linkedit = seg;
            }
        }
        command = (struct load_command *)((void *)command + command->cmdsize);
    }

    if (retagged && sigCmd != NULL) {
        uint8_t *sliceBase = (uint8_t *)header;
        uint32_t dataoff = sigCmd->dataoff;
        uint32_t origDatasize = sigCmd->datasize;
        size_t blobLen = ame107_adhoc_blob_size(dataoff, strlen(kAme107Identifier) + 1);

        if (dataoff == 0 || (uint64_t)dataoff + origDatasize > ctx->sliceSize || blobLen == 0) {
            // 畸形边界：保留旧签名（失效哈希，Task106 前的被容忍行为）
            ame107_log_warn3("signature load command out of slice bounds, kept stale", ctx->path);
        } else if (blobLen <= origDatasize) {
            // 原位置换：datasize 先收紧（页 0 定稿），再算哈希建 blob，
            // 尾部死区清零。FAT 切片天然安全（不越过旧 blob 末尾）。
            sigCmd->datasize = (uint32_t)blobLen;
            size_t builtLen = 0;
            uint8_t *blob = ame107_build_adhoc_superblob(sliceBase, dataoff, kAme107Identifier,
                                                         ame107_cc_sha256, &builtLen);
            if (blob != NULL && builtLen == blobLen) {
                memcpy(sliceBase + dataoff, blob, builtLen);
                memset(sliceBase + dataoff + builtLen, 0, origDatasize - builtLen);
                ame107_log_ok3("re-signed ad-hoc after platform retag (in place)", ctx->path);
            } else {
                sigCmd->datasize = origDatasize; // 回滚：blob 构建失败不能留半改状态
            }
            free(blob);
        } else if (ctx->canGrow) {
            // thin 增长。顺序关键：
            //   1) 以“偏移量”记录 sigCmd/__LINKEDIT（realloc 会搬移基址）；
            //   2) 预扩缓冲并清零扩展区，重取切片指针；
            //   3) 定稿页 0（datasize + __LINKEDIT 覆盖范围）；
            //   4) 再算哈希建 blob（哈希覆盖页 0 终态）；
            //   5) 写入 blob。任一步失败回滚 datasize/linkedit，保持旧签名。
            size_t sigOff = (size_t)((uint8_t *)sigCmd - sliceBase);
            size_t linkOff = linkedit ? (size_t)((uint8_t *)linkedit - sliceBase) : 0;
            size_t newEnd = (size_t)ctx->sliceOffset + dataoff + blobLen;
            BOOL grown = (newEnd <= ctx->size);
            if (!grown) {
                uint8_t *nb = (uint8_t *)realloc(ctx->data, newEnd);
                if (nb != NULL) {
                    memset(nb + ctx->size, 0, newEnd - ctx->size);
                    ctx->data = nb;
                    ctx->size = newEnd;
                    grown = YES;
                }
            }
            if (grown) {
                sliceBase = ctx->data + ctx->sliceOffset; // realloc 后重取
                sigCmd = (struct linkedit_data_command *)(sliceBase + sigOff);
                linkedit = linkOff ? (struct segment_command_64 *)(sliceBase + linkOff) : NULL;
                uint64_t savedFilesize = linkedit ? linkedit->filesize : 0;
                uint64_t savedVmsize = linkedit ? linkedit->vmsize : 0;
                sigCmd->datasize = (uint32_t)blobLen;
                if (linkedit != NULL) {
                    uint64_t newFileSize = (uint64_t)dataoff + (uint64_t)blobLen - linkedit->fileoff;
                    if (newFileSize > linkedit->filesize) linkedit->filesize = newFileSize;
                    if (linkedit->filesize > linkedit->vmsize) linkedit->vmsize = linkedit->filesize;
                }
                size_t builtLen = 0;
                uint8_t *blob = ame107_build_adhoc_superblob(sliceBase, dataoff, kAme107Identifier,
                                                             ame107_cc_sha256, &builtLen);
                if (blob != NULL && builtLen == blobLen) {
                    memcpy(sliceBase + dataoff, blob, builtLen);
                    ame107_log_ok3("re-signed ad-hoc after platform retag (grown)", ctx->path);
                } else {
                    sigCmd->datasize = origDatasize; // 回滚页 0，保持旧签名
                    if (linkedit != NULL) { linkedit->filesize = savedFilesize; linkedit->vmsize = savedVmsize; }
                }
                free(blob);
            } else {
                ame107_log_warn3("re-sign grow alloc failed, kept stale", ctx->path);
            }
        } else {
            // FAT 无法后移切片：保留旧签名（失效哈希；team 签名的 FAT
            // 库仍会死——spark libasyncProfiler 由 hooked_dlopen 拦截，
            // 其余场景以此日志暴露）。
            ame107_log_warn3("FAT slice cannot grow for re-sign, kept stale", ctx->path);
        }
    } else if (retagged && sigCmd == NULL) {
        // 无签名 macOS 库：重标签照旧，但无法重建签名（不新增 LC）。
        // 本设备历史 0 例；留取证日志以便下轮日志直接定位。
        ame107_log_warn3("retagged unsigned lib, no signature to rebuild", ctx->path);
    }
    // 返回值语义与 Task106 前完全一致：除“平台已匹配早退”外一律 YES
    // （dylib 名重写等改动同样需要写回，即便未发生重标签——如 VERSION_MIN
    // 形态的旧库）。
    return YES;
}


BOOL PLPatchMachOPlatformForFile(const char *path) {
    // 读入-改写-写回（替代 mmap MAP_SHARED）：需要支持 thin 文件增长，
    // 且避免映射写回与 ftruncate 的交互。多线程 dlopen 互斥保护。
    static pthread_mutex_t sLock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&sLock);

    int fd = open(path, O_RDWR, (mode_t)0600);
    if (fd == -1) { pthread_mutex_unlock(&sLock); return NO; }
    struct stat s;
    if (fstat(fd, &s) != 0 || s.st_size <= 0) { close(fd); pthread_mutex_unlock(&sLock); return NO; }
    size_t fileSize = (size_t)s.st_size;

    uint8_t *buf = (uint8_t *)malloc(fileSize);
    if (buf == NULL) { close(fd); pthread_mutex_unlock(&sLock); return NO; }
    size_t got = 0;
    while (got < fileSize) {
        ssize_t n = read(fd, buf + got, fileSize - got);
        if (n <= 0) break;
        got += (size_t)n;
    }
    if (got != fileSize) { free(buf); close(fd); pthread_mutex_unlock(&sLock); return NO; }

    ame107_slice_ctx ctx = { buf, fileSize, NO, 0, (uint32_t)fileSize, path };

    BOOL patched = NO;
    uint32_t magic = *(uint32_t *)buf;
    if (magic == FAT_CIGAM) {
        // Find compatible slice
        struct fat_header *header = (struct fat_header *)buf;
        struct fat_arch *arch = (struct fat_arch *)(buf + sizeof(struct fat_header));
        for (int i = 0; i < OSSwapInt32(header->nfat_arch); i++) {
            if (OSSwapInt32(arch->cputype) == CPU_TYPE_ARM64) {
                NSLog(@"[Prisma] Patching %s", path);
                uint32_t off = OSSwapInt32(arch->offset);
                uint32_t sz = OSSwapInt32(arch->size);
                if (off + sz <= fileSize) {
                    ame107_slice_ctx sliceCtx = { buf, fileSize, NO, off, sz, path };
                    patched |= PLPatchMachOPlatformForSlice((struct mach_header_64 *)(buf + off), &sliceCtx);
                    // FAT 切片永不增长，ctx 尺寸不变
                }
            }
            arch = (struct fat_arch *)((void *)arch + sizeof(struct fat_arch));
        }
    } else if (magic == MH_MAGIC_64 && ((struct mach_header_64 *)buf)->cputype == CPU_TYPE_ARM64) {
        ctx.canGrow = YES;
        patched = PLPatchMachOPlatformForSlice((struct mach_header_64 *)buf, &ctx);
    }

    if (patched) {
        if (pwrite(fd, ctx.data, ctx.size, 0) == (ssize_t)ctx.size) {
            if (ctx.size != fileSize) (void)ftruncate(fd, (off_t)ctx.size);
        } else {
            NSLog(@"[Prisma] Task107: write-back failed for %s", path);
        }
    }
    free(ctx.data);
    close(fd);
    pthread_mutex_unlock(&sLock);
    return patched;
}
