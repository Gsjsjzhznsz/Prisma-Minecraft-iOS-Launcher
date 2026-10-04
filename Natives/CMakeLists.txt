cmake_minimum_required(VERSION 3.6)
project(AngelAuraAmethyst)

# 从环境变量读取 CurseForge API Key
# 不能通过 Makefile 的 -D 参数传递，因为 Make 会对环境变量值进行递归展开，
# 导致 bcrypt 哈希格式（$2a$10$...）中的 $2、$1、$Q 被 Make 解释为变量引用并替换为空，
# 最终生成损坏的 Key（如 a06bVFEP... 而非 $2a$10$Q6bVFEP...）
if(DEFINED ENV{CONFIG_CURSEFORGE_API_KEY})
    set(CONFIG_CURSEFORGE_API_KEY "$ENV{CONFIG_CURSEFORGE_API_KEY}")
endif()

configure_file(${CMAKE_CURRENT_LIST_DIR}/config.h.in ${CMAKE_CURRENT_LIST_DIR}/config.h)

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -target arm64-apple-ios -mcpu=apple-a8 -fcommon -fobjc-arc -ObjC -F'${CMAKE_OSX_SYSROOT}/System/Cryptexes/OS/System/Library/Frameworks'")
set(CMAKE_C_FLAGS_DEBUG "-funwind-tables -g")

if("${CMAKE_HOST_SYSTEM_NAME}" MATCHES "Linux|^GNU$|Android")
  set(GLOBAL_LDFLAGS "-isysroot ${CMAKE_OSX_SYSROOT} -Wl,-syslibroot,${CMAKE_OSX_SYSROOT} -fuse-ld=lld")
  set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} ${GLOBAL_LDFLAGS}")
  set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} ${GLOBAL_LDFLAGS}")
endif()

include_directories(
  "."
  "external/AFNetworking/AFNetworking"
  "external/AFNetworking/UIKit+AFNetworking"
  "external/DBNumberedSlider/Classes"
  "external/NRFileManager"
  "external/UnzipKit"
  "external/fishhook"
  "external/lzma"
  "external/mesa"
  "external/AltKit"
  "external/Apple"
  "external/ballpa1n"
  "external/ballpa1n/wrapped"
  "external/mach"
  # "external/ZeroTierFramework/ios-example-app/zt.framework/Headers"  # ZeroTier 暂时移除
)

# ============================================================================
# ZeroTier Apple Framework 集成 —— 暂时移除（注释掉以排查启动崩溃）
# ============================================================================
# set(ZT_FRAMEWORK_DIR "${CMAKE_CURRENT_LIST_DIR}/external/ZeroTierFramework/ios-example-app")
# set(ZT_FRAMEWORK_LIB "${ZT_FRAMEWORK_DIR}/zt.framework/zt")
# if(EXISTS "${ZT_FRAMEWORK_LIB}")
#   message(STATUS "Found ZeroTier framework binary: ${ZT_FRAMEWORK_LIB}")
#   set(ZT_FRAMEWORK_SEARCH_PATH "-F'${ZT_FRAMEWORK_DIR}'")
#   set(ZT_FRAMEWORK_LINK "-framework zt")
#   set(ZT_CXX_LIB "-lc++")
# else()
#   message(FATAL_ERROR "ZeroTier framework not found at ${ZT_FRAMEWORK_LIB}. Please run: git submodule update --init --recursive")
# endif()
set(ZT_FRAMEWORK_SEARCH_PATH "")
set(ZT_FRAMEWORK_LINK "")
set(ZT_CXX_LIB "")

# ============================================================================
# libterracotta.xcframework 集成（陶瓦联机）—— 暂时移除（注释掉以排查启动崩溃）
# ============================================================================
# set(TERRACOTTA_LIB_DIR "${CMAKE_CURRENT_LIST_DIR}/terracotta")
# set(TERRACOTTA_XCFW "${TERRACOTTA_LIB_DIR}/libterracotta.xcframework")
# set(TERRACOTTA_LIB "")
# set(TERRACOTTA_AVAILABLE OFF)
# if(EXISTS "${TERRACOTTA_XCFW}/ios-arm64/libterracotta.a")
#   set(_TC_LIB_PATH "${TERRACOTTA_XCFW}/ios-arm64/libterracotta.a")
#   set(TERRACOTTA_LIB "-Wl,-force_load,${_TC_LIB_PATH}")
#   set(TERRACOTTA_AVAILABLE ON)
# elseif(EXISTS "${TERRACOTTA_LIB_DIR}/libterracotta.a")
#   set(_TC_LIB_PATH "${TERRACOTTA_LIB_DIR}/libterracotta.a")
#   set(TERRACOTTA_LIB "-Wl,-force_load,${_TC_LIB_PATH}")
#   set(TERRACOTTA_AVAILABLE ON)
# endif()
set(TERRACOTTA_LIB "")
set(TERRACOTTA_AVAILABLE OFF)

# For cacio support library
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -rpath @loader_path -rpath @executable_path/java_runtimes/java-8-openjdk/lib -rpath /usr/lib/jvm/java-8-openjdk/lib")

# EXT: stub library, delete after compile awt_xawt
add_library(awt_headless SHARED
  awt_xawt/empty.m
)
target_link_libraries(awt_headless)

# EXT: cacio support library
add_library(awt_xawt SHARED
  awt_xawt/xawt_fake.m
)
target_link_libraries(awt_xawt
  "-L'${CMAKE_CURRENT_LIST_DIR}/build'"
  awt_headless
)

