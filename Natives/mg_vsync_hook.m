// ===== Task 298：MobileGL(DirectVulkan) 帧率解锁根修 —— vkCreateSwapchainKHR
// present mode 强制 IMMEDIATE（POJAV_DISABLE_VSYNC=1 时） =====
//
// 病历（用户 2026-10-19："现在就 zink 渲染器可以超过 60fps"）：
//   MobileGL(libMobileGL.dylib, DirectVulkan) 后端的 swapchain present mode
//   由其静态偏好表 ChooseSwapchainPresentMode 决定（上游
//   Amethyst-iOS-MyRemastered Natives/external/MobileGL/MobileGL/
//   MG_Backend/DirectVulkan/Renderer/SwapchainObject.h：
//   s_desiredPresentModes = { MAILBOX, IMMEDIATE, FIFO_RELAXED, FIFO }），
//   首选 MAILBOX —— MoltenVK 的 MAILBOX/FIFO 都按 CAMetalLayer 显示节奏
//   同步（60Hz 面板=60fps 锁死）。而 MC 关垂直同步发的 eglSwapInterval(0)
//   在该后端是空操作：上游 MG_Impl/EGLImpl/EGLImpl.cpp SwapInterval 转发
//   BackendObject::SetEGLSwapInterval → backendFunctions.SetSwapInterval，
//   但 DirectVulkan.cpp 根本没有实现 SetSwapInterval 钩子（DirectGLES 才有
//   ApplyRequestedSwapInterval，符号表实锤）→ interval 永远到不了呈现层。
//   zink（GL→Mesa→Vulkan→MoltenVK）不同：gl_bridge gl_make_current 读
//   POJAV_DISABLE_VSYNC=1 提前 eglSwapInterval(0)，Mesa zink 据此在
//   swapchain 创建时选 VK_PRESENT_MODE_IMMEDIATE_KHR → 帧率解锁。这就是
//   "只有 zink 能超 60fps" 的完整根因链。
//
// 修法（libMobileGL.dylib 是预编译成品不可改源 → 进程内 GOT 改绑）：
//   libMobileGL.dylib 直链 @rpath/libMoltenVK.dylib，其 __got 走
//   LC_DYLD_CHAINED_FIXUPS（Mach-O 取证实锤：无经典 indirect symbol
//   table，本仓 283 行经典 fishhook 不支持 chained fixups，Task132/133
//   病历同款）——不解析 chained 导入表，直接 value-scan：
//   ① 遍历已加载镜像找到 libMoltenVK.dylib，dlopen(NOLOAD)+dlsym 拿
//      vkCreateSwapchainKHR 真实地址；
//   ② 扫 libMobileGL.dylib 的 __DATA_CONST __got（S_NON_LAZY_SYMBOL_
//      POINTERS）中等于该地址的指针槽（解析值唯一，即其导入槽）；
//   ③ vm_protect RW|COPY 改写槽值为包装器（Task132 同款页保护手法）。
//   包装器在 POJAV_DISABLE_VSYNC=1 时把 VkSwapchainCreateInfoKHR.
//   presentMode 改为 VK_PRESENT_MODE_IMMEDIATE_KHR（枚举值 0）再转发；
//   vsync 开启（=0）时原样透传（MobileGL 的 MAILBOX 默认语义保留）。
//   zink/ANGLE/virgl 等其他渲染器不经 libMobileGL 的 __got，零误伤；
//   -gles 变体（DirectGLES 后端，无 Vulkan swapchain）钩了也不触发。
//
// 安装点（Task299 重构）：①ctxbridges/gl_bridge.m dlsym_EGL（经典 GL 路径）
//   ②egl_bridge.m pojavInitOpenGLInternal 渲染器预加载 dlopen 后（SDL3 路径
//   ——装机 7672dd9 latestlog line725/754/755 实锤 mg/DirectVulkan 会话只走
//   SDL_GL_LoadLibrary->pojavInitOpenGLForSDL3，全程零 [VSyncUnlock] 日志，
//   Task298 唯一安装点不在其路径上，钩子从未装上）。幂等可重入。
//   ③ dyld add-image 观察者：libMoltenVK 晚于安装点加载（DirectVulkan 后端
//   初始化时才 dlopen），Task298 原版此时会 latch done=1 永久放弃——重构后
//   未就绪一律 defer 不锁存，观察者在 MoltenVK 镜像落地瞬间精确安装
//   （先于任何 swapchain 创建）。
//   env 检查移入包装器（swapchain 创建时动态读 POJAV_DISABLE_VSYNC）：
//   安装期与解锁开关无时序耦合，彻底消除 Task298 的 env-latch 病。
// 失败路径全部落日志（状态变化才打，add-image 风暴不刷屏）：安装失败=下
// 一个装机日志可直接对单，绝不静默。

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <stdalign.h>
#import <stddef.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

