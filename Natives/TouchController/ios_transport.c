/*
 * ios_transport.c
 * Angel Aura Amethyst
 *
 * TouchController iOS transport——双 ABI 兼容实现（Task 134，根治
 * "MC 26.2 TouchController 功能失效"）。
 *
 * 【根因（2026-09-21 取证）】上游 mod（github.com/TouchController/
 * TouchController）在 26.2 世代的版本里把原生传输层从【句柄制】改成了
 * 【单例制】：
 *   - 旧 ABI（本启动器曾捆绑的 TouchController.xcframework）：
 *       JNI: init()=no-op; new(String path)->long 句柄;
 *            receive(long handle, byte[] buffer); send(long handle,
 *            byte[] buffer, int off, int len); destroy(long handle)
 *       C:   touchcontroller_ios_new(path) / _receive(handle,buf,len) /
 *            _send(handle,buf,off,len) / _destroy(handle)
 *   - 新 ABI（mod 仓库当前 touchcontroller/proxy/server/ios/ios.{h,c}，
 *     MC 26.2 兼容版本起使用）：
 *       JNI: init() 创建单例队列; receive(byte[] buffer);
 *            send(byte[] buffer, int off, int len)
 *       C:   touchcontroller_ios_receive(void* buf) /
 *            touchcontroller_ios_send(const void* buf, int len)
 * 两者 JNI 符号【同名不同签名】：旧符号以 (env,clazz,handle,buffer,...)
 * 调用、新符号以 (env,clazz,buffer,...) 调用。旧库被新 mod 调用时，
 * jbyteArray 落进 jlong 形参、垃圾寄存器落进 buffer 形参，且旧 init()
 * 是 no-op、队列从未创建——mod 侧 Transport 全部抛 NPE / 错乱，功能全灭。
 *
 * 【本实现】同一份代码同时服务两个 ABI：
 *   1. JNI receive/send 用【指针注册表判别】trampoline：旧 mod 传入的
 *      handle 必然是本实现 touchcontroller_ios_new() 返回的活动指针——
 *      活动指针注册表命中 = 旧 ABI（x2=句柄,x3=缓冲区），未命中 = 新 ABI
 *      （x2=缓冲区）。注册表按【指针同一性】判别、零解引用，jbyteArray
 *      不可能命中（活动的 Java 对象与活动的 malloc 传输块是互斥的不同
 *      分配）。arm64 寄存器布局：旧 send 的 off/len 在 w4/w5、新 send
 *      的 off/len 在 w3/w4——trampoline 以 (env,clazz,a2,a3,a4,a5) 声明
 *      读原始寄存器后按 ABI 分别重解释（新 ABI 的 off 取 a3 低 32 位）。
 *   2. 单例通道（新 mod）+ 命名通道（旧 mod，按路径复用同一传输块）并存；
 *      启动器侧消息循环同时轮询两条通道、发送同时广播两条通道——无论
 *      mod 是哪个 ABI 世代都全通。
 *   3. 新 C API 沿用 mod 仓库当前签名（touchcontroller_ios_receive/
 *      send），旧 C API 加 _v1 后缀（启动器 TouchControllerBridge 同步
 *      改用）。
 *
 * 许可：与上游 ios.c（LGPL-3.0，fifth_light）语义等价的移植 + 双 ABI
 * 扩展；ring_buffer 见 ring_buffer.c（同上游移植）。
 */

#include "ring_buffer.h"

/* strdup 是 POSIX 符号（非 C11 标准）；Apple 工具链默认可见，
 * 此宏保证在严格 -std=c11 下也可移植编译 */
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE
#endif

#include <jni.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define TC_MAX_QUEUE_SIZE (4 * 1024)
#define TC_MAX_NAMED_TRANSPORTS 16

static os_log_t tc_log(void) {
    static os_log_t log = NULL;
    if (log == NULL) {
        log = os_log_create("com.air-devs.air", "TouchControllerTransport");
    }
    return log;
}

