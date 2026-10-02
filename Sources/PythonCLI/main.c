// TrollAgent 原生 Python CLI (v4.4.9-fix3cg)
// 嵌入式 CPython 入口：链接 App 内置 Python.framework，PYTHONHOME 指向 App bundle/python/。
// 用法：python3 [-c code | -m module | script.py | 无参(打印版本/帮助)]
// 编译：xcrun -sdk iphoneos clang -arch arm64 -isysroot $SDK -I<Framework>/Headers
//        -F<Frameworks> -framework Python -Wl,-rpath,@executable_path/../Frameworks -o python3 main.c
#include <Python.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>

// fix3cg: 诊断文件——iOS 无 tty 时 stdout/stderr 均不可见，关键状态写诊断文件。
// fix3ch: /tmp 在 python3 子进程沙盒可能只读 → 同时写相对 cwd（App 容器）+ /tmp，
// Swift 侧自动读回附加到输出，AI 直接看到无需手动 cat。
// fix3ck: 实测 fd 1/2 层彻底无效（os.write(1) 也丢），且 /tmp 与相对 cwd 的 diag 均未被 Swift 读到——
// 改为优先写 Swift 传的 TROLL_PY_DIAG（App Documents，沙盒一定可写），Swift 读同一绝对路径。
// fix3cl: 再兜底写 App 工作区 Workspace（/var/mobile/Documents/Workspace，App 数据容器一定可写可读）——
// 四通道（env 指定 / Workspace / /tmp / cwd），Swift 端逐一读回，总有一个能到。
static void diag(const char *msg) {
    const char *envd = getenv("TROLL_PY_DIAG");
    if (envd && envd[0]) {
        FILE *f = fopen(envd, "a");
        if (f) { fprintf(f, "%s\n", msg); fclose(f); }
    }
    FILE *f = fopen("/var/mobile/Documents/Workspace/troll_py_diag.txt", "a");
    if (f) { fprintf(f, "%s\n", msg); fclose(f); }
    f = fopen("/tmp/troll_py_diag.txt", "a");
    if (f) { fprintf(f, "%s\n", msg); fclose(f); }
    f = fopen("troll_py_diag.txt", "a");
    if (f) { fprintf(f, "%s\n", msg); fclose(f); }
    fprintf(stderr, "%s\n", msg);
}

// 从 argv[0] 推导 App bundle 路径：<bundle>/bin/python3 → <bundle>
// iOS 上 argv[0] 通常是完整路径；同时兼容相对路径兜底（用 cwd 拼）。
static void derive_bundle(const char *argv0, char *buf, size_t size) {
    // posix_spawn 调用时 argv[0] 为绝对路径（BuildRunner 传完整 executable 路径）
    snprintf(buf, size, "%s", (argv0 && argv0[0]) ? argv0 : "/var/mobile/Documents/Workspace/TrollAgent.app");
    // 去掉文件名和 bin 目录两级
    char *p = strrchr(buf, '/'); if (p) *p = '\0';  // .../TrollAgent.app/bin
    p = strrchr(buf, '/'); if (p) *p = '\0';        // .../TrollAgent.app
}

