//
//  TouchControllerBridge.m
//  Angel Aura Amethyst
//
//  TouchController JNI 桥接实现
//  实现 Minecraft TouchController Mod 与 iOS 启动器之间的通信
//
//  Task 134：双 ABI 通道。mod 26.2 世代改为单例 Transport（无句柄），
//  旧世代为句柄制。传输层（Natives/TouchController/ios_transport.c）同时
//  维护单例通道与命名句柄通道；本桥接把两条通道都打开——收发同时走
//  单例（新 mod）与命名句柄（旧 mod），无论 mod 是哪个世代都全通。
//

#import "TouchControllerBridge.h"
#import <dlfcn.h>
#import <os/log.h>

// TouchController 静态库的 C API 函数指针类型声明
// 这些类型匹配 touchcontroller_ios_* 系列函数签名（无 JNIEnv*/jclass 参数），
// 通过 dlsym 查找 C API 符号名（而非 JNI 命名符号），避免调用约定不匹配导致的崩溃
typedef void (*JNI_Init_Func)(void);              // touchcontroller_ios_init
typedef long long (*JNI_New_Func)(const char *name);  // touchcontroller_ios_new
typedef int (*JNI_Receive_Func)(long long handle, void *buffer, int length);  // touchcontroller_ios_receive_v1
typedef void (*JNI_Send_Func)(long long handle, const void *buffer, int offset, int length);  // touchcontroller_ios_send_v1
typedef void (*JNI_Destroy_Func)(long long handle);  // touchcontroller_ios_destroy
// Task 134：单例通道（新 ABI mod）——mod 仓库当前 C API 签名
typedef int (*TC_Singleton_Receive_Func)(void *buffer);      // touchcontroller_ios_receive
typedef int (*TC_Singleton_Send_Func)(const void *buffer, int len);  // touchcontroller_ios_send

// 函数指针
static JNI_Init_Func g_TouchController_Init = NULL;
static JNI_New_Func g_TouchController_New = NULL;
static JNI_Receive_Func g_TouchController_Receive = NULL;
static JNI_Send_Func g_TouchController_Send = NULL;
static JNI_Destroy_Func g_TouchController_Destroy = NULL;
static TC_Singleton_Receive_Func g_TouchController_SingletonReceive = NULL;
static TC_Singleton_Send_Func g_TouchController_SingletonSend = NULL;

// 是否已初始化
static BOOL g_Initialized = NO;
static void *g_LibraryHandle = NULL;

// 日志
static os_log_t touchControllerLog = NULL;

@implementation TouchControllerBridge

+ (void)load {
    touchControllerLog = os_log_create("com.air-devs.air", "TouchController");
    [self initializeTouchController];
}

+ (BOOL)initializeTouchController {
    if (g_Initialized) {
        return YES;
    }

    os_log_info(touchControllerLog, "Initializing TouchController bridge (Task134 dual-ABI)...");

    // 尝试加载 TouchController 静态库
    // 由于是静态链接，我们直接检查符号是否存在
    // 如果静态库已链接到可执行文件中，dlsym(RTLD_DEFAULT) 应该能找到符号

    g_TouchController_Init = (JNI_Init_Func)dlsym(RTLD_DEFAULT, "touchcontroller_ios_init");
    g_TouchController_New = (JNI_New_Func)dlsym(RTLD_DEFAULT, "touchcontroller_ios_new");
    g_TouchController_Receive = (JNI_Receive_Func)dlsym(RTLD_DEFAULT, "touchcontroller_ios_receive_v1");
    g_TouchController_Send = (JNI_Send_Func)dlsym(RTLD_DEFAULT, "touchcontroller_ios_send_v1");
    g_TouchController_Destroy = (JNI_Destroy_Func)dlsym(RTLD_DEFAULT, "touchcontroller_ios_destroy");
    g_TouchController_SingletonReceive = (TC_Singleton_Receive_Func)dlsym(RTLD_DEFAULT, "touchcontroller_ios_receive");
    g_TouchController_SingletonSend = (TC_Singleton_Send_Func)dlsym(RTLD_DEFAULT, "touchcontroller_ios_send");

    // 检查所有函数是否都找到了
    if (!g_TouchController_Init || !g_TouchController_New || !g_TouchController_Receive ||
        !g_TouchController_Send || !g_TouchController_Destroy) {
        const char *error = dlerror();
        os_log_error(touchControllerLog, "Failed to load TouchController symbols: %s", error ? error : "unknown error");
        g_Initialized = NO;
        return NO;
    }

    // 调用初始化函数（Task 134：现在会创建单例通道——新 ABI mod 的
    // Transport.init() 是幂等的，提前创建无副作用；旧 ABI mod 不走单例）
    if (g_TouchController_Init) {
        g_TouchController_Init();
    }

    g_Initialized = YES;
    os_log_info(touchControllerLog, "TouchController bridge initialized successfully (singleton=%{public}d)",
                g_TouchController_SingletonReceive != NULL && g_TouchController_SingletonSend != NULL);
    return YES;
}

