//! 鸿蒙专属 FFI 边界。编辑器与全部算法保持安全 Rust。
//! cadcraft 的 `CadApp` 已把宿主缝直接暴露为 `new(Session, Services)` /
//! `logic(ctx)` / `raw_input_hook(ctx, raw)` / `ui(ui)` / `open_path(&Path)`，无需 patch 上游 ui-egui。
#![allow(clippy::needless_lifetimes)]
mod appearance;
mod bridge;
mod display_color;
mod file_open;
mod form_factor;
mod input;
mod render;

use serde::Deserialize;
use cadcraft_ui_egui::CadApp;
use std::{
    sync::{
        OnceLock,
        mpsc,
        atomic::{AtomicI8, Ordering},
    },
    time::{Duration, Instant},
};

/// 把 `log` crate 的记录转到 hilog：wgpu-hal 的 EGL 诊断（平台选择 / surface 创建 / swap 失败）
/// 默认没有 logger 就会被丢掉，设备上完全看不见。
#[cfg(target_env = "ohos")]
mod glog {
    use std::ffi::{CString, c_char};

    unsafe extern "C" {
        fn sc_hilog(level: i32, message: *const c_char);
    }

    struct Hilog;

    impl log::Log for Hilog {
        fn enabled(&self, _: &log::Metadata<'_>) -> bool {
            true
        }

        fn log(&self, record: &log::Record<'_>) {
            let level = match record.level() {
                log::Level::Error => 2,
                log::Level::Warn => 1,
                _ => 0,
            };
            let line = format!("[{}] {}: {}", record.level(), record.target(), record.args());
            if let Ok(text) = CString::new(line) {
                // SAFETY: 有效的 NUL 结尾 C 字符串；sc_hilog 只读该指针。
                unsafe { sc_hilog(level, text.as_ptr()) };
            }
        }

        fn flush(&self) {}
    }

    static LOGGER: Hilog = Hilog;

    pub fn install() {
        if log::set_logger(&LOGGER).is_ok() {
            log::set_max_level(log::LevelFilter::Info);
        }
    }
}

#[derive(Deserialize)]
#[allow(dead_code)]
struct Config {
    files: String,
    #[serde(default)]
    documents: String,
    #[serde(default = "default_scale")]
    scale: f32,
    #[serde(default)]
    language: String,
    /// 系统 locale（`zh-Hans-CN` 这类 BCP-47 标签），决定「跟随系统」解析到哪种语言。
    #[serde(default, rename = "systemLocale")]
    system_locale: String,
    #[serde(default, rename = "displayP3")]
    display_p3: bool,
    #[serde(default, rename = "systemTheme")]
    system_theme: String,
    #[serde(default)]
    fullscreen: bool,
    #[serde(default, rename = "deviceType")]
    device_type: String,
    #[serde(default, rename = "widthVp")]
    width_vp: f32,
}
fn default_scale() -> f32 {
    1.
}

#[allow(dead_code)]
enum Message {
    Attach(usize, u32, u32),
    Resize(u32, u32),
    Detach,
    Frame,
    Active(bool),
    Input(input::Input),
    Open(String, Vec<u8>),
    Drop(String, Vec<u8>, f32, f32),
    DropFile(String, std::fs::File, f32, f32),
    Close,
    Wake(Duration),
    Command(String, serde_json::Value),
}

static SEND: OnceLock<mpsc::Sender<Message>> = OnceLock::new();
fn send(message: Message) {
    if let Some(tx) = SEND.get() {
        let _ = tx.send(message);
    }
}

/// 把 ArkTS 上报的系统主题透传给 appearance 模块。
static SYSTEM_THEME_TOKEN: AtomicI8 = AtomicI8::new(0);

/// # Safety
/// `ptr`/`len` 必须在调用期间指向可读内存；调用方保证。
unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if len > isize::MAX as usize || (ptr.is_null() && len != 0) {
        return None;
    }
    if len == 0 {
        return Some(&[]);
    }
    Some(unsafe { std::slice::from_raw_parts(ptr, len) })
}

fn copy_bytes(data: &[u8]) -> Result<Vec<u8>, String> {
    let mut bytes = Vec::new();
    bytes
        .try_reserve_exact(data.len())
        .map_err(|e| format!("Not enough memory to open file: {e}"))?;
    bytes.extend_from_slice(data);
    Ok(bytes)
}

fn write_temp_file(dir: &str, name: &str, bytes: &[u8]) -> std::io::Result<String> {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let safe: String = name
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '.' || c == '-' || c == '_' { c } else { '_' })
        .collect();
    let path = std::path::Path::new(dir).join(format!("{stamp}_{safe}"));
    std::fs::write(&path, bytes)?;
    Ok(path.to_string_lossy().into_owned())
}

// ===================== 文件读写钩子 =====================

/// 向引擎登记文件读写钩子。`cadcraft-engine` 刻意保持 I/O 无关、wasm 安全（见
/// `crates/engine/src/cmd/file.rs` 顶部注释），真正的 DWG/DXF 解码编码由宿主经
/// `cmd::file::set_io` 注入；缺了这一步，`打开`/`另存`/`插入`/`导入` 全部报
/// "file formats are not available in this build"。桌面 App（`apps/cadcraft/src/main.rs`
/// 的 `install_io`）正是这么接的，鸿蒙侧此前漏掉，导致「打开」点了没反应。
fn install_io() {
    use cadcraft_engine::cmd::file;
    file::set_io(file::IoHooks {
        read: |b, name| cadcraft_io::read(b, name).map_err(|e| e.to_string()),
        write: |d, name| cadcraft_io::write(d, name).map_err(|e| e.to_string()),
        plot: Some(|d, space, opts| {
            cadcraft_io::plotter::plot(d, space, opts).map_err(|e| e.to_string())
        }),
    });
    file::set_image_decoder(|b| cadcraft_io::raster::decode(b).map_err(|e| e.to_string()));
    file::set_write_as(|d, name, o| {
        cadcraft_io::write_with(d, name, &cadcraft_io::SaveOptions {
            version: o.version,
            binary: o.binary,
        })
        .map_err(|e| e.to_string())
    });
    // AutoLISP 的 entget/entmake/entmod 把实体当作 DXF 组来读写。
    file::set_entity_codec(file::EntityCodec {
        groups: cadcraft_io::entity_groups,
        entity: cadcraft_io::entity_from_groups,
    });
}

// ===================== FFI 导出（C++ 边界调用） =====================

/// # Safety
/// 指针/长度对必须指向可读内存直到本调用返回；notify 回调在进程生命周期内保持有效。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_init(ptr: *const u8, len: usize, notify: bridge::Notify) -> bool {
    let Some(data) = (unsafe { bytes(ptr, len) }) else {
        return false;
    };
    let Ok(config) = serde_json::from_slice::<Config>(data) else {
        return false;
    };
    if !config.scale.is_finite() || config.scale <= 0. || config.scale > 8. {
        return false;
    }
    bridge::init(notify);
    // 必须先注入文件读写钩子，否则任何「打开/另存」都会被引擎拒为 "file formats are not
    // available in this build"。`set_io` 用 OnceLock，重复调用只生效一次，故在此安全地幂等登记。
    install_io();
    #[cfg(target_env = "ohos")]
    glog::install();
    if !config.system_theme.is_empty() {
        let dark = config.system_theme.eq_ignore_ascii_case("dark");
        SYSTEM_THEME_TOKEN.store(if dark { 1 } else { -1 }, Ordering::Release);
        appearance::set_dark(dark);
    }
    let (tx, rx) = mpsc::channel();
    if SEND.set(tx).is_err() {
        return true;
    }
    std::thread::Builder::new()
        .name("cadcraft-native".into())
        .spawn(move || {
            if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| worker(config, rx)))
                .is_err()
            {
                bridge::notify(0, "error", "Native host initialization failed", &[]);
            }
        })
        .is_ok()
}

/// # Safety
/// 指针/长度对必须可读直到返回。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_input(ptr: *const u8, len: usize) {
    let Some(data) = (unsafe { bytes(ptr, len) }) else { return; };
    let Ok(value) = serde_json::from_slice(data) else { return; };
    send(Message::Input(value));
}

/// # Safety
/// 同 `sc_init`。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_reply(
    id: u64,
    ok: bool,
    text: *const u8,
    text_len: usize,
    data: *const u8,
    len: usize,
) {
    let Some(text) = (unsafe { bytes(text, text_len) }) else {
        bridge::reply(id, Err("Invalid reply text buffer".into()));
        return;
    };
    let Some(data) = (unsafe { bytes(data, len) }) else {
        bridge::reply(id, Err("Invalid reply data buffer".into()));
        return;
    };
    let text = String::from_utf8_lossy(text).into_owned();
    bridge::reply(
        id,
        if ok {
            copy_bytes(data).map(|data| (text, data))
        } else {
            Err(text)
        },
    );
}

