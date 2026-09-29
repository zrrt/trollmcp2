// Jinx VIP Bypass — 诊断 v3：全类扫描找 NSObject 边界类 + vtable 页保护探测
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>

static void _log(NSString *msg) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *lp = [(paths.count ? paths[0] : @"/tmp") stringByAppendingPathComponent:@"vip_hook.log"];
    NSData *d = [[msg stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:lp];
    if (!fh) { [[NSFileManager defaultManager] createFileAtPath:lp contents:nil attributes:nil];
               fh = [NSFileHandle fileHandleForWritingAtPath:lp]; }
    if (fh) { [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile]; }
}

static BOOL _kw(NSString *s) {
    s = s.lowercaseString;
    return [s containsString:@"vip"] || [s containsString:@"paid"] || [s containsString:@"purchas"]
        || [s containsString:@"receipt"] || [s containsString:@"entitle"] || [s containsString:@"subscri"]
        || [s containsString:@"storekit"] || [s containsString:@"unlock"] || [s containsString:@"premium"]
        || [s containsString:@"product"] || [s containsString:@"pay"] || [s containsString:@"order"];
}

static void _protAt(const void *p, NSString *tag) {
    mach_vm_address_t addr = (mach_vm_address_t)p;
    mach_vm_size_t sz = 0;
    vm_region_submap_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
    natural_t depth = 16;
    kern_return_t kr = mach_vm_region(mach_task_self(), &addr, &sz, VM_REGION_SUBMAP_INFO_COUNT_64,
                                     (vm_region_recurse_info_t)&info, &cnt);
    if (kr == KERN_SUCCESS) {
        _log([NSString stringWithFormat:@"%@ prot=r%@%@ x%@ @%p", tag,
              (info.protection & VM_PROT_READ) ? @"+" : @"-",
              (info.protection & VM_PROT_WRITE) ? "w+" : "-",
              (info.protection & VM_PROT_EXECUTE) ? "+" : "-", p]);
    } else {
        _log([tag stringByAppendingString:@" region query failed"]);
    }
}

__attribute__((constructor))
static void _init(void) {
    _log(@"======= diag v3 =======");
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    int hit = 0;
    for (unsigned i = 0; i < count; i++) {
        Class c = classes[i];
        const char *img = class_getImageName(c);
        if (!img) continue;
        NSString *imgS = [NSString stringWithUTF8String:img];
        if (![imgS containsString:@"/Jinx"]) continue;
        NSString *cn = NSStringFromClass(c);
        Class sup = class_getSuperclass(c);
        NSString *sn = sup ? NSStringFromClass(sup) : @"-";
        if (_kw(cn)) { _log([NSString stringWithFormat:@"%@ : %@", cn, sn]); hit++; }
    }
    free(classes);
    _log([NSString stringWithFormat:@"--- matched %d Jinx classes ---", hit]);

    Class vip = NSClassFromString(@"Jinx.VIPManager");
    if (vip) {
        _protAt((const void *)vip, @"meta      ");
        // Swift class vtable 通常在 metadata 偏移 0x50~0x300
        _protAt((const char *)vip + 0x80, @"meta+0x80 ");
        _protAt((const char *)vip + 0x100, @"meta+0x100");
        _protAt((const char *)vip + 0x200, @"meta+0x200");
    }
    _log(@"======= diag v3 done =======");
}