typedef struct tc_message {
    size_t size;
    void *data;
} tc_message_t;

typedef struct ios_transport {
    // mod → 启动器（JNI send 入队 / C 出队）
    ring_buffer_t *to_launcher_queue;
    pthread_mutex_t to_launcher_mutex;
    // 启动器 → mod（C 入队 / JNI receive 出队）
    ring_buffer_t *to_mod_queue;
    pthread_mutex_t to_mod_mutex;
} ios_transport_t;

// —— 单例通道（新 ABI mod）——
static ios_transport_t *g_singleton = NULL;
static pthread_mutex_t g_singleton_mutex = PTHREAD_MUTEX_INITIALIZER;

// —— 命名通道注册表（旧 ABI mod + 启动器侧老桥接）——
static ios_transport_t *g_named[TC_MAX_NAMED_TRANSPORTS];
static char *g_named_paths[TC_MAX_NAMED_TRANSPORTS];
static pthread_mutex_t g_named_mutex = PTHREAD_MUTEX_INITIALIZER;

static ios_transport_t *tc_transport_create(void) {
    ios_transport_t *t = calloc(1, sizeof(ios_transport_t));
    if (t == NULL) {
        return NULL;
    }
    t->to_launcher_queue = NULL;
    t->to_mod_queue = NULL;
    // 上游 ios.c 同款 init 标志：部分初始化失败时只销毁已初始化的资源
    int launcher_mutex_inited = 0, mod_mutex_inited = 0;
    t->to_launcher_queue = ring_buffer_alloc(TC_MAX_QUEUE_SIZE);
    t->to_mod_queue = ring_buffer_alloc(TC_MAX_QUEUE_SIZE);
    if (t->to_launcher_queue == NULL || t->to_mod_queue == NULL) {
        goto cleanup;
    }
    if (pthread_mutex_init(&t->to_launcher_mutex, NULL) != 0) {
        goto cleanup;
    }
    launcher_mutex_inited = 1;
    if (pthread_mutex_init(&t->to_mod_mutex, NULL) != 0) {
        goto cleanup;
    }
    mod_mutex_inited = 1;
    return t;

cleanup:
    if (launcher_mutex_inited) pthread_mutex_destroy(&t->to_launcher_mutex);
    if (mod_mutex_inited) pthread_mutex_destroy(&t->to_mod_mutex);
    if (t->to_launcher_queue) ring_buffer_free(t->to_launcher_queue);
    if (t->to_mod_queue) ring_buffer_free(t->to_mod_queue);
    free(t);
    return NULL;
}

static void tc_message_free(tc_message_t *msg) {
    if (msg == NULL) {
        return;
    }
    free(msg->data);
    free(msg);
}

static void tc_transport_destroy(ios_transport_t *t) {
    if (t == NULL) {
        return;
    }
    // 清空两条队列里残留的消息
    tc_message_t *msg;
    while ((msg = ring_buffer_dequeue(t->to_launcher_queue)) != NULL) {
        tc_message_free(msg);
    }
    while ((msg = ring_buffer_dequeue(t->to_mod_queue)) != NULL) {
        tc_message_free(msg);
    }
    ring_buffer_free(t->to_launcher_queue);
    ring_buffer_free(t->to_mod_queue);
    pthread_mutex_destroy(&t->to_launcher_mutex);
    pthread_mutex_destroy(&t->to_mod_mutex);
    free(t);
}

static void tc_ensure_singleton(void) {
    pthread_mutex_lock(&g_singleton_mutex);
    if (g_singleton == NULL) {
        g_singleton = tc_transport_create();
        os_log_info(tc_log(), "Task134: singleton transport created (%{public}s)",
                    g_singleton ? "ok" : "FAILED");
    }
    pthread_mutex_unlock(&g_singleton_mutex);
}