# TouchController iOS native library
# Provides JNI / C API for touch control communication between Minecraft mod and launcher
#
# 四级回退检测逻辑（按优先级从高到低）：
#   Level 0 — 源码编译（Task 134 起的最高优先级）：Natives/TouchController/
#             ios_transport.c 是双 ABI（旧句柄制 + 新单例制）兼容实现，
#             随 Task 134 引入——修复 MC 26.2 世代 mod 的 Transport 单例
#             ABI 与旧 xcframework 句柄 ABI 的 JNI 同名异签名错位。
#             XCFramework（旧 ABI）保留在仓库仅作历史参考，不再参与构建。
#   Level 1 — 预编译 XCFramework：检测 TouchController.xcframework/，从 ios-arm64
#             子目录提取设备静态库链接（由 build_xcframework.sh 生成）
#   Level 2 — 预编译独立 .a：检测 libproxy_server_ios.a (device) 或
#             libproxy_server_ios_simulator.a (simulator)，保持向后兼容
#   Level 3 — 源码编译回退：检测 ios_transport.c 源文件，CMake 直接编译为对象库
#   禁用   — 以上都不存在时，TOUCHCONTROLLER_LIB 置空并打印警告
#
# 重要：TouchControllerBridge.m 通过 dlsym(RTLD_DEFAULT, "touchcontroller_ios_*")
# 运行时查找符号，编译期没有任何直接引用。Apple ld 处理静态库（.a）时按需加载，
# 只提取被直接引用的对象文件——未被引用的对象文件会被丢弃，导致 dlsym 找不到符号。
# 因此：
#   - Level 1/2（预编译 .a）：必须用 -Wl,-force_load,<path> 强制加载整个静态库
#   - Level 0/3（源码编译）：改用 OBJECT 库，对象文件直接链接到可执行文件，
#     所有符号自动保留，无需 -force_load
set(TOUCHCONTROLLER_LIB_DIR "${CMAKE_CURRENT_LIST_DIR}/TouchController")
set(TOUCHCONTROLLER_XCFW "${TOUCHCONTROLLER_LIB_DIR}/TouchController.xcframework")
set(TOUCHCONTROLLER_LIB "")

# Level 0: 源码编译（Task 134 起最高优先级——双 ABI 修复版）
if(EXISTS "${TOUCHCONTROLLER_LIB_DIR}/ios_transport.c")
  message(STATUS "Building TouchController from source (Level 0: Task134 dual-ABI transport)")
  # 使用 OBJECT 库而非 STATIC 库：对象文件直接链接到可执行文件，
  # 所有符号自动保留，避免 dlsym 找不到符号的问题
  add_library(proxy_server_ios OBJECT
    ${TOUCHCONTROLLER_LIB_DIR}/ios_transport.c
    ${TOUCHCONTROLLER_LIB_DIR}/ring_buffer.c
  )
  # jni.h 位于 Natives/ 根目录（OpenJDK 自包含头）
  target_include_directories(proxy_server_ios PRIVATE
    ${TOUCHCONTROLLER_LIB_DIR}
    ${CMAKE_CURRENT_LIST_DIR}
  )
  set(TOUCHCONTROLLER_LIB proxy_server_ios)
# Level 1: 预编译 XCFramework
elseif(EXISTS "${TOUCHCONTROLLER_XCFW}/ios-arm64/libproxy_server_ios.a")
  set(_TC_LIB_PATH "${TOUCHCONTROLLER_XCFW}/ios-arm64/libproxy_server_ios.a")
  message(STATUS "Found TouchController XCFramework (Level 1: prebuilt xcframework) at ${_TC_LIB_PATH}")
  # 强制加载整个静态库，确保 dlsym 能找到所有 touchcontroller_ios_* 符号
  set(TOUCHCONTROLLER_LIB "-Wl,-force_load,${_TC_LIB_PATH}")
# Level 2: 预编译独立 .a（保持兼容）
elseif(EXISTS "${TOUCHCONTROLLER_LIB_DIR}/libproxy_server_ios.a")
  set(_TC_LIB_PATH "${TOUCHCONTROLLER_LIB_DIR}/libproxy_server_ios.a")
  message(STATUS "Found TouchController device library (Level 2: prebuilt .a) at ${_TC_LIB_PATH}")
  set(TOUCHCONTROLLER_LIB "-Wl,-force_load,${_TC_LIB_PATH}")
elseif(EXISTS "${TOUCHCONTROLLER_LIB_DIR}/libproxy_server_ios_simulator.a")
  set(_TC_LIB_PATH "${TOUCHCONTROLLER_LIB_DIR}/libproxy_server_ios_simulator.a")
  message(STATUS "Found TouchController simulator library (Level 2: prebuilt .a) at ${_TC_LIB_PATH}")
  set(TOUCHCONTROLLER_LIB "-Wl,-force_load,${_TC_LIB_PATH}")
# Level 3: 源码编译回退（使用 OBJECT 库确保所有符号被保留）
elseif(EXISTS "${TOUCHCONTROLLER_LIB_DIR}/ios_transport.c")
  message(STATUS "Building TouchController from source (Level 3: source compilation)")
  # 使用 OBJECT 库而非 STATIC 库：对象文件直接链接到可执行文件，
  # 所有符号自动保留，避免 dlsym 找不到符号的问题
  add_library(proxy_server_ios OBJECT
    ${TOUCHCONTROLLER_LIB_DIR}/ios_transport.c
    ${TOUCHCONTROLLER_LIB_DIR}/ring_buffer.c
  )
  target_include_directories(proxy_server_ios PRIVATE ${TOUCHCONTROLLER_LIB_DIR})
  set(TOUCHCONTROLLER_LIB proxy_server_ios)
