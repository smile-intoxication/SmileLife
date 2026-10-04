#!/usr/bin/env python3
"""生成 App 图标（1024x1024，**无 alpha 通道**）。

为什么要用脚本生成、而不是往仓库里塞一个二进制 PNG：
  1. 可复现、可改、可 review —— 二进制文件在 diff 里什么都看不出来；
  2. 能顺手保证 App Store 的两条硬性要求（下面 `_flatten` 就是干这个的）。

⚠️ App Store 对图标的两条硬性要求（违反会被 exportArchive / 上传直接拒收）：
  1. **不能有 alpha 通道**（"can't be transparent nor contain an alpha channel"）
  2. iOS 需要 1024x1024 的 App Store 图标

本项目走 Apple 的 **single size** 方案（官方文档 "Configuring your app icon using
an asset catalog" 明说 iOS 和 watchOS 都能从**一张 1024x1024** 自动派生出全部尺寸），
所以只需要生成这一张，120x120 之类的由 actool 在构建时派生。

用法：
    python ci/make-app-icon.py
"""

import json
import math
import os

from PIL import Image, ImageDraw

# ——— 配色：上浅下深的暖红渐变（心率类 app 一眼能认出来）———
TOP = (255, 107, 138)
BOTTOM = (198, 18, 68)

SIZE = 1024

ASSETS = {
    # 输出目录 : asset catalog 里的 platform 值
    "ios/Assets.xcassets": "ios",
    "watch/Assets.xcassets": "watchos",
}


def vertical_gradient(w, h, top, bottom):
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / (h - 1)
        c = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        d.line([(0, y), (w, y)], fill=c)
    return img


def heart_mask(w, h):
    """用心形参数曲线生成遮罩：x = 16 sin^3 t, y = 13 cos t - 5 cos 2t - 2 cos 3t - cos 4t"""
    pts = []
    for i in range(1441):
        t = math.radians(i * 0.25)
        x = 16 * math.sin(t) ** 3
        y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
        pts.append((x, y))

    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    span_x = max(xs) - min(xs)
    span_y = max(ys) - min(ys)

    # 心形占画布宽度的 62%，然后按包围盒精确居中
    scale = (w * 0.62) / span_x
    cx = w / 2
    cy = h / 2
    mid_x = (max(xs) + min(xs)) / 2
    mid_y = (max(ys) + min(ys)) / 2

    mapped = [(cx + (x - mid_x) * scale, cy - (y - mid_y) * scale) for x, y in pts]

    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).polygon(mapped, fill=255)
    return m


def ecg_mask(w, h):
    """标准 PQRST 心电波形。"""
    # (x, y) 都是 0~1 的归一化坐标，y=0.52 是基线
    shape = [
        (0.055, 0.520),
        (0.260, 0.520),
        (0.300, 0.487),   # P 波
        (0.340, 0.520),
        (0.375, 0.548),   # Q
        (0.415, 0.352),   # R 尖峰
        (0.455, 0.618),   # S
        (0.492, 0.520),
        (0.545, 0.474),   # T 波
        (0.605, 0.520),
        (0.945, 0.520),
    ]
    xy = [(x * w, y * h) for x, y in shape]

    stroke = round(w * 0.030)
    m = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(m)
    d.line(xy, fill=255, width=stroke, joint="curve")
    # line() 的端点不是圆的，补上圆头
    r = stroke / 2
    for px, py in xy:
        d.ellipse([px - r, py - r, px + r, py + r], fill=255)
    return m


def build_icon():
    bg = vertical_gradient(SIZE, SIZE, TOP, BOTTOM)
    icon = bg.copy()

    # 1) 白色实心心
    icon.paste((255, 255, 255), (0, 0), heart_mask(SIZE, SIZE))

    # 2) 用心电线把背景"切"出来 —— 这样线在心上显示为渐变红、在背景上自然隐形，
    #    比硬画一条固定颜色的线好看得多（也更耐缩放）。
    icon.paste(bg, (0, 0), ecg_mask(SIZE, SIZE))

    return icon.convert("RGB")  # ← 关键：确保没有 alpha 通道


def write_json(path, obj):
    """按 Xcode 自己的格式写 JSON —— 注意 Xcode 用的是 `"key" : value`（冒号两边都有空格），
    而 json.dump 默认是 `"key": value`。刻意对齐 Xcode，免得以后用 Xcode 打开时被重排。"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    text = json.dumps(obj, indent=2, ensure_ascii=False).replace('": ', '" : ')
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
        f.write("\n")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)

    icon = build_icon()

    for rel, platform in ASSETS.items():
        catalog = os.path.join(root, rel)
        iconset = os.path.join(catalog, "AppIcon.appiconset")
        os.makedirs(iconset, exist_ok=True)

        png = os.path.join(iconset, "AppIcon-1024.png")
        icon.save(png, "PNG", optimize=True)

        write_json(os.path.join(catalog, "Contents.json"),
                   {"info": {"author": "xcode", "version": 1}})

        write_json(os.path.join(iconset, "Contents.json"), {
            "images": [{
                "filename": "AppIcon-1024.png",
                "idiom": "universal",
                "platform": platform,
                "size": "1024x1024",
            }],
            "info": {"author": "xcode", "version": 1},
        })

        # 自检：必须是无 alpha 的 RGB，否则 App Store 会拒收
        check = Image.open(png)
        assert check.mode == "RGB", "icon must have no alpha channel, got %s" % check.mode
        assert check.size == (SIZE, SIZE), check.size

        print("wrote %s  (%s, %dx%d, no alpha)"
              % (os.path.relpath(png, root), check.mode, check.size[0], check.size[1]))


if __name__ == "__main__":
    main()