// —— 指针注册表判别（零解引用）——
static int tc_is_registered_handle(void *candidate) {
    if (candidate == NULL) {
        return 0;
    }
    int hit = 0;
    pthread_mutex_lock(&g_named_mutex);
    for (int i = 0; i < TC_MAX_NAMED_TRANSPORTS; i++) {
        if (g_named[i] == candidate) {
            hit = 1;
            break;
        }
    }
    pthread_mutex_unlock(&g_named_mutex);
    return hit;
}

// —— 方向语义（与上游一致）：to_launcher = mod→启动器；to_mod = 启动器→mod ——
static int tc_enqueue(ring_buffer_t *queue, pthread_mutex_t *mutex,
                      const void *buf, int offset, int len) {
    if (queue == NULL || buf == NULL || len <= 0 || len > UINT8_MAX) {
        return -1;
    }
    tc_message_t *msg = malloc(sizeof(tc_message_t));
    if (msg == NULL) {
        return -1;
    }
    msg->size = (size_t)len;
    msg->data = malloc((size_t)len);
    if (msg->data == NULL) {
        free(msg);
        return -1;
    }
    memcpy(msg->data, (const uint8_t *)buf + offset, (size_t)len);
    pthread_mutex_lock(mutex);
    int ret = ring_buffer_enqueue(queue, msg);
    pthread_mutex_unlock(mutex);
    if (ret != 0) {
        tc_message_free(msg);
        return -1;
    }
    return 0;
}

static tc_message_t *tc_dequeue(ring_buffer_t *queue, pthread_mutex_t *mutex) {
    pthread_mutex_lock(mutex);
    tc_message_t *msg = ring_buffer_dequeue(queue);
    pthread_mutex_unlock(mutex);
    return msg;
}

// =====================================================================
// JNI——新 ABI（单例）。init 建单例；receive/send 无句柄参数。
// =====================================================================

static void tc_throw_exception(JNIEnv *env, const char *msg) {
    if (env == NULL) {
        return;
    }
    jclass cls = (*env)->FindClass(env, "java/lang/Exception");
    if (cls != NULL) {
        (*env)->ThrowNew(env, cls, msg);
    }
}

static void tc_throw_npe(JNIEnv *env, const char *msg) {
    if (env == NULL) {
        return;
    }
    jclass cls = (*env)->FindClass(env, "java/lang/NullPointerException");
    if (cls != NULL) {
        (*env)->ThrowNew(env, cls, msg);
    }
}

// 兼容两代 mod 的 init()：新 mod 期望它创建单例；旧 mod 曾把它当 no-op，
// 提前建好单例对旧 mod 无影响（旧 mod 不走单例通道）。
JNIEXPORT void JNICALL
Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_init(JNIEnv *env, jclass clazz) {
    (void)env;
    (void)clazz;
    tc_ensure_singleton();
    os_log_info(tc_log(), "Task134: JNI init() called (singleton ensured)");
}

// =====================================================================
// JNI——旧 ABI（句柄制）。仅旧世代 mod 会调用。
// =====================================================================

JNIEXPORT jlong JNICALL
Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_new(JNIEnv *env, jclass clazz, jstring path) {
    (void)clazz;
    if (env == NULL || path == NULL) {
        return 0;
    }
    const char *cPath = (*env)->GetStringUTFChars(env, path, NULL);
    if (cPath == NULL) {
        return 0;
    }
    ios_transport_t *t = NULL;
    char *ownedPath = NULL;
    pthread_mutex_lock(&g_named_mutex);
    // 同路径复用：旧 mod 与启动器各调一次 new(path)，必须拿到同一传输块
    for (int i = 0; i < TC_MAX_NAMED_TRANSPORTS; i++) {
        if (g_named_paths[i] != NULL && strcmp(g_named_paths[i], cPath) == 0) {
            t = g_named[i];
            break;
        }
    }
    if (t == NULL) {
        for (int i = 0; i < TC_MAX_NAMED_TRANSPORTS; i++) {
            if (g_named[i] == NULL) {
                t = tc_transport_create();
                if (t != NULL) {
                    ownedPath = strdup(cPath);
                    if (ownedPath == NULL) {
                        tc_transport_destroy(t);
                        t = NULL;
                    } else {
                        g_named[i] = t;
                        g_named_paths[i] = ownedPath;
                    }
                }
                break;
            }
        }
    }
    pthread_mutex_unlock(&g_named_mutex);
    os_log_info(tc_log(), "Task134: JNI new(%{public}s) -> %{private}p", cPath, t);
    (*env)->ReleaseStringUTFChars(env, path, cPath);
    return (jlong)(intptr_t)t;
}

