package net.kdt.pojavlaunch.utils;

import java.util.*;
import java.io.*;

import net.kdt.pojavlaunch.*;

public class MCOptionUtils
{
    private static List<String> mLineList;
    
    public static void load() {
        if (mLineList == null) {
            mLineList = new ArrayList<String>();
        } else {
            mLineList.clear();
        }
        
        // ame274：reader 收进 try-with-resources——readLine 中途 IOException
        // 时旧实现永远到不了 close()，启动链每次调用泄漏一个 fd。
        try (BufferedReader reader = new BufferedReader(new FileReader(Tools.DIR_GAME_PROFILE + "/options.txt"))) {
            String line;
            while ((line = reader.readLine()) != null) {
                mLineList.add(line);
            }
        } catch (IOException e) {
            System.err.println("Could not load options.txt");
            e.printStackTrace();
        }
    }
    
    public static void set(String key, String value) {
        // ★ Task275 J-P3-10：save() 置 null 后调 set/setDefault 恒 NPE——与 remove
        //   的防御口径、get() 的懒加载口径统一（当前调用序安全，纯属埋雷）。
        if (mLineList == null) {
            load();
        }
        // Task 104：去重写入。MC 的 Options.load 逐行 putString —— 同 key
        // 多行时【后出现的行覆盖先前的行】。旧实现对重复行只改第一处，
        // 残留的后续旧行会在 MC 侧覆盖我们的值（例：历史遗留的
        // inactivityFpsLimit:afk 会让写入的 minimized 失效 → 26.3 的
        // SHORT_AFK 限帧 30fps）。现在第一处替换、后续重复全部删除。
        String prefix = key + ":";
        boolean replaced = false;
        ListIterator<String> it = mLineList.listIterator();
        while (it.hasNext()) {
            String line = it.next();
            if (line.startsWith(prefix)) {
                if (!replaced) {
                    it.set(key + ":" + value);
                    replaced = true;
                } else {
                    it.remove(); // 重复行：MC 侧后行覆盖前行，必须清除
                }
            }
        }
        if (!replaced) {
            mLineList.add(key + ":" + value);
        }
    }

    public static void setDefault(String key, String value) {
        if (mLineList == null) {
            load();   // ★ Task275 J-P3-10：懒加载口径统一
        }
        if (get(key) == null) {
            mLineList.add(key + ":" + value);
        }
    }

    /**
     * 移除 options.txt 中指定 key 的行（如果存在）。
     * 用于在用户选择"默认"时清除之前写入的值，让 MC 使用内部默认行为。
     * 注意：调用前必须先 load()。
     */
    public static void remove(String key) {
        if (mLineList == null) return;
        // ame270：与 set() 的去重语义对齐——MC 侧 last-wins，只删首行时
        // 残留的后续重复行仍会在 MC 侧生效。倒序遍历删除所有匹配行，
        // 避免正序 remove(i) 后索引漂移漏删。
        String prefix = key + ":";
        for (int i = mLineList.size() - 1; i >= 0; i--) {
            if (mLineList.get(i).startsWith(prefix)) {
                mLineList.remove(i);
            }
        }
    }

    public static String get(String key){
        if (mLineList == null){
            load();
        }
        for (int i = 0; i < mLineList.size(); i++) {
            String line = mLineList.get(i);
            if (line.startsWith(key + ":")) {
                String value = mLineList.get(i);
                return value.substring(value.indexOf(":")+1);
            }
        }
        return null;
    }

    public static void save() {
        StringBuilder result = new StringBuilder();
        for (int i = 0; i < mLineList.size(); i++) {
            result.append(mLineList.get(i));
            if (i + 1 < mLineList.size()) {
                result.append("\n");
            }
        }
        
        try {
            Tools.write(Tools.DIR_GAME_PROFILE + "/options.txt", result.toString());
        } catch (IOException e) {
            System.err.println("Could not save options.txt");
            e.printStackTrace();
        }
        mLineList = null;
    }

    /**
     * Task 104：从磁盘【重新读取】指定 key 的值（绕过内存链表）。
     * 用途：save() 后的落盘校验——内存 get() 只能证明内存态，不能证明
     * MC 即将读取的文件内容（写入路径错位/写入失败/重复行残留都会让
     * 内存态与磁盘态分叉，26.3 的 30fps 限帧正是这种分叉的实锤现场）。
     */
    public static String getFromFile(String key) {
        // ame274：同 load()——reader 收进 try-with-resources，异常路径不再泄漏 fd。
        try (BufferedReader reader = new BufferedReader(new FileReader(Tools.DIR_GAME_PROFILE + "/options.txt"))) {
            String line;
            String last = null;
            int occurrences = 0;
            while ((line = reader.readLine()) != null) {
                if (line.startsWith(key + ":")) {
                    last = line.substring(line.indexOf(":") + 1);
                    occurrences++;
                }
            }
            if (occurrences > 1) {
                System.out.println("[MCOptionUtils] Task104 WARNING: '" + key + "' appears " + occurrences
                    + " times in options.txt (last-wins at MC side): " + last);
            }
            return last;
        } catch (IOException e) {
            return "<read-failed: " + e.getClass().getSimpleName() + ">";
        }
    }
}