# 全部未命中：禁用 TouchController 支持
else()
  message(STATUS "TouchController library not found, TouchController support will be disabled")
  set(TOUCHCONTROLLER_LIB "")
endif()

set(CMAKE_FRAMEWORK_PATH "${CMAKE_CURRENT_LIST_DIR}/resources/Frameworks")

set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -rpath @executable_path/Frameworks -rpath @loader_path/Frameworks")
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -rpath @executable_path/Frameworks -rpath @loader_path/Frameworks")

# ANGLE wrapper for 1.17+
add_library(tinygl4angle SHARED
  external/gl4es/string_utils.c
  external/gl4es/tinygl4angle.c
)
target_link_libraries(tinygl4angle
  "${GLOBAL_LDFLAGS}"
  "-F'${CMAKE_CURRENT_LIST_DIR}/resources/Frameworks'"
  "-framework libEGL"
  "-framework libGLESv2"
)
# Task173：桌面 GL 补全层（tinygl4angle.c 的 ANGLE pipeline/gui 崩溃根修）
# 用到 NSArray/NSLog/`dispatch_once`（取证日志），把该文件强制 objective-c
# 方言 + ARC（与 osm_bridge.mm 的 set_source_files_properties 同款先例，
# 但 .c 目标默认走纯 C）。string_utils.c 保持纯 C。
set_source_files_properties(external/gl4es/tinygl4angle.c PROPERTIES
  COMPILE_OPTIONS "-x;objective-c;-fobjc-arc")

