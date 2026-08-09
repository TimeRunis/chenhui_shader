# -*- coding: utf-8 -*-
# 重建部署 zip:收集 晨辉光影/ 全部文件 -> staging zip -> os.replace 到游戏目录
# 仅用 Python 标准库(os/re/zipfile)。zip 被游戏占用时 os.replace 抛错 -> LOCKED,
# 此时 staging 已就绪,游戏关闭后重跑本脚本即可完成替换。
import os, io, re, zipfile, sys, shutil, tempfile

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "晨辉光影")
ZIP = r"H:\Game\MineCraft\1.20.1\.minecraft\shaderpacks\晨辉光影.zip"
PREFIX = "晨辉光影"  # zip 内顶层前缀(与游戏识别的包名一致)

def main():
    files = []
    for dp, dn, fns in os.walk(SRC):
        for fn in fns:
            full = os.path.join(dp, fn)
            rel = os.path.relpath(full, SRC).replace("\\", "/")
            files.append((full, PREFIX + "/" + rel))
    files.sort(key=lambda x: x[1].lower())
    print("收集 %d 个文件" % len(files))

    # staging:与目标同盘,保证 os.replace 原子
    tmp = ZIP + ".staging.tmp"
    try:
        if os.path.exists(tmp):
            os.remove(tmp)
    except OSError:
        pass
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, allowZip64=True) as z:
        for full, arc in files:
            z.write(full, arc)
    size = os.path.getsize(tmp)
    print("staging zip: %.1f KB (%d 条目)" % (size / 1024.0, len(files)))

    try:
        os.replace(tmp, ZIP)
        print("已部署:", ZIP)
    except PermissionError:
        print("LOCKED: 游戏正在运行(或 zip 被占用)。关闭游戏后再次运行本脚本完成替换。")
        sys.exit(1)

if __name__ == "__main__":
    main()
