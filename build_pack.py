# -*- coding: utf-8 -*-
# 临时打包脚本：晨辉光影/ -> shaderpacks/晨辉光影.zip（保留顶层前缀）
import zipfile, os, sys

src = '晨辉光影'
out = r'H:\Game\MineCraft\1.20.1\.minecraft\shaderpacks\晨辉光影.zip'
top = '晨辉光影'

with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(src):
        for f in sorted(files):
            p = os.path.join(root, f)
            rel = os.path.relpath(p, src).replace(os.sep, '/')
            z.write(p, top + '/' + rel)
        for d in sorted(dirs):
            rel = os.path.relpath(os.path.join(root, d), src).replace(os.sep, '/')
            z.writestr(zipfile.ZipInfo(top + '/' + rel + '/'), '')

names = [i.filename for i in zipfile.ZipFile(out).infolist()]
print('entries:', len(names))
for n in names:
    if 'composite1.fsh' in n or 'shaders.properties' in n or n.endswith('shadow.vsh'):
        print('  ', n)
