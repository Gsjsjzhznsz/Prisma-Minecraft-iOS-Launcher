package com.metallum.agent;

import java.lang.reflect.Method;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Task258: Knot(fabric) loader gate for MetallumAgent's eager metallum-class define.
 *
 * Forensics (8dc60b9 latestlog.old.txt, FO modpack 26.3 session, 19:11:57):
 *   defineMetallumClasses(KnotClassLoader, "classes263") defined MetalGpuTexture
 *   (implements com.mojang.renderpearl.api.textures.GpuTexture) and friends at
 *   mixin-subsystem-init time (~t0.65s). HotSpot eagerly resolves super
 *   interfaces at defineClass, so renderpearl GpuTexture/GpuBackend/GpuDevice
 *   got LOADED through the Knot loader BEFORE mixin config prepare (~t1.5s).
 *   Iris's mixins.iris.json:MixinGpuTexture3 then failed with
 *   MixinTargetAlreadyLoadedException ("was loaded too early"), the failed
 *   prepare poisoned the transformer, ModernFixPreLaunchFabric's preLaunch
 *   class transform rethrew, Fabric displayed "A mod crashed on startup!" and
 *   exit(1)'d. Vanilla 26.3 never crashes because nothing mixin-targets
 *   renderpearl there; desktop FO never sees this because there is no agent.
 *
 * Fix: when the target loader is Fabric's KnotClassLoader, skip the eager
 * define and defer it to a post-mixin moment:
 *   - primary signal: the load of "net/minecraft/client/main/Main" (Knot loads
 *     the target class AFTER all preLaunch entrypoints, i.e. after mixin
 *     prepare, and BEFORE Main.main runs any device-init code);
 *   - fallback: a 5s daemon timer, in case the entry class name ever changes.
 * Both paths funnel through defineOnce(), which reflects the agent's private
 * static defineMetallumClasses(ClassLoader, String) -- the same code that ran
 * eagerly before, just later. Non-Knot loaders (PojavClassLoader vanilla,
 * Forge) keep the original eager behavior unchanged.
 */
public final class Task258KnotGate {
    private static final AtomicBoolean FIRED = new AtomicBoolean(false);
    private static final AtomicBoolean DEFINED = new AtomicBoolean(false);
    private static volatile ClassLoader sLoader;
    private static volatile String sPrefix;

    private Task258KnotGate() {}

    /** Same descriptor as the real defineMetallumClasses(ClassLoader, String)V. */
    public static void defineMetallumClassesMaybe(ClassLoader loader, String prefix) {
        if (loader != null && loader.getClass().getName() != null
                && loader.getClass().getName().contains("KnotClassLoader")) {
            armDeferred(loader, prefix);
            return;
        }
        reflectDefine(loader, prefix);
    }

    private static void armDeferred(ClassLoader loader, String prefix) {
        if (!FIRED.compareAndSet(false, true)) {
            return; // second ensure12111-style trigger already armed the gate
        }
        sLoader = loader;
        sPrefix = prefix;
        try {
            MainSignal.register();
        } catch (Throwable t) {
            System.out.println("[MetallumAgent] Task258: main-signal unavailable (" + t + "), timer-only");
        }
        Thread timer = new Thread(() -> {
            try { Thread.sleep(5000L); } catch (InterruptedException ignored) { }
            defineOnce("timer");
        }, "Task258-KnotDefer-Timer");
        timer.setDaemon(true);
        timer.start();
        System.out.println("[MetallumAgent] Task258: Knot loader detected -- eager define deferred "
                + "(mixin loaded-too-early guard; defines at Main-load or +5s)");
    }

    /** Registered as a ClassFileTransformer watching only the Main entry class name. */
    static final class MainSignal {
        private static volatile boolean sDone;

        static void register() throws Exception {
            Class<?> agent = Class.forName("com.metallum.agent.MetallumAgent");
            java.lang.reflect.Field fInst = agent.getDeclaredField("gInst");
            fInst.setAccessible(true);
            final Object inst = fInst.get(null);
            if (inst == null) throw new IllegalStateException("gInst null");
            final java.lang.instrument.Instrumentation instrumentation =
                    (java.lang.instrument.Instrumentation) inst;
            instrumentation.addTransformer(new java.lang.instrument.ClassFileTransformer() {
                @Override
                public byte[] transform(ClassLoader loader2, String className, Class<?> beingRedefined,
                                        java.security.ProtectionDomain domain, byte[] bytes) {
                    if (!sDone && className != null && className.startsWith("net/minecraft/client/main/Main")) {
                        sDone = true;
                        defineOnce("main-signal(" + className + ")");
                    }
                    return null;
                }
            }, false);
            System.out.println("[MetallumAgent] Task258: Main-load signal armed");
        }
    }

    private static void defineOnce(String source) {
        if (!DEFINED.compareAndSet(false, true)) return;
        try {
            reflectDefine(sLoader, sPrefix);
            System.out.println("[MetallumAgent] Task258: Knot-safe deferred define done via " + source
                    + " (prefix=" + sPrefix + ")");
        } catch (Throwable t) {
            DEFINED.set(false);
            System.out.println("[MetallumAgent] Task258: deferred define FAILED via " + source + ": " + t);
        }
    }

    private static void reflectDefine(ClassLoader loader, String prefix) {
        try {
            Class<?> agent = Class.forName("com.metallum.agent.MetallumAgent");
            Method m = agent.getDeclaredMethod("defineMetallumClasses", ClassLoader.class, String.class);
            m.setAccessible(true);
            m.invoke(null, loader, prefix);
        } catch (java.lang.reflect.InvocationTargetException ite) {
            Throwable cause = ite.getCause();
            if (cause instanceof RuntimeException) throw (RuntimeException) cause;
            if (cause instanceof Error) throw (Error) cause;
            throw new RuntimeException(cause);
        } catch (ReflectiveOperationException e) {
            throw new RuntimeException(e);
        }
    }
}
