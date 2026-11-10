import native from 'libcadcraft.so';
import { common } from '@kit.AbilityKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { i18n } from '@kit.LocalizationKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';
import { inputMethod } from '@kit.IMEKit';
import { SYSTEM_THEME_DARK, SYSTEM_THEME_LIGHT } from '../SystemTheme';

// Mirrors the Rust `Config` deserialized in native/rust/src/lib.rs.
class NativeConfig {
  files: string;
  documents: string;
  scale: number;
  language: string;
  systemLocale: string;
  displayP3: boolean;
  systemTheme: string;
  fullscreen: boolean;
  deviceType: string;
  widthVp: number;
  constructor(files: string, documents: string, scale: number, language: string, systemLocale: string,
              displayP3: boolean, systemTheme: string, fullscreen: boolean, deviceType: string, widthVp: number) {
    this.files = files;
    this.documents = documents;
    this.scale = scale;
    this.language = language;
    this.systemLocale = systemLocale;
    this.displayP3 = displayP3;
    this.systemTheme = systemTheme;
    this.fullscreen = fullscreen;
    this.deviceType = deviceType;
    this.widthVp = widthVp;
  }
}

/**
 * 系统语言的完整 BCP-47 标签（如 `zh-Hans-CN`）：Rust 侧用它决定界面语言，也据此挑中文字体。
 * getSystemLocale 在个别设备上可能不可用，退回只带语言的 getSystemLanguage。
 */
function systemLocaleTag(): string {
  try {
    const locale = i18n.System.getSystemLocale();
    if (locale && locale.length > 0) {
      return locale;
    }
  } catch (error) {
    console.info(`System locale unavailable: ${(error as Error).message}`);
  }
  return i18n.System.getSystemLanguage();
}

class NativeMessage { kind: string = ''; text: string = ''; }

@Entry
@Component
struct Index {
  @State private failure: string = '';
  @State private initialized: boolean = false;
  @State private startupVisible: boolean = true;
  @State private startupOpacity: number = 1;
  private alive: boolean = false;
  private generation: number = 0;
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
  @State private deviceScale: number = 1;
  // 中文输入法（官方「自定义编辑框」方案，与 DeckCraft/WordCraft/GridCraft/SolidCraft 同一修法）：
  // attach 前必须先有一个获焦的 ArkUI 编辑组件（XComponent 原生表面不算），
  // 且监听器必须在 attach 成功之后注册（提前注册抛 12800009，键盘完全不弹）。
  private imeController: inputMethod.InputMethodController | undefined = undefined;
  private imeAttached: boolean = false;
  private imeShown: boolean = false;
  private imeInComposition: boolean = false;
  private imeBound: boolean = false;
  private imeWanted: boolean = false;

  aboutToAppear(): void {
    console.info('CADCraft native page appearing');
    this.alive = true;
    this.generation++;
    this.initializeHost(this.generation);
    // 启动兜底：遮罩盖在 XComponent 之上，若首帧通知因任何原因没到，它会永久遮住原生画面
    // （表现为满屏漆黑）。到点必须揭开。
    setTimeout((): void => { this.hideStartup(); }, 4000);
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.generation++;
    this.initialized = false;
    native.active(false);
  }

  private async initializeHost(generation: number): Promise<void> {
    try {
      let scale: number = this.getUIContext().vp2px(1);
      this.deviceScale = scale;
      let systemTheme = AppStorage.get<string>('cadcraftSystemTheme') ?? '';
      if (systemTheme !== SYSTEM_THEME_DARK && systemTheme !== SYSTEM_THEME_LIGHT) {
        systemTheme = '';
      }
      const filesDir = this.context.filesDir;
      const documents = filesDir + '/Documents';
      try { fileIo.mkdirSync(documents, true); } catch (e) { /* exists */ }
      native.init(JSON.stringify(new NativeConfig(
          filesDir, documents, scale, i18n.System.getSystemLanguage(), systemLocaleTag(), false, systemTheme,
          false, deviceInfo.deviceType, this.getUIContext().px2vp(display.getDefaultDisplaySync().width))),
        (id: number, message: string, data: ArrayBuffer): void => { this.receive(id, message, data); });
      this.initialized = true;
      this.failure = '';
      // A file launched from the system shares its URI through onNewWant.
      const want = AppStorage.get<string>('cadcraftOpenWant');
      if (want && want.length > 0) {
        AppStorage.setOrCreate('cadcraftOpenWant', '');
        this.openWant(want);
      }
    } catch (error) {
      if (this.alive && generation === this.generation) { this.failure = (error as Error).message; }
    }
  }