// Vulkan 1.0 VkSwapchainCreateInfoKHR（arm64 自然对齐 C 映射，96 字节；
// 只关心 presentMode@80 —— VK_PRESENT_MODE_IMMEDIATE_KHR = 0）
typedef struct {
    uint32_t sType;
    const void *pNext;
    uint32_t flags;
    void *surface;
    uint32_t minImageCount;
    int32_t imageFormat;
    uint32_t imageWidth;
    uint32_t imageHeight;
    uint32_t imageArrayLayers;
    uint32_t imageUsage;
    uint32_t queueFamilyIndexCount;
    const uint32_t *pQueueFamilyIndices;
    uint32_t preTransform;
    uint32_t compositeAlpha;
    int32_t presentMode;
    uint32_t clipped;
    void *oldSwapchain;
} ame298_VkSwapchainCreateInfoKHR;

_Static_assert(sizeof(ame298_VkSwapchainCreateInfoKHR) == 96,
               "ame298: VkSwapchainCreateInfoKHR layout drift");
_Static_assert(offsetof(ame298_VkSwapchainCreateInfoKHR, presentMode) == 80,
               "ame298: presentMode offset drift");

static void *(*ame298_real_vkCreateSwapchainKHR)(void *, const void *, const void *, void *);

// ===== Task300 第二层：vk*ProcAddr 解析器拦截 =====
// 取证（装机 dfc438f 用户反馈 fps 解锁仍无效 + libMobileGL.dylib 二进制串统计：
// vkGetInstanceProcAddr ×13 / vkGetDeviceProcAddr ×5 vs vkCreateSwapchainKHR ×2）
// ——MG 疑似经 vk*ProcAddr 动态解析 Vulkan 入口，静态 __got 直补层（第一层）
// 0 命中时改拦解析器本身：MG 查询 vkCreateSwapchainKHR 时直接返回包装器。
static int32_t ame298_hook_vkCreateSwapchainKHR(void *device, const void *pCreateInfo,
                                                const void *pAllocator, void *pSwapchain);
static void *ame300_real_vkGetInstanceProcAddr;
static void *ame300_real_vkGetDeviceProcAddr;

static void *ame300_hook_vkGetInstanceProcAddr(void *ame300_instance, const char *ame300_name) {
    if (ame300_name != NULL && strcmp(ame300_name, "vkCreateSwapchainKHR") == 0) {
        return (void *)&ame298_hook_vkCreateSwapchainKHR;
    }
    return ((void *(*)(void *, const char *))ame300_real_vkGetInstanceProcAddr)(ame300_instance, ame300_name);
}

static void *ame300_hook_vkGetDeviceProcAddr(void *ame300_device, const char *ame300_name) {
    if (ame300_name != NULL && strcmp(ame300_name, "vkCreateSwapchainKHR") == 0) {
        return (void *)&ame298_hook_vkCreateSwapchainKHR;
    }
    return ((void *(*)(void *, const char *))ame300_real_vkGetDeviceProcAddr)(ame300_device, ame300_name);
}

