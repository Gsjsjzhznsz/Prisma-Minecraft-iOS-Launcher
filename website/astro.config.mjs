import { defineConfig } from 'astro/config';

// Prisma 启动器介绍站 —— 静态输出，GitHub Pages / 任意静态托管皆可
export default defineConfig({
  site: 'https://gsjsjzhznsz.github.io',
  base: '/Prisma-Minecraft-iOS-Launcher',
  output: 'static',
  compressHTML: true,
});