JNIEXPORT void JNICALL
Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_destroy(JNIEnv *env, jclass clazz, jlong handle) {
    (void)env;
    (void)clazz;
    ios_transport_t *t = (ios_transport_t *)(intptr_t)handle;
    pthread_mutex_lock(&g_named_mutex);
    for (int i = 0; i < TC_MAX_NAMED_TRANSPORTS; i++) {
        if (g_named[i] == t) {
            g_named[i] = NULL;
            free(g_named_paths[i]);
            g_named_paths[i] = NULL;
            break;
        }
    }
    pthread_mutex_unlock(&g_named_mutex);
    if (t != NULL) {
        tc_transport_destroy(t);
    }
    os_log_info(tc_log(), "Task134: JNI destroy(%lld)", (long long)handle);
}

// =====================================================================
// JNI trampoline——receive：同符号双签名判别。
//   旧 mod 调用: receive(long handle, byte[] buffer)
//     寄存器: x0=env x1=clazz x2=handle x3=buffer
//   新 mod 调用: receive(byte[] buffer)
//     寄存器: x0=env x1=clazz x2=buffer
// 形参声明 (env, clazz, a2, a3) 原样读取 x2/x3；a2 命中活动句柄注册表
// 即旧 ABI，否则按新 ABI 处理（a2 即缓冲区）。
// =====================================================================

static jint tc_jni_receive_new(JNIEnv *env, jbyteArray buffer) {
    if (buffer == NULL) {
        tc_throw_npe(env, "Buffer is null");
        return 0;
    }
    if (g_singleton == NULL) {
        tc_ensure_singleton();
        if (g_singleton == NULL) {
            tc_throw_npe(env, "Queue handle is null. Make sure you have initialized the transport.");
            return 0;
        }
    }
    tc_message_t *msg = tc_dequeue(g_singleton->to_mod_queue, &g_singleton->to_mod_mutex);
    if (msg == NULL) {
        return 0;
    }
    jsize capacity = (*env)->GetArrayLength(env, buffer);
    if ((jsize)msg->size > capacity) {
        os_log_error(tc_log(), "Task134: new-ABI receive buffer too small (msg=%zu cap=%d), dropping",
                     msg->size, (int)capacity);
        tc_message_free(msg);
        return -1;
    }
    (*env)->SetByteArrayRegion(env, buffer, 0, (jsize)msg->size, (const jbyte *)msg->data);
    jint len = (jint)msg->size;
    tc_message_free(msg);
    return len;
}

static jint tc_jni_receive_old(JNIEnv *env, jlong handle, jbyteArray buffer) {
    if (buffer == NULL) {
        tc_throw_npe(env, "Buffer is null");
        return 0;
    }
    ios_transport_t *t = (ios_transport_t *)(intptr_t)handle;
    if (t == NULL || !tc_is_registered_handle(t)) {
        tc_throw_npe(env, "Queue handle is null. Make sure you have initialized the transport.");
        return 0;
    }
    tc_message_t *msg = tc_dequeue(t->to_mod_queue, &t->to_mod_mutex);
    if (msg == NULL) {
        return 0;
    }
    jsize capacity = (*env)->GetArrayLength(env, buffer);
    if ((jsize)msg->size > capacity) {
        tc_message_free(msg);
        return -1;
    }
    (*env)->SetByteArrayRegion(env, buffer, 0, (jsize)msg->size, (const jbyte *)msg->data);
    jint len = (jint)msg->size;
    tc_message_free(msg);
    return len;
}