static int32_t ame298_hook_vkCreateSwapchainKHR(void *device, const void *pCreateInfo,
                                                const void *pAllocator, void *pSwapchain) {
    void *ame298_real = ame298_real_vkCreateSwapchainKHR;
    if (ame298_real == NULL) {
        return -1; // 理论不可达：槽被改写前 real 必已解析
    }
    // Task299：env 动态读（每次 swapchain 创建至多一次 getenv，成本可忽略）——
    // 安装期 env 未就绪不再造成永久失联（Task298 env-latch 病根治）。
    const char *ame298_dis = getenv("POJAV_DISABLE_VSYNC");
    if (pCreateInfo != NULL && ame298_dis != NULL && strcmp(ame298_dis, "1") == 0) {
        const ame298_VkSwapchainCreateInfoKHR *ci = (const ame298_VkSwapchainCreateInfoKHR *)pCreateInfo;
        if (ci->sType == 1000001000 /* VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR */ &&
            ci->presentMode != 0 /* VK_PRESENT_MODE_IMMEDIATE_KHR */) {
            ame298_VkSwapchainCreateInfoKHR patched = *ci;
            patched.presentMode = 0;
            static int ame298_logged_once = 0;
            if (!ame298_logged_once) {
                ame298_logged_once = 1;
                NSLog(@"[VSyncUnlock] ame298: swapchain presentMode %d -> IMMEDIATE (POJAV_DISABLE_VSYNC=1, MobileGL DirectVulkan unlock)",
                      ci->presentMode);
            }
            return ((int32_t (*)(void *, const void *, const void *, void *))ame298_real)(
                device, &patched, pAllocator, pSwapchain);
        }
    }
    return ((int32_t (*)(void *, const void *, const void *, void *))ame298_real)(
        device, pCreateInfo, pAllocator, pSwapchain);
}

