// ★ Task259（清单 9）：公告同步仓库。
// 构建期从仓库 main 分支拉取 announcements.json（与启动器内公告同一数据源，
// 单一事实源），写入 src/data/announcements.json 供页面静态渲染；
// 网络不可用时回退到已提交的快照（零构建失败）。
import { writeFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const RAW_URL =
  'https://raw.githubusercontent.com/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher/main/announcements.json';
const OUT = fileURLToPath(new URL('../src/data/announcements.json', import.meta.url));

async function main() {
  try {
    const res = await fetch(RAW_URL, { signal: AbortSignal.timeout(15000) });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const text = await res.text();
    const parsed = JSON.parse(text); // validate before persisting
    if (!parsed || !Array.isArray(parsed.announcements)) {
      throw new Error('unexpected schema: announcements[] missing');
    }
    await mkdir(new URL('../src/data', import.meta.url), { recursive: true });
    await writeFile(OUT, JSON.stringify(parsed, null, 2) + '\n', 'utf8');
    console.log('[sync-announcements] synced', parsed.announcements.length, 'items from repo main');
  } catch (err) {
    console.warn('[sync-announcements] fetch failed (' + err.message + ') -- using committed snapshot');
  }
}

main();
