package net.kdt.patchjna;

import java.io.*;
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.IllegalClassFormatException;
import java.lang.instrument.Instrumentation;
import java.lang.reflect.InvocationTargetException;
import java.security.ProtectionDomain;

public class PatchJNAAgent implements ClassFileTransformer {
    public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined,
    ProtectionDomain protectionDomain, byte[] classfileBuffer) throws IllegalClassFormatException {
        byte[] transformeredByteCode = classfileBuffer;
        // ame270：instrument 契约允许 className 为 null（如 lambda 合成类），
        // 字面量前置判等避免 NPE。
        if ("com/sun/jna/Platform".equals(className)) {
            System.out.println("PatchJNAAgent: Replacing class");
            // ame270：patch 流用 try-with-resources 确保 close（原实现泄漏）；
            // 资源缺失(null)与读取失败均回退原类字节码——与既有 catch 失败路径
            // 语义一致，且避免 readFully 半途失败时把零填充数组当类字节码返回。
            try (InputStream inputStream = PatchJNAAgent.class.getClassLoader().getResourceAsStream("com/sun/jna/Platform.class.patch")) {
                if (inputStream == null) {
                    System.err.println("PatchJNAAgent: Platform.class.patch not found, using original bytecode");
                    return classfileBuffer;
                }
                // ★ Task275 J-P1-1：available() 定长 + readFully = 短读静默截断类字节码
                //   （readFully 只保证读满给定数组，available 少报时补丁残缺且无任何
                //   日志——PatchSVC 274 已根治同款，本 agent 漏平移）。改全量读至 EOF。
                java.io.ByteArrayOutputStream ame275_buf = new java.io.ByteArrayOutputStream();
                byte[] ame275_chunk = new byte[8192];
                int ame275_n;
                while ((ame275_n = inputStream.read(ame275_chunk)) != -1) {
                    ame275_buf.write(ame275_chunk, 0, ame275_n);
                }
                byte[] patchedByteCode = ame275_buf.toByteArray();
                if (patchedByteCode.length == 0) {
                    System.err.println("PatchJNAAgent: Platform.class.patch is empty, using original bytecode");
                    return classfileBuffer;
                }
                transformeredByteCode = patchedByteCode;
            } catch (Exception e) {
                e.printStackTrace();
            }
        }
        return transformeredByteCode;
    }

    public static void premain(String args, Instrumentation instrumentation) {
        System.out.println("PatchJNAAgent: premain called");
        instrumentation.addTransformer(new PatchJNAAgent());
    }
}