// 在指定镜像的段表里找 __DATA_CONST __got（S_NON_LAZY_SYMBOL_POINTERS），
// value-scan 等于 real 的槽改写为 hook。返回改写槽数（-1=段遍历失败）。
// Task300：label 入参化——同一扫描器复用于 vk*ProcAddr 解析器拦截，日志可对单。
static int ame298_patch_got_slots(const struct mach_header_64 *ame298_hdr, intptr_t ame298_slide,
                                  uintptr_t ame298_real, uintptr_t ame298_hook,
                                  const char *ame298_label) {
    if (ame298_hdr == NULL || ame298_hdr->magic != MH_MAGIC_64) {
        return -1;
    }
    uint8_t *ame298_base = (uint8_t *)ame298_hdr;
    struct load_command *ame298_lc =
        (struct load_command *)(ame298_base + sizeof(struct mach_header_64));
    uint32_t ame298_nsects_total = 0;
    struct segment_command_64 *ame298_seg = NULL;
    for (uint32_t i = 0; i < ame298_hdr->ncmds; ++i) {
        if (ame298_lc->cmd == LC_SEGMENT_64) {
            ame298_seg = (struct segment_command_64 *)ame298_lc;
            if (strcmp(ame298_seg->segname, "__DATA_CONST") == 0) {
                struct section_64 *ame298_sect =
                    (struct section_64 *)((uint8_t *)ame298_seg + sizeof(struct segment_command_64));
                for (uint32_t s = 0; s < ame298_seg->nsects; ++s, ++ame298_sect) {
                    // S_NON_LAZY_SYMBOL_POINTERS = 0x6（SectionType 掩码 0xff）
                    if ((ame298_sect->flags & SECTION_TYPE) != S_NON_LAZY_SYMBOL_POINTERS) {
                        continue;
                    }
                    if (strcmp(ame298_sect->sectname, "__got") != 0) {
                        continue;
                    }
                    uintptr_t *ame298_slots =
                        (uintptr_t *)(ame298_base + ame298_sect->addr + ame298_slide);
                    size_t ame298_count = ame298_sect->size / sizeof(uintptr_t);
                    for (size_t k = 0; k < ame298_count; ++k) {
                        if (ame298_slots[k] != ame298_real) {
                            continue;
                        }
                        long ame298_psize = sysconf(_SC_PAGESIZE);
                        if (ame298_psize <= 0) ame298_psize = 16384; // arm64 iOS 16KB
                        uintptr_t ame298_slot_addr = (uintptr_t)&ame298_slots[k];
                        uintptr_t ame298_page = ame298_slot_addr & ~((uintptr_t)ame298_psize - 1);
                        kern_return_t ame298_kr = vm_protect(
                            mach_task_self(), (vm_address_t)ame298_page,
                            (vm_size_t)ame298_psize, FALSE,
                            VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                        if (ame298_kr != KERN_SUCCESS) {
                            NSLog(@"[VSyncUnlock] ame298: vm_protect failed (%d) at slot %p -- %s",
                                  ame298_kr, (void *)ame298_slot_addr,
                                  "MobileGL present-mode unlock NOT installed");
                            return -1;
                        }
                        ame298_slots[k] = ame298_hook;
                        ame298_nsects_total++;
                        NSLog(@"[VSyncUnlock] ame300: __got slot #%zu @%p rebound %s -> hook (real=%p)",
                              k, (void *)ame298_slot_addr, ame298_label, (void *)ame298_real);
                    }
                }
            }
        }
        ame298_lc = (struct load_command *)((uint8_t *)ame298_lc + ame298_lc->cmdsize);
    }
    return (int)ame298_nsects_total;
}

// Task299 安装状态机：done 仅在【终态】锁存（已装/硬失败/放弃）；
// 镜像未就绪一律 defer（Task298 的 MoltenVK 晚加载 latch 病根治）。
static int ame298_done = 0;
static int ame298_attempts = 0;
static BOOL ame298_defer_logged = NO;

static void ame298_try_install(const char *ame298_trigger) {
    if (ame298_done) {
        return;
    }
    ame298_attempts++;

    // ① 定位 libMobileGL.dylib 镜像（严格名匹配，-gles 物理同体但 DirectGLES
    //    无 Vulkan swapchain，钩槽不会触发，无需区分）
    const struct mach_header_64 *ame298_mg_hdr = NULL;
    intptr_t ame298_mg_slide = 0;
    const char *ame298_mv_path = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *ame298_name = _dyld_get_image_name(i);
        if (ame298_name == NULL) continue;
        const char *ame298_leaf = strrchr(ame298_name, '/');
        ame298_leaf = ame298_leaf ? ame298_leaf + 1 : ame298_name;
        if (strcmp(ame298_leaf, "libMobileGL.dylib") == 0) {
            ame298_mg_hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
            ame298_mg_slide = _dyld_get_image_vmaddr_slide(i);
        } else if (strcmp(ame298_leaf, "libMoltenVK.dylib") == 0) {
            ame298_mv_path = ame298_name;
        }
    }
    if (ame298_mg_hdr == NULL || ame298_mv_path == NULL) {
        // 未就绪：不锁存，等 dyld add-image 观察者在镜像落地瞬间重试。
        // 每 20 次尝试落一条日志（注册即对已加载全镜像回调，绝不刷屏）。
        if (!ame298_defer_logged || (ame298_attempts % 20) == 0) {
            ame298_defer_logged = YES;
            NSLog(@"[VSyncUnlock] ame299: images not ready (MobileGL=%d MoltenVK=%d, attempt %d, trigger=%s) -- deferred",
                  ame298_mg_hdr != NULL, ame298_mv_path != NULL, ame298_attempts, ame298_trigger);
        }
        if (ame298_attempts >= 100) {
            ame298_done = 1;
            NSLog(@"[VSyncUnlock] ame299: %d attempts without both images -- renderer never became MobileGL, hook disarmed",
                  ame298_attempts);
        }
        return;
    }

    // ② 拿 vkCreateSwapchainKHR 真实地址（NOLOAD 引用已加载镜像）
    void *ame298_mv = dlopen(ame298_mv_path, RTLD_LAZY | RTLD_NOLOAD);
    if (ame298_mv == NULL) {
        ame298_mv = dlopen(ame298_mv_path, RTLD_LAZY);
    }
    if (ame298_mv == NULL) {
        ame298_done = 1;
        NSLog(@"[VSyncUnlock] ame299: dlopen(libMoltenVK) failed: %s -- hook aborted", dlerror() ?: "?");
        return;
    }
    void *ame298_real = dlsym(ame298_mv, "vkCreateSwapchainKHR");
    if (ame298_real == NULL) {
        ame298_done = 1;
        NSLog(@"[VSyncUnlock] ame299: dlsym(vkCreateSwapchainKHR) failed: %s -- hook aborted", dlerror() ?: "?");
        return;
    }
    ame298_real_vkCreateSwapchainKHR =
        (void *(*)(void *, const void *, const void *, void *))ame298_real;

    // ③ value-scan + GOT 改绑
    int ame298_patched = ame298_patch_got_slots(
        ame298_mg_hdr, ame298_mg_slide, (uintptr_t)ame298_real, (uintptr_t)&ame298_hook_vkCreateSwapchainKHR,
        "vkCreateSwapchainKHR");
    ame298_done = 1;
    if (ame298_patched < 0) {
        NSLog(@"[VSyncUnlock] ame299: __got scan failed -- MobileGL present-mode unlock NOT installed");
    } else if (ame298_patched == 0) {
        // Task300 第二层：动态解析路径拦截（证据与设计见文件头与钩子函数注释）。
        void *ame300_real_gi = dlsym(ame298_mv, "vkGetInstanceProcAddr");
        void *ame300_real_gd = dlsym(ame298_mv, "vkGetDeviceProcAddr");
        int ame300_patched_pa = 0;
        if (ame300_real_gi != NULL) {
            ame300_real_vkGetInstanceProcAddr = ame300_real_gi;
            ame300_patched_pa += ame298_patch_got_slots(
                ame298_mg_hdr, ame298_mg_slide, (uintptr_t)ame300_real_gi,
                (uintptr_t)&ame300_hook_vkGetInstanceProcAddr, "vkGetInstanceProcAddr");
        }
        if (ame300_real_gd != NULL) {
            ame300_real_vkGetDeviceProcAddr = ame300_real_gd;
            ame300_patched_pa += ame298_patch_got_slots(
                ame298_mg_hdr, ame298_mg_slide, (uintptr_t)ame300_real_gd,
                (uintptr_t)&ame300_hook_vkGetDeviceProcAddr, "vkGetDeviceProcAddr");
        }
        if (ame300_patched_pa > 0) {
            NSLog(@"[VSyncUnlock] ame300: proc-addr interception installed (%d resolver slot(s)) -- "
                  @"vkCreateSwapchainKHR queries now return IMMEDIATE wrapper (dynamic-resolution path)",
                  ame300_patched_pa);
        } else {
            NSLog(@"[VSyncUnlock] ame300: no __got slot matched vkCreateSwapchainKHR or vk*ProcAddr "
                  @"(real=%p) -- MobileGL resolves Vulkan entry points neither via static GOT nor "
                  @"imported resolvers; unlock NOT installed (diagnostic anchor for next round)",
                  ame298_real);
        }
    } else {
        NSLog(@"[VSyncUnlock] ame299: installed (%d slot(s)) -- swapchains will present IMMEDIATE while POJAV_DISABLE_VSYNC=1",
              ame298_patched);
    }
}

// dyld 镜像加载回调：MoltenVK 由 DirectVulkan 后端初始化时才 dlopen，
// 该回调保证在【任何 swapchain 创建之前】给出精确安装时机。
// 注册时 dyld 会对全部已加载镜像各回调一次（文档行为）——回调体必须廉价：
// done 短路 + 名称扫描，仅状态变化才落日志（ame298_try_install 内控）。
static void ame298_image_added_cb(const struct mach_header *ame298_mh, intptr_t ame298_slide) {
    (void)ame298_mh; (void)ame298_slide;
    if (ame298_done) return;
    ame298_try_install("add-image");
}

void ame298_install_mg_vsync_hook(void) {
    static dispatch_once_t ame298_arm_once;
    dispatch_once(&ame298_arm_once, ^{
        _dyld_register_func_for_add_image(ame298_image_added_cb);
        NSLog(@"[VSyncUnlock] ame299: dyld add-image observer armed -- env checked at swapchain time, MoltenVK late-load covered");
    });
    ame298_try_install("eager");
}
