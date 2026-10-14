#!/usr/bin/env python3
# Task 268 r2 Java 三项 + Makefile 回退 6.5.0
import re, sys

FAILURES = []

def patch(path, pattern, repl, label, expect=1, marker=None, flags=0):
    data = open(path, "rb").read().decode("utf-8")
    if marker and marker in data:
        print(f"SKIP {label}")
        return
    new, n = re.subn(pattern, repl, data, count=expect, flags=flags)
    if n != expect:
        FAILURES.append(f"{label}: {n}/{expect} in {path}")
        return
    open(path, "wb").write(new.encode("utf-8"))
    print(f"OK {label} x{n}")

# ① ShowdownAgent：died 去 seenAlive 门 + deadline 兜底移出循环（原 stalled 死代码）
SA = "JavaApp/src/showdown_agent/com/prisma/showdown/ShowdownAgent.java"
patch(SA,
    r"""                            boolean alive = \(\(Thread\) sdThread\)\.isAlive\(\);\n                            if \(alive\) \{\n                                seenAlive = true;\n                            \}\n                            boolean died = seenAlive && !alive;\n                            boolean stalled = System\.currentTimeMillis\(\) >= deadline;\n                            if \(died \|\| stalled\) \{\n                                latch\.countDown\(\);\n                                System\.out\.println\("\[Task263\] watchdog: showdown latch force-released \("\n                                        \+ \(died \? "showdown thread died uncaught" : "stalled past deadline"\)\n                                        \+ "; boot continues, Cobblemon battles degraded\)"\);\n                                return;\n                            \}""",
    """                            boolean alive = ((Thread) sdThread).isAlive();
                            // ★ Task268（scan-b #1 证伪修复）：原 died 要求先观测到存活
                            // （seenAlive 门，首轮 5s 轮询前死亡不触发）；stalled 判定在
                            // while(now<deadline) 体内恒 false（死代码）= 240s 防 livelock
                            // 兜底实际不存在。died 直接取 !alive（sdThread 对象存在且
                            // 非存活 = 线程已终止）；deadline 兜底移到循环外。
                            if (!alive) {
                                latch.countDown();
                                System.out.println("[Task263] watchdog: showdown latch force-released (showdown thread died uncaught; boot continues, Cobblemon battles degraded)");
                                return;
                            }""",
    "sa-died-fix", marker="scan-b #1")

patch(SA,
    r"""                        Thread\.sleep\(5000\);\n                    \}\n                \} catch \(Throwable fatal\) \{""",
    """                        Thread.sleep(5000);
                    }
                    // ★ Task268：deadline 到点兜底（原 stalled 死代码补位）——
                    // latch 仍 armed 即放行，防 showdown 线程存活但卡死的 livelock。
                    try {
                        Object instance = cob.getField("INSTANCE").get(null);
                        Object sdThread = readField(cob, instance, "showdownThread");
                        if (sdThread != null) {
                            CountDownLatch latch = (CountDownLatch) readField(sdThread.getClass(), sdThread, "latch");
                            if (latch != null && latch.getCount() != 0) {
                                latch.countDown();
                                System.out.println("[Task263] watchdog: showdown latch force-released (stalled past deadline; boot continues, Cobblemon battles degraded)");
                            }
                        }
                    } catch (Throwable t) {
                        System.out.println("[Task263] watchdog post-deadline probe error: " + t);
                    }
                } catch (Throwable fatal) {""",
    "sa-deadline-bailout", marker="post-deadline probe error")

# ② Tools.insertSafety：空串死逻辑修正
patch("JavaApp/src/launcher/net/kdt/pojavlaunch/Tools.java",
    r"""                if \(\(\(value instanceof String\) && !\(\(String\) value\)\.isEmpty\(\)\) \|\| value != null\) \{""",
    """                // ★ Task268（scan-b #4）：原条件空串经 value!=null 恒真（死逻辑），
                // 子版本 JSON 带空 mainClass 会覆盖父版本有效值（loadClass("") 崩）。
                if (value != null && (!(value instanceof String) || !((String) value).isEmpty())) {""",
    "tools-insert-safety", marker="scan-b #4")

# ③ IOSTargetDataLine：release 宽限延迟（UAF 面消除）
patch("JavaApp/src/launcher/com/apple/ios/audio/IOSTargetDataLine.java",
    r"""        if \(handle != 0\) \{\n            NativeAudioCapture\.release\(handle\);\n        \}""",
    """        if (handle != 0) {
            // ★ Task268（scan-b #2）：read() 锁内取句柄/锁外用句柄，close 同步
            // release 与在途 native read 构成 UAF（native read 会阻塞等音频数据，
            // 不能持 Java 键）。stop() 已广播唤醒在途 read，宽限 500ms 后释放，
            // 覆盖其返回路径（守护线程，不阻塞关闭）。
            Thread ame268Releaser = new Thread(new Runnable() {
                public void run() {
                    try { Thread.sleep(500); } catch (InterruptedException ignored) {}
                    NativeAudioCapture.release(handle);
                }
            }, "Ame268-AudioCaptureRelease");
            ame268Releaser.setDaemon(true);
            ame268Releaser.start();
        }""",
    "audio-grace-release", marker="Ame268-AudioCaptureRelease")

# ④ Makefile：回退 6.5.0（用户指令：本批修复走 v6.5.0 静默替换通道）
patch("Makefile",
    r"VERSION     := 6\.5\.5",
    "VERSION     := 6.5.0",
    "makefile-650")

print()
if FAILURES:
    print("FAILURES:")
    for f in FAILURES:
        print(" -", f)
    sys.exit(1)
print("JAVA+MAKEFILE OK")
