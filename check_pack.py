# -*- coding: utf-8 -*-
"""晨辉光影 静态一致性检查"""
import os, re, sys, io
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "晨辉光影", "shaders")
errors = []
warns = []

def err(msg):
    errors.append(msg)
def warn(msg):
    warns.append(msg)

# ---------- 1. 收集所有 .fsh 中的选项定义（含维度子目录 world0/world1/world-1） ----------
fsh_files = []
for dp, dn, fnl in os.walk(ROOT):
    if os.path.basename(dp) == "lib":
        continue
    for fn in fnl:
        if fn.endswith(".fsh"):
            fsh_files.append(os.path.join(dp, fn))
defs = {}            # option -> set of (file, define_line)
bool_opts = set()
int_opts = set()
value_lists = {}     # option -> [values]
used_in = {}         # option -> set of files that reference it (via #if/#ifdef/#ifndef or direct use)

opt_re = re.compile(r'^\s*#\s*define\s+([A-Za-z_][A-Za-z0-9_]*)(\s+([-0-9.]+))?\s*(//\s*(.*))?$', re.M)

for fn in fsh_files:
    path = os.path.join(ROOT, fn)
    with io.open(path, encoding="utf-8") as f:
        content = f.read()
    for m in opt_re.finditer(content):
        name, _, val, _, comment = m.group(1), m.group(2), m.group(3), m.group(4), m.group(5)
        if name in ("ifdef", "define", "version", "if", "else", "endif", "include"):
            continue
        defs.setdefault(name, set()).add(fn)
        if val is None:
            bool_opts.add(name)
        else:
            int_opts.add(name)
            if comment and "[" in comment:
                lst = comment.split("[", 1)[1].split("]", 1)[0]
                value_lists[name] = [v.strip() for v in lst.split()]
    # 引用检查
    for m in re.finditer(r'#\s*(?:ifdef|ifndef)\s+([A-Za-z_]\w*)', content):
        used_in.setdefault(m.group(1), set()).add(fn)
    for m in re.finditer(r'#\s*if\s+([A-Za-z_]\w*)', content):
        used_in.setdefault(m.group(1), set()).add(fn)

# ---------- 2. 选项定义一致性 ----------
for name, files in defs.items():
    if len(files) > 1:
        lines = set()
        for fn in files:
            with io.open(os.path.join(ROOT, fn), encoding="utf-8") as f:
                for m in opt_re.finditer(f.read(), re.M):
                    if m.group(1) == name:
                        lines.add(m.group(0).strip())
        if len(lines) > 1:
            err("选项 %s 在不同文件中定义不一致: %s" % (name, sorted(lines)))
    # 每个定义选项必须有 GUI 注释（bool 或带值列表的 int）
    for fn in files:
        with io.open(os.path.join(ROOT, fn), encoding="utf-8") as f:
            for m in opt_re.finditer(f.read(), re.M):
                if m.group(1) == name and not m.group(4) and not (m.group(5) and "[" in m.group(5)):
                    warn("选项 %s 在 %s 中缺少 GUI 注释" % (name, fn))

# ---------- 3. lang 键检查 ----------
lang_path = os.path.join(ROOT, "lang", "zh_CN.lang")
lang = io.open(lang_path, encoding="utf-8").read()
for name in defs:
    if ("option.%s=" % name) not in lang:
        err("lang 缺少选项中文名: option.%s" % name)
    if ("option.%s.comment=" % name) not in lang:
        warn("lang 缺少选项说明: option.%s.comment" % name)
    if name in bool_opts and ("#ifdef %s" % name) not in " ".join(open(os.path.join(ROOT, f), encoding="utf-8").read() for f in fsh_files):
        err("布尔选项 %s 从未被 #ifdef 引用（无法被识别）" % name)
# lang 中多余的 option 键（仅匹配带 "=" 的键，避免 option.X 与 option.X.comment 重复报告）
# shadowMapResolution/shadowDistance 是 Iris 内置选项（非 #define），由 Iris 自身处理
BUILTIN_OPTS = ("shadowMapResolution", "shadowDistance")
for m in re.finditer(r'^option\.([A-Za-z_]\w*)\s*=', lang, re.M):
    if m.group(1) not in defs and m.group(1) not in BUILTIN_OPTS:
        warn("lang 中存在未定义的选项: %s" % m.group(1))

