SHELL := /bin/bash
.SHELLFLAGS = -ec
# Use `make VERBOSE=1` to print commands.
$(VERBOSE).SILENT:

# Prerequisite variables
SOURCEDIR   := $(shell printf "%q\n" "$(shell pwd)")
OUTPUTDIR   := $(SOURCEDIR)/artifacts
WORKINGDIR  := $(SOURCEDIR)/Natives/build
DETECTPLAT  := $(shell uname -s)
DETECTARCH  := $(shell uname -m)
VERSION     := 1.0
BRANCH      := $(shell git branch --show-current)
COMMIT      := $(shell git log --oneline | sed '2,10000000d' | cut -b 1-7)
PLATFORM    ?= 2

# Release vs Debug
RELEASE ?= 0

# Check if running on github runner
RUNNER ?= 0

# Check if slimmed should be built
SLIMMED ?= 0

# Check if slimmed should be built, and additionally skip normal build
SLIMMED_ONLY ?= 0

# If not in a GitHub repository, default to these
# so that compiling doesn't fail
BRANCH ?= "unknown"
COMMIT ?= "unknown"

# Team IDs and provisioning profile for the codesign function
# Default to -1 for check
# Currently requires a paid Apple Developer account, will fix later
SIGNING_TEAMID ?= -1
TEAMID ?= -1
PROVISIONING ?= -1

ifeq (1,$(RELEASE))
CMAKE_BUILD_TYPE := Release
else
CMAKE_BUILD_TYPE := Debug
endif


# Distinguish iOS from macOS, and *OS from others
ifeq ($(DETECTPLAT),Darwin)
OSVER       := $(shell sw_vers -productVersion | cut -b 1-2)
ifeq ($(shell sw_vers -productName),macOS)
IOS         := 0
SDKPATH     ?= $(shell xcrun --sdk iphoneos --show-sdk-path)
BOOTJDK     ?= $(shell /usr/libexec/java_home -v 1.8)/bin
$(warning Building on macOS.)
else
IOS         := 1
SDKPATH     ?= /usr/share/SDKs/iPhoneOS.sdk
BOOTJDK     ?= /usr/lib/jvm/java-8-openjdk/bin
ifeq ($(shell test "$(OSVER)" -gt 14; echo $$?),0)
PREFIX      ?= /var/jb/
else
PREFIX      ?= /
endif
$(warning Building on iOS. Note that all targets may not compile or require external components.)
endif
else ifeq ($(DETECTPLAT),Linux)
IOS         := 0
# SDKPATH presence is checked later
BOOTJDK     ?= /usr/bin
$(warning Building on Linux. Note that all targets may not compile or require external components.)
else
$(error This platform is not currently supported for building Angel Aura Amethyst.)
endif

# Define PLATFORM_NAME from PLATFORM
ifeq ($(PLATFORM),2)
PLATFORM_NAME := ios
$(warning Set PLATFORM to 2, which is equal to iOS.)
else ifeq ($(PLATFORM),3)
PLATFORM_NAME := tvos
$(warning Set PLATFORM to 3, which is equal to tvOS.)
else ifeq ($(PLATFORM),6)
PLATFORM_NAME := maccatalyst
$(warning Set PLATFORM to 6, which is equal to Mac Catalyst.)
else ifeq ($(PLATFORM),7)
PLATFORM_NAME := iossimulator
$(warning Set PLATFORM to 7, which is equal to iOS Simulator.)
else ifeq ($(PLATFORM),8)
PLATFORM_NAME := tvossimulator
$(warning Set PLATFORM to 8, which is equal to tvOS Simulator.)
else ifeq ($(PLATFORM),11)
PLATFORM_NAME := xros
$(warning Set PLATFORM to 11, which is equal to visionOS.)
else ifeq ($(PLATFORM),12)
PLATFORM_NAME := xrsimulator
$(warning Set PLATFORM to 12, which is equal to visionOS Simulator.)
else
$(error PLATFORM is not valid.)
endif

POJAV_BUNDLE_DIR      ?= $(OUTPUTDIR)/AngelAuraAmethyst.app
POJAV_JRE8_DIR        ?= $(SOURCEDIR)/depends/java-8-openjdk
POJAV_JRE17_DIR       ?= $(SOURCEDIR)/depends/java-17-openjdk
POJAV_JRE21_DIR       ?= $(SOURCEDIR)/depends/java-21-openjdk
POJAV_JRE25_DIR       ?= $(SOURCEDIR)/depends/java-25-openjdk
MOLTENVK_LIBRARY      ?= $(SOURCEDIR)/Natives/resources/Frameworks/libMoltenVK.dylib

# Function to use later for checking dependencies
METHOD_DEPCHECK   = $(shell $(1) >/dev/null 2>&1 && echo 1)

# Function to modify Info.plist files
METHOD_INFOPLIST  =  \
	if [ '$(4)' = '0' ]; then \
		plutil -replace $(1) -string $(2) $(3); \
	else \
		plutil -value $(2) -key $(1) $(3); \
	fi

