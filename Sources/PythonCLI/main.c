// TrollAgent 原生 Python CLI (v4.4.4)
// 嵌入式 CPython 入口：链接 App 内置 Python.framework，PYTHONHOME 指向 App bundle/python/。
// 用法：python3 [-c code | -m module | script.py | 无参(打印版本/帮助)]
// 编译：xcrun -sdk iphoneos clang -arch arm64 -isysroot $SDK -I<Framework>/Headers
//        -F<Frameworks> -framework Python -Wl,-rpath,@executable_path/../Frameworks -o python3 main.c
#include <Python.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

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
    PyStatus status;
    PyConfig config;
    PyConfig_InitPythonConfig(&config);

    // iOS 安全/兼容配置（官方 iOS 指南要求）
    config.utf8_mode = 1;             // UTF-8 模式
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
    PyWideStringList paths;
    PyWideStringList_Init(&paths);
    wchar_t *wlib = Py_DecodeLocale(libdir, NULL);
    PyWideStringList_Append(&paths, wlib);
    config.module_search_paths = paths;
    config.module_search_paths_set = 1;

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        Py_ExitStatusException(status);
    }

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

    int rc = 0;
    if (show_version) {
        PyRun_SimpleString("import sys; print(sys.version)");
    } else if (code) {
        rc = PyRun_SimpleString(code);
    } else if (module) {
        PyObject *mod = PyImport_ImportModule(module);
        if (!mod) { PyErr_Print(); rc = 1; }
        else { Py_DECREF(mod); }
    } else if (script) {
        FILE *fp = fopen(script, "rb");
        if (!fp) {
            fprintf(stderr, "python3: can't open file '%s': No such file or directory\n", script);
            rc = 2;
        } else {
            rc = PyRun_AnyFileExFlags(fp, script, 1, NULL);
        }
    } else {
        // 无参数：打印可用性 + 简短说明（iOS 无交互 REPL）
        PyRun_SimpleString(
            "import sys\n"
            "print('TrollAgent native Python', sys.version.split()[0], '(iOS arm64)')\n"
            "print('usage: python3 -c <code> | -m <module> | <script.py>')\n");
    }
    if (rc != 0 && PyErr_Occurred()) { PyErr_Print(); rc = 1; }

    Py_Finalize();
    free(wlib);
    return rc;
}