JNIEXPORT jint JNICALL
Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_receive(JNIEnv *env, jclass clazz,
                                                                          jlong handle_or_buffer,
                                                                          jbyteArray buffer_or_garbage) {
    (void)clazz;
    static _Atomic int s_new_abi_seen = 0;
    if (tc_is_registered_handle((void *)(intptr_t)handle_or_buffer)) {
        return tc_jni_receive_old(env, handle_or_buffer, buffer_or_garbage);
    }
    if (!s_new_abi_seen) {
        s_new_abi_seen = 1;
        os_log_info(tc_log(), "Task134: new-ABI mod detected (singleton Transport), first receive");
    }
    return tc_jni_receive_new(env, (jbyteArray)(intptr_t)handle_or_buffer);
}

// =====================================================================
// JNI trampoline——send：同符号双签名判别（注意 off/len 的寄存器错位）。
//   旧 mod 调用: send(long handle, byte[] buffer, int off, int len)
//     寄存器: x0=env x1=clazz x2=handle x3=buffer w4=off w5=len
//   新 mod 调用: send(byte[] buffer, int off, int len)
//     寄存器: x0=env x1=clazz x2=buffer w3=off w4=len
// 形参 (env, clazz, a2, a3, a4, a5) 原样读 x2/x3/w4/w5 后分别重解释：
//   旧: handle=a2 buffer=a3 off=a4 len=a5
//   新: buffer=a2 off=(jint)a3 低 32 位 len=a4
// =====================================================================

JNIEXPORT void JNICALL
Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_send(JNIEnv *env, jclass clazz,
                                                                       jlong handle_or_buffer,
                                                                       jbyteArray buffer_or_off,
                                                                       jint len_or_off,
                                                                       jint garbage_or_len) {
    (void)clazz;
    if (tc_is_registered_handle((void *)(intptr_t)handle_or_buffer)) {
        // 旧 ABI
        ios_transport_t *t = (ios_transport_t *)(intptr_t)handle_or_buffer;
        jbyteArray buffer = buffer_or_off;
        jint off = len_or_off;
        jint len = garbage_or_len;
        if (buffer == NULL) {
            tc_throw_npe(env, "Buffer is null");
            return;
        }
        if (len <= 0 || len > UINT8_MAX) {
            tc_throw_exception(env, "Bad message size");
            return;
        }
        jbyte *elements = (*env)->GetByteArrayElements(env, buffer, NULL);
        if (elements == NULL) {
            return;
        }
        int rc = tc_enqueue(t->to_launcher_queue, &t->to_launcher_mutex,
                            elements, (int)off, (int)len);
        (*env)->ReleaseByteArrayElements(env, buffer, elements, JNI_ABORT);
        if (rc != 0) {
            tc_throw_exception(env, "Failed to write message into write buffer");
        }
        return;
    }
    // 新 ABI
    jbyteArray buffer = (jbyteArray)(intptr_t)handle_or_buffer;
    jint off = (jint)(uint32_t)(uintptr_t)buffer_or_off;  // w3 低 32 位
    jint len = len_or_off;                                 // w4
    if (buffer == NULL) {
        tc_throw_npe(env, "Buffer is null");
        return;
    }
    if (len <= 0 || len > UINT8_MAX) {
        tc_throw_exception(env, "Bad message size");
        return;
    }
    if (off < 0 || (jint)0 + off + len > (*env)->GetArrayLength(env, buffer)) {
        tc_throw_exception(env, "Bad message range");
        return;
    }
    if (g_singleton == NULL) {
        tc_ensure_singleton();
        if (g_singleton == NULL) {
            tc_throw_npe(env, "Queue handle is null. Make sure you have initialized the transport.");
            return;
        }
    }
    jbyte *elements = (*env)->GetByteArrayElements(env, buffer, NULL);
    if (elements == NULL) {
        return;
    }
    int rc = tc_enqueue(g_singleton->to_launcher_queue, &g_singleton->to_launcher_mutex,
                        elements, (int)off, (int)len);
    (*env)->ReleaseByteArrayElements(env, buffer, elements, JNI_ABORT);
    if (rc != 0) {
        tc_throw_exception(env, "Failed to write message into write buffer");
    }
}