  private openWant(uri: string): void {
    try {
      const path = new fileUri.FileUri(uri).path;
      const name = path.length > 0 ? path.substring(path.lastIndexOf('/') + 1) : 'document';
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const bytes = this.readAll(file.fd);
      fileIo.closeSync(file);
      native.open(name, bytes);
    } catch (error) {
      console.error(`CADCraft open want failed: ${(error as Error).message}`);
    }
  }

  private readAll(fd: number): ArrayBuffer {
    const chunks: ArrayBuffer[] = [];
    let total = 0;
    const bufSize = 1024 * 1024;
    while (true) {
      const buf = new ArrayBuffer(bufSize);
      const n = fileIo.readSync(fd, buf);
      if (n <= 0) { break; }
      chunks.push(n === bufSize ? buf : buf.slice(0, n));
      total += n;
    }
    const out = new Uint8Array(total);
    let offset = 0;
    for (const c of chunks) {
      out.set(new Uint8Array(c), offset);
      offset += c.byteLength;
    }
    return out.buffer;
  }

  /**
   * 把 picker 授权的 `src`（完整 URI 或裸路径）落盘到沙箱 `dst`。
   * 用 openSync(URI) 打开再读取，而不是 copyFileSync：picker 授予的是「URI 级权限」，
   * 对网络/外部挂载盘（file://docs/storage/userExternal/<IP>/...）这类 URI，copyFileSync
   * 走裸路径解析会失败（"No such file or directory" / errno 107），而 openSync 按授权 URI 读能成功。
   * 成功返回 true，失败返回 false（调用方继续尝试其它来源）。
   */
  private copyViaOpenSync(src: string, dst: string): boolean {
    try {
      const file = fileIo.openSync(src, fileIo.OpenMode.READ_ONLY);
      try {
        const data = this.readAll(file.fd);
        const out = fileIo.openSync(dst, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
        try {
          fileIo.writeSync(out.fd, data);
        } finally {
          fileIo.closeSync(out);
        }
        return true;
      } finally {
        fileIo.closeSync(file);
      }
    } catch (e) {
      console.warn(`CADCraft pick open: openSync(${src}) failed (${(e as Error).message})`);
      return false;
    }
  }

  private receive(id: number, message: string, data: ArrayBuffer): void {
    const request = JSON.parse(message) as NativeMessage;
    console.info(`CADCraft native ${request.kind}: ${request.text}`);
    if (!this.alive) {
      if (id > 0) { native.reply(id, false, 'cancelled', new ArrayBuffer(0)); }
      return;
    }
    if (request.kind === 'error') {
      this.failure = request.text;
    } else if (request.kind === 'ready' || request.kind === 'first_frame') {
      this.failure = '';
      if (request.kind === 'first_frame') { this.revealEditor(); }
    } else if (request.kind === 'close') {
      this.context.terminateSelf();
    } else if (request.kind === 'url') {
      this.context.startAbility({ action: 'ohos.want.action.viewData', uri: request.text })
        .catch((error: BusinessError) => { console.error(`External link: ${error.message}`); });
    } else if (request.kind === 'open' || request.kind === 'file') {
      this.pickDocument(id, false);
    } else if (request.kind === 'save') {
      this.pickSave(id, request.text);
    } else if (request.kind === 'ime') {
      // Rust 通知：egui 文本字段获得/失去焦点 → 弹起/收起软键盘。
      this.setImeKeyboard(request.text === 'show');
    }
  }

  // ===================== 中文输入法（IME） =====================
  // 鸿蒙软键盘中文输入法走 InputMethod 框架，不经 XComponent 原始按键事件。
  // 顺序（真机实测，不可颠倒）：锚点获焦 → attach(true) → **attach 成功后**注册监听。

  private imeControllerOrGet(): inputMethod.InputMethodController | undefined {
    if (this.imeController) {
      return this.imeController;
    }
    try {
      const controller: inputMethod.InputMethodController = inputMethod.getController();
      this.imeController = controller;
      return controller;
    } catch (error) {
      console.error(`CADCraft IME controller failed: ${(error as Error).message}`);
      return undefined;
    }
  }

  private bindImeListeners(controller: inputMethod.InputMethodController): void {
    if (this.imeBound) {
      return;
    }
    try {
      // insertText = 已确认上屏文本；setPreviewText = 拼音组合态；finishTextPreview = 组合结束；
      // deleteLeft = 退格（组合态内由键盘自行处理）；sendFunctionKey = 回车；sendKeyboardStatus = 显隐。
      controller.on('insertText', (text: string): void => { this.sendIme('commit', text); });
      controller.on('setPreviewText', (text: string, _range: inputMethod.Range): void => {
        this.imeInComposition = (text.length > 0);
        this.sendIme('preedit', text);
      });
      controller.on('finishTextPreview', (): void => { this.imeInComposition = false; this.sendIme('preedit', ''); });
      controller.on('deleteLeft', (length: number): void => {
        if (!this.imeInComposition) { this.sendIme('delete', String(length)); }
      });
      controller.on('sendFunctionKey', (_key: inputMethod.FunctionKey): void => { this.sendIme('enter', ''); });
      controller.on('sendKeyboardStatus', (status: inputMethod.KeyboardStatus): void => {
        this.imeShown = (status === inputMethod.KeyboardStatus.SHOW);
      });
      this.imeBound = true;
      console.info('CADCraft IME listeners bound');
    } catch (error) {
      console.warn(`CADCraft IME bind failed: ${(error as Error).message}`);
    }
  }

  private async setImeKeyboard(show: boolean): Promise<void> {
    if (!this.alive) {
      return;
    }
    this.imeWanted = show;
    const controller = this.imeControllerOrGet();
    if (!controller) {
      return;
    }
    if (show) {
      try {
        this.getUIContext().getFocusController().requestFocus('cadcraft-ime-anchor');
      } catch (error) {
        console.warn(`CADCraft IME anchor focus failed: ${(error as Error).message}`);
      }
      try {
        await controller.attach(true, this.imeTextConfig());
        this.imeAttached = true;
        this.imeShown = true;
        console.info('CADCraft IME attached');
      } catch (error) {
        console.warn(`CADCraft IME attach failed: ${(error as Error).message}`);
        try {
          await controller.showTextInput(inputMethod.RequestKeyboardReason.OTHER);
          this.imeAttached = true;
          this.imeShown = true;
        } catch (e2) {
          console.warn(`CADCraft IME show failed: ${(e2 as Error).message}`);
        }
      }
      if (this.imeAttached) {
        this.bindImeListeners(controller);
        try {
          // PC 模式/外接键盘下 attach(true) 可能只出现悬浮工具栏，TOUCH 理由尝试强制展开面板。
          await controller.showTextInput(inputMethod.RequestKeyboardReason.TOUCH);
        } catch (error) {
          console.warn(`CADCraft IME touch-show failed: ${(error as Error).message}`);
        }
      }
    } else {
      this.imeInComposition = false;
      try {
        if (this.imeAttached) { await controller.hideTextInput(); }
      } catch (error) {
        console.warn(`CADCraft IME hide failed: ${(error as Error).message}`);
      }
      try {
        if (this.imeAttached) { await controller.detach(); }
      } catch (error) {
        // 未绑定 / 重复 detach：忽略。
      }
      this.imeAttached = false;
      this.imeShown = false;
    }
  }

  private imeTextConfig(): inputMethod.TextConfig {
    return {
      inputAttribute: {
        textInputType: inputMethod.TextInputType.TEXT,
        enterKeyType: inputMethod.EnterKeyType.NEWLINE,
        consumeKeyEvents: true,
      },
    };
  }

  private sendIme(op: string, text: string): void {
    if (!this.alive) {
      return;
    }
    native.input(JSON.stringify({ kind: 'ime', op, text }));
  }

  private async pickDocument(id: number, _gallery: boolean): Promise<void> {
    const generation = this.generation;
    try {
      const uris = await new picker.DocumentViewPicker(this.context).select(new picker.DocumentSelectOptions());
      if (!this.alive || generation !== this.generation || uris.length === 0) {
        console.info(`CADCraft pick open: cancelled (alive=${this.alive} gen ${generation}!=${this.generation} n=${uris.length})`);
        native.reply(id, false, 'cancelled', new ArrayBuffer(0));
        return;
      }
      const uriStr = uris[0];
      const info = new fileUri.FileUri(uriStr);
      const baseName = info.name || uriStr.substring(uriStr.lastIndexOf('/') + 1) || 'document';
      console.info(`CADCraft pick open: uri=${uriStr} path=${info.path} name=${baseName}`);

      // 把 picker 授权的文件落进沙箱 .inbox，Rust 侧再用 std::fs 按路径读取。
      // 注意：writeSync 的 buffer 参数必须是 ArrayBuffer/string，传 Uint8Array 视图会触发
      // "Invalid arraybuffer or options"（readAll 返回的就是 ArrayBuffer，符合要求）。
      const inbox = this.context.filesDir + '/.inbox';
      try {
        fileIo.mkdirSync(inbox, true);
      } catch (e) {
        // 目录已存在。
      }
      const dst = inbox + '/' + Date.now() + '_' + baseName;
      // 落盘顺序：先按 picker 完整 URI 的授权读（对网络/外部挂载盘 file://docs/... 也能读到），
      // 再按解码后的裸路径读，最后才退回 copyFileSync（兼容本地普通文件）。
      let via = '';
      if (uriStr.length > 0 && this.copyViaOpenSync(uriStr, dst)) {
        via = 'picker URI';
      } else if (info.path.length > 0 && this.copyViaOpenSync(info.path, dst)) {
        via = 'decoded path';
      } else {
        fileIo.copyFileSync(uriStr, dst);
        via = 'copyFileSync (fallback)';
      }
      const size = fileIo.statSync(dst).size;
      console.info(`CADCraft pick open: copied ${size} bytes -> ${dst} via ${via}`);
      // 把沙箱路径回传给 Rust（open/file 读此路径，save 写此路径）。
      native.reply(id, true, dst, new ArrayBuffer(0));
    } catch (error) {
      const err = error as Error;
      console.error(`CADCraft pick open FAILED: ${err.message}\n${err.stack ?? ''}`);
      native.reply(id, false, String(err.message ?? error), new ArrayBuffer(0));
    }
  }

  // v1 limitation: the chosen name is written into the app sandbox (filesDir). True OS-level
  // "save to user location" needs a write-back request loop and is deferred.
  private async pickSave(id: number, suggested: string): Promise<void> {
    const generation = this.generation;
    try {
      const name = suggested.length > 0 ? suggested : 'drawing.dwg';
      if (!this.alive || generation !== this.generation) {
        native.reply(id, false, 'cancelled', new ArrayBuffer(0));
        return;
      }
      const path = this.context.filesDir + '/' + name;
      console.info(`CADCraft save (sandbox) -> ${path}`);
      native.reply(id, true, path, new ArrayBuffer(0));
    } catch (error) {
      native.reply(id, false, (error as Error).message, new ArrayBuffer(0));
    }
  }

  private hideStartup(): void {
    if (!this.alive || !this.startupVisible) { return; }
    this.startupOpacity = 0;
    this.startupVisible = false;
  }

  private revealEditor(): void {
    if (!this.startupVisible) { return; }
    // 遮罩必须无条件消失：动画在任何环节失败都不能把原生画面永久盖住。
    try {
      this.getUIContext().animateTo({ duration: 320, curve: Curve.EaseOut, onFinish: (): void => this.hideStartup() },
        (): void => { this.startupOpacity = 0; });
    } catch (error) {
      console.warn(`Reveal animation failed: ${(error as Error).message}`);
      this.hideStartup();
    }
    // 兜底：动画若被系统丢弃（回调线程/丢帧），首帧之后必须让原生画面露出来。
    setTimeout((): void => this.hideStartup(), 600);
  }

  build() {
    Stack() {
      if (this.initialized) {
        XComponent({ id: 'cadcraft-native', type: XComponentType.SURFACE, libraryname: 'cadcraft' })
          .width('100%').height('100%')
          .onLoad((): void => {
            try { this.getUIContext().getFocusController().requestFocus('cadcraft-editor'); } catch (e) {}
          })
          // 不设 focusOnTouch：打字期间点击画布若把焦点抢回 XComponent（非编辑代理），
          // 会断开输入法绑定导致键盘收起；触摸/指针事件不经 ArkUI 焦点，不受影响。
          .id('cadcraft-editor').focusable(true).defaultFocus(true)
      }
      // 隐藏的 IME 锚点：输入法框架只认「获得焦点的编辑组件」为可输入位置，
      // attach 前必须先聚焦它（官方自定义编辑框方案）。
      Text('')
        .id('cadcraft-ime-anchor')
        .focusable(true)
        .width(1).height(1)
        .opacity(0)
        .hitTestBehavior(HitTestMode.None)
        .onBlur((): void => {
          if (this.imeAttached) {
            this.imeAttached = false;
            this.imeShown = false;
            console.info('CADCraft IME anchor blurred, binding reset');
          }
        })
      if (this.startupVisible) {
        Column() {
          Column({ space: 18 }) {
            Image($r('app.media.app_icon')).width(76).height(76).borderRadius(18)
            Text('CADCraft').fontSize(30).fontWeight(FontWeight.Medium).fontColor('#F4F4F5')
            Row({ space: 10 }) {
              LoadingProgress().width(18).height(18).color('#A5BFFF')
              Text(this.initialized ? '正在启动编辑器…' : '正在准备文档目录…')
                .fontSize(14).fontColor('#B8BAC2')
            }
          }
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor('#10203F').opacity(this.startupOpacity)
        .hitTestBehavior(HitTestMode.Block)
      }
      if (this.failure.length > 0) {
        Column() {
          Text('CADCraft 原生运行错误').fontSize(20).fontColor('#FFFFFF')
          Text(this.failure).fontSize(14).fontColor('#FFFFFF').margin({ top: 12 })
          if (!this.initialized) {
            Button('重试').onClick((): void => { this.failure = ''; this.initializeHost(this.generation); })
          } else {
            Button('关闭提示').onClick((): void => { this.failure = ''; })
          }
        }.padding(24).backgroundColor('#DD262626').borderRadius(8).width('80%')
      }
    }.width('100%').height('100%').backgroundColor('#262626')
  }
}
