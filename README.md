# CADCraft HarmonyOS 移植版（cadcraft-hmos）

CADCraft 是 [@ceremcem](https://github.com/ceremcem) 的 CAD 应用，基于 Rust + [egui](https://github.com/emilk/egui)。
本项目将其移植到 **HarmonyOS / OpenHarmony**，构建出可在真机安装的 HAP。

当前版本：**0.19.0**（跟随上游 `cadcraft/` workspace 版本，不另立版本体系，`versionCode = 1900`）。

## 特性
- 完整 CAD 绘图能力（草图、建模、标注、块、图层、特性…），界面**全中文**。
- **中文输入法（IME）**：通过 `@kit.IMEKit` 接入系统软键盘，支持中文提交（Commit）/ 预编辑（Preedit）。
- 基于 XComponent `SURFACE` + NAPI/C++ 桥 + Rust `staticlib`，双架构 `aarch64` / `x86_64` 交叉编译。
- 内嵌 Noto Sans SC，离线渲染中文。

## 仓库结构
```
cadcraft-hmos/
├── cadcraft/          # 上游 cadcraft 源码（fork 形式 vendored 在内，使仓库自包含、clone 即可编译）
├── vendor/            # vendored egui / winit / craft-libs forks（经 [patch.crates-io] 指向本地）
├── third_party/       # wgpu-hal 等补丁
├── native/rust/       # Rust NAPI/FFI 适配层（lib.rs / input.rs / render.rs / bridge.rs / Cargo.toml）
├── entry/             # ArkTS UIAbility（XComponent、IME、文件选择）
├── AppScope/          # 应用级配置（bundleName 等）
├── scripts/           # 构建/签名/装机脚本
└── signing/           # 本地签名材料（**不入库**，见下方说明）
```

## 构建（需要 DevEco Studio + OpenHarmony SDK）
1. 用 DevEco Studio 打开本工程目录。
2. 配置 `.cargo/config.toml` 中的 OHOS clang / sysroot 路径（已按本机环境填好，迁移机器需改）。
3. 编译 native Rust（双架构）：
   ```bash
   cd native/rust
   cargo build --release --target aarch64-unknown-linux-ohos
   cargo build --release --target x86_64-unknown-linux-ohos
   ```
4. 在 DevEco 中 `Build > Build Hap(s)`（hvigor `assembleHap`），自动链接 `.a` 并签名。

## 关于签名材料
- `build-profile.json5` 提交的是**占位符版本**（不含真实签名 material）。
- 本地真实签名文件保存在 `signing/build-profile.local.json5`（已被 `.gitignore` 排除，**不入库**）。
- 实际打包前，请用本地未跟踪的 `signing/build-profile.local.json5` 内容覆盖回 `build-profile.json5`，
  或自行在 DevEco「Project Structure → Signing Configs」用专属 `bundleName`
  `io.github.shaliuxin.cadcraft.hmos` 重新自动签名。
- **重要**：每个鸿蒙移植项目必须用各自专属的 `bundleName`，切勿复用其它项目的包名。

## IME（中文输入）实现位置
- ArkTS：`entry/src/main/ets/pages/Index.ets`（`inputMethod` 控制器、监听 `setPreviewText`/`finishTextPreview`/`sendFunctionKey`）
- Rust：`native/rust/src/input.rs`（`Event::Ime(ImeEvent::Commit/Preedit)` 映射）、`native/rust/src/lib.rs`（IME 显隐通知）

## 许可
上游 cadcraft 采用其自身许可证；vendor 的各 fork 遵循各自上游许可（egui: MIT）。
详见 [LICENSE](./LICENSE)。
