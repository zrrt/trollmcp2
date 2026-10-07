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

extern "C" void HUDMainStart(void);
extern "C" void HUDExit(void);
extern "C" int HUDCheck(void);

int main(int argc, char *argv[])
{
    @autoreleasepool
    {
        for (int i = 1; i < argc; i++)
        {
            if (argv[i] && strcmp(argv[i], "-hud") == 0)
            {
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