# Function to check directories
METHOD_DIRCHECK   = \
	if [ ! -d '$(1)' ]; then \
		mkdir -p $(1); \
	else \
		rm -rf $(1)/*; \
	fi
	
# Function to change the platform on Mach-O files.
# iOS = 2, tvOS = 3, iOS Simulator = 7, tvOS Simulator = 8, visionOS = 11, visionOS Simulator = 12
# https://github.com/apple-oss-distributions/xnu/blob/main/EXTERNAL_HEADERS/mach-o/loader.h
# TODO: Change Info.plist for visionOS 1.0
METHOD_CHANGE_PLAT = \
	if [ '$(1)' != '11' ] && [ '$(1)' != '12' ]; then \
		vtool -arch arm64 -set-build-version $(1) 14.0 16.0 -replace -output $(2) $(2); \
		ldid -S -M $(2); \
	else \
		vtool -arch arm64 -set-build-version $(1) 1.0 1.0 -replace -output $(2) $(2); \
	fi \
	
# Function to package the application
# 修复：使用统一的命名格式 amethystremastered
METHOD_PACKAGE = \
	if [ '$(TROLLSTORE_JIT_ENT)' == '1' ]; then \
		IPA_SUFFIX="-trollstore.tipa"; \
	else \
		IPA_SUFFIX=".ipa"; \
	fi; \
	rm -f $(OUTPUTDIR)/com.air-devs.air-$(VERSION)-$(PLATFORM_NAME)$$IPA_SUFFIX; \
	rm -f $(OUTPUTDIR)/com.air-devs.air.slimmed-$(VERSION)-$(PLATFORM_NAME)$$IPA_SUFFIX; \
	if [ '$(SLIMMED_ONLY)' = '0' ]; then \
		zip --symlinks -r $(OUTPUTDIR)/com.air-devs.air-$(VERSION)-$(PLATFORM_NAME)$$IPA_SUFFIX Payload; \
	fi; \
	if [ '$(SLIMMED)' = '1' ] || [ '$(SLIMMED_ONLY)' = '1' ]; then \
		zip --symlinks -r $(OUTPUTDIR)/com.air-devs.air.slimmed-$(VERSION)-$(PLATFORM_NAME)$$IPA_SUFFIX Payload --exclude='Payload/AngelAuraAmethyst.app/java_runtimes/*'; \
	fi

# Function to download and unpack Java runtimes.
METHOD_JAVA_UNPACK = \
	cd $(SOURCEDIR)/depends; \
	if [ ! -f "java-$(1)-openjdk/release" ] && [ ! -f "$(ls jre$(1)-*.tar.xz)" ]; then \
		if [ "$(RUNNER)" != "1" ]; then \
			wget_ok=0; \
			for attempt in 1 2 3 4 5; do \
				if wget '$(2)' --timeout=90 --tries=2 --retry-connrefused --show-progress -O jre$(1)-ios-aarch64.zip; then wget_ok=1; break; fi; \
				echo '[jre] download failed (attempt '$$attempt'/5), retrying in 15s: $(2)'; \
				sleep 15; \
			done; \
			if [ "$$wget_ok" != "1" ]; then echo '[jre] FATAL: could not download $(2) after 5 attempts'; exit 1; fi; \
			unzip jre$(1)-ios-aarch64.zip && rm jre$(1)-ios-aarch64.zip; \
		fi; \
		mkdir -p java-$(1)-openjdk; \
		tar xvf jre$(1)-*.tar.xz -C java-$(1)-openjdk; \
	fi

# Function to codesign binaries.
METHOD_CODESIGN = \
	codesign --remove-signature $(2); \
	codesign -f -s $(1) --generate-entitlement-der --entitlements entitlements.codesign.xml $(2); \
	printf 'File: '; printf $(2); printf ', Codesigned with team: '; printf $(1); printf '\n'

# Function to run code when finding Mach-O files.
METHOD_MACHO = \
	for file in $$(find $(1)); do \
		if [[ "$$(file $$file)" == *"Mach-O"* ]]; then \
			$(2); \
		fi; \
	done

# Make sure everything is already available for use. Error if they require something
ifneq ($(call METHOD_DEPCHECK,cmake --version),1)
$(error You need to install cmake)
endif

ifneq ($(call METHOD_DEPCHECK,$(BOOTJDK)/javac -version),1)
$(error You need to install JDK 8)
endif

ifeq ($(IOS),0)
ifeq ($(filter 1.8.0,$(shell $(BOOTJDK)/javac -version &> javaver.txt && cat javaver.txt | cut -b 7-11 && rm -rf javaver.txt)),)
$(error You need to install JDK 8)
endif
endif

ifneq ($(call METHOD_DEPCHECK,ldid),1)
$(error You need to install ldid)
endif

ifneq ($(call METHOD_DEPCHECK,wget --version),1)
$(error You need to install wget)
endif

ifeq ($(DETECTPLAT),Linux)
ifneq ($(call METHOD_DEPCHECK,lld),1)
$(error You need to install lld)
endif
endif

ifneq ($(filter sysctl,$(shell sysctl -n hw.logicalcpu)),)
ifneq ($(call METHOD_DEPCHECK,nproc --version),1)
ifneq ($(call METHOD_DEPCHECK,gnproc --version),1)
$(warning Unable to determine number of threads, defaulting to 2.)
JOBS   ?= 2
else
JOBS   ?= $(shell gnproc)
endif
else
JOBS   ?= $(shell nproc)
endif
else
JOBS   ?= $(shell sysctl -n hw.logicalcpu)
endif

ifndef SDKPATH
$(error You need to specify SDKPATH to the path of iPhoneOS.sdk. The SDK version should be 14.0 or newer.)
endif

all: clean native java jre assets payload package dsym

help:
	echo 'Makefile to compile Angel Aura Amethyst'
	echo ''
	echo 'Usage:'
	echo '    make                                Makes everything under all'
	echo '    make help                           Displays this message'
	echo '    make all                            Builds the entire app'
	echo '    make native                         Builds the native app'
	echo '    make java                           Builds the Java app'
	echo '    make jre                            Downloads/unpacks the iOS JREs'
	echo '    make assets                         Compiles Assets.xcassets'
	echo '    make payload                        Makes Payload/AngelAuraAmethyst.app'
	echo '    make package                        Builds ipa of Angel Aura Amethyst'
	echo '    make deploy                         Copies files to local iDevice'
	echo '    make dsym                           Generate debug symbol files'
	echo '    make clean                          Cleans build directories'
	echo '    make check                          Dump all variables for checking'

check:
	$(foreach v, \
		$(shell echo "$(filter-out METHOD_% .% MAKEFILE_LIST MAKEFLAGS CURDIR,$(.VARIABLES))" | tr ' ' '\n' | sort), \
		$(if $(filter file,$(origin $(v))), \
		$(info $(shell printf "%-20s" "$(v)") = $(value $(v)))) \
	)

native: dep_mg
	echo '[Amethyst v$(VERSION)] native - start'
	mkdir -p $(WORKINGDIR)
	cd $(WORKINGDIR) && cmake \
		-DCMAKE_BUILD_TYPE=$(CMAKE_BUILD_TYPE) \
		-DCMAKE_CROSSCOMPILING=true \
		-DCMAKE_SYSTEM_NAME=Darwin \
		-DCMAKE_SYSTEM_PROCESSOR=aarch64 \
		-DCMAKE_OSX_SYSROOT="$(SDKPATH)" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
		-DCMAKE_C_FLAGS="-arch arm64" \
		-DCONFIG_BRANCH="$(BRANCH)" \
		-DCONFIG_COMMIT="$(COMMIT)" \
		-DCONFIG_RELEASE=$(RELEASE) \
		..

	cmake --build $(WORKINGDIR) --config $(CMAKE_BUILD_TYPE) -j$(JOBS)
	#	--target awt_headless awt_xawt libOSMesaOverride.dylib tinygl4angle AngelAuraAmethyst
	rm $(WORKINGDIR)/libawt_headless.dylib
	echo '[Amethyst v$(VERSION)] native - end'

java:
	echo '[Amethyst v$(VERSION)] java - start'
	$(MAKE) -C JavaApp -j$(JOBS) BOOTJDK=$(BOOTJDK)
	echo '[Amethyst v$(VERSION)] java - end'

jre: native
	echo '[Amethyst v$(VERSION)] jre - start'
	mkdir -p $(SOURCEDIR)/depends
	cd $(SOURCEDIR)/depends; \
	$(call METHOD_JAVA_UNPACK,8,'https://assets.angelauramc.dev/openjdk/ios-arm64/jre8-ios-aarch64.zip'); \
	$(call METHOD_JAVA_UNPACK,17,'https://assets.angelauramc.dev/openjdk/ios-arm64/jre17-ios-aarch64.zip'); \
	$(call METHOD_JAVA_UNPACK,21,'https://assets.angelauramc.dev/openjdk/ios-arm64/jre21-ios-aarch64.zip'); \
	$(call METHOD_JAVA_UNPACK,25,'https://assets.angelauramc.dev/openjdk/ios-arm64/jre25-ios-aarch64.zip'); \
	if [ -f "$(ls jre*.tar.xz)" ]; then rm $(SOURCEDIR)/depends/jre*.tar.xz; fi; \
	cd $(SOURCEDIR); \
	rm -rf $(SOURCEDIR)/depends/java-{8,17,21,25}-openjdk/{ASSEMBLY_EXCEPTION,bin,include,jre,legal,LICENSE,man,THIRD_PARTY_README,lib/{ct.sym,jspawnhelper,libjsig.dylib,src.zip,tools.jar}}; \
	# Task 74: FFM upcall stub mirror translation fix. UpcallStub::create in the
	# bundled JRE 21/25 forgets mirrored_find_rw() after CodeCache::allocate(),
	# so the first CodeBlob header store writes the RX-only debugger JIT region
	# -> SIGBUS (Controlify/FFM upcalls on iOS 26+ TXM mirror JIT). JRE 17 is
	# unaffected (OptimizedEntryBlob::create already translates). Idempotent;
	# loud failure on runtime version drift. Details: scripts/patch_jre_upcall_mirror.py.
	python3 $(SOURCEDIR)/scripts/patch_jre_upcall_mirror.py \
		$(POJAV_JRE21_DIR)/lib/server/libjvm.dylib \
		$(POJAV_JRE25_DIR)/lib/server/libjvm.dylib || exit 1; \
	$(call METHOD_DIRCHECK,$(OUTPUTDIR)/java_runtimes); \
	cp -R $(POJAV_JRE8_DIR) $(OUTPUTDIR)/java_runtimes; \
	cp -R $(POJAV_JRE17_DIR) $(OUTPUTDIR)/java_runtimes; \
	cp -R $(POJAV_JRE21_DIR) $(OUTPUTDIR)/java_runtimes; \
	cp -R $(POJAV_JRE25_DIR) $(OUTPUTDIR)/java_runtimes; \
	cp $(WORKINGDIR)/libawt_xawt.dylib $(OUTPUTDIR)/java_runtimes/java-8-openjdk/lib; \
	cp $(WORKINGDIR)/libawt_xawt.dylib $(OUTPUTDIR)/java_runtimes/java-17-openjdk/lib;
	cp $(WORKINGDIR)/libawt_xawt.dylib $(OUTPUTDIR)/java_runtimes/java-21-openjdk/lib
	cp $(WORKINGDIR)/libawt_xawt.dylib $(OUTPUTDIR)/java_runtimes/java-25-openjdk/lib
	echo '[Amethyst v$(VERSION)] jre - end'

dep_mg:
	echo '[Amethyst v$(VERSION)] dep_mg - start'

	# The shader conversion pipeline (desktop GLSL -> ESSL) is only validated
	# against the submodule commits pinned in .gitmodules. A 3rdparty/ tree
	# populated from arbitrary master snapshots produced ESSL that ANGLE-Metal
	# rejects as empty ("ERROR: 1:1: '' : syntax error" on every shader, MC
	# 26.x black screen). Force the pinned versions before configuring cmake,
	# and fail loudly if they are still missing afterwards.
	@if [ ! -f "$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/glslang/CMakeLists.txt" ] || \
	    [ ! -f "$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/SPIRV-Cross/CMakeLists.txt" ] || \
	    [ ! -f "$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/xxhash/xxhash32.h" ]; then \
		echo '3rdparty/ incomplete: checking out pinned glslang/SPIRV-Cross/xxhash submodules'; \
		git -C $(SOURCEDIR) submodule update --init --force --recursive \
			Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/glslang \
			Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/SPIRV-Cross \
			Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/xxhash || exit 1; \
	fi
	@test -f "$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/glslang/CMakeLists.txt" || { echo "ERROR: glslang submodule still missing - cannot build MobileGlues"; exit 1; }
	@test -f "$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/SPIRV-Cross/CMakeLists.txt" || { echo "ERROR: SPIRV-Cross submodule still missing - cannot build MobileGlues"; exit 1; }
	@test -f "$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/xxhash/xxhash32.h" || { echo "ERROR: xxhash submodule still missing - cannot build MobileGlues"; exit 1; }
	# The pinned glslang (f5f664d) dereferences the swizzle selector aggregate in
	# TParseContext::lValueErrorCheck without a null check. On iOS/arm64 that
	# exact chain SIGSEGV'd the process while parsing Minecraft 26.x's
	# position_color vertex shader (666 bytes post moj_import), killing the game
	# during startup. Apply the defensive null-guard patch on top of the pinned
	# submodule; idempotent across cached and fresh CI workspaces.
	@if git -C $(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/glslang apply --check $(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/glslang-lvalue-nullguard.patch >/dev/null 2>&1; then \
		git -C $(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/glslang apply $(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/glslang-lvalue-nullguard.patch && echo 'glslang-lvalue-nullguard.patch applied'; \
	else \
		echo 'glslang-lvalue-nullguard.patch already applied or submodule absent - continuing'; \
	fi
	# Task 45: pool-block zero-fill + constArray size guards, applied ON TOP of
	# the nullguard patch (requires it). The prebuilt libshaderc_impl.dylib crash
	# family (45 tasks: constArray+0xd8 reads recycled source-text bytes -> SIGSEGV
	# -> all pipelines fail -> MC dies) is closed at the source level: every fresh
	# glslang pool block (malloc-recycled OR freelist-reused) is zero-filled, so
	# any un-initialized / stale field read observes 0/NULL and the nullguards
	# degrade gracefully (identity swizzle / skipped element) instead of dying.
	# Idempotent: --check first, matching the nullguard block above.
	@if git -C $(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/glslang apply --check $(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/glslang-pool-zero-and-size-guards.patch >/dev/null 2>&1; then \
		git -C $(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/glslang apply $(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/glslang-pool-zero-and-size-guards.patch && echo 'glslang-pool-zero-and-size-guards.patch applied'; \
	else \
		echo 'glslang-pool-zero-and-size-guards.patch already applied or submodule absent - continuing'; \
	fi
	mkdir -p $(WORKINGDIR)/mobileglues
	# Task 27: 显式设 CMAKE_BUILD_TYPE=RelWithDebInfo。此前未设置（--config 对
	# 单配置生成器无效），CMake 不追加 -O2/-DNDEBUG：整库 -O0 且 glslang/
	# SPIRV-Cross/MG 的 assert() 全部激活——assert 触发即 __assert_rtn->abort()，
	# 被 hooked_abort 拦截后表现为直接进启动器错误界面且无 .ips/hs_err。
	# RelWithDebInfo = -O2 -g -DNDEBUG，对齐上游 Release 语义。
	cd $(WORKINGDIR)/mobileglues && cmake \
		-DMACOS="1" \
		-DCMAKE_CROSSCOMPILING=true \
		-DCMAKE_SYSTEM_NAME=Darwin \
		-DCMAKE_SYSTEM_PROCESSOR=aarch64 \
		-DCMAKE_OSX_SYSROOT="$(SDKPATH)" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
		-DCMAKE_C_FLAGS="-arch arm64" \
		-DCMAKE_BUILD_TYPE=RelWithDebInfo \
		$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/

	# Task 45: also build the SPIRV emitter + default resource limits static
	# libraries - dep_shader_shims links them (with libglslang.a) into the
	# from-source libshaderc_impl.dylib. mobileglues itself only links
	# glslang::glslang, so these targets must be named explicitly.
	# Task 46: the archives land under <build>/3rdparty/glslang/ - the
	# MobileGlues superbuild add_subdirectory(3rdparty/glslang) keeps
	# source-relative binary dirs. Task 45 checked the standalone-glslang
	# layout (<build>/SPIRV/..., produced only by a manual standalone
	# configure) and aborted CI with "libSPIRV.a missing" right after an
	# all-green compile (run 34105892191). Check the superbuild layout,
	# fall back to locating the archive by name, fail with a listing.
	cmake --build $(WORKINGDIR)/mobileglues --config RelWithDebInfo -j$(JOBS) --target mobileglues SPIRV glslang-default-resource-limits
	@mg_spirv_a=$(WORKINGDIR)/mobileglues/3rdparty/glslang/SPIRV/libSPIRV.a; \
	[ -f "$$mg_spirv_a" ] || mg_spirv_a=$$(find $(WORKINGDIR)/mobileglues -type f -name libSPIRV.a -print -quit 2>/dev/null); \
	mg_glslang_a=$(WORKINGDIR)/mobileglues/3rdparty/glslang/glslang/libglslang.a; \
	[ -f "$$mg_glslang_a" ] || mg_glslang_a=$$(find $(WORKINGDIR)/mobileglues -type f -name libglslang.a -print -quit 2>/dev/null); \
	mg_rl_a=$(WORKINGDIR)/mobileglues/3rdparty/glslang/glslang/libglslang-default-resource-limits.a; \
	[ -f "$$mg_rl_a" ] || mg_rl_a=$$(find $(WORKINGDIR)/mobileglues -type f -name libglslang-default-resource-limits.a -print -quit 2>/dev/null); \
	if [ -z "$$mg_spirv_a" ] || [ ! -f "$$mg_spirv_a" ] || [ -z "$$mg_glslang_a" ] || [ ! -f "$$mg_glslang_a" ] || [ -z "$$mg_rl_a" ] || [ ! -f "$$mg_rl_a" ]; then \
		echo "ERROR: glslang static libs unresolved (spirv=$$mg_spirv_a glslang=$$mg_glslang_a rl=$$mg_rl_a) - from-source shaderc impl cannot link"; \
		find $(WORKINGDIR)/mobileglues -type f -name "lib*.a" 2>/dev/null | head -20; \
		exit 1; \
	fi; \
	echo "[shaderc-impl] glslang static libs OK (spirv=$$mg_spirv_a glslang=$$mg_glslang_a rl=$$mg_rl_a)"
	cp $(WORKINGDIR)/mobileglues/libmobileglues*.dylib $(WORKINGDIR)/
	echo '[Amethyst v$(VERSION)] dep_mg - end'
dep_mobilegl:
	# Task 113：MobileGL 重新集成（仅 DirectVulkan 后端）。
	# - libMobileGL.dylib 为预编译产物（MobileGL-Dev，LGPL-3.0），随包携带于
	#   Natives/resources/Frameworks/，payload 的 "cp -R resources/*" 自动打包。
	# - 上游同款二进制（caf6822 会话实测 26.3 完全流畅：CAMetalLayer 直呈 +
	#   IMMEDIATE 呈现模式 + 无 CPU 回读）。
	# - 运行时入口 = 设置-视频-"MobileGL Vulkan 直呈渲染器"开关（mobilegl_vulkan），
	#   不进主渲染器列表（用户要求）；GLES 变体（libMobileGL-gles.dylib）不引入
	#   （上游实测其他后端有问题）。
	# - 源码构建路径（BUILD_MOBILEGL=1，见上游 Makefile dep_mobilegl_build）未引入：
	#   预编译产物已验证可用；需要重建时参照上游 55256e33 的 vendored source 流程。
	# 保留空目标避免外部 make 调用报错（payload 依赖 resources/ 直拷，无需本目标做事）
	@echo '[Amethyst v$(VERSION)] dep_mobilegl - using prebuilt libMobileGL.dylib in Natives/resources/Frameworks/ (Task113, Vulkan-only)'


dep_openal_shim:
	# Task 129：OpenAL ALC_SOFT_system_events 兼容垫片（26.1.2 整合包崩溃修复）。
	# - 真库已 git mv 为 libopenal_impl.dylib（openal-soft 1.20.1 iOS 构建，无
	#   ALC_SOFT_system_events 扩展）；本目标构建同名垫片 libopenal.dylib：
	#   re-export impl 全部符号 + 覆盖 alcGetString/alcIsExtensionPresent 宣称扩展
	#   + 提供 alcEventIsSupportedSOFT/alcEventControlSOFT/alcEventCallbackSOFT 桩。
	# - 根因：MC 26.1.2 CallbackDeviceTracker.isSupported 无扩展守卫，直接调
	#   LWJGL 绑定 -> ICD 槽位 0 -> NPE 崩溃（26.3 有守卫故存活）。
	#   桩返回 ALC_FALSE 使 MC 干净回退 PollingDeviceTracker。
	# - 与 dep_shader_shim 同款模式：re-export 必须指向 impl 名（LC_ID 先修正），
	#   否则加载递归；本地函数定义优先于 re-export 符号（shaderc 先例）。
	echo '[Amethyst v$(VERSION)] dep_openal_shim - start'
	cp $(SOURCEDIR)/Natives/resources/Frameworks/libopenal_impl.dylib $(WORKINGDIR)/ || exit 1
	install_name_tool -id @rpath/libopenal_impl.dylib $(WORKINGDIR)/libopenal_impl.dylib || exit 1
	xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
		-install_name @rpath/libopenal.dylib \
		-Wl,-reexport_library,$(WORKINGDIR)/libopenal_impl.dylib \
		-o $(WORKINGDIR)/libopenal.dylib \
		$(SOURCEDIR)/Natives/openal_shim.c || exit 1
	echo '[Amethyst v$(VERSION)] dep_openal_shim - end'

dep_mithril_glshim:
	echo '[Amethyst v$(VERSION)] dep_mithril_glshim - start'
	# Task 156: Mithril GL provider shim (libmithril_glshim.dylib).
	# - re-export every libmithril.dylib symbol (dep_openal_shim pattern;
	#   its install name is already @rpath/libmithril.dylib -- no LC_ID fix
	#   needed). LWJGL points -Dorg.lwjgl.opengl.libname at the shim, so the
	#   Delegate per-name dlsym lands on Mithril's own implementations.
	# - local glGetIntegerv/glGetInteger64v win over the re-exports and floor
	#   zero limit enums (GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT=0 caused MC 26.2
	#   DynamicUniformStorage divide-by-zero; see Natives/mithril_gl_shim.c).
	xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
		-install_name @rpath/libmithril_glshim.dylib \
		-Wl,-reexport_library,$(SOURCEDIR)/Natives/resources/Frameworks/libmithril.dylib \
		-o $(WORKINGDIR)/libmithril_glshim.dylib \
		$(SOURCEDIR)/Natives/mithril_gl_shim.c || exit 1
	echo '[Amethyst v$(VERSION)] dep_mithril_glshim - end'

assets:
	echo '[Amethyst v$(VERSION)] assets - start'
	if [ '$(IOS)' = '0' ] && [ '$(DETECTPLAT)' = 'Darwin' ]; then \
		mkdir -p $(WORKINGDIR)/AngelAuraAmethyst.app/Base.lproj; \
		xcrun actool $(SOURCEDIR)/Natives/Assets.xcassets \
			--compile $(SOURCEDIR)/Natives/resources \
			--platform iphoneos \
			--minimum-deployment-target 14.0 \
			--app-icon AppIcon-Light \
			--output-partial-info-plist /dev/null || exit 1; \
	else \
		echo 'Due to the required tools not being available, you cannot compile the extras for Angel Aura Amethyst with an iOS device.'; \
	fi
	echo '[Amethyst v$(VERSION)] assets - end'

# shaderc / spirv-cross serializing shims (hs_err_pid27329: concurrent compiles
# from multiple contexts trampled glslang AST node memory). Real libs were
# renamed *_impl.dylib (git mv). This target:
#   1) copies the impls into WORKINGDIR and fixes their LC_ID with
#      install_name_tool (re-export must point at the impl name, not back at
#      the shim, or loading recurses forever);
#   2) builds same-name shims with -reexport_library (pass through ALL impl
#      symbols); the 3 shaderc compile entries and 2 heavy spvc entries are
#      defined by the shims with a process-global recursive mutex, so every
#      resolution path (hooked dlsym / RTLD_DEFAULT / any direct dlsym) lands
#      on the locking forwarders. Deadlock avoidance details in
#      Natives/shaderc_shim.c header comment.
dep_shader_shims: dep_mg
	echo '[Amethyst v$(VERSION)] dep_shader_shims - start'
	# Task 45: build libshaderc_impl.dylib FROM SOURCE - glue over the glslang C
	# interface (Natives/shaderc_impl_glue.c) linked against the SAME pinned
	# f5f664d static libs dep_mg just built (nullguard + pool-zero/size-guard
	# patches applied). Retires the prebuilt unpatched impl blob and the Task-34
	# machine-code cave patch (scripts/patch_shaderc_lvalue_guard.py stays
	# in-repo for archaeology). The 45-task crash family (constArray+0xd8
	# reading recycled source-text bytes, deterministic per-run / ASLR-luck
	# across runs, surviving every in-process mitigation) had exactly one
	# untested variable left - the impl binary itself; now the only glslang in
	# the process is the patched, freshly-built one. dep_mg ordering: this
	# target links dep_mg's outputs (parallel-make safety).
	# Task 46: resolve the glslang static libs from the superbuild layout
	# (<build>/3rdparty/glslang/...). Task 45 pointed at the
	# standalone-glslang layout (<build>/SPIRV/...), which this build never
	# produces - CI run 34105892191 died at "libSPIRV.a missing" after an
	# all-green compile. Primary: superbuild paths; fallback: locate by
	# archive name under the mobileglues build tree so future CMake layout
	# drift cannot break the link.
	mg_bindir=$(WORKINGDIR)/mobileglues/3rdparty/glslang; \
	mg_spirv_a=$$mg_bindir/SPIRV/libSPIRV.a; \
	[ -f "$$mg_spirv_a" ] || mg_spirv_a=$$(find $(WORKINGDIR)/mobileglues -type f -name libSPIRV.a -print -quit 2>/dev/null); \
	mg_glslang_a=$$mg_bindir/glslang/libglslang.a; \
	[ -f "$$mg_glslang_a" ] || mg_glslang_a=$$(find $(WORKINGDIR)/mobileglues -type f -name libglslang.a -print -quit 2>/dev/null); \
	mg_rl_a=$$mg_bindir/glslang/libglslang-default-resource-limits.a; \
	[ -f "$$mg_rl_a" ] || mg_rl_a=$$(find $(WORKINGDIR)/mobileglues -type f -name libglslang-default-resource-limits.a -print -quit 2>/dev/null); \
	if [ -z "$$mg_spirv_a" ] || [ ! -f "$$mg_spirv_a" ] || [ -z "$$mg_glslang_a" ] || [ ! -f "$$mg_glslang_a" ] || [ -z "$$mg_rl_a" ] || [ ! -f "$$mg_rl_a" ]; then \
		echo "ERROR: glslang static libs unresolved (spirv=$$mg_spirv_a glslang=$$mg_glslang_a rl=$$mg_rl_a) - from-source shaderc impl cannot link"; \
		exit 1; \
	fi; \
	extra_glslang_libs=""; \
	for l in libOGLCompiler.a libOSDependent.a; do \
		if [ -f "$$mg_bindir/glslang/$$l" ]; then \
			extra_glslang_libs="$$extra_glslang_libs $$mg_bindir/glslang/$$l"; \
		fi; \
	done; \
	echo "[shaderc-impl] linking from-source impl (spirv=$$mg_spirv_a glslang=$$mg_glslang_a rl=$$mg_rl_a extra libs:$$extra_glslang_libs)"; \
	xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
		-install_name @rpath/libshaderc_impl.dylib \
		-I$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/glslang \
		-o $(WORKINGDIR)/libshaderc_impl.dylib \
		$(SOURCEDIR)/Natives/shaderc_impl_glue.c \
		"$$mg_spirv_a" \
		"$$mg_glslang_a" \
		"$$mg_rl_a" \
		$$extra_glslang_libs \
		-lc++ || exit 1
	install_name_tool -id @rpath/libshaderc_impl.dylib $(WORKINGDIR)/libshaderc_impl.dylib || exit 1
	cp $(SOURCEDIR)/Natives/resources/Frameworks/libspirv-cross-c-shared.0.impl.dylib $(WORKINGDIR)/ || exit 1
	install_name_tool -id @rpath/libspirv-cross-c-shared.0.impl.dylib $(WORKINGDIR)/libspirv-cross-c-shared.0.impl.dylib || exit 1
	xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
		-install_name @rpath/libshaderc.dylib \
		-Wl,-reexport_library,$(WORKINGDIR)/libshaderc_impl.dylib \
		-o $(WORKINGDIR)/libshaderc.dylib \
		$(SOURCEDIR)/Natives/shaderc_shim.c \
		$(SOURCEDIR)/Natives/shaderc_include.c \
		$(SOURCEDIR)/Natives/shaderc_sandbox.m || exit 1
	xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
		-install_name @rpath/libspirv-cross-c-shared.0.dylib \
		-Wl,-reexport_library,$(WORKINGDIR)/libspirv-cross-c-shared.0.impl.dylib \
		-o $(WORKINGDIR)/libspirv-cross-c-shared.0.dylib \
		$(SOURCEDIR)/Natives/spvc_shim.c || exit 1
	echo '[Amethyst v$(VERSION)] dep_shader_shims - end'

dep_nggl4es: dep_mg
	echo '[Amethyst v$(VERSION)] dep_nggl4es - start'
	# Task206: NG-GL4ES ("Krypton Wrapper", BZLZHH/NG-GL4ES) -- the gl4es used
	# by ZalithLauncher 2, vendored at ThirdParty/ZalithLauncher2 (see its
	# CMakeLists PROVENANCE header). Built as its own cmake tree against the
	# dep_mg glslang statics (pinned f5f664d 15.0.0 + lvalue-nullguard +
	# pool-zero/size-guards -- inheriting the crash-family fixes; NG's vendored
	# 15.4 headers were removed so headers and libs cannot drift) and the
	# prebuilt SPIRV-Cross C API impl dylib (header verified byte-identical).
	# Output libnggl4es.dylib rides the payload "cp $(WORKINGDIR)/*.dylib".
	# Task206g（CI 36809835918）：双路径——3rdparty/ 让 <glslang/SPIRV/GlslangToSpv.h>
	# 落到源码树根的 SPIRV/；3rdparty/glslang 让 <glslang/Public|Include/...> 落到
	# glslang 子目录（NG 的 vendored 头是安装布局，源码树没有 glslang/SPIRV/）。
	# 注意：续行链中间不能有无反斜杠的注释行——# 会截止逻辑行（本轮 CI 教训）。
	mg_bindir=$(WORKINGDIR)/mobileglues/3rdparty/glslang; \
	mg_spirv_a=$$mg_bindir/SPIRV/libSPIRV.a; \
	[ -f "$$mg_spirv_a" ] || mg_spirv_a=$$(find $(WORKINGDIR)/mobileglues -type f -name libSPIRV.a -print -quit 2>/dev/null); \
	mg_glslang_a=$$mg_bindir/glslang/libglslang.a; \
	[ -f "$$mg_glslang_a" ] || mg_glslang_a=$$(find $(WORKINGDIR)/mobileglues -type f -name libglslang.a -print -quit 2>/dev/null); \
	mg_rl_a=$$mg_bindir/glslang/libglslang-default-resource-limits.a; \
	[ -f "$$mg_rl_a" ] || mg_rl_a=$$(find $(WORKINGDIR)/mobileglues -type f -name libglslang-default-resource-limits.a -print -quit 2>/dev/null); \
	if [ -z "$$mg_spirv_a" ] || [ ! -f "$$mg_spirv_a" ] || [ -z "$$mg_glslang_a" ] || [ ! -f "$$mg_glslang_a" ] || [ -z "$$mg_rl_a" ] || [ ! -f "$$mg_rl_a" ]; then \
		echo "ERROR: glslang static libs unresolved (spirv=$$mg_spirv_a glslang=$$mg_glslang_a rl=$$mg_rl_a) - dep_mg must run first"; \
		exit 1; \
	fi; \
	extra_glslang_libs=""; \
	for l in libOGLCompiler.a libOSDependent.a; do \
		if [ -f "$$mg_bindir/glslang/$$l" ]; then \
			extra_glslang_libs="$$extra_glslang_libs;$$mg_bindir/glslang/$$l"; \
		fi; \
	done; \
	ngg_libs="$$mg_spirv_a;$$mg_glslang_a;$$mg_rl_a$$extra_glslang_libs"; \
	echo "[nggl4es] linking against glslang statics: $$ngg_libs"; \
	mkdir -p $(WORKINGDIR)/nggl4es; \
	cd $(WORKINGDIR)/nggl4es && cmake \
		-DMACOS="1" \
		-DCMAKE_CROSSCOMPILING=true \
		-DCMAKE_SYSTEM_NAME=Darwin \
		-DCMAKE_SYSTEM_PROCESSOR=aarch64 \
		-DCMAKE_OSX_SYSROOT="$(SDKPATH)" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
		-DCMAKE_C_FLAGS="-arch arm64" \
		-DCMAKE_BUILD_TYPE=RelWithDebInfo \
		-DNGGL4ES_GLSLANG_INCLUDE="$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty;$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/glslang" \
		-DNGGL4ES_GLSLANG_LIBS="$$ngg_libs" \
		-DNGGL4ES_SPVC_IMPL="$(SOURCEDIR)/Natives/resources/Frameworks/libspirv-cross-c-shared.0.impl.dylib" \
		-DNGGL4ES_FRAMEWORK_DIR="$(SOURCEDIR)/Natives/resources/Frameworks" \
		$(SOURCEDIR)/ThirdParty/ZalithLauncher2/ || exit 1
	cmake --build $(WORKINGDIR)/nggl4es --config RelWithDebInfo -j$(JOBS) --target nggl4es || exit 1
	cp $(WORKINGDIR)/nggl4es/libnggl4es.dylib $(WORKINGDIR)/ || exit 1
	echo '[Amethyst v$(VERSION)] dep_nggl4es - end'

dep_gl4eszl2:
	echo '[Amethyst v$(VERSION)] dep_gl4eszl2 - start'
	# Task211: ZL2 CLASSIC gl4es (PojavLauncherTeam/gl4es_extra_extra,
	# ZL2's legacy renderer 'gl4es', prebuilt by ZL2 as libgl4es_114.so)
	# -- vendored at ThirdParty/gl4es_extra_extra (see its CMakeLists
	# PROVENANCE header). Pure C: the classic converter is the string-
	# rewriting shaderconv.c, NO glslang / NO SPIRV-Cross, so this target
	# is STANDALONE (no dep_mg ordering, cannot race the glslang statics).
	# Output libgl4eszl2.dylib rides the payload "cp $(WORKINGDIR)/*.dylib".
	mkdir -p $(WORKINGDIR)/gl4eszl2; \
	cd $(WORKINGDIR)/gl4eszl2 && cmake \
	-DMACOS="1" \
	-DCMAKE_CROSSCOMPILING=true \
	-DCMAKE_SYSTEM_NAME=Darwin \
	-DCMAKE_SYSTEM_PROCESSOR=aarch64 \
	-DCMAKE_OSX_SYSROOT="$(SDKPATH)" \
	-DCMAKE_OSX_ARCHITECTURES=arm64 \
	-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
	-DCMAKE_C_FLAGS="-arch arm64" \
	-DCMAKE_BUILD_TYPE=RelWithDebInfo \
	-DGL4ESZL2_FRAMEWORK_DIR="$(SOURCEDIR)/Natives/resources/Frameworks" \
	$(SOURCEDIR)/ThirdParty/gl4es_extra_extra/ || exit 1
	cmake --build $(WORKINGDIR)/gl4eszl2 --config RelWithDebInfo -j$(JOBS) --target gl4eszl2 || exit 1
	cp $(WORKINGDIR)/gl4eszl2/libgl4eszl2.dylib $(WORKINGDIR)/ || exit 1
	echo '[Amethyst v$(VERSION)] dep_gl4eszl2 - end'

# Task 215: VirGLRenderer(≤26.2)（ZL2 移植，Task212 预留 stage 2 的落地）三件套：
#  1. libepoxy          —— vendored Natives/external/libepoxy（iOS 补丁：dlopen 指向 ANGLE 框架）
#  2. libvtestserver.dylib —— vendored virglrenderer 1.3.0（vtest server + vrend，静态链 epoxy；
#     上游 vtest_server.c 本身导出 vtest_main，vtest_main.c 的 main 不参与链接）
#  3. libOSMesaVirgl.dylib —— Mesa 25.0.7（下载 tar.xz + patches/mesa-215-osmesa-virgl.patch，
#     virgl 驱动 + softpipe 回退，osmesa 前端导出全量 gl*；GALLIUM_DRIVER=virgl 经
#     VTEST_SOCKET_NAME 连接进程内 vtest server）
# 快路径：三个 dylib 已 commit-back 到 Frameworks 时跳过整链构建；
# 任一环节失败不阻断主构建：渲染器表按 dylib 存在性自动隐藏该选项。
# Task216 hotfix 3（run 602/603 实锤兑现上述承诺）：dep_virgl 原实现把 meson 链的 || exit 1 直接暴露给 payload，链上任何一环失败（当前 = CI mac runner 的 meson 交叉工具探测：pkg-config/build-machine compiler/Apple ld 不认 --version）都拖死整个主构建，与设计注释矛盾。改为包装层：dep_virgl_build 全链失败只告警放行（VirGL 项隐藏，装机可辨），meson 链本身的修复留给独立轮次不受主构建节奏裹挟。
VIRGL_MESA_VERSION ?= 25.0.7
# Task217 hotfix 2（run 609）：CI 构建步骤的步骤级 env
# IPHONEOS_DEPLOYMENT_TARGET=14.0 会污染 meson 的 build 机探测——裸 clang
# （native file 钉的 build 机编译器）编出的 sanity 二进制以 iOS 为平台
# 目标（sysroot 仍是 MacOSX，-Wincompatible-sysroot 告警），exec 即
# SIGKILL（run 609 meson-log: sanity -> -9 -> "Compiler for language c
# for the build machine not found"）。三处 meson setup 前剥部署目标类 env；
# host（cross）侧不受影响——c_args/c_link_args 显式携带 min-version。
VIRGL_ENV_CLEAN = env -u IPHONEOS_DEPLOYMENT_TARGET -u MACOSX_DEPLOYMENT_TARGET -u TVOS_DEPLOYMENT_TARGET -u WATCHOS_DEPLOYMENT_TARGET -u XROS_DEPLOYMENT_TARGET -u SDKROOT
dep_virgl:
	@$(MAKE) --no-print-directory dep_virgl_build \
		|| echo '[Amethyst v$(VERSION)] dep_virgl - build failed; VirGL renderer entry hidden (graceful degradation by design)'
# Task217 热修 5（run 612）：libvtestserver.dylib 链接语义——-force_load 双
# 静态库撞出 4 份 u_format_table（virglrenderer 的多个内部 target 各自编译
# 了生成的格式表；ld: duplicate symbol '_util_format_description'）。改用
# -u _vtest_main 作种子走常规归档拉链：按需拉入 vtest_main 的依赖闭包，
# 重复定义的表成员休眠不拉；libvtest.a 排前（其表拷贝优先满足引用）。本行
# 为 make 级注释（列首无 TAB），TAB 基线不动（662 被 7 个验证器锚定）。
# Task217 热修 9（run 616）：mesa 904/904 全编译后，最终 osmesa 链接死于
# brew 的 macOS 版 libzstd.dylib（cross [binaries] 的 pkg-config 解析到
# /opt/homebrew；其余 -lexpat -lz 均来自 iPhoneOS SDK）。-Dzstd=disabled
# 剥除该依赖——zstd 仅用于磁盘缓存压缩，进程内渲染零功能损失。

dep_virgl_build:
	@if [ -f "$(SOURCEDIR)/Natives/resources/Frameworks/libOSMesaVirgl.dylib" ] && \
	    [ -f "$(SOURCEDIR)/Natives/resources/Frameworks/libvtestserver.dylib" ] && \
	    [ -f "$(SOURCEDIR)/Natives/resources/Frameworks/libepoxy.dylib" ]; then \
		echo '[Amethyst v$(VERSION)] dep_virgl - cached (Frameworks prebuilts present)'; \
		cp $(SOURCEDIR)/Natives/resources/Frameworks/libOSMesaVirgl.dylib \
		   $(SOURCEDIR)/Natives/resources/Frameworks/libvtestserver.dylib \
		   $(SOURCEDIR)/Natives/resources/Frameworks/libepoxy.dylib $(WORKINGDIR)/; \
		exit 0; \
	fi
	echo '[Amethyst v$(VERSION)] dep_virgl - start'
	# ---- 0. meson 交叉文件（本地生成，SDK 路径随机器变化）----
	printf '%s\n' \
		'[binaries]' \
		"c = 'clang'" \
		"cpp = 'clang++'" "objc = 'clang'" \
		"ar = 'ar'" \
		"strip = 'strip'" \
		"pkg-config = 'pkg-config'" \
		'' \
		'[properties]' \
		"c_args = ['-arch','arm64','-miphoneos-version-min=14.0','-fno-common','-isysroot','$(SDKPATH)','-I$(SOURCEDIR)/Natives/external/mesa']" \
		"cpp_args = ['-arch','arm64','-miphoneos-version-min=14.0','-fno-common','-isysroot','$(SDKPATH)','-I$(SOURCEDIR)/Natives/external/mesa']" "objc_args = ['-arch','arm64','-miphoneos-version-min=14.0','-fno-common','-isysroot','$(SDKPATH)','-I$(SOURCEDIR)/Natives/external/mesa']" \
		"c_link_args = ['-arch','arm64','-miphoneos-version-min=14.0','-isysroot','$(SDKPATH)']" \
		"cpp_link_args = ['-arch','arm64','-miphoneos-version-min=14.0','-isysroot','$(SDKPATH)']" "objc_link_args = ['-arch','arm64','-miphoneos-version-min=14.0','-isysroot','$(SDKPATH)']" \
		'' \
		'[host_machine]' \
		"system = 'darwin'" \
		"cpu_family = 'aarch64'" \
		"cpu = 'aarch64'" \
		"endian = 'little'" \
		> $(WORKINGDIR)/virgl-cross.txt
	# ---- 0b. Task217：native file（build 机编译器钉死裸 clang）----
	# CI 主构建步骤导出 CC="ccache clang"（Task205 ccache 接线），meson 交叉
	# 构建时会把环境 CC 当作 build 机编译器参与探测——包装器掺和探测链是
	# run 602/603 三连错的家族根源（"Compiler for language c for the build
	# machine not found" / Apple ld 对 --version 的探测异常 / pkg-config for
	# host machine not found）。--native-file 显式声明 build 机工具后，环境
	# 变量被完全绕开；cross [binaries] 补 pkg-config 消掉第三连错。
	printf '%s\n' \
		'[binaries]' \
		"c = 'clang'" \
		"cpp = 'clang++'" "objc = 'clang'" \
		> $(WORKINGDIR)/virgl-native.txt
	# ---- 1. libepoxy（静态，装进 libvtestserver.dylib）----
	rm -rf $(WORKINGDIR)/virgl-epoxy $(WORKINGDIR)/virgl-prefix
	$(VIRGL_ENV_CLEAN) meson setup $(WORKINGDIR)/virgl-epoxy $(SOURCEDIR)/Natives/external/libepoxy \
		--cross-file $(WORKINGDIR)/virgl-cross.txt \
		--native-file $(WORKINGDIR)/virgl-native.txt \
		-Dglx=no -Degl=yes -Dx11=false -Dtests=false \
		-Ddefault_library=static --prefix=$(WORKINGDIR)/virgl-prefix || exit 1
	ninja -C $(WORKINGDIR)/virgl-epoxy install || exit 1
	test -f $(WORKINGDIR)/virgl-prefix/lib/libepoxy.a || { echo 'ERROR: libepoxy.a missing'; exit 1; }
	# ---- 2. virglrenderer（静态 + 链接 libvtestserver.dylib）----
	rm -rf $(WORKINGDIR)/virgl-renderer
	PKG_CONFIG_PATH=$(WORKINGDIR)/virgl-prefix/lib/pkgconfig \
	$(VIRGL_ENV_CLEAN) meson setup $(WORKINGDIR)/virgl-renderer $(SOURCEDIR)/Natives/external/virglrenderer \
		--cross-file $(WORKINGDIR)/virgl-cross.txt \
		--native-file $(WORKINGDIR)/virgl-native.txt \
		-Dplatforms=egl -Dvenus=false -Dvulkan-dload=false -Dtests=false \
		-Ddefault_library=static || exit 1
	ninja -C $(WORKINGDIR)/virgl-renderer || exit 1
	test -f $(WORKINGDIR)/virgl-renderer/vtest/libvtest.a || { echo 'ERROR: libvtest.a missing'; exit 1; }
	test -f $(WORKINGDIR)/virgl-renderer/src/libvirglrenderer.a || { echo 'ERROR: libvirglrenderer.a missing'; exit 1; }
	xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
		-install_name @rpath/libvtestserver.dylib \
		-o $(WORKINGDIR)/libvtestserver.dylib \
		-Wl,-u,_vtest_main $(WORKINGDIR)/virgl-renderer/vtest/libvtest.a \
		$(WORKINGDIR)/virgl-renderer/src/libvirglrenderer.a \
		$(WORKINGDIR)/virgl-prefix/lib/libepoxy.a \
		-lc++ || exit 1
	install_name_tool -id @rpath/libvtestserver.dylib $(WORKINGDIR)/libvtestserver.dylib || exit 1
	# ---- 3. Mesa virgl guest（下载 + 补丁 + 构建）----
	mkdir -p $(SOURCEDIR)/depends/virgl
	cd $(SOURCEDIR)/depends/virgl; \
		if [ ! -f mesa-$(VIRGL_MESA_VERSION)/src/gallium/targets/osmesa/.task215_patched ]; then \
			wget_ok=0; \
			for attempt in 1 2 3 4 5; do \
				if wget "https://archive.mesa3d.org/mesa-$(VIRGL_MESA_VERSION).tar.xz" --timeout=90 --tries=2 --retry-connrefused -O mesa-$(VIRGL_MESA_VERSION).tar.xz; then wget_ok=1; break; fi; \
				echo '[virgl] mesa download failed (attempt '$$attempt'/5), retry in 15s'; sleep 15; \
			done; \
			[ "$$wget_ok" = "1" ] || { echo '[virgl] FATAL: mesa download failed'; exit 1; }; \
			rm -rf mesa-$(VIRGL_MESA_VERSION) && tar xf mesa-$(VIRGL_MESA_VERSION).tar.xz; \
			( cd mesa-$(VIRGL_MESA_VERSION) && patch -p1 < $(SOURCEDIR)/patches/mesa-215-osmesa-virgl.patch \
			  && touch src/gallium/targets/osmesa/.task215_patched ) || exit 1; \
		fi
	test -f $(SOURCEDIR)/depends/virgl/mesa-$(VIRGL_MESA_VERSION)/src/gallium/targets/osmesa/.task215_patched || { echo 'ERROR: mesa patch not applied'; exit 1; }
	rm -rf $(WORKINGDIR)/virgl-mesa
	cd $(SOURCEDIR)/depends/virgl/mesa-$(VIRGL_MESA_VERSION) && $(VIRGL_ENV_CLEAN) meson setup $(WORKINGDIR)/virgl-mesa \
		--cross-file $(WORKINGDIR)/virgl-cross.txt \
		--native-file $(WORKINGDIR)/virgl-native.txt \
		-Dgallium-drivers=virgl,softpipe -Dvulkan-drivers=[] \
		-Dosmesa=true -Dllvm=disabled -Dglx=disabled -Degl=disabled -Dgbm=disabled \
		-Dplatforms=[] -Dshared-glapi=disabled -Dvideo-codecs=[] -Dzstd=disabled \
		-Dbuild-tests=false -Dtools=[] || exit 1
	ninja -C $(WORKINGDIR)/virgl-mesa || exit 1
	test -f $(WORKINGDIR)/virgl-mesa/src/gallium/targets/osmesa/libOSMesa.8.dylib || { echo 'ERROR: libOSMesa.8.dylib (virgl guest) missing'; exit 1; }
	cp $(WORKINGDIR)/virgl-mesa/src/gallium/targets/osmesa/libOSMesa.8.dylib $(WORKINGDIR)/libOSMesaVirgl.dylib
	install_name_tool -id @rpath/libOSMesaVirgl.dylib $(WORKINGDIR)/libOSMesaVirgl.dylib || exit 1
	echo '[Amethyst v$(VERSION)] dep_virgl - end'

dep_angle_freeze:
	echo '[Amethyst v$(VERSION)] dep_angle_freeze - start'
	# Task 57 (hua-mian-fen-lie gen-zhi): 8-byte machine-code patch -- ANGLE Metal
	# WindowSurfaceMtl::checkIfLayerResized: expected size source switched from
	# bounds*contentsScale (poisoned by windowed-mode background-thread portrait
	# geometry, CALayer cross-thread split-brain) to the surface's own latched
	# mWidth/mHeight ([x19,#0x430/0x438]) -- surface size frozen at creation
	# geometry (creation reads always clean); transposition becomes physically
	# impossible; on drawableSize drift the enforcement branch re-writes the
	# frozen value back onto the layer. Idempotent; loud failure on byte
	# mismatch (ANGLE version drift guard); full root-cause chain in script
	# header comments (scripts/patch_angle_surface_freeze.py).
	python3 $(SOURCEDIR)/scripts/patch_angle_surface_freeze.py \
		$(SOURCEDIR)/Natives/resources/Frameworks/libGLESv2.framework/libGLESv2 || exit 1
	echo '[Amethyst v$(VERSION)] dep_angle_freeze - end'

dep_sdl3_guard:
	echo '[Amethyst v$(VERSION)] dep_sdl3_guard - start'
	# Task 135 (26.1.2 controlify/JNA closure SIGBUS 源头根治): libSDL3.dylib
	# 入口机器码守卫 -- SDL_SetEventFilter / SDL_AddEventWatch 的非空回调指针
	# 一律置空/拒绝注册。controlify 3.0.1 经 JNA 回退加载本 Frameworks 的 iOS
	# 版 SDL3 后,把 JNA/libffi closure (RW 不可执行 trampoline 页) 注册进 SDL
	# 事件过滤器, SDL 调用即 SIGBUS。Task131 的 dlsym 层守卫对 LWJGL/FFM 解析
	# 路径有效 (26.2 会话实证), 但 JNA 解析路径仍可绕行 (26.1.2 会话零守卫日志);
	# 本补丁把守卫下沉到 SDL 二进制自身, 与符号解析链路完全无关。启动器自身与
	# MC/LWJGL 均不使用 SDL 事件过滤器 (全仓 grep 验证), 零误伤; 签名由打包时
	# ldid -S 全 app 重签覆盖 (dep_angle_freeze 同款流程)。幂等; 字节不匹配
	# (SDL3 版本漂移) 响亮失败。补丁工艺与字节推导见脚本头注释。
	python3 $(SOURCEDIR)/scripts/patch_sdl3_eventfilter_guard.py \
		$(SOURCEDIR)/Natives/resources/Frameworks/libSDL3.dylib || exit 1
	echo '[Amethyst v$(VERSION)] dep_sdl3_guard - end'

payload: native dep_mg java jre assets dep_shader_shims dep_openal_shim dep_mithril_glshim dep_nggl4es dep_gl4eszl2 dep_virgl dep_angle_freeze dep_sdl3_guard
	echo '[Amethyst v$(VERSION)] payload - start'
	$(call METHOD_DIRCHECK,$(WORKINGDIR)/AngelAuraAmethyst.app/libs)
	$(call METHOD_DIRCHECK,$(WORKINGDIR)/AngelAuraAmethyst.app/libs_caciocavallo)
	$(call METHOD_DIRCHECK,$(WORKINGDIR)/AngelAuraAmethyst.app/libs_caciocavallo17)
	cp -R $(SOURCEDIR)/Natives/resources/en.lproj/LaunchScreen.storyboardc $(WORKINGDIR)/AngelAuraAmethyst.app/Base.lproj/ || exit 1
	cp -R $(SOURCEDIR)/Natives/resources/* $(WORKINGDIR)/AngelAuraAmethyst.app/ || exit 1
	# Task192：gl4es EGL 解析根修（4 字节二进制补丁）——proc_address 回退
	# dlsym(RTLD_NEXT) 在 iOS 加载序下永远找不到先于 gl4es 加载的
	# libEGL/libGLESv2 框架（它们是 gl4es 的依赖，加载在它之前）→ 构造器
	# 内 egl_* 全 NULL → 调 NULL → SIGSEGV pc=0（956ea9b 装机 latestlog.old）。
	# 改为 RTLD_DEFAULT（全局作用域可见这些框架）。补丁幂等 + 指纹防漂移。
	# Task202——gl4es 构造器崩溃免疫：GetHardwareExtensions 的 glGetString(GL_EXTENSIONS) 无上下文时返回 NULL，
	# 首个 strstr(NULL) 峻 SIGSEGV（e4d704e 装机 latestlog.1 反盘；垫片把 NULL 换成空串，构造器完整跑完）
	# Task212：holy gl4es（libgl4es_114.dylib）退役删除——Task192 的 RTLD_DEFAULT
	# 补丁与 Task202 的 ggstr NULL 守卫两个二进制手术随 dylib 一并移除：接棒者
	# ZL2 经典版 gl4es（libgl4eszl2.dylib，dep_gl4eszl2 目标）从源码构建，
	# 构建期即带 Task208 三件套，无需任何 post-build 二进制补丁。
	cp $(WORKINGDIR)/*.dylib $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/ || exit 1
	# spirv-cross 软链接（防御性兜底）：若 MobileGlues 构建产出 libspirv-cross-c-shared.0.dylib，
	# 创建 libspirv-cross.dylib 软链接，兼容按 macOS 默认名加载的 native 代码。
	if [ -f "$(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/libspirv-cross-c-shared.0.dylib" ] && [ ! -f "$(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/libspirv-cross.dylib" ]; then \
		ln -sf libspirv-cross-c-shared.0.dylib $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/libspirv-cross.dylib; \
	fi
		cp -R $(SOURCEDIR)/JavaApp/libs/others/* $(WORKINGDIR)/AngelAuraAmethyst.app/libs/ || exit 1
	cp $(SOURCEDIR)/JavaApp/build/launcher.jar $(SOURCEDIR)/JavaApp/build/patchjna_agent.jar $(SOURCEDIR)/JavaApp/build/patchsvc.jar $(SOURCEDIR)/JavaApp/build/mojang-stubs.jar $(WORKINGDIR)/AngelAuraAmethyst.app/libs/ || exit 1
	# LWJGL 以双版本 jar 发布，由启动器按 MC 版本在运行时选择其一（26.x+ -> 341，其余 -> 333）。
	# 必须放进各自的 libs/lwjgl-<ver>/ 子目录：若平铺进 libs/，会被 classpath 中的 libs/*
	# 一并加载，使 3.3.3 与 3.4.1 的同名类同时进入 classpath 造成冲突。lwjgl.jar 是占位
	# 产物，不进 app 的 libs 目录。
	mkdir -p $(WORKINGDIR)/AngelAuraAmethyst.app/libs/lwjgl-333 $(WORKINGDIR)/AngelAuraAmethyst.app/libs/lwjgl-341; \
	cp $(SOURCEDIR)/JavaApp/build/lwjgl-333.jar $(WORKINGDIR)/AngelAuraAmethyst.app/libs/lwjgl-333/lwjgl.jar || exit 1
	cp $(SOURCEDIR)/JavaApp/build/lwjgl-341.jar $(WORKINGDIR)/AngelAuraAmethyst.app/libs/lwjgl-341/lwjgl.jar || exit 1
	cp -R $(SOURCEDIR)/JavaApp/libs/caciocavallo/* $(WORKINGDIR)/AngelAuraAmethyst.app/libs_caciocavallo || exit 1
	cp -R $(SOURCEDIR)/JavaApp/libs/caciocavallo17/* $(WORKINGDIR)/AngelAuraAmethyst.app/libs_caciocavallo17 || exit 1
	# Copy TouchController static library if available
	if [ -f "$(SOURCEDIR)/TouchController/libproxy_server_ios.a" ]; then \
		mkdir -p $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks; \
		cp $(SOURCEDIR)/TouchController/libproxy_server_ios.a $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/ || exit 1; \
		echo '[Amethyst v$(VERSION)] Copied TouchController device library'; \
	elif [ -f "$(SOURCEDIR)/TouchController/libproxy_server_ios_simulator.a" ]; then \
		mkdir -p $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks; \
		cp $(SOURCEDIR)/TouchController/libproxy_server_ios_simulator.a $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/ || exit 1; \
		echo '[Amethyst v$(VERSION)] Copied TouchController simulator library'; \
	else \
		echo '[Amethyst v$(VERSION)] TouchController library not found, skipping'; \
	fi
	$(call METHOD_DIRCHECK,$(OUTPUTDIR)/Payload)
	cp -R $(WORKINGDIR)/AngelAuraAmethyst.app $(OUTPUTDIR)/Payload
	if [ '$(SLIMMED_ONLY)' != '1' ]; then \
		cp -R $(OUTPUTDIR)/java_runtimes $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app; \
	fi
	ldid -S $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app; \
	if [ '$(TROLLSTORE_JIT_ENT)' == '1' ]; then \
		ldid -S$(SOURCEDIR)/entitlements.trollstore.xml $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/AngelAuraAmethyst; \
	elif [ '$(PLATFORM)' == '6' ]; then \
		ldid -S$(SOURCEDIR)/entitlements.codesign.xml $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/AngelAuraAmethyst; \
	else \
		ldid -S$(SOURCEDIR)/entitlements.sideload.xml $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/AngelAuraAmethyst; \
	fi
	chmod -R 755 $(OUTPUTDIR)/Payload
	# 总是运行平台重打标（对齐 Ynnyny 仓库）—— 对已 iOS 标记的 Mach-O 是幂等的，
	# 但能捕获从 Maven 直接拉取的新 dylib（如 3.3.5 lwjgl-stb），它们 ship 时
	# platform=macos，iOS dyld 会静默拒绝加载，导致 LWJGL 抛 UnsatisfiedLinkError。
	# 原本用 [ PLATFORM != 2 ] 守卫的假设是所有 commit 的 dylib 都已 iOS 标记，
	# 这个假设在同步 Ynnyny 顶层 dylib 时被打破。
	$(call METHOD_MACHO,$(OUTPUTDIR)/Payload/AngelAuraAmethyst.app,$(call METHOD_CHANGE_PLAT,$(PLATFORM),$$file)); \
	$(call METHOD_MACHO,$(OUTPUTDIR)/java_runtimes,$(call METHOD_CHANGE_PLAT,$(PLATFORM),$$file));
	echo '[Amethyst v$(VERSION)] payload - end'

deploy:
	echo '[Amethyst v$(VERSION)] deploy - start'
	cd $(OUTPUTDIR); \
	if [ '$(IOS)' = '1' ]; then \
		ldid -S $(WORKINGDIR)/AngelAuraAmethyst.app || exit 1; \
		ldid -S$(SOURCEDIR)/entitlements.trollstore.xml $(WORKINGDIR)/AngelAuraAmethyst.app/AngelAuraAmethyst || exit 1; \
		sudo mv $(WORKINGDIR)/*.dylib $(PREFIX)Applications/AngelAuraAmethyst.app/Frameworks/ || exit 1; \
		sudo mv $(WORKINGDIR)/AngelAuraAmethyst.app/AngelAuraAmethyst $(PREFIX)Applications/AngelAuraAmethyst.app/AngelAuraAmethyst || exit 1; \
		sudo mkdir -p $(PREFIX)Applications/AngelAuraAmethyst.app/libs/lwjgl-333 $(PREFIX)Applications/AngelAuraAmethyst.app/libs/lwjgl-341 || exit 1; \
		sudo mv $(SOURCEDIR)/JavaApp/build/launcher.jar $(SOURCEDIR)/JavaApp/build/patchjna_agent.jar $(SOURCEDIR)/JavaApp/build/patchsvc.jar $(PREFIX)Applications/AngelAuraAmethyst.app/libs/ || exit 1; \
		sudo mv $(SOURCEDIR)/JavaApp/build/lwjgl-333.jar $(PREFIX)Applications/AngelAuraAmethyst.app/libs/lwjgl-333/lwjgl.jar || exit 1; \
		sudo mv $(SOURCEDIR)/JavaApp/build/lwjgl-341.jar $(PREFIX)Applications/AngelAuraAmethyst.app/libs/lwjgl-341/lwjgl.jar || exit 1; \
		cd $(PREFIX)Applications/AngelAuraAmethyst.app/Frameworks || exit 1; \
		sudo chown -R 501:501 $(PREFIX)Applications/AngelAuraAmethyst.app/* || exit 1; \
	elif [ '$(IOS)' = '0' ] && [ '$(DETECTPLAT)' = 'Darwin' ]; then \
		if [ '$(PLATFORM)' != '2' ] || [ '$(TEAMID)' = '-1' ] || [ '$(SIGNING_TEAMID)' = '-1' ] || [ '$(PROVISIONING)' = '-1' ]; then \
			echo 'Configuration not supported for deploy recipe.'; \
		else \
			$(call METHOD_PACKAGE); \
			if [ '$(SLIMMED_ONLY)' = '0' ]; then \
				open $(OUTPUTDIR)/com.air-devs.air-$(VERSION)-$(PLATFORM_NAME).ipa; \
			else \
				open $(OUTPUTDIR)/com.air-devs.air.slimmed-$(VERSION)-$(PLATFORM_NAME).ipa; \
			fi; \
		fi; \
	else \
		echo 'Device not supported for deploy recipe.'; \
	fi
	echo '[Amethyst v$(VERSION)] deploy - end'

package: payload
	echo '[Amethyst v$(VERSION)] package - start'
	if [ '$(TEAMID)' != '-1' ] && [ '$(SIGNING_TEAMID)' != '-1' ] && [ -f '$(PROVISIONING)' ] && [ '$(DETECTPLAT)' = 'Darwin' ]; then \
		printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n	<key>application-identifier</key>\n	<string>$(TEAMID).com.air-devs.air</string>\n	<key>com.apple.developer.team-identifier</key>\n	<string>$(TEAMID)</string>\n	<key>get-task-allow</key>\n	<true/>\n	<key>keychain-access-groups</key>\n	<array>\n	<string>$(TEAMID).*</string>\n	<string>com.apple.token</string>\n	</array>\n	<key>com.apple.developer.kernel.extended-virtual-addressing</key>\n	<true/>\n	<key>com.apple.developer.kernel.increased-memory-limit</key>\n	<true/>\n</dict>\n</plist>' > entitlements.codesign.xml; \
		$(MAKE) codesign; \
		rm -rf entitlements.codesign.xml; \
	else \
		echo 'Skipped codesigning. If not intentional, check your variables.'; \
	fi
	cd $(OUTPUTDIR); \
	$(call METHOD_PACKAGE); \
	zip --symlinks -r $(OUTPUTDIR)/java_runtimes.zip java_runtimes; \
	echo '[Amethyst v$(VERSION)] package - end'

dsym: payload
	echo '[Amethyst v$(VERSION)] dsym - start'
	dsymutil --arch arm64 $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/AngelAuraAmethyst; \
	rm -rf $(OUTPUTDIR)/AngelAuraAmethyst.dSYM; \
	mv $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/AngelAuraAmethyst.dSYM $(OUTPUTDIR)/AngelAuraAmethyst.dSYM
	echo '[Amethyst v$(VERSION)] dsym - end'
	
codesign:
	echo '[Amethyst v$(VERSION)] codesign - start'
	cp '$(PROVISIONING)' $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/embedded.mobileprovision
	$(call METHOD_MACHO,$(OUTPUTDIR)/Payload/AngelAuraAmethyst.app,$(call METHOD_CODESIGN,$(SIGNING_TEAMID),$$file))
	$(call METHOD_MACHO,$(OUTPUTDIR)/java_runtimes,$(call METHOD_CODESIGN,$(SIGNING_TEAMID),$$file))
	echo '[Amethyst v$(VERSION)] codesign - end'

clean:
	echo '[Amethyst v$(VERSION)] clean - start'
	rm -rf $(WORKINGDIR)
	rm -rf JavaApp/build
	rm -rf $(OUTPUTDIR)
	echo '[Amethyst v$(VERSION)] clean - end'

.PHONY: all clean check native java jre package dsym deploy help dep_virgl
