import com.metallum.shaded.asm.ClassReader;
import com.metallum.shaded.asm.ClassVisitor;
import com.metallum.shaded.asm.ClassWriter;
import com.metallum.shaded.asm.MethodVisitor;
import com.metallum.shaded.asm.Opcodes;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;
import java.util.jar.JarOutputStream;
import java.util.jar.Manifest;

/**
 * Task258: reroute ensure12111's defineMetallumClasses call through the Knot gate.
 *
 * Patch: inside MetallumAgent.ensure12111(Ljava/lang/ClassLoader;)V exactly one
 * call site `invokestatic MetallumAgent.defineMetallumClasses:(ClassLoader,String)V`
 * is retargeted to `Task258KnotGate.defineMetallumClassesMaybe` (same descriptor).
 * No branches are inserted, no stack shapes change, so the original
 * StackMapTable stays valid (COMPUTE_MAXS only, no COMPUTE_FRAMES) -- same
 * philosophy as Task211's daemon patch.
 *
 * All other defineMetallumClasses call sites (the (ClassLoader) overload and
 * the DeferDefine retry thread inside the agent) are left untouched.
 *
 * Reproduce:
 *   cp scripts/task258_knot_gate/Task258MetallumKnotGatePatch.java /tmp/Task258MetallumKnotGatePatch.java
 *   cp scripts/task258_knot_gate/Task258KnotGate.java /tmp/Task258KnotGate.java
 *   java -jar /tmp/ecj.jar -21 -nowarn -cp JavaApp/libs/others/metallum_agent.jar \
 *       /tmp/Task258MetallumKnotGatePatch.java /tmp/Task258KnotGate.java -d /tmp/t258
 *   java -cp /tmp/t258:JavaApp/libs/others/metallum_agent.jar \
 *       Task258MetallumKnotGatePatch JavaApp/libs/others/metallum_agent.jar \
 *       /tmp/t258-gate.jar com/metallum/agent/Task258KnotGate.class
 */
public class Task258MetallumKnotGatePatch {
    static final String TARGET_METHOD = "ensure12111";
    static final String TARGET_DESC = "(Ljava/lang/ClassLoader;)V";
    static final String OLD_OWNER = "com/metallum/agent/MetallumAgent";
    static final String OLD_NAME = "defineMetallumClasses";
    static final String OLD_DESC = "(Ljava/lang/ClassLoader;Ljava/lang/String;)V";
    static final String NEW_OWNER = "com/metallum/agent/Task258KnotGate";
    static final String NEW_NAME = "defineMetallumClassesMaybe";

