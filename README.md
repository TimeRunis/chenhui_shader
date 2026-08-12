# 晨辉光影 (ChenHui Shaders)

一款为 **Minecraft 1.20.1** 打造的光影包，兼容 **Iris 1.7.2**（Fabric）。

## 特性

| 特性 | 说明 |
|---|---|
| ☁️ 体积云 | 程序化 3D 云层（稳定高度云带），风场漂移、太阳前向散射、自阴影 |
| 🌌 程序化天空 | 大气渐变、日月盘面细节（太阳米粒/黑子、月亮月海/环形山）、星空 |
| 💧 水面 | 程序化波浪（参数移植自 Derivative Main）、半透明混合、SSR 屏幕空间反射（命中/未命中回退，反射天空与云层）、水底光斑 caustics（高斯曲率网状图案，水面/水下双路径，仅阳光直射处出现） |
| ☀️ 阳光阴影 | PCSS 动态半影 + Poisson PCF，4096 阴影图，关闭阴影 pass 面剔除 |
| 🔥 光照合成 | 前向合成：天光/方块光/太阳直射/月光/环境光/高光/自发光，夜晚天光与点光源解耦 |
| 🖐️ 手持光源 | 手持火把/萤石等照亮周围（颜色从物品材质提取，材质响应） |
| 🌧️ 雨天效果 | 雨滴屏幕效果、湿润反光、水面雨纹 |
| 🎛️ 中文参数 | 全部参数中文显示（lang/zh_CN.lang）+ 三档中文预设（性能/均衡/极致），含太阳光强度/月光强度滑条 |

## 安装

1. 将 `晨辉光影` 文件夹（或 `晨辉光影.zip`）放入 `.minecraft/shaderpacks`
2. Fabric + **Iris 1.7.2**，Minecraft 1.20.1
3. 视频设置 → 光影 → 选择「晨辉光影」，F3+R 重载

## 渲染管线（实际结构）

```
shadow pass（太阳方向阴影图，4096，culling 关闭）
gbuffers（18 个正向程序：terrain/block/entities/water/particles/textured...）
  └─ calcLight：光照合成 → colortex0（预曝光颜色 + a=方块光等级）
  └─ colortex1 = 水面深度+材质标志 / colortex2 = albedo / colortex3 = 不透明深度+颜色快照
composite1（全分辨率）
  ├─ 天空分支（程序化天空/日月/云）
  ├─ 方块光屏幕空间扩散、距离雾、水下雾
  ├─ 水面 SSR（屏幕空间 marching + 二分细化 + 高度过滤 + 未命中回退含云）
  ├─ 水底 caustics（高斯曲率图案，反射混合前应用，阴影门控）
  ├─ 手持光源
  └─ 逆预曝光 + HDR 软压缩（线性直出，无分段后处理曲线）
final（线性直出）
```

- 缓冲：colortex0（RGBA16F 预曝光主色）、colortex1（RGBA32F 水面深度/标志）、colortex2（RGBA16F albedo）、colortex3（RGBA32F 不透明深度+预曝光色快照）
- 全分辨率后处理（scale=1.0），GLSL 450 compatibility
- 水面半透明混合需显式 `blend.gbuffers_water`（Iris 默认关混合）

## 开发与调试

- **打包**：`python build_pack.py` → `H:\Game\MineCraft\1.20.1\.minecraft\shaderpacks\晨辉光影.zip`（保留 晨辉光影/ 顶层前缀）
- **调试开关**：
  - `DEBUG_LIGHT`（common.fsh）：光照链路分解 1~11（albedo/ambient/direct/合成/emissive/lightmap/skyNight 等）
  - `DEBUG_SSR`（composite1.fsh）：SSR 门禁/命中/权重/阴影图诊断 1~34
- 选项宏需在全部 16 个 .fsh 文件中保持定义一致；lib 文件不直接使用选项宏（SUN_STRENGTH/MOON_STRENGTH 为例外，有 #ifndef 回退）

## 已知限制

- SSR 为屏幕空间反射：被遮挡/出屏内容不可反射；相机与水面之间的物体已做深度门禁排除
- 阴影边缘存在纹素步进（太阳移动时"一卡卡"）：Iris 1.7.2 前向管线无法做跨帧时间域平滑（gbuffers 读 colortex 恒 0，已实验验证），靠 4096 分辨率 + PCF 软边缓解
- 方块背光面阴影存在梯形亮区残留（阴影图内容问题，已加 `shadow.culling=false` 缓解，未根治）
- 水底光斑在水下洞穴/遮挡处无门控（光照图与太阳遮挡方案均试验失败后回退）
- 动态光源为屏幕空间光晕式（非全局光照），光线不会真实投影到几何体上
- PBR 需搭配提供 `_n`/`_s` 贴图的材质包（LabPBR 标准）
