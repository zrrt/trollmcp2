// CompileProbe - 编译探针 tweak
// 目的：验证云端/本机 theos 工具链能否正确产出 .dylib / .deb
// 可替换成你自己的实际 hook 逻辑。
#import <UIKit/UIKit.h>

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
	%orig;
	NSLog(@"[CompileProbe] loaded - toolchain works");
}

%end
