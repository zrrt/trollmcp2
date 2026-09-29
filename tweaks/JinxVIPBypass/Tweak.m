// Jinx VIP Bypass — 诊断 v2：用模块前缀定位 @objc Swift 类，dump 真实方法/属性
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

static void _log(NSString *msg) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = paths.count ? paths[0] : @"/tmp";
    NSString *lp = [docs stringByAppendingPathComponent:@"vip_hook.log"];
    NSData *d = [[msg stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:lp];
    if (!fh) { [[NSFileManager defaultManager] createFileAtPath:lp contents:nil attributes:nil];
               fh = [NSFileHandle fileHandleForWritingAtPath:lp]; }
    if (fh) { [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile]; }
}

static BOOL _match(NSString *s) {
    s = s.lowercaseString;
    return [s containsString:@"vip"] || [s containsString:@"paid"] || [s containsString:@"premium"]
        || [s containsString:@"entitle"] || [s containsString:@"subscri"] || [s containsString:@"purchas"]
        || [s containsString:@"pro"] || [s containsString:@"active"] || [s containsString:@"unlock"]
        || [s containsString:@"lifetime"] || [s containsString:@"trial"];
}

static void _dump(NSString *name) {
    Class c = NSClassFromString(name);
    if (!c) { _log([NSString stringWithFormat:@"### %@ = NIL", name]); return; }
    _log([NSString stringWithFormat:@"### %@ FOUND (%@)", name, c]);
    unsigned int mc = 0;
    Method *ms = class_copyMethodList(c, &mc);
    for (unsigned i = 0; i < mc; i++) {
        NSString *sn = NSStringFromSelector(method_getName(ms[i]));
        if (_match(sn)) _log([@"  M: " stringByAppendingString:sn]);
    }
    free(ms);
    unsigned int pc = 0;
    objc_property_t *ps = class_copyPropertyList(c, &pc);
    for (unsigned i = 0; i < pc; i++) {
        NSString *pn = [NSString stringWithUTF8String:property_getName(ps[i])];
        if (_match(pn)) _log([@"  P: " stringByAppendingString:pn]);
    }
    free(ps);
    Class sup = class_getSuperclass(c);
    if (sup) _log([NSString stringWithFormat:@"  super: %@", NSStringFromClass(sup)]);
}

__attribute__((constructor))
static void _init(void) {
    _log(@"======= diag v2 =======");
    NSArray *names = @[@"Jinx.VIPManager", @"Jinx.RealPaidVIPManager", @"Jinx.StoreKitManager",
                       @"Jinx.PurchaseStatusManager", @"Jinx.RealPaidVIPSharedStore",
                       @"VIPManager", @"RealPaidVIPManager"];
    for (int i = 0; i < 8; i++) {
        BOOL any = NO;
        for (NSString *n in names) if (NSClassFromString(n)) any = YES;
        if (any) break;
        usleep(300000);
    }
    for (NSString *n in names) _dump(n);
    _log(@"======= diag v2 done =======");
}