+ (BOOL)isTouchControllerAvailable {
    return g_Initialized;
}

+ (long long)createTransportWithName:(NSString *)name {
    if (!g_Initialized || !g_TouchController_New) {
        os_log_error(touchControllerLog, "TouchController not initialized");
        return -1;
    }

    const char *cName = [name UTF8String];
    long long handle = g_TouchController_New(cName);

    if (handle < 0) {
        os_log_error(touchControllerLog, "Failed to create transport with name: %s", cName);
    } else {
        os_log_debug(touchControllerLog, "Created transport with handle: %lld", handle);
    }

    return handle;
}

+ (int)receiveFromTransport:(long long)handle buffer:(NSMutableData *)buffer {
    if (!g_Initialized) {
        os_log_error(touchControllerLog, "TouchController not initialized");
        return -1;
    }

    if (handle < 0) {
        os_log_error(touchControllerLog, "Invalid transport handle: %lld", handle);
        return -1;
    }

    // 分配缓冲区
    static const int BUFFER_SIZE = 4096;
    uint8_t tempBuffer[BUFFER_SIZE];

    // Task 134：先轮询单例通道（新 ABI mod 的消息走这里）
    if (g_TouchController_SingletonReceive) {
        int singletonResult = g_TouchController_SingletonReceive(tempBuffer);
        if (singletonResult > 0) {
            [buffer appendBytes:tempBuffer length:singletonResult];
            os_log_debug(touchControllerLog, "Received %d bytes from singleton transport", singletonResult);
            return singletonResult;
        }
    }

    // 再轮询命名句柄通道（旧 ABI mod 的消息走这里）
    int result = g_TouchController_Receive(handle, tempBuffer, BUFFER_SIZE);

    if (result > 0) {
        // 成功接收数据
        [buffer appendBytes:tempBuffer length:result];
        os_log_debug(touchControllerLog, "Received %d bytes from transport %lld", result, handle);
    } else if (result == 0) {
        // 无数据可用
        os_log_debug(touchControllerLog, "No data available from transport %lld", handle);
    } else {
        // 接收失败
        os_log_error(touchControllerLog, "Failed to receive from transport %lld", handle);
    }

    return result;
}

+ (BOOL)sendToTransport:(long long)handle data:(NSData *)data {
    if (!g_Initialized) {
        os_log_error(touchControllerLog, "TouchController not initialized");
        return NO;
    }

    if (handle < 0) {
        os_log_error(touchControllerLog, "Invalid transport handle: %lld", handle);
        return NO;
    }

    if (!data || data.length == 0) {
        os_log_error(touchControllerLog, "No data to send");
        return NO;
    }

    // Task 134：广播到单例通道（新 ABI mod 从这里收）
    if (g_TouchController_SingletonSend) {
        g_TouchController_SingletonSend(data.bytes, (int)data.length);
    }

    // 同时发送到命名句柄通道（旧 ABI mod 从这里收）
    g_TouchController_Send(handle, data.bytes, 0, (int)data.length);

    os_log_debug(touchControllerLog, "Sent %lu bytes (dual-channel)", (unsigned long)data.length);
    return YES;
}

+ (void)destroyTransport:(long long)handle {
    if (!g_Initialized || !g_TouchController_Destroy) {
        os_log_error(touchControllerLog, "TouchController not initialized");
        return;
    }

    if (handle < 0) {
        os_log_error(touchControllerLog, "Invalid transport handle: %lld", handle);
        return;
    }

    g_TouchController_Destroy(handle);
    os_log_debug(touchControllerLog, "Destroyed transport %lld", handle);
}

@end