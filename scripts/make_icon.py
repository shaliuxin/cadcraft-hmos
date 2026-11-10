#!/usr/bin/env python3
"""生成/安装鸿蒙应用图标（1024x1024 RGBA，圆角已烘进图里）。

cadcraft 的上游图标本身就是一张「成品启动器图标」：蓝色网格底 + 三角板（绘图
三角尺）+ 圆弧 + 橙色端点，1024x1024、四角透明（圆角已内建）。

这与 photocraft 那张「透明等距 S 标志 + 需自绘蓝底」不同，所以这里不做
whiten()/gradient 二次加工（那会把黑描边和网格一起重染，毁掉原图），而是直接
把上游 1024 成品图落到 AppScope 与 entry 两处，供 build-profile 打包时引用。

用法：
    python scripts/make_icon.py                # 校验上游图标并写入 AppScope 与 entry 两处
    python scripts/make_icon.py out1.png ...    # 只写入指定的目标文件
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# 上游 cadcraft 成品图标（1024x1024 RGBA，圆角已内建）。
# 若上游调整了目录结构，改这里即可。
LOGO = os.path.join(
    ROOT, "..", "cadcraft", "assets", "app-icon", "cadcraft-1024.png"
)

TARGETS = [
    os.path.join(ROOT, "AppScope", "resources", "base", "media", "app_icon.png"),
    os.path.join(ROOT, "entry", "src", "main", "resources", "base", "media", "app_icon.png"),
]

SIZE = 1024


def validate(path: str) -> None:
    try:
        from PIL import Image
    except ImportError:
        # 没装 Pillow 也能跑，只是无法校验尺寸/圆角；这里放宽。
        print(f"  (Pillow 不可用，跳过尺寸校验) {path}", file=sys.stderr)
        return
    im = Image.open(path)
    im.load()
    if im.size != (SIZE, SIZE):
        print(f"warning: 上游图标尺寸 {im.size} != 期望 (1024,1024)，仍会使用", file=sys.stderr)
    if im.mode != "RGBA":
        print(f"warning: 上游图标模式 {im.mode}（期望 RGBA）", file=sys.stderr)
    else:
        corner = im.getpixel((0, 0))[3]
        if corner != 0:
            print("note: 四角不透明（圆角可能未内建），鸿蒙启动器将按原图形状显示", file=sys.stderr)
    print(f"  source: {path}  size={im.size} mode={im.mode}", file=sys.stderr)


def main(argv: list) -> int:
    if not os.path.exists(LOGO):
        print(f"missing upstream icon: {LOGO}", file=sys.stderr)
        return 1
    paths = [os.path.abspath(a) for a in argv] if argv else list(TARGETS)
    validate(LOGO)
    for path in paths:
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        # 直接拷贝成品图；不重采样、不改色，保留上游的圆角与配色。
        with open(LOGO, "rb") as src, open(path, "wb") as dst:
            dst.write(src.read())
        print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