# ============================================================================
# Task173: VGPU 渲染器（PojavLauncherTeam/VGPU，gl4es 分支 + 强化的着色器
# 语法转换器——GLSL120 兼容 → ESSL3.x，隐式类型转换，gl_FragData 等
# 内建变量在 shader 里改写）。面向旧版 MC（<1.13 生态；FCL 同款可选
# 渲染器）。iOS 移植补丁（见各文件 Task173 标记）：
#   - src/gl/pack/load.c: dlopen 库名 → iOS 框架名（libGLESv2.framework/
#     libGLESv2，经 @executable_path/Frameworks rpath 解析）
#   - src/glx/glx.c + src/gl/pack/printf_def.h: android/log.h 移除
#     （iOS 无 bionic 日志；printf 路由到启动器重定向的 stdout）
# 构建口径与 Android.mk 一致：-DNOX11 -DNO_GBM -DDEFAULT_ES=3 -DSHAREDLIB。
# __APPLE__ 在 loader.h 触发 NO_LOADER（gl4es 运行时 dlopen 装载器退役，
# VGPU 自己的 pack/load_all() 惰性装载接管）。双重 basename（pack/shader.c
# vs gl/shader.c、pack/shaderconv.c vs gl/shaderconv.c）会撞 Makefile 生成器
# 的目标文件名——拆两个 OBJECT 库再链接（.o 全路径互不冲突）。
# ============================================================================
set(VGPU_DIR "${CMAKE_CURRENT_LIST_DIR}/external/vgpu")
set(VGPU_PACK_SRC
  "${VGPU_DIR}/src/gl/pack/pack.c"
  "${VGPU_DIR}/src/gl/pack/load.c"
  "${VGPU_DIR}/src/gl/pack/Initialization.c"
  "${VGPU_DIR}/src/gl/pack/shaderconv.c"
  "${VGPU_DIR}/src/gl/pack/shader.c"
)
set(VGPU_CORE_SRC
  "${VGPU_DIR}/src/glx/hardext.c"
  "${VGPU_DIR}/src/glx/glx.c"
  "${VGPU_DIR}/src/glx/lookup.c"
  "${VGPU_DIR}/src/glx/gbm.c"
  "${VGPU_DIR}/src/glx/streaming.c"
  "${VGPU_DIR}/src/gl/arbconverter.c"
  "${VGPU_DIR}/src/gl/arbgenerator.c"
  "${VGPU_DIR}/src/gl/arbhelper.c"
  "${VGPU_DIR}/src/gl/arbparser.c"
  "${VGPU_DIR}/src/gl/array.c"
  "${VGPU_DIR}/src/gl/blend.c"
  "${VGPU_DIR}/src/gl/blit.c"
  "${VGPU_DIR}/src/gl/buffers.c"
  "${VGPU_DIR}/src/gl/build_info.c"
  "${VGPU_DIR}/src/gl/debug.c"
  "${VGPU_DIR}/src/gl/decompress.c"
  "${VGPU_DIR}/src/gl/depth.c"
  "${VGPU_DIR}/src/gl/directstate.c"
  "${VGPU_DIR}/src/gl/drawing.c"
  "${VGPU_DIR}/src/gl/enable.c"
  "${VGPU_DIR}/src/gl/envvars.c"
  "${VGPU_DIR}/src/gl/eval.c"
  "${VGPU_DIR}/src/gl/face.c"
  "${VGPU_DIR}/src/gl/fog.c"
  "${VGPU_DIR}/src/gl/fpe.c"
  "${VGPU_DIR}/src/gl/fpe_cache.c"
  "${VGPU_DIR}/src/gl/fpe_shader.c"
  "${VGPU_DIR}/src/gl/framebuffers.c"
  "${VGPU_DIR}/src/gl/gl_lookup.c"
  "${VGPU_DIR}/src/gl/getter.c"
  "${VGPU_DIR}/src/gl/gl4es.c"
  "${VGPU_DIR}/src/gl/glstate.c"
  "${VGPU_DIR}/src/gl/hint.c"
  "${VGPU_DIR}/src/gl/init.c"
  "${VGPU_DIR}/src/gl/light.c"
  "${VGPU_DIR}/src/gl/line.c"
  "${VGPU_DIR}/src/gl/list.c"
  "${VGPU_DIR}/src/gl/listdraw.c"
  "${VGPU_DIR}/src/gl/listrl.c"
  "${VGPU_DIR}/src/gl/loader.c"
  "${VGPU_DIR}/src/gl/logs.c"
  "${VGPU_DIR}/src/gl/matrix.c"
  "${VGPU_DIR}/src/gl/oldprogram.c"
  "${VGPU_DIR}/src/gl/pixel.c"
  "${VGPU_DIR}/src/gl/planes.c"
  "${VGPU_DIR}/src/gl/pointsprite.c"
  "${VGPU_DIR}/src/gl/preproc.c"
  "${VGPU_DIR}/src/gl/program.c"
  "${VGPU_DIR}/src/gl/queries.c"
  "${VGPU_DIR}/src/gl/raster.c"
  "${VGPU_DIR}/src/gl/render.c"
  "${VGPU_DIR}/src/gl/shader.c"
  "${VGPU_DIR}/src/gl/shaderconv.c"
  "${VGPU_DIR}/src/gl/shader_hacks.c"
  "${VGPU_DIR}/src/gl/stack.c"
  "${VGPU_DIR}/src/gl/stencil.c"
  "${VGPU_DIR}/src/gl/string_utils.c"
  "${VGPU_DIR}/src/gl/stubs.c"
  "${VGPU_DIR}/src/gl/texenv.c"
  "${VGPU_DIR}/src/gl/texgen.c"
  "${VGPU_DIR}/src/gl/texture.c"
  "${VGPU_DIR}/src/gl/texture_compressed.c"
  "${VGPU_DIR}/src/gl/texture_params.c"
  "${VGPU_DIR}/src/gl/texture_read.c"
  "${VGPU_DIR}/src/gl/texture_3d.c"
  "${VGPU_DIR}/src/gl/uniform.c"
  "${VGPU_DIR}/src/gl/vertexattrib.c"
  "${VGPU_DIR}/src/gl/wrap/gl4eswraps.c"
  "${VGPU_DIR}/src/gl/wrap/vgpu_darwin_aliases.c"
  "${VGPU_DIR}/src/gl/wrap/gles.c"
  "${VGPU_DIR}/src/gl/wrap/glstub.c"
  "${VGPU_DIR}/src/gl/math/matheval.c"
  "${VGPU_DIR}/src/gl/matvec.c"
)
add_library(vgpu_pack OBJECT ${VGPU_PACK_SRC})
add_library(vgpu_core OBJECT ${VGPU_CORE_SRC})
foreach(ame173_vgpu_tgt vgpu_pack vgpu_core)
  target_include_directories(${ame173_vgpu_tgt} PRIVATE "${VGPU_DIR}/include")
  target_compile_definitions(${ame173_vgpu_tgt} PRIVATE
    # Task179：+NOEGL——GetHardwareExtensions 的临时 EGL 探测上下文路径在
    # iOS 上全灭（装机 38a887d 实锤：egl_eglGetDisplay/eglBindAPI 等 LOAD_EGL
    # 全部 NULL——proc_address 苹果分支的 dlsym(RTLD_NEXT) 在晚加载的 vgpu
    # 里找不到任何东西，宿主早已加载框架），首个 egl_eglGetDisplay(...) 调用
    # = 调 NULL = SIGSEGV pc=0（1.8.9+vgpu 首个 GL 调用即崩）。
    # NOEGL 语义 = "GL 调用来自宿主已绑定的当前上下文"（我们的 gl_bridge 正是
    # 这么工作的：先建好上下文再让 vgpu 转译 GL 调用）——扩展探测改在【当前
    # 游戏上下文】上做，零临时上下文、零 egl_* 依赖。
    NOX11 NO_GBM NOEGL DEFAULT_ES=3 SHAREDLIB
  )
  target_link_libraries(${ame173_vgpu_tgt}
    "${GLOBAL_LDFLAGS}"
  )
endforeach()
add_library(vgpu SHARED
  $<TARGET_OBJECTS:vgpu_pack>
  $<TARGET_OBJECTS:vgpu_core>
)
target_link_libraries(vgpu
  "${GLOBAL_LDFLAGS}"
  "-F'${CMAKE_CURRENT_LIST_DIR}/resources/Frameworks'"
  "-framework libEGL"
  "-framework libGLESv2"
)
# payload 的 "cp $(WORKINGDIR)/*.dylib" 会把 libvgpu.dylib 自动带进 app
# 的 Frameworks（与 libtinygl4angle.dylib 同链路）。