/// # Safety
/// 指针/长度对必须可读直到返回。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_open(text: *const u8, n: usize, data: *const u8, len: usize) {
    if let (Some(text), Some(data)) = (unsafe { bytes(text, n) }, unsafe { bytes(data, len) }) {
        match copy_bytes(data) {
            Ok(data) => send(Message::Open(String::from_utf8_lossy(text).into_owned(), data)),
            Err(error) => bridge::notify(0, "error", &error, &[]),
        }
    }
}

/// # Safety
/// 指针/长度对必须可读直到返回。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_drop(
    text: *const u8,
    n: usize,
    data: *const u8,
    len: usize,
    x: f32,
    y: f32,
) {
    if !x.is_finite() || !y.is_finite() {
        return;
    }
    if let (Some(text), Some(data)) = (unsafe { bytes(text, n) }, unsafe { bytes(data, len) }) {
        send(Message::Drop(
            String::from_utf8_lossy(text).into_owned(),
            data.to_vec(),
            x,
            y,
        ));
    }
}

/// # Safety
/// `text`/`n` 必须可读且 `fd` 打开直到返回。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_drop_file(text: *const u8, n: usize, fd: i32, x: f32, y: f32) {
    if !x.is_finite() || !y.is_finite() {
        return;
    }
    let Some(text) = (unsafe { bytes(text, n) }) else {
        return;
    };
    match unsafe { file_open::duplicate(fd) } {
        Ok(file) => send(Message::DropFile(
            String::from_utf8_lossy(text).into_owned(),
            file,
            x,
            y,
        )),
        Err(error) => bridge::notify(0, "error", &error, &[]),
    }
}

/// # Safety
/// `id` 为自由文本命令标识。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_command(ptr: *const u8, len: usize) {
    let Some(data) = (unsafe { bytes(ptr, len) }) else { return; };
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(data) else { return; };
    let Some(id) = v.get("id").and_then(|v| v.as_str()) else { return; };
    send(Message::Command(
        id.into(),
        v.get("params").cloned().unwrap_or_default(),
    ));
}