int main(int argc, char **argv) {
    // fix3cl3: 无条件启动标记——在 diag 之前直接 fopen 多路径写，
    // Swift 读回区分"main 根本没跑"(dyld/入口问题) vs "跑了但后面失败"(绑定/Py_Initialize)。
    {
        const char *paths[] = {
            "/var/mobile/Documents/Workspace/troll_py_start.txt",
            "/tmp/troll_py_start.txt",
            "troll_py_start.txt"
        };
        for (int i = 0; i < 3; i++) {
            FILE *sf = fopen(paths[i], "w");
            if (sf) { fprintf(sf, "start argc=%d argv0=%s\n", argc, argv && argv[0] ? argv[0] : "?"); fclose(sf); }
        }
    }
    diag("=== python3 main start ===");

    // fix3cg: Py_Initialize 前保存 BuildRunner 重定向的 stdout/stderr fd。
    // 官方 iOS CPython 在 Py_Initialize 内部可能把 fd 0/1/2 重定向到 /dev/null（无终端安全机制），
    // 导致 print()/os.write() 全部静默丢失。dup 保存后用 dup2 恢复，让 Python 层输出直达
    // BuildRunner 的临时文件（AI 读回）。
    int saved_out = -1, saved_err = -1;
    saved_out = dup(1);
    saved_err = dup(2);
    diag(saved_out >= 0 ? "dup stdout ok" : "dup stdout FAIL");
    diag(saved_err >= 0 ? "dup stderr ok" : "dup stderr FAIL");

    PyStatus status;
    PyConfig config;
    PyConfig_InitPythonConfig(&config);

    // iOS 安全/兼容配置（官方 iOS 指南要求）
    // fix3bp: Python 3.14 移除 PyConfig.utf8_mode（默认 UTF-8 模式）
    config.buffered_stdio = 0;        // 关闭缓冲（管道交互实时）
    config.write_bytecode = 0;        // 不写 __pycache__（沙盒禁止写）
    config.install_signal_handlers = 1;
    config.use_environment = 1;       // 允许环境变量覆盖（PYTHONHOME/PATH 等）

    char bundle[1024];
    derive_bundle(argc > 0 ? argv[0] : NULL, bundle, sizeof bundle);

    char pythonhome[1100];
    snprintf(pythonhome, sizeof pythonhome, "%s/python", bundle);
    status = PyConfig_SetBytesString(&config, &config.home, pythonhome);
    if (PyStatus_Exception(status)) { Py_ExitStatusException(status); }

    // module search path：stdlib + lib-dynload（.so 扩展模块）+ site-packages（wheels 解包处）
    // fix3p: site-packages 缺失导致原生 python3 找不到 numpy/pandas(wheel 解包于此, build-ipa.sh 集成)
    char libdir[1600];
    snprintf(libdir, sizeof libdir,
             "%s/python/lib/python3.14:%s/python/lib/python3.14/lib-dynload:%s/python/lib/python3.14/site-packages",
             bundle, bundle, bundle);
    PyWideStringList paths = {0};   // fix3bp: 3.14 移除 PyWideStringList_Init，改零初始化
    wchar_t *wlib = Py_DecodeLocale(libdir, NULL);
    PyWideStringList_Append(&paths, wlib);
    config.module_search_paths = paths;
    config.module_search_paths_set = 1;

    diag("calling Py_InitializeFromConfig");
    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        // fix3ch: 初始化失败必须留痕——PyStatus 错误文本写诊断（/tmp+相对 cwd+stderr），
        // 退出码非 0（旧版 Py_ExitStatusException 在 exitcode 未设置时 exit(0)，AI 误判成功）。
        char errbuf[512];
        snprintf(errbuf, sizeof errbuf, "Py_InitializeFromConfig EXCEPTION: %s",
                 status.err_msg ? status.err_msg : "(no message)");
        diag(errbuf);
        exit(1);
    }
    diag(Py_IsInitialized() ? "Py initialized OK" : "Py NOT initialized (fatal)");
    if (!Py_IsInitialized()) { return 1; }

    // fix3cg: 恢复 BuildRunner 的 stdout/stderr（Py_Initialize 可能已重定向到 /dev/null）
    if (saved_out >= 0) { dup2(saved_out, 1); close(saved_out); diag("restored stdout"); }
    if (saved_err >= 0) { dup2(saved_err, 2); close(saved_err); diag("restored stderr"); }

    // 参数解析（对齐 CPython CLI 常用子集）
    const char *code = NULL;      // -c
    const char *module = NULL;    // -m
    const char *script = NULL;    // 脚本文件
    int show_version = 0;
    int i;
    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0 && i + 1 < argc) { code = argv[++i]; }
        else if (strcmp(argv[i], "-m") == 0 && i + 1 < argc) { module = argv[++i]; }
        else if (strcmp(argv[i], "--version") == 0 || strcmp(argv[i], "-V") == 0) { show_version = 1; }
        else if (argv[i][0] == '-') { /* 忽略其他旗标，保持简单 */ }
        else { script = argv[i]; break; }  // 第一个非选项参数 = 脚本
    }
    // fix3ch: argv 诊断——确认 -c 代码是否真正解析到（怀疑 shellSplitArgs 拆参异常致 code 丢失）
    {
        char abuf[600];
        snprintf(abuf, sizeof abuf, "argc=%d code=%s module=%s script=%s show_version=%d",
                 argc, code ? "SET" : "NULL", module ? "SET" : "NULL",
                 script ? script : "NULL", show_version);
        diag(abuf);
    }

    // v4.4.9-fix3cd/fix3cg: iOS framework 版 Python 的 sys.stdout/stderr 在无 tty 环境下未绑定 fd 1/2，
    // print() 输出在 Python 层被静默丢弃（C 层 fflush 救不了——数据根本没到 C stdout）→ AI 实测看到空结果。
    // fix3ch: 绑定代码用 os.write 直写 fd 1（绕过 sys.stdout）验证 fd 状态。
    // fix3ck: 真机实测 os.write(1) 也空——fd 1/2 层在 iOS CPython 无 tty 时不可靠（PEP 730）。
    // 改为彻底不依赖 fd：sys.stdout/stderr 直接重定向到 Swift 传的 TROLL_PY_OUT 文件（App Documents），
    // print/os.write 全部写入该文件，Swift 执行后读回——与 node 的 stdout 重定向同一思路。
    // 保留 os.write 标记仅作诊断（TROLL_PY_DIAG 一定能读到，用于确认 main 是否真的执行）。
    int bind_rc = PyRun_SimpleString(
        "import sys, os\n"
        "_d = os.environ.get('TROLL_PY_OUT', '') or '/var/mobile/Documents/Workspace/troll_py_out.txt'\n"
        "if _d:\n"
        "    _f = open(_d, 'w', encoding='utf-8', errors='replace')\n"
        "    sys.stdout = _f\n"
        "    sys.stderr = _f\n"
        "    os.write(1, b'[PY-BIND-FILE]\\n')\n"   // fd1 可能无效，写失败不致命（文件重定向已接管）
        "else:\n"
        "    sys.stdout = sys.stderr = open(os.devnull, 'w')\n");
    diag(bind_rc == 0 ? "bind PyRun ok" : "bind PyRun FAIL (rc != 0)");
    if (PyErr_Occurred()) { PyErr_Print(); PyErr_Clear(); diag("cleared bind PyErr"); }

    int rc = 0;
    if (show_version) {
        rc = PyRun_SimpleString("import sys; print(sys.version)");
        diag(rc == 0 ? "version PyRun ok" : "version PyRun FAIL");
    } else if (code) {
        rc = PyRun_SimpleString(code);
        diag(rc == 0 ? "code PyRun ok" : "code PyRun FAIL");
        if (rc != 0) { PyErr_Print(); PyErr_Clear(); diag("cleared code PyErr"); }
    } else if (module) {
        PyObject *mod = PyImport_ImportModule(module);
        if (!mod) { PyErr_Print(); rc = 1; diag("module import FAIL"); }
        else { Py_DECREF(mod); diag("module import ok"); }
        if (PyErr_Occurred()) { PyErr_Clear(); }
    } else if (script) {
        FILE *fp = fopen(script, "rb");
        if (!fp) {
            fprintf(stderr, "python3: can't open file '%s': No such file or directory\n", script);
            diag("script open FAIL");
            rc = 2;
        } else {
            rc = PyRun_AnyFileExFlags(fp, script, 1, NULL);
            diag(rc == 0 ? "script PyRun ok" : "script PyRun FAIL");
            if (PyErr_Occurred()) { PyErr_Print(); PyErr_Clear(); }
        }
    } else {
        // 无参数：打印可用性 + 简短说明（iOS 无交互 REPL）
        rc = PyRun_SimpleString(
            "import sys\n"
            "print('TrollAgent native Python', sys.version.split()[0], '(iOS arm64)')\n"
            "print('usage: python3 -c <code> | -m <module> | <script.py>')\n");
        diag(rc == 0 ? "usage PyRun ok" : "usage PyRun FAIL");
    }
    if (rc != 0 && PyErr_Occurred()) { PyErr_Print(); rc = 1; }

    fflush(stdout);
    fflush(stderr);
    diag("=== python3 main end ===");
    Py_Finalize();
    free(wlib);
    return rc;
}
