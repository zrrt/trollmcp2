//
//  HUDApp.h
//  TrollAgent
//
//  单可执行双模式的 C 接口——主 App（Swift）的 main() 按 argv 分支调用。
//

#ifndef HUDApp_h
#define HUDApp_h

#ifdef __cplusplus
extern "C" {
#endif

// -hud：进悬浮模式（不返回）
void HUDMainStart(void);

// -exit：杀悬浮进程
void HUDExit(void);

// -check：返回 EXIT_FAILURE(存活) / EXIT_SUCCESS(未跑)
int HUDCheck(void);

#ifdef __cplusplus
}
#endif

#endif /* HUDApp_h */
