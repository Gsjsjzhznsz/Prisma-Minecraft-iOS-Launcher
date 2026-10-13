# Prerequisite variables
SOURCEDIR := src
OUTPUTDIR := build

SOURCES := $(shell find $(SOURCEDIR) -type f -name '*.java')
CLASSES := $(SOURCES:$(SOURCEDIR)/%.java=$(OUTPUTDIR)/%.class)

TARGETS := $(shell find $(SOURCEDIR) -mindepth 1 -maxdepth 1 -type d)
TARGETS := $(TARGETS:$(SOURCEDIR)/%=$(OUTPUTDIR)/%.jar)

# Add all jars to classpath and allow compiling with private API
# 编译期 classpath 顺序说明：$(wildcard libs/*/*.jar) 按字典序展开，
# libs/lwjgl < libs/lwjgl-333 < libs/lwjgl-341，因此老版 Amethyst 预编译 jar
# （含 GLFW.mGLFWWindowWidth 等扩展 API 表面）会排在版本化集合之前。
# 参考仓库显式列出各目录是为了固定该顺序，此处 wildcard 的字典序已等价满足。
# 运行时只使用 lwjgl-333.jar / lwjgl-341.jar，不依赖 libs/lwjgl。
JCFLAGS := -cp "$(subst $() $(),:,$(wildcard $(SOURCEDIR)/*/):$(wildcard libs/*/*.jar))" -XDignore.symbol.file

all: $(TARGETS) $(OUTPUTDIR)/mojang-stubs.jar