# LTW (Large Thin Wrapper) - OpenGL Core 3.3 → OpenGL ES 3 转译层
# 复刻自官方 MojoLauncher/LTW 仓库（master 分支），iOS 移植修改：
#   - proc.c: 从 libtinygl4angle.dylib 加载 eglGetProcAddress（替代 libEGL.so）
#   - egl.c/egl.h: thread_local → pthread_key_t（更可靠的 TLS）
#   - shader_wrapper.c: 修复 offset 未递增 bug（count > 1 时 shader 源码损坏）
#   - ltw_compat/threads.h: 提供 C11 <threads.h> 兼容（iOS SDK 不提供）
# 功能：
#   - 伪装成 OpenGL 3.3 Core Profile 让 MC 1.17+ 正常运行
#   - 主动声明 GL_ARB_buffer_storage / GL_ARB_texture_buffer_object 等 ARB 扩展
#     让 Sodium 的 persistent mapped buffers / texture buffers 正常工作
#   - 主动声明 GL_ARB_draw_buffers_blend（Iris 必需）
#   - 主动声明 GL_ARB_timer_query（Blaze3D TimerQuery）
#   - Fragment shader 编译失败时忽略错误（shader_wrapper.c HACK），
#     让 BSL/Mellow Shader 等光影包能在 ES 上运行
set(LTW_DIR "${CMAKE_CURRENT_LIST_DIR}/external/LTW/ltw/src/main/tinywrapper")
set(LTW_INCLUDES
  "${LTW_DIR}"
  "${LTW_DIR}/GL"
  "${CMAKE_CURRENT_LIST_DIR}/cmake/ltw_compat"
  "${LTW_DIR}/glsl_optimizer/include"
  "${LTW_DIR}/glsl_optimizer/src"
  "${LTW_DIR}/vgpu_shaderconv"
  "${LTW_DIR}/unordered_map"
  "${CMAKE_CURRENT_LIST_DIR}/external/MobileGlues/src/main/cpp/include"
)

include(cmake/ltw_sources.cmake)

add_library(glsl_optimizer STATIC ${GLSL_OPTIMIZER_SRC})
target_include_directories(glsl_optimizer PRIVATE ${LTW_INCLUDES})
set_target_properties(glsl_optimizer PROPERTIES
  POSITION_INDEPENDENT_CODE ON
  CXX_STANDARD 17
  C_STANDARD 11
)
target_compile_definitions(glsl_optimizer PRIVATE
  _LIB NOMINMAX _USE_MATH_DEFINES __STDC_NO_THREADS__
  __STDC_LIMIT_MACROS __STDC_FORMAT_MACROS __STDC_CONSTANT_MACROS
  UTL_ARCH_LITTLE_ENDIAN UNIX
  HAVE_OPENGL HAVE_OPENGL_ES_1 HAVE_OPENGL_ES_2
  HAVE_TIMESPEC_GET HAVE_STRUCT_TIMESPEC
  VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK=VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK_EXT
)

add_library(ltw SHARED ${LTW_CORE_SRC})
target_include_directories(ltw PRIVATE ${LTW_INCLUDES})
target_link_libraries(ltw
  "${GLOBAL_LDFLAGS}"
  glsl_optimizer
  "-F'${CMAKE_CURRENT_LIST_DIR}/resources/Frameworks'"
  "-framework libEGL"
  "-framework libGLESv2"
)
set_target_properties(ltw PROPERTIES
  C_STANDARD 11
  C_STANDARD_REQUIRED ON
)
target_compile_definitions(ltw PRIVATE
  _LIB NOMINMAX _USE_MATH_DEFINES __STDC_NO_THREADS__
  __STDC_LIMIT_MACROS __STDC_FORMAT_MACROS __STDC_CONSTANT_MACROS
  UTL_ARCH_LITTLE_ENDIAN UNIX
  HAVE_OPENGL HAVE_OPENGL_ES_1 HAVE_OPENGL_ES_2
  HAVE_TIMESPEC_GET HAVE_STRUCT_TIMESPEC
)

# AFNetworking
add_library(AFNetworking SHARED
  external/AFNetworking/AFNetworking/AFSecurityPolicy.m
  external/AFNetworking/AFNetworking/AFHTTPSessionManager.m
  external/AFNetworking/AFNetworking/AFURLRequestSerialization.m
  external/AFNetworking/AFNetworking/AFURLSessionManager.m
  external/AFNetworking/AFNetworking/AFNetworkReachabilityManager.m
  external/AFNetworking/AFNetworking/AFURLResponseSerialization.m
  external/AFNetworking/UIKit+AFNetworking/AFNetworkActivityIndicatorManager.m
  external/AFNetworking/UIKit+AFNetworking/AFAutoPurgingImageCache.m
  external/AFNetworking/UIKit+AFNetworking/AFImageDownloader.m
  external/AFNetworking/UIKit+AFNetworking/UIButton+AFNetworking.m
  external/AFNetworking/UIKit+AFNetworking/UIImageView+AFNetworking.m
)
target_link_libraries(AFNetworking
  "-framework CoreGraphics"
  "-framework CoreServices"
  "-framework Security"
  "-framework SystemConfiguration"
  "-framework UIKit"
)

# MinecraftAccount JNI
add_library(AmethystAccountJNI SHARED
  authenticator/MinecraftAccountJNI.m
)
target_link_libraries(AmethystAccountJNI)

# Audio capture JNI bridge (SimpleVoiceChat Mod support)
add_library(audio_capture SHARED
  audio_capture_bridge.m
)
target_link_libraries(audio_capture
  "-framework AVFoundation"
)