// =====================================================================
// C API——新 ABI（mod 仓库当前签名）：单例通道。
// =====================================================================

int touchcontroller_ios_receive(void *buf) {
    if (g_singleton == NULL) {
        return -1;
    }
    tc_message_t *msg = tc_dequeue(g_singleton->to_launcher_queue, &g_singleton->to_launcher_mutex);
    if (msg == NULL) {
        return 0;
    }
    memcpy(buf, msg->data, msg->size);
    int len = (int)msg->size;
    tc_message_free(msg);
    return len;
}

int touchcontroller_ios_send(const void *buf, int len) {
    if (g_singleton == NULL) {
        return -1;
    }
    return tc_enqueue(g_singleton->to_mod_queue, &g_singleton->to_mod_mutex, buf, 0, len);
}

// =====================================================================
// C API——旧 ABI 兼容（启动器 TouchControllerBridge 使用）。
//   receive/send 加 _v1 后缀避免与新 ABI 同名异签名冲突；
//   new/destroy/init 名称两代一致，语义不变。
// =====================================================================

void touchcontroller_ios_init(void) {
    tc_ensure_singleton();
}

long long touchcontroller_ios_new(const char *path) {
    if (path == NULL) {
        return -1;
    }
    // 与 JNI new() 同一注册表：启动器与旧 mod 各自 new(同路径) 拿到同一块
    pthread_mutex_lock(&g_named_mutex);
    ios_transport_t *t = NULL;
    for (int i = 0; i < TC_MAX_NAMED_TRANSPORTS; i++) {
        if (g_named_paths[i] != NULL && strcmp(g_named_paths[i], path) == 0) {
            t = g_named[i];
            break;
        }
    }
    if (t == NULL) {
        for (int i = 0; i < TC_MAX_NAMED_TRANSPORTS; i++) {
            if (g_named[i] == NULL) {
                t = tc_transport_create();
                if (t != NULL) {
                    char *owned = strdup(path);
                    if (owned == NULL) {
                        tc_transport_destroy(t);
                        t = NULL;
                    } else {
                        g_named[i] = t;
                        g_named_paths[i] = owned;
                    }
                }
                break;
            }
        }
    }
    pthread_mutex_unlock(&g_named_mutex);
    os_log_info(tc_log(), "Task134: C new(%{public}s) -> %{private}p", path, t);
    return t ? (long long)(intptr_t)t : -1;
}

int touchcontroller_ios_receive_v1(long long handle, void *buffer, int buffer_length) {
    ios_transport_t *t = (ios_transport_t *)(intptr_t)handle;
    if (t == NULL || !tc_is_registered_handle(t)) {
        return -1;
    }
    tc_message_t *msg = tc_dequeue(t->to_launcher_queue, &t->to_launcher_mutex);
    if (msg == NULL) {
        return 0;
    }
    int len = (int)msg->size;
    if (len > buffer_length) {
        // 暂存语义见旧 xcframework：缓冲区不足时丢弃并报 -2
        tc_message_free(msg);
        return -2;
    }
    memcpy(buffer, msg->data, msg->size);
    tc_message_free(msg);
    return len;
}

void touchcontroller_ios_send_v1(long long handle, const void *buffer, int offset, int length) {
    ios_transport_t *t = (ios_transport_t *)(intptr_t)handle;
    if (t == NULL || !tc_is_registered_handle(t)) {
        return;
    }
    tc_enqueue(t->to_mod_queue, &t->to_mod_mutex, buffer, offset, length);
}

void touchcontroller_ios_destroy(long long handle) {
    Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_destroy(NULL, NULL, handle);
}