# Sometimes the CI produces empty class file resulting in broken jar, so we check and abort here
# 改进：发现空 class 文件时先从 classes/ 目录重新复制（修复 cp 与 javac 并行竞态
# 导致次级 class 文件如 NarratorDummy.class 为空的偶发问题），重试后仍为空才报错。
check_empty_classes:
	@set -e
	@echo "Checking for empty class files"
	@for f in $$(find $(OUTPUTDIR) -not -path '$(OUTPUTDIR)/classes/*' -name '*.class' -size 0 2>/dev/null); do \
		rel=$${f#$(OUTPUTDIR)/}; \
		module=$$(echo "$$rel" | cut -d/ -f1); \
		classpath=$${rel#$$module/}; \
		src="$(OUTPUTDIR)/classes/$$classpath"; \
		if [ -f "$$src" ] && [ -s "$$src" ]; then \
			echo "Warning: re-copying empty $$classpath from classes/"; \
			cp -f "$$src" "$$f"; \
		fi; \
	done
	@EMPTY_CLASSES=$$(find $(OUTPUTDIR) -not -path '$(OUTPUTDIR)/classes/*' -name '*.class' -size 0 2>/dev/null); \
	if [ -n "$$EMPTY_CLASSES" ]; then \
		echo "Error: found empty class files in $@: $$EMPTY_CLASSES"; \
		exit 1; \
	fi

# Rules for building java class
$(CLASSES): $(OUTPUTDIR)/%.class: $(SOURCEDIR)/%.java
	@set -e
	$(eval TARGET=$(word 2, $(subst /, ,$@)))
	@mkdir -p $(OUTPUTDIR)/classes
	@mkdir -p $(dir $@)
	@echo "Compiling $<"
	@$(BOOTJDK)/javac $(JCFLAGS) -d $(OUTPUTDIR)/classes $<
	@cp $(@:$(OUTPUTDIR)/$(TARGET)/%.class=$(OUTPUTDIR)/classes/%*.class) $(dir $@)/
	@# 防御性校验：CI 偶发产生空 class 文件（cp 与 javac/并行任务竞态），
	@# 复制后若主 class 仍为 0 字节则重试一次，避免 check_empty_classes 误报中断构建。
	@if [ -e "$@" ] && [ ! -s "$@" ]; then \
		echo "Warning: $@ is empty after cp, retrying copy"; \
		cp -f $(@:$(OUTPUTDIR)/$(TARGET)/%.class=$(OUTPUTDIR)/classes/%*.class) $(dir $@)/; \
	fi

$(OUTPUTDIR)/launcher.jar: $(CLASSES) check_empty_classes
	@set -e
	@echo "Creating $@"
	@cp -r $(SOURCEDIR)/launcher/META-INF $(basename $@)/ 2>/dev/null || true
	# Task191（Forge 26.1.2 崩溃根修）：launcher.jar 剔除 com/mojang/text2speech。
	# 病历（dde0f82 装机 latestlog.txt，Forge-26.1.2-64.1.3 会话）：
	#   java.lang.module.ResolutionException: Modules mojang.stubs and
	#   launcher export package com.mojang.text2speech to module logging
	# 机制：Forge 26.1.2 的 bootstrap 2.1.7（net.minecraftforge.bootstrap）
	# 在模块解析时把 launcher.jar 与 mojang-stubs.jar 一并模块化（自动
	# 模块名 launcher / mojang.stubs），两 jar 均含 com/mojang/text2speech
	# → 双供应商 split-package，模块图解析当场失败（exit(1)，swapOK=0）。
	# 1.20.1 时代不踩坑是因旧 bootstrap 遵守 -DignoreList（Task154 的
	# launcher.jar 排除仍生效）；26.1.2 行为已变，包必须全局唯一。
	# 归属决策：mojang-stubs.jar 是唯一持有者——模块层（GameNarrator 的
	# MC-BOOTSTRAP 桩，Task158）与系统类加载器（classpath 上它排在
	# launcher.jar 之前，first-wins）都由它满足；launcher 主代码对该包
	# 零引用（grep 实证，仅 Tools.java 的库名过滤字符串）。
	# 实现注意：打 jar 前把目录移走、打完恢复——mojang-stubs.jar 规则
	# 仍依赖 $(OUTPUTDIR)/launcher/com/mojang/text2speech 的存在（cp 源）。
	# stash 目录防御性清场（上次构建中断的残留会让 mv 落进嵌套目录）。
	@rm -rf $(OUTPUTDIR)/.task191_t2s_stash
	@if [ -d "$(basename $@)/com/mojang/text2speech" ]; then \
		mv $(basename $@)/com/mojang/text2speech $(OUTPUTDIR)/.task191_t2s_stash; \
	fi
	# Task192（Forge 26.1.2 崩溃第四轮，同族第三包）：剔除
	# com/mojang/blaze3d/platform（iOS MacosUtil no-op 桩）。
	# 病历（956ea9b 装机 latestlog.2，Forge-26.1.2-64.1.3 会话）：
	#   java.lang.module.ResolutionException: Modules minecraft and
	#   launcher export package com.mojang.blaze3d.platform to module
	#   net.minecraftforge.forge
	# 机制与 Task188（com.apple.ios.audio）/Task191（text2speech）同族：
	# bootstrap 2.1.7 把 launcher.jar 模块化（自动模块导出全部包），
	# 而 minecraft 客户端 jar 自带 com.mojang.blaze3d.platform → 双导出。
	# 与前两例不同：本包的"正主"是 minecraft 自己（无法挪走），桩只能
	# 撤。MacosUtil 桩原本靠 Pojav 类加载器 first-wins 遮蔽真类（真类
	# 经 java-objc-bridge 驱动 AppKit，iOS 上崩溃）——模块层建立后该
	# 遮蔽对 Forge 会话本就失效（MC 类从 minecraft 模块加载，系统
	# classpath 的桩不可见）。真类的 AppKit 调用由原生 AppKitStub 层
	# （Task99/100：NSApplication/NSMenu selector 拦截 + 通用 nil no-op，
	# 7a30912 会话已实证 MacosUtil.java:27 NPE 被治愈）接管。
	# 桩源码保留在 src/（编译不受影响，仅不进 launcher.jar）。
	@rm -rf $(OUTPUTDIR)/.task192_blaze3d_stash
	@if [ -d "$(basename $@)/com/mojang/blaze3d" ]; then \
		mv $(basename $@)/com/mojang/blaze3d $(OUTPUTDIR)/.task192_blaze3d_stash; \
	fi
	@$(BOOTJDK)/jar -cf $@ -C $(basename $@) .
	@if [ -d "$(OUTPUTDIR)/.task192_blaze3d_stash" ]; then \
		mv $(OUTPUTDIR)/.task192_blaze3d_stash $(basename $@)/com/mojang/blaze3d; \
	fi
	@if [ -d "$(OUTPUTDIR)/.task191_t2s_stash" ]; then \
		mv $(OUTPUTDIR)/.task191_t2s_stash $(basename $@)/com/mojang/text2speech; \
	fi

# 按 LWJGL 版本分别产出一个合并 jar（3.3.3 与 3.4.1）。
#
# 解压顺序即覆盖优先级（后者覆盖前者）：
#   1) 仓库根 lwjgl.jar —— iOS 专用 LWJGL 补丁层，同时提供 LWJGL2 兼容类
#      （org/lwjgl/opengl/Display、org/lwjgl/input/Keyboard、LWJGLException 等），
#      老版本 MC（Java 8 / 1.12.2 及以下）依赖这些类，必须作为基底保留。
#   2) libs/lwjgl-<ver>/*.jar —— 版本化的 LWJGL3。341 集合含真正的
#      lwjgl-sdl.jar（加载真实 libSDL3），是 SDL3 输入注入的前提。
#      放在基底之后，以便版本化的 LWJGL3 核心类（GLFW / MemoryUtil / SDL 等）
#      覆盖根 jar 中的同名旧类。
#   3) build/lwjgl/ —— Amethyst overlay（GLFW.java 等带 iOS 桥接的改写类），
#      必须最后覆盖。
$(OUTPUTDIR)/lwjgl-%.jar: $(CLASSES) check_empty_classes
	@set -e
	@echo "Creating $@"
	@mkdir -p $(OUTPUTDIR)/lwjgl_lib_$*
	@cd $(OUTPUTDIR)/lwjgl_lib_$* && $(BOOTJDK)/jar -xf "../../../lwjgl.jar" && rm -rf META-INF
	# 仓库根 lwjgl.jar 里混入了 3 个用 JDK 25 编译的类（major 69）：
	#   org/lwjgl/openal/SOFTSystemEvent{,s,ProcI}.class
	# 它是"3.3.3 提供 3.4.1 API 兼容"的定制版，这 3 个类是从 3.4.1 一并塞进来的。
	# 3.4.1 自带它们的 Java 8 版本，下一步解压后会被覆盖回来；但 3.3.3 没有这些
	# 类，若保留 JDK 25 版本，Java 8 上的老版本 MC 一旦碰到就会抛
	# UnsupportedClassVersionError。因此在叠加版本化 jar 之前先删掉。
	@cd $(OUTPUTDIR)/lwjgl_lib_$* && find org/lwjgl/openal -maxdepth 1 -name 'SOFTSystemEvent*.class' -delete 2>/dev/null || true
	@cd $(OUTPUTDIR)/lwjgl_lib_$* && find ../../libs/lwjgl-$* -name 'lwjgl*.jar' -exec $(BOOTJDK)/jar -xf {} \; && rm -rf META-INF
	@cp -R $(OUTPUTDIR)/lwjgl/* $(OUTPUTDIR)/lwjgl_lib_$*/
	# Task188（Forge 26.1.2 崩溃根修）：撤除 com/apple/ios/audio 镜像。
	# 病历（15fddc2 latestlog.2 实锤）：Forge 的模块化引导把 launcher.jar 与
	# lwjgl-341.jar 一并解析为命名模块，两 jar 均含 com.apple.ios.audio →
	#   java.lang.module.ResolutionException: Modules launcher and lwjgl
	#   export package com.apple.ios.audio to module com.sun.jna.platform
	# → ForgeBootstrap 直接退出（exit(1)，swapOK=0）。
	# 审计结论：lwjgl overlay（src/lwjgl）对 com.apple.ios.audio 零引用，
	# 唯一消费者是 JavaSound 的 ServiceLoader（META-INF/services），而
	# launcher.jar 恒在 classpath —— 类留在 launcher.jar 单处即可被发现，
	# 镜像纯属历史冗余（c71dcfa SDL-hook provider mirror 时代引入）。
	# services 文件一并撤除：provider 类不在本 jar 时，classpath 上的
	# launcher.jar 同名 services 条目仍会被 ServiceLoader 命中，行为等价。
	@$(BOOTJDK)/jar -cf $@ -C $(OUTPUTDIR)/lwjgl_lib_$* .

# lwjgl.jar 仅作占位：all 目标因 src/lwjgl 是源码目录而列出它，但运行时使用
# lwjgl-333.jar / lwjgl-341.jar。build/lwjgl.jar 不得进入 app 的 libs 目录，
# 否则会被 classpath 中的 libs/* 与版本化 jar 一并加载，造成同名类冲突。
$(OUTPUTDIR)/lwjgl.jar: $(OUTPUTDIR)/lwjgl-333.jar $(OUTPUTDIR)/lwjgl-341.jar
	@echo "Skipping $@ (lwjgl-333.jar / lwjgl-341.jar are used instead)"

$(OUTPUTDIR)/patchjna_agent.jar: $(CLASSES)
	@set -e
	@mv $(basename $@)/com/sun/jna/Platform.class $(basename $@)/com/sun/jna/Platform.class.patch
	@echo "Creating $@"
	@$(BOOTJDK)/jar -cfm $@ $(SOURCEDIR)/patchjna_agent.txt -C $(basename $@) .

$(OUTPUTDIR)/patchsvc.jar: $(CLASSES)
	@set -e
	@mv $(basename $@)/de/maxhenkel/lame4j/Mp3Decoder.class $(basename $@)/de/maxhenkel/lame4j/Mp3Decoder.class.patch
	@mv $(basename $@)/de/maxhenkel/lame4j/Mp3Encoder.class $(basename $@)/de/maxhenkel/lame4j/Mp3Encoder.class.patch
	@mv $(basename $@)/de/maxhenkel/opus4j/OpusDecoder.class $(basename $@)/de/maxhenkel/opus4j/OpusDecoder.class.patch
	@mv $(basename $@)/de/maxhenkel/opus4j/OpusEncoder.class $(basename $@)/de/maxhenkel/opus4j/OpusEncoder.class.patch
	@mv $(basename $@)/de/maxhenkel/rnnoise4j/Denoiser.class $(basename $@)/de/maxhenkel/rnnoise4j/Denoiser.class.patch
	@mv $(basename $@)/de/maxhenkel/speex4j/AutomaticGainControl.class $(basename $@)/de/maxhenkel/speex4j/AutomaticGainControl.class.patch
	@rm -rf $(basename $@)/de/maxhenkel/*/*.class
	@echo "Creating $@"
	@$(BOOTJDK)/jar -cfm $@ $(SOURCEDIR)/patchsvc.txt -C $(basename $@) .

# Task 158（Forge 模块层 mojang 桩）：Forge 的 MC-BOOTSTRAP/GAME 模块层对
# 系统类加载器完全不可见（securejarhandler ModuleClassLoader 的父链是
# boot/platform 层），而 launcher.jar 被 -DignoreList 排除在模块层外
#（Task154 的 split-package 根治）——模块层内 GameNarrator 需要的
# com.mojang.text2speech 桩必须由一个【会被 BootstrapLauncher 模块化】的
# jar 提供。本 jar 只含 com/mojang/text2speech 桩类（与 launcher.jar 同源
# 同字节，getNarrator() 恒返回 NarratorDummy，iOS 无叙述器副作用），随包放
# app/libs/ → 恒在 -cp → 恒在 java.class.path → 自动成为 MC-BOOTSTRAP 层的
# 自动模块（文件名不含任何 ignoreList 前缀）。真实 text2speech 库继续被
# Java 侧 preProcessLibraries _skip（进 classpath 会与桩 split-package）。
# 装机锚点：Forge 1.20.1 过 GameNarrator（NoClassDefFoundError: Narrator 消失）。
# Task263（Cobblemon 大型整合包 showdown 卡死根修）：in-memory 路径绝对化 agent。
# 病历（261/262/263 四轮装机 gamelog，挂死签名逐字一致）：ShowdownThread.run() ->
# GraalShowdownService.openConnection() -> attemptUnbundle()（java.io File("showdown")
# 系统调用按进程真实 CWD 落盘）-> createContext() 首次 Context.eval 触发 GraalJS
# JSRealm.addCommonJSGlobals() 校验 js.commonjs-require-cwd="showdown"，其
# TruffleFile.exists() 走自定义 FileSystem checkAccess -> NIO UnixPath.toRealPath，
# 相对路径解析基准是 -Duser.dir（StaticProperty）属性。两个基准在 iOS 上分裂时
# （JDK21 桌面实证：java.io 走真实 CWD、NIO 预绝对化走属性基准），刚解压的
# <真实CWD>/showdown 对校验基准不可见 -> guest Error "Invalid CommonJS root
# folder: showdown" -> ShowdownThread 未捕获死亡，latch.countDown() 永不执行 ->
# ShowdownThread.launch() 的 latch.await() 永久驻停 Render thread -> JVM 全局静止、
# fps=0、SDL 窗口永不创建 -> 黑屏"无输出"。修复：premain 注册 ClassFileTransformer，
# 按类名门控（仅 GraalShowdownService/GraalShowdownUnbundler 两个类）把 4 个相对
# 路径 LDC 常量改写为 System.getProperty("ame.showdown.home","")+"/showdown*"
# 绝对拼接（无分支插入、栈形不变、COMPUTE_MAXS、StackMapTable 原样保留；同
# Task258 KnotGate 哲学）。绝对路径彻底绕开相对解析基准，java.io 解压、NIO 校验、
# checkAccess 越狱判定、require()/boot() 全部收敛到同一目录。内存内改写，mod jar
# 磁盘文件不动；无 Cobblemon 会话零影响。ASM 9.7（class major 49）内嵌自
# src/libs/asm/asm-9.7-relocated.jar，agent 类本体按 javac(BOOTJDK) 默认 target 输出，
# 全会话可加载（同 patchsvc 无条件注入先例）。
# 装机锚点：会话日志应见 "[Task263] showdown-agent armed: user.dir=... ame.showdown.home=..."，
# Cobblemon 会话另见 "[Task263] showdown path-fix applied to ... GraalShowdownService (3 sites)"
# 与 "... GraalShowdownUnbundler (2 sites)"；整合包进世界即修复成功。
$(OUTPUTDIR)/showdown_agent.jar: $(CLASSES)
	@set -e
	@echo "Creating $@"
	@if [ ! -f "$(basename $@)/com/prisma/showdown/ShowdownAgent.class" ]; then \
		echo "ERROR: showdown agent classes missing com/prisma/showdown"; \
		exit 1; \
	fi
	@mkdir -p $(basename $@)/asm_embed
	@cd $(basename $@)/asm_embed && $(BOOTJDK)/jar -xf $(CURDIR)/libs/asm/asm-9.7-relocated.jar
	@rm -rf $(basename $@)/asm_embed/META-INF $(basename $@)/asm_embed/module-info.class
	@if [ ! -f "$(basename $@)/asm_embed/com/prisma/shaded/ClassReader.class" ]; then \
		echo "ERROR: asm embed missing com/prisma/shaded/ClassReader.class"; \
		exit 1; \
	fi
	@cp -R $(basename $@)/asm_embed/com $(basename $@)/
	@rm -rf $(basename $@)/asm_embed
	@cd $(basename $@) && $(BOOTJDK)/jar -cfm ../showdown_agent.jar $(CURDIR)/src/showdown_agent.txt .
	@echo "Created $(OUTPUTDIR)/showdown_agent.jar (Task263 showdown path absolutizer, asm embedded)"

$(OUTPUTDIR)/mojang-stubs.jar: $(OUTPUTDIR)/launcher.jar
	@set -e
	@rm -rf $(OUTPUTDIR)/mojang-stubs
	@mkdir -p $(OUTPUTDIR)/mojang-stubs/com/mojang
	@if [ ! -d "$(OUTPUTDIR)/launcher/com/mojang/text2speech" ]; then \
		echo "ERROR: launcher classes missing com/mojang/text2speech (Task158 mojang-stubs)"; \
		exit 1; \
	fi
	@cp -R $(OUTPUTDIR)/launcher/com/mojang/text2speech $(OUTPUTDIR)/mojang-stubs/com/mojang/
	@cd $(OUTPUTDIR)/mojang-stubs && $(BOOTJDK)/jar -cf ../mojang-stubs.jar com
	@echo "Created $(OUTPUTDIR)/mojang-stubs.jar (Forge module-layer com.mojang.text2speech stubs, Task158)"

clean:
	rm -rf $(OUTPUTDIR)

.SUFFIXES: .java
.PHONY: all clean