/// # Safety
/// `window` 必须是存活的 OHNativeWindow，且已获取一个原生引用；该引用所有权转移给 worker 及其 wgpu surface。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sc_attach(window: usize, w: u32, h: u32) {
    if window != 0 {
        send(Message::Attach(window, w, h));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn sc_resize(w: u32, h: u32) {
    send(Message::Resize(w, h));
}

#[unsafe(no_mangle)]
pub extern "C" fn sc_detach() {
    bridge::cancel();
    send(Message::Detach);
}

#[unsafe(no_mangle)]
pub extern "C" fn sc_frame() {
    send(Message::Frame);
}

#[unsafe(no_mangle)]
pub extern "C" fn sc_active(active: bool) {
    send(Message::Active(active));
}

#[unsafe(no_mangle)]
pub extern "C" fn sc_close() {
    send(Message::Close);
}

// ===================== 仅 OHOS 宿主逻辑 =====================

#[cfg(target_env = "ohos")]
unsafe extern "C" {
    fn sc_request_vsync();
}

#[cfg(target_env = "ohos")]
fn worker(config: Config, rx: mpsc::Receiver<Message>) {
    bridge::notify(0, "stage", "Rust worker entered", &[]);
    let ctx = egui::Context::default();
    // cadcraft 的界面字体在 `CadApp::ui` 首拍经 `theme::install_fonts` 自动安装：先找系统字体
    // （桌面路径，鸿蒙上没有），再退回构建期用 `CRAFT_FONTS_DIR` 嵌入的 craft-fonts（与 web
    // 构建一致，离线可用）；界面语言则由宿主填 `app.system_languages`（下方）。
    let form = form_factor::Form::new(&config.device_type, config.width_vp);
    bridge::notify(
        0,
        "diagnostic",
        &format!(
            "form factor {:?}, {:.0} vp, {:?}",
            form.device_type, form.width_vp, form.width_class
        ),
        &[],
    );

    let mut app = CadApp::new(cadcraft_engine::Session::new(), services());
    // cadcraft 的「跟随系统」（`i18n::Preference::Auto`）从 `CadApp::system_languages` 解析语言
    // （`i18n::locale_language` 只取主语言段，`zh-CN`→`zh`）；桌面 App 正是用 OS locale 填这个
    // 字段（见 `apps/cadcraft/src/main.rs`）。鸿蒙侧由 ArkTS 上报真实 locale 后交到这里。
    if !config.system_locale.is_empty() {
        app.system_languages = config
            .system_locale
            .split_whitespace()
            .map(str::to_string)
            .collect();
    }
    // ArkTS 已把用户在设置里选定的界面语言以代码（如 `zh`/`en`）透传；空串表示「跟随系统」。
    if !config.language.is_empty() {
        if let Some(pref) = cadcraft_ui_egui::i18n::Preference::parse(&config.language) {
            app.ui.interface_language = pref;
        }
    }
    bridge::notify(0, "stage", "editor ready", &[]);

    // 起始逻辑帧（无用户输入）：让 app 在宿主登记系统字体前先跑一次 logic。
    let _ = ctx.run_logic(&egui::RawInput::default(), |ctx| app.logic(ctx));

    let mut render = match render::Render::new(config.display_p3) {
        Ok(render) => render,
        Err(error) => {
            bridge::notify(0, "error", &error, &[]);
            return;
        }
    };
    let ui_pass_in_progress = std::cell::Cell::new(false);
    let mut active = true;
    let mut visible = false;
    let mut deadline: Option<Instant> = None;
    let started = Instant::now();
    let mut events: Vec<egui::Event> = Vec::new();
    let mut input_state = input::State::default();
    let mut close = false;
    // 软键盘显隐：egui 的 TextEdit 获得焦点时会把 `platform_output.ime` 置为 Some，
    // 失焦置 None。只在**状态变化**时通知 ArkTS，避免每帧刷消息。
    let mut ime_shown = false;
    let mut gpu_installed = false;

    ctx.set_request_repaint_callback(|info| send(Message::Wake(info.delay)));
    bridge::notify(0, "ready", "Native host initialized", &[]);

    loop {
        let wait = deadline.map(|d| d.saturating_duration_since(Instant::now()));
        let message = match wait {
            Some(wait) => match rx.recv_timeout(wait) {
                Ok(m) => m,
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    deadline = None;
                    if active && visible && render.attached() {
                        unsafe { sc_request_vsync() };
                    }
                    continue;
                }
                Err(_) => break,
            },
            None => match rx.recv() {
                Ok(m) => m,
                Err(_) => break,
            },
        };
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(
            || -> Result<(), String> {
                match message {
                    Message::Attach(ptr, w, h) => {
                        visible = w > 0 && h > 0;
                        ime_shown = false;
                        render.bind(render::Window(ptr), w, h)?;
                        if !gpu_installed {
                            if let Some(rs) = render.egui_render_state() {
                                // 3D 视口需要带深度/模板缓冲的 RenderState；位数与 render.rs 的
                                // 深度附件格式严格一致，否则 set_pipeline 校验失败、整帧被丢弃。
                                // cadcraft 的 GPU canvas 用 `stencil` 参数承载 depth+stencil 状态；
                                // 与 render.rs 的深度附件同源（Depth24PlusStencil8），否则 set_pipeline 校验失败整帧被丢弃。
                                app.set_wgpu(&rs, Some(render::depth_format()));
                                gpu_installed = true;
                            }
                        }
                        bridge::resume();
                        deadline = Some(Instant::now());
                        bridge::notify(0, "ready", "Native egui / wgpu GLES", &[]);
                    }
                    Message::Resize(w, h) => {
                        visible = w > 0 && h > 0;
                        render.resize(w, h)?;
                        deadline = Some(Instant::now());
                    }
                    Message::Detach => {
                        visible = false;
                        deadline = None;
                        render.detach();
                        input_state.cancel(&mut events);
                        // 表面销毁时输入客户端一定已断：复位状态并显式收起软键盘，
                        // 否则下次 Attach 会以为键盘还开着而不再弹。
                        if ime_shown {
                            ime_shown = false;
                            bridge::notify(0, "ime", "hide", &[]);
                        }
                    }
                    Message::Active(value) => {
                        active = value;
                        if active {
                            bridge::resume();
                            deadline = Some(Instant::now());
                        } else {
                            deadline = None;
                            input_state.cancel(&mut events);
                        }
                    }
                    Message::Input(value) => {
                        if value.kind == "system_theme" {
                            let dark = value.text.eq_ignore_ascii_case("dark");
                            appearance::set_dark(dark);
                            deadline = Some(Instant::now());
                            return Ok(());
                        }
                        input_state.push(value, config.scale, &mut events);
                        deadline = Some(Instant::now());
                    }
                    Message::Open(name, data) => {
                        if let Ok(path) = write_temp_file(&config.files, &name, &data) {
                            app.open_path(std::path::Path::new(&path));
                        }
                        deadline = Some(Instant::now());
                    }
                    Message::Drop(name, data, _x, _y) => {
                        if let Ok(path) = write_temp_file(&config.files, &name, &data) {
                            app.open_path(std::path::Path::new(&path));
                        }
                        deadline = Some(Instant::now());
                    }
                    Message::DropFile(name, file, _x, _y) => {
                        match file_open::read(file) {
                            Ok(data) => {
                                if let Ok(path) = write_temp_file(&config.files, &name, &data) {
                                    app.open_path(std::path::Path::new(&path));
                                }
                            }
                            Err(e) => bridge::notify(0, "error", &e, &[]),
                        }
                        deadline = Some(Instant::now());
                    }
                    Message::Close => {
                        bridge::resume();
                        close = true;
                        deadline = Some(Instant::now());
                    }
                    Message::Wake(delay) => {
                        if active && visible {
                            if let Some(next) = Instant::now().checked_add(delay) {
                                deadline = Some(deadline.map_or(next, |d| d.min(next)));
                            }
                        }
                    }
                    Message::Command(id, params) => {
                        let result = app.run(&id, params);
                        bridge::notify(
                            0,
                            "command",
                            &format!("{id}: {result:?}"),
                            &[],
                        );
                        deadline = Some(Instant::now());
                    }
                    Message::Frame => {
                        if !active || !visible {
                            return Ok(());
                        }
                        if !render.attached() {
                            return Ok(());
                        }
                        let size = egui::vec2(
                            render.width as f32 / config.scale,
                            render.height as f32 / config.scale,
                        );
                        let mut raw = egui::RawInput {
                            screen_rect: Some(egui::Rect::from_min_size(egui::Pos2::ZERO, size)),
                            time: Some(started.elapsed().as_secs_f64()),
                            events: std::mem::take(&mut events),
                            system_theme: appearance::current(),
                            ..Default::default()
                        };
                        let viewport = raw.viewports.entry(egui::ViewportId::ROOT).or_default();
                        viewport.native_pixels_per_point = Some(config.scale);
                        viewport.inner_rect = raw.screen_rect;
                        viewport.focused = Some(true);
                        let validating_close = close;
                        if close {
                            viewport.events.push(egui::ViewportEvent::Close);
                            close = false;
                        }
                        app.raw_input_hook(&ctx, &mut raw);
                        ui_pass_in_progress.set(true);
                        let output = editor_frame(&ctx, &mut app, raw);
                        ui_pass_in_progress.set(false);
                        for command in &output.platform_output.commands {
                            if let egui::OutputCommand::OpenUrl(url) = command {
                                bridge::notify(0, "url", &url.url, &[]);
                            }
                        }
                        // egui 文本焦点变化 → 通知 ArkTS 弹起/收起软键盘（只在变化时发）。
                        let ime_wanted = output.platform_output.ime.is_some();
                        if ime_wanted != ime_shown {
                            ime_shown = ime_wanted;
                            bridge::notify(0, "ime", if ime_wanted { "show" } else { "hide" }, &[]);
                        }
                        let mut commands = Vec::new();
                        let mut repaint_delay: Option<Duration> = None;
                        if let Some(v) = output.viewport_output.get(&egui::ViewportId::ROOT) {
                            commands.extend(v.commands.clone());
                            repaint_delay = Some(v.repaint_delay);
                        }
                        match close_action(validating_close, &commands) {
                            CloseAction::Confirm => bridge::notify(0, "close", "", &[]),
                            CloseAction::Request => {
                                close = true;
                                deadline = Some(Instant::now());
                            }
                            CloseAction::Cancel | CloseAction::None => {}
                        }
                        let painted = render.paint(&ctx, output)?;
                        if first_frame_marker(painted) {
                            bridge::notify(0, "first_frame", "Native UI presented", &[]);
                        }
                        // 按 egui 的 `repaint_delay` 排下一帧：视口在动时它是 0（连续重绘），
                        // 静止时是一个很大的值或 MAX（等输入/vsync 唤醒），避免空转耗电。
                        if painted && active && visible && render.attached() {
                            deadline = match repaint_delay {
                                Some(delay) if delay.is_zero() => Some(Instant::now()),
                                Some(delay) if delay < Duration::from_secs(3600) => {
                                    Some(Instant::now() + delay)
                                }
                                _ => None,
                            };
                        }
                    }
                }
                Ok(())
            },
        ));
        let _ = result;
    }
}