# ---------- 4. 使用选项的文件必须定义了它 ----------
for name, files in used_in.items():
    if name in ("FOG",):
        continue
    if name not in defs:
        err("选项 %s 被引用但从未定义" % name)
        continue
    for fn in files:
        if fn not in defs[name]:
            err("选项 %s 在 %s 中被引用但未定义（规则：使用处必须定义）" % (name, fn))

# ---------- 5. 预设值检查 ----------
props = io.open(os.path.join(ROOT, "shaders.properties"), encoding="utf-8").read()
for pm in re.finditer(r'^profile\.(\S+)=(.*)$', props, re.M):
    pname, vals = pm.group(1), pm.group(2).split()
    for v in vals:
        if v.startswith("!"):
            opt = v[1:]
            if opt not in bool_opts:
                err("预设 %s 对非布尔选项 %s 使用 ! 语法" % (pname, opt))
        elif ":" in v:
            opt, val = v.split(":", 1)
            if opt not in int_opts:
                err("预设 %s 设置了未定义选项 %s" % (pname, opt))
            elif opt in value_lists and val not in value_lists[opt]:
                err("预设 %s 的值 %s 不在 %s 的可选列表 %s 中" % (pname, val, opt, value_lists[opt]))
        else:
            if v not in bool_opts:
                err("预设 %s 的布尔项 %s 未定义" % (pname, v))

# ---------- 6. RENDERTARGETS 与括号平衡 ----------
for fn in fsh_files:
    path = os.path.join(ROOT, fn)
    content = io.open(path, encoding="utf-8").read()
    base = os.path.basename(fn)
    # 注意：本包依赖默认输出（gbuffers→colortex0，composite→colortex0），故缺 RENDERTARGETS 仅警告
    if base.startswith(("gbuffers", "composite")) and "RENDERTARGETS" not in content:
        warn("%s 未声明 RENDERTARGETS（默认写 colortex0，本包链路依赖此行为）" % fn)
    if base == "final.fsh" and "RENDERTARGETS" in content:
        warn("final.fsh 带有 RENDERTARGETS（final 直接输出屏幕，通常不需要）")
    bal = content.count("{") - content.count("}")
    if bal != 0:
        err("%s 括号不平衡 (%+d)" % (fn, bal))

# ---------- 7. lib 文件不得含 #version 或选项宏 ----------
for fn in os.listdir(os.path.join(ROOT, "lib")):
    content = io.open(os.path.join(ROOT, "lib", fn), encoding="utf-8").read()
    if re.search(r'^\s*#\s*version\b', content, re.M):
        err("lib/%s 不应包含 #version（会被 include 进主文件）" % fn)
    for name in defs:
        if re.search(r'#\s*(ifdef|ifndef|if)\s+%s\b' % name, content) or \
           re.search(r'^\s*#\s*define\s+%s\b' % name, content, re.M):
            err("lib/%s 使用了选项宏 %s（选项只允许在顶层 .fsh 中）" % (fn, name))

# ---------- 8. 缓冲格式常量格式 ----------
for fn in fsh_files:
    content = io.open(os.path.join(ROOT, fn), encoding="utf-8").read()
    for m in re.finditer(r'const\s+int\s+(\w+Format)\s*=\s*(\w+);', content):
        if m.group(2) not in ("RGBA8", "RGBA16F", "RGBA32F", "R16F", "R32F", "RG16F", "RGB10_A2", "R8", "RGBA8_SNORM"):
            err("%s 未知缓冲格式 %s" % (fn, m.group(2)))

print("== 晨辉光影 一致性检查 ==")
print("检查文件数: %d 个 .fsh" % len(fsh_files))
print("选项数: %d (布尔 %d, 数值 %d)" % (len(defs), len(bool_opts), len(int_opts)))
if errors:
    print("\n[错误] %d 项:" % len(errors))
    for e in errors:
        print("  ✗ " + e)
else:
    print("\n[错误] 0 项 ✔")
if warns:
    print("\n[警告] %d 项:" % len(warns))
    for w in warns:
        print("  △ " + w)
sys.exit(1 if errors else 0)