# Angel Aura Amethyst
add_executable(AngelAuraAmethyst
  dyld_bypass_validation.m
  dyld_patch_platform.m
  main.m
  main_hook.m
  # Task 42：shaderc 编译进程外沙箱（父进程 spawn 本体为 helper 子进程，
  # Unix socket 传输编译请求/响应；详见 Natives/shaderc_sandbox.h 注释）
  shaderc_sandbox.m
  # SDL3 兼容层（移植自 ZalithLauncher2 的 sdl_hook.c）：建窗前强制 ES profile、
  # 主窗口复用、EGL 兼容重试、Vulkan 加载器句柄共享。iOS 无 bytehook，
  # 由 main_hook.m 的 hooked_dlsym 驱动。
  sdl3_hook.m
  JavaLauncher.m
  external/fishhook/fishhook.c
  UIKit+hook.m
  ScreenUtils.m
  # Task137：新拟态（NeomorphKit）退役，替换为 iOS 原生表面辅助与原生通知卡片
  UIKit+NativeSurface.m
  NMToast.m
  UIViewController+AMEPanel.m

  authenticator/BaseAuthenticator.m
  authenticator/LocalAuthenticator.m
  authenticator/MicrosoftAuthenticator.m
  authenticator/ThirdPartyAuthenticator.m

  ctxbridges/gl_bridge.m
  ctxbridges/osm_bridge.mm
  ctxbridges/mgl_fsr.mm
  ctxbridges/mgl_metal_fsr.mm
  ctxbridges/vk_bridge.m
  # Task 215：VirGLRenderer(≤26.2)（ZL2 移植）—— vtest 服务端引导桥
  # （egl_bridge 渲染器分支调用 ame_virgl_start_server；guest/服务端 dylib
  #  由 Makefile dep_virgl 产出并随 Frameworks 打包）
  ctxbridges/virgl_server.m

  customcontrols/ControlButton.m
  customcontrols/ControlDrawer.m
  customcontrols/ControlJoystick.m
  customcontrols/ControlLayout.m
  customcontrols/ControlSubButton.m
  customcontrols/CustomControlsUtils.m
  customcontrols/NSPredicateUtilitiesExternal.m

  external/DBNumberedSlider/Classes/DBNumberedSlider.m
  external/NRFileManager/NSFileManager+NRFileManager.m
  external/ballpa1n/HostManager.c
  external/ballpa1n/wrapped/HostManagerBridge.m
  external/mach/mach_excServer.c

  installer/FabricInstallViewController.m
  installer/ForgeInstallViewController.m
  installer/ForgeInstallSchemeViewController.m
  installer/ForgeDirectInstaller.m
  installer/NeoForgeDirectInstaller.m
  installer/ForgeProcessorExecutor.m
  installer/ModpackInstallViewController.m
  installer/ModLoaderInstallViewController.m
  installer/FabricUtils.m
  installer/NeoForgeVersionFetcher.m
  installer/modpack/ModpackUtils.m
  installer/modpack/ModpackConfiguration.m
  installer/modpack/ModpackAPI.m
  installer/modpack/ModrinthAPI.m
        installer/modpack/CurseForgeAPI.m

  input/ControllerInput.m
  input/GyroInput.m
  input/KeyboardInput.m

  AccountListViewController.m
  AccountLoginViewController.m
  ThirdPartyLoginViewController.m
  GameMenuOverlayView.m
  InlineMessageView.m
  DownloadTaskItem.m
  DownloadTaskManager.m
  PLTaskStage.m
  PLTaskProgressViewController.m
  DownloadTasksViewController.m
  DownloadHistoryViewController.m
  DownloadHistoryStore.m
  PLDownloadClient.m
  PLMirrorCenter.m
  DataTransferService.m
  AboutViewController.m
  # Task218：崩溃识别引擎（hs_err 分型/渲染器归因，JavaLauncher 消费）
  CrashAnalyzer.m
  # Task218：首次使用欢迎向导（语言/下载源/数据导入三步引导）
  WelcomeViewController.m
  AppDelegate.m
  CustomControlsViewController.m
  CustomControlsViewController+UndoManager.m
  ControlRepoViewController.m
  FileListViewController.m
  GameSurfaceView.m
  JavaGUIViewController.m
  # ZeroTier 联机暂时移除（排查启动崩溃）
  # MultiplayerManager.m
  # MultiplayerViewController.m
  # LanPortDetector.m
  # ZeroTierBridge.m
  # SOCKS5Proxy.m
  # PortForwarder.m
  LauncherMenuViewController.m
  LauncherNavigationController.m
  LauncherNewsViewController.m
  LauncherHelpViewController.m
  HomeCustomizeViewController.m
  LauncherRootViewController.m
  LauncherCardLayoutViewController.m
  LauncherRightPanelViewController.m
  VersionManagerViewController.m
  ProfileSettingsViewController.m
  DownloadViewController.m
  LauncherPreferences.m
  LauncherPreferencesViewController.m
  LauncherPrefContCfgViewController.m
  LauncherPrefGameDirViewController.m
  LauncherPrefManageJREViewController.m
  LauncherProfileEditorViewController.m
  LauncherSplitViewController.m
  MinecraftResourceDownloadTask.m
  MinecraftResourceUtils.m
  PickTextField.m
  PLLogOutputView.m
  PLCrashView.m
  PLPickerView.m
  PLPreferences.m
  PLPrefTableViewController.m
  PLProfiles.m
  SceneDelegate.m
  SceneExternalDelegate.m
  SurfaceViewController.m
  SurfaceViewController+ExternalDisplay.m
  SurfaceViewController+LogView.m
  SurfaceViewController+Navigation.m
  TrackedTextField.m
  egl_bridge.m
  ZinkConfig.m
  input_bridge_v3.m
  ios_uikit_bridge.m
  utils.m

  # Version card cell (used by DownloadViewController)
  VersionCardCell.m

  # Resource management shared base classes (card cell + list VC, shared by the 6 resource managers)
  ResourceCardTableViewCell.m
  ResourceListViewController.m

  # Mod-related sources (ensure implementations are compiled and linked)
  MarqueeLabel.m
  ModItem.m
  ModService.m
  ModTableViewCell.m
  ModTableViewController.m
  ModsManagerViewController.m
  ModVersion.m
  ModVersionViewController.m
  ModVersionTableViewCell.m

  # 通用资源详情页头部视图（Mod/Shader/Asset 版本页共用，展示项目封面图/信息/标签/描述）
  AssetDetailHeaderView.m

  # 模组加载器图标统一工具类（优先 bundle PNG，回退 SF Symbol，统一全项目加载器品牌色与图标）
  ModLoaderIconHelper.m

  # 统一的项目图标加载器（双层缓存+降采样+并发控制+CDN镜像，参照 FCL Glide + ZL2 Coil）
  IconLoader.m

  # Shader-related sources
  ShaderItem.m
  ShaderService.m
  ShaderVersion.m
  ShaderVersionTableViewCell.m
  ShaderVersionViewController.m
  ShadersManagerViewController.m

  # Modpack import/export sources
  ModpackImportViewController.m
  ModpackImportService.m
  ModpackExportService.m
  ModpackExportViewController.m

  # CurseForge MurmurHash2 fingerprint tool
  MurmurHash2.m
  # CurseForge MurmurHash2 指纹便捷计算（mod 检测更新反查用，过滤空白字节后计算）
  CurseForgeMurmurHash.m

  # Resource Pack / Data Pack / World management (services, items, version VC, manager VCs)
  ResourcePackItem.m
  DataPackItem.m
  WorldItem.m
  ResourcePackService.m
  DataPackService.m
  WorldService.m
  AssetVersionViewController.m
  ResourcePacksManagerViewController.m
  DataPacksManagerViewController.m
  WorldsManagerViewController.m

  # Server projects (Modrinth Server Projects + CurseForge server packs)
  ServerItem.m
  ServerService.m
  ServerListViewController.m
  ServerDetailViewController.m

  # CurseForge API Key settings page
  installer/CurseForgeAPIKeyViewController.m

  # Mod update service (dual-source SHA1/MurmurHash2 reverse lookup)
  ModUpdateService.m

  # Custom icon management sources
  CustomIconManager.m
  ImageCropperViewController.m

  # Account custom avatar management sources
  AvatarManager.m

  # Background wallpaper sources
  BackgroundManager.m
  BackgroundSettingsViewController.m

  # Task151: Bing daily wallpaper (HPImageArchive fetch/cache + gallery)
  BingWallpaperManager.m
  BingWallpaperGalleryViewController.m

  # FCL-style interface is implemented in LauncherMenuViewController.m

  # TouchController bridge and preferences
  TouchControllerBridge.m
  TouchControllerPreferencesViewController.m

  # Terracotta multiplayer（陶瓦联机）—— 暂时移除（排查启动崩溃）
  # TerracottaBridge.m
  # TerracottaManager.m
  # SilentAudioPlayer.m
  # TerracottaViewController.m

  # Update checker（参考 FCL/ZL2，使用 GitHub Releases API 检查正式版更新）
  UpdateChecker.m

  # Minecraft 新闻（参考 PCL-CE，调用 minecraft-services.net 官方新闻 API）
  MinecraftNewsItem.m
  MinecraftNewsService.m
  MinecraftNewsViewController.m

  # 公告系统（从官网拉取 JSON，支持 Markdown 渲染）
  AnnouncementItem.m
  AnnouncementService.m
  MarkdownParser.m
  AnnouncementListViewController.m
  AnnouncementDetailViewController.m

  # Air AI Agent（OpenAI 兼容聊天助手）
  AI/AiProvider.m
  AI/AiProviderStore.m
  AI/AiMessage.m
  AI/AiSession.m
  AI/AiSessionStore.m
  AI/AiSettings.m
  AI/AiAPIClient.m
  AI/AiAgent.m
  AI/AIMessageCell.m
  AI/AIInputBarView.m
  AI/AIViewController.m
  AI/AISessionListViewController.m
  AI/AIProviderConfigViewController.m
  AI/AISystemPromptEditorViewController.m

  # Air AI Agent 工具基础层（3a：注册表 / 安全机制 / 实例 / 日志 / 崩溃 / 文件 / 问答）
  AI/AiToolRegistry.m
  AI/AiSafetyManager.m
  AI/AiToolBootstrapper.m
  AI/AiInstancesTool.m
  AI/AiLogReader.m
  AI/AiCrashAnalyzer.m
  AI/AiFileTools.m
  AI/AiAskTool.m

  # Air AI Agent 资源/网络工具（3b：Modrinth 搜索 + 资源安装/引导）
  AI/AiAssetTools.m

  # Air AI Agent 第二轮增强（enhance-ai-agent：设置 / to-do / sleep / 下载查询 / 实例创建）
  AI/AiSettingsTools.m
  AI/AiTodoTool.m
  AI/AiSleepTool.m
  AI/AiDownloadProbe.m
  AI/AiInstanceCreator.m
)