#[cfg(target_env = "ohos")]
#[allow(dead_code)]
fn first_frame_marker(painted: bool) -> bool {
    use std::sync::atomic::{AtomicBool, Ordering};
    static FIRST: AtomicBool = AtomicBool::new(false);
    if painted && !FIRST.swap(true, Ordering::AcqRel) {
        true
    } else {
        false
    }
}

#[cfg(target_env = "ohos")]
fn editor_frame(
    ctx: &egui::Context,
    app: &mut CadApp,
    raw: egui::RawInput,
) -> egui::FullOutput {
    // 与上游宿主一致：每个 pass 的首拍都推进一次 `logic`（内含 file_load/theme/frame_watch
    // 等必须逐帧运行的 tick），随后把 `ui` 画进 CentralPanel。只跑首帧会让界面停摆。
    ctx.run_ui(raw, |ui| {
        if ui.ctx().current_pass_index() == 0 {
            app.logic(ui.ctx());
        }
        app.ui(ui);
    })
}

#[cfg(target_env = "ohos")]
#[derive(Debug, PartialEq, Eq)]
enum CloseAction {
    None,
    Request,
    Cancel,
    Confirm,
}

#[cfg(target_env = "ohos")]
fn close_action(validating: bool, commands: &[egui::ViewportCommand]) -> CloseAction {
    if commands.contains(&egui::ViewportCommand::CancelClose) {
        CloseAction::Cancel
    } else if validating {
        CloseAction::Confirm
    } else if commands.contains(&egui::ViewportCommand::Close) {
        CloseAction::Request
    } else {
        CloseAction::None
    }
}

