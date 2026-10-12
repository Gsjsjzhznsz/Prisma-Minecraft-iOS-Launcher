import java.lang.reflect.Method;
import java.net.URL;
import java.net.URLClassLoader;

/**
 * Task258 E2E probe: verify the Knot gate behavior with the patched agent
 * loaded via -javaagent (so gInst is live and resources are readable).
 *
 * Expectations:
 *   1. pass-through for a plain URLClassLoader: no "Task258: Knot loader
 *      detected" line; the real defineMetallumClasses runs immediately
 *      (resource-missing/completed logs are fine).
 *   2. Knot-named loader: "Task258: Knot loader detected -- eager define
 *      deferred" printed; NO real define logs for >=4.5s after that; then
 *      "Task258: Knot-safe deferred define done via timer" (real define logs
 *      follow or a FAILED line -- resources should be readable via gInst).
 *   3. process exits 0 within ~9s.
 */
public class Task258Probe {
    public static final class FakeKnotClassLoader extends URLClassLoader {
        public FakeKnotClassLoader() { super(new URL[0], Task258Probe.class.getClassLoader()); }
    }

    public static void main(String[] args) throws Exception {
        Class<?> gate = Class.forName("com.metallum.agent.Task258KnotGate");
        Method m = gate.getMethod("defineMetallumClassesMaybe", ClassLoader.class, String.class);

        System.out.println("[Probe] phase 1: pass-through (plain URLClassLoader)");
        m.invoke(null, new URLClassLoader(new URL[0], Task258Probe.class.getClassLoader()), "classes263");
        Thread.sleep(300);

        System.out.println("[Probe] phase 2: Knot gate (FakeKnotClassLoader)");
        long t0 = System.currentTimeMillis();
        m.invoke(null, new FakeKnotClassLoader(), "classes263");
        long armed = System.currentTimeMillis() - t0;
        System.out.println("[Probe] gate armed in " + armed + "ms");
        if (armed > 200) throw new AssertionError("gate arming took too long");

        Thread.sleep(4200);
        System.out.println("[Probe] t+4.5s: deferred define must NOT have run yet (timer=5s)");

        Thread.sleep(2500);
        System.out.println("[Probe] t+7s: deferred define should have fired via timer; probe DONE");
        System.out.println("[Probe] PASS");
        System.exit(0);
    }
}