# Task 83（FSR 独立化）：osm_bridge.mm 与 mgl_fsr.mm（Task119 新增）是仅有的
# 两个 ObjC++ 源——它们都包含 MobileGlues FSRShaderSource.h（C++ raw string
# 字面量，必须 C++ 方言）与 ObjC 世界头。工程未启用 OBJCXX
# 语言（全部 .m 走 C + "-ObjC" 强制路线），CMake 会把 .mm 当纯 CXX 编译，
# @interface 直接解析失败（CI run 34987233296，28 errors）。单文件强制
# objective-c++ 方言 + ARC + gnu++17（Apple clang 15 的 clang++ 默认 gnu++98，
# 不认 C++11 raw string——FSRShaderSource.h 的 R"fsr_glsl(...)" 需要，
# CI run 34992226284："use of undeclared identifier R"）。与 .m 侧口径对齐。
set_source_files_properties(ctxbridges/osm_bridge.mm PROPERTIES
  COMPILE_OPTIONS "-x;objective-c++;-fobjc-arc;-std=gnu++17")
# Task 119：MobileGL 预交换 FSR1 EASU 模块（与 osm_bridge 同款 FSRShaderSource.h
# 依赖，同方言同标准）。实现见 Natives/ctxbridges/mgl_fsr.mm 头注释。
set_source_files_properties(ctxbridges/mgl_fsr.mm PROPERTIES
  COMPILE_OPTIONS "-x;objective-c++;-fobjc-arc;-std=gnu++17")