#[cfg(target_env = "ohos")]
fn services() -> cadcraft_ui_egui::Services {
    // cadcraft 的文件选择是同步闭包（`Fn() -> Option<String>`）：在 worker 线程里发起请求、
    // 阻塞等待 ArkTS 把文件落到沙箱并回传真实路径（open 读、save 写同一路径），期间 UI 线程不受阻。
    cadcraft_ui_egui::Services {
        pick_open: Some(Box::new(|| file_pick("open", ""))),
        pick_save: Some(Box::new(|name| file_pick("save", name))),
        pick_lisp: Some(Box::new(|name| file_pick("lisp", name))),
        // 0.19.0 新增：选 `.pgp` 别名文件（起始文件夹为 Option<&str>，空串即默认）。
        pick_pgp: Some(Box::new(|folder: Option<&str>| file_pick("pgp", folder.unwrap_or("")))),
        no_file_system: false,
    }
}

// 文件选择：向 ArkTS 同步请求一个沙箱路径。ArkTS 已把文件落到应用沙箱并回传**真实文件系统路径**
// （open/lisp 时 Rust 读该路径，save 时写该路径）；这里不再二次落盘，否则 save 会写到临时位置。
#[cfg(target_env = "ohos")]
fn file_pick(kind: &str, name: &str) -> Option<String> {
    log::info!("[cc] file_pick request kind={kind} name={name:?}");
    let result = bridge::request(kind, name, &[]).and_then(|(path, _bytes)| {
        if path.is_empty() {
            log::warn!("[cc] file_pick kind={kind} returned an empty path");
            Err("empty path".to_string())
        } else {
            Ok(path)
        }
    });
    match result {
        Ok(path) => {
            log::info!("[cc] file_pick kind={kind} resolved path={path:?}");
            Some(path)
        }
        Err(e) => {
            log::warn!("[cc] file_pick kind={kind} failed: {e}");
            bridge::notify(0, "error", &e, &[]);
            None
        }
    }
}

#[cfg(not(target_env = "ohos"))]
fn worker(_config: Config, _rx: mpsc::Receiver<Message>) {
    bridge::notify(0, "error", "Native host requires an OHOS target", &[]);
}
