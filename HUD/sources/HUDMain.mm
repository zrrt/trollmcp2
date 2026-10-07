//
//  HUDMain.mm
//  TrollAgent
//
//  独立 HUD 二进制的 main 入口（方案A：不复用主可执行）。
//  独立二进制 TrollAgentHUD.app 由 TrollStore 随主 App 重签（签名有效，AMFI 放行），
//  收到 -hud 时进入悬浮核心 HUDMainStart()（GSInitialize/UIApplicationInitialize/__completeAndRunAsPlugin runloop 常驻）。
//  参考主 App main() 的 argv 分支，但独立二进制本身就是悬浮载体。
//

#import <UIKit/UIKit.h>
#import <string.h>
#import <stdio.h>
#import <unistd.h>

extern "C" void HUDMainStart(void);
extern "C" void HUDExit(void);
extern "C" int HUDCheck(void);

// v6.0.4：argv 确定性诊断——确证独立 HUD 二进制 exec 成功后 main 收到什么 argv、
// 是否进入 -hud 悬浮分支（子进程 sandbox 可能拒写某路径，多处落盘取成功者）
static void hud_diag(const char *msg)
{
    char buf[512];
    snprintf(buf, sizeof(buf), "%s pid=%d\n", msg, getpid());
    const char *paths[] = { "/tmp/hud.arg.log",
                            "/var/mobile/Library/Caches/hud.arg.log" };
    for (size_t i = 0; i < sizeof(paths)/sizeof(paths[0]); i++)
    {
        FILE *f = fopen(paths[i], "a");
        if (f) { fputs(buf, f); fclose(f); }
    }
}

int main(int argc, char *argv[])
{
    @autoreleasepool
    {
        char argvline[512] = {0};
        for (int i = 1; i < argc; i++)
        {
            if (strlen(argvline) + 32 < sizeof(argvline))
            {
                strcat(argvline, argv[i] ? argv[i] : "");
                strcat(argvline, " ");
            }
        }
        hud_diag("main entered");
        hud_diag(argvline);

        for (int i = 1; i < argc; i++)
        {
            if (argv[i] && strcmp(argv[i], "-hud") == 0)
            {
                hud_diag("got -hud, calling HUDMainStart");
                HUDMainStart();   // 悬浮模式，内部 runloop 不返回
                return 0;
            }
            else if (argv[i] && strcmp(argv[i], "-exit") == 0)
            {
                HUDExit();
                return 0;
            }
            else if (argv[i] && strcmp(argv[i], "-check") == 0)
            {
                return HUDCheck();
            }
        }
    }
    // 无参数时兜底进普通 UIApplication（不应发生；独立二进制只被 -hud 拉起）
    return UIApplicationMain(argc, argv, nil, nil);
}