# Task 166：MobileGL DirectVulkan 的 Metal 层 FSR1 模块（双 CAMetalLayer
# 交换层拦截 + MSL EASU/RCAS，与 osm_bridge/mgl_fsr 同为 ObjC++ 方言；
# 含 Metal/Metal 依赖与 ObjC 协议实现）。实现见
# Natives/ctxbridges/mgl_metal_fsr.mm 文件头。
set_source_files_properties(ctxbridges/mgl_metal_fsr.mm PROPERTIES
  COMPILE_OPTIONS "-x;objective-c++;-fobjc-arc;-std=gnu++17")

# Add ModLoaderIcons PNG files into the app bundle Resources/ModLoaderIcons so they are available at runtime.
# This will copy all *.png under Natives/ModLoaderIcons into the bundle at Resources/ModLoaderIcons/<name>.png
set(MODLOADER_ICONS_DIR "${CMAKE_CURRENT_LIST_DIR}/ModLoaderIcons")
if(EXISTS "${MODLOADER_ICONS_DIR}")
  file(GLOB MODLOADER_ICON_FILES "${MODLOADER_ICONS_DIR}/*.png")
  if(MODLOADER_ICON_FILES)
    foreach(_icon ${MODLOADER_ICON_FILES})
      get_filename_component(_name ${_icon} NAME)
      message(STATUS "Including mod loader icon in bundle: ${_name}")
      # Place into Resources/ModLoaderIcons inside the .app bundle so your code can find resourcePath/ModLoaderIcons/...
      set_source_files_properties(${_icon} PROPERTIES MACOSX_PACKAGE_LOCATION "Resources/ModLoaderIcons")
    endforeach()
    # Attach the resource files to the main executable target so CMake copies them into the bundle
    target_sources(AngelAuraAmethyst PRIVATE ${MODLOADER_ICON_FILES})
  endif()
else()
  message(STATUS "ModLoaderIcons directory not found: ${MODLOADER_ICONS_DIR}")
endif()

if("${CMAKE_HOST_SYSTEM_NAME}" MATCHES "Linux|^GNU$|Android")
  target_sources(AngelAuraAmethyst PUBLIC non_darwin_utils.m)
endif()

target_link_libraries(AngelAuraAmethyst
  PUBLIC AFNetworking
  lzma
  # Task 83（FSR 独立化）：目标含 .mm 后 CMake 把链接器从 C 切到 CXX，
  # C 驱动的链接行曾带 CMAKE_C_FLAGS（-fobjc-arc -ObjC）触发 Foundation
  # 自动链接，CXX 驱动不带 → NS*/NSURLSession 全体 undefined（run
  # 35036079381）。显式链接 Foundation（UIKit 的传递依赖不再依赖驱动魔法）。
  "-framework Foundation"
  "-F'${CMAKE_CURRENT_LIST_DIR}/build'"
  "-F'${CMAKE_CURRENT_LIST_DIR}/resources/Frameworks'"
  # ZeroTier 暂时移除："${ZT_FRAMEWORK_SEARCH_PATH}" "${ZT_FRAMEWORK_LINK}" "${ZT_CXX_LIB}"
  "-framework AltKit"
  "-framework AuthenticationServices"
  "-framework AVFoundation"
  "-framework CAltKit"
  "-framework CoreFoundation"
  "-framework CoreGraphics"
  "-framework CoreImage"
  "-framework CoreMedia"
  "-framework ImageIO"
  # Task151：Bing 壁纸保存到相册（PHPhotoLibrary/PHAssetChangeRequest）
  "-framework Photos"
  "-framework CoreMotion"
  "-framework GameController"
  "-framework IOKit"
  # Task 166：Metal 层 FSR1（mgl_metal_fsr.mm 的 MTLDevice/管线/命令缓冲）。
  "-framework Metal"
  "-framework QuartzCore"
  "-framework UIKit"
  "-framework UniformTypeIdentifiers"
  "-framework UnzipKit"
  "-framework WebKit"
  "-weak_framework SafariServices"
  ${TOUCHCONTROLLER_LIB}
  # Terracotta multiplayer 暂时移除：${TERRACOTTA_LIB} "-lc++" "-lresolv"
)
set_target_properties(AngelAuraAmethyst PROPERTIES
  MACOSX_BUNDLE TRUE
  MACOSX_FRAMEWORK_IDENTIFIER org.cmake.ExecutableTarget
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_LIST_DIR}/Info.plist")