    public static void main(String[] args) throws Exception {
        if (args.length < 4) {
            System.err.println("usage: Task258MetallumKnotGatePatch <in-jar> <out-jar> <gate-class-resource> <gate-classes-dir>");
            System.exit(2);
        }
        Path in = Path.of(args[0]);
        Path out = Path.of(args[1]);
        String gateResource = args[2];
        Path gateDir = Path.of(args[3]); // dir containing freshly compiled Task258KnotGate*.class
        if (!Files.isDirectory(gateDir)) throw new IllegalStateException("gate dir missing: " + gateDir);
        java.util.List<Path> gateClasses = new java.util.ArrayList<>();
        try (java.util.stream.Stream<Path> st = Files.list(gateDir)) {
            st.filter(p -> p.getFileName().toString().startsWith("Task258KnotGate"))
              .filter(p -> p.getFileName().toString().endsWith(".class"))
              .sorted().forEach(gateClasses::add);
        }
        if (gateClasses.isEmpty()) throw new IllegalStateException("no Task258KnotGate*.class in " + gateDir);

        byte[] original;
        try (JarFile jar = new JarFile(in.toFile())) {
            InputStream is = jar.getInputStream(new JarEntry("com/metallum/agent/MetallumAgent.class"));
            if (is == null) throw new IllegalStateException("MetallumAgent.class not found in " + in);
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            is.transferTo(bos);
            original = bos.toByteArray();
        }

        ClassReader cr = new ClassReader(original);
        ClassWriter cw = new ClassWriter(cr, ClassWriter.COMPUTE_MAXS);
        final int[] patched = {0};
        cr.accept(new ClassVisitor(Opcodes.ASM9, cw) {
            @Override
            public MethodVisitor visitMethod(int access, String name, String descriptor,
                                             String signature, String[] exceptions) {
                MethodVisitor mv = super.visitMethod(access, name, descriptor, signature, exceptions);
                if (!name.equals(TARGET_METHOD) || !descriptor.equals(TARGET_DESC)) return mv;
                return new MethodVisitor(Opcodes.ASM9, mv) {
                    @Override
                    public void visitMethodInsn(int opcode, String owner, String mName, String mDesc, boolean isInterface) {
                        if (opcode == Opcodes.INVOKESTATIC
                                && owner.equals(OLD_OWNER)
                                && mName.equals(OLD_NAME)
                                && mDesc.equals(OLD_DESC)) {
                            super.visitMethodInsn(opcode, NEW_OWNER, NEW_NAME, mDesc, false);
                            patched[0]++;
                        } else {
                            super.visitMethodInsn(opcode, owner, mName, mDesc, isInterface);
                        }
                    }
                };
            }
        }, 0);
        byte[] patchedClass = cw.toByteArray();

        if (patched[0] != 1) {
            throw new IllegalStateException("expected exactly 1 defineMetallumClasses call site in ensure12111, patched " + patched[0]);
        }

        // Byte-verified jar rebuild: everything except MetallumAgent.class is a
        // raw entry copy; MetallumAgent.class is replaced; gate classes are added.
        final byte[] patchedClassFinal = patchedClass;
        try (JarFile jar = new JarFile(in.toFile());
             JarOutputStream jos = new JarOutputStream(Files.newOutputStream(out))) {
            var entries = jar.entries();
            boolean wroteAgent = false;
            java.util.Set<String> writtenGates = new java.util.HashSet<>();
            while (entries.hasMoreElements()) {
                JarEntry e = entries.nextElement();
                String n = e.getName();
                if (n.equals("com/metallum/agent/MetallumAgent.class")) {
                    jos.putNextEntry(new JarEntry(n));
                    jos.write(patchedClassFinal);
                    wroteAgent = true;
                } else if (isGateEntry(n, gateResource, gateClasses)) {
                    jos.putNextEntry(new JarEntry(n));
                    jos.write(readGate(n, gateResource, gateClasses));
                    writtenGates.add(n);
                } else {
                    if (e.isDirectory()) { jos.putNextEntry(new JarEntry(n)); continue; }
                    jos.putNextEntry(new JarEntry(n));
                    try (InputStream is2 = jar.getInputStream(e)) { is2.transferTo(jos); }
                }
            }
            for (Path g : gateClasses) {
                String res = "com/metallum/agent/" + g.getFileName();
                if (!writtenGates.contains(res)) {
                    jos.putNextEntry(new JarEntry(res));
                    jos.write(Files.readAllBytes(g));
                }
            }
            if (!wroteAgent) throw new IllegalStateException("agent class not written");
        }
        System.out.println("Task258 patch OK: ensure12111 define call rerouted (1 site), gate classes "
                + gateClasses.size() + " file(s); wrote " + out);
    }

    private static boolean isGateEntry(String name, String primary, java.util.List<Path> gateClasses) {
        for (Path g : gateClasses) if (name.equals("com/metallum/agent/" + g.getFileName())) return true;
        return false;
    }

    private static byte[] readGate(String name, String primary, java.util.List<Path> gateClasses) throws Exception {
        for (Path g : gateClasses) if (name.equals("com/metallum/agent/" + g.getFileName())) return Files.readAllBytes(g);
        throw new IllegalStateException("not a gate entry: " + name);
    }
}
