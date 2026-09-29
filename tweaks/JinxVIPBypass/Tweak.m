// Jinx 探针 v3b：全防御式 Swift ClassMetadata 解析
// 所有内存读取走 mach_vm_read_overwrite（失败返错不崩溃），杜绝越界 segfault
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <string.h>
#import <mach/mach.h>
#import <mach/vm_map.h>

static void _log(NSString *msg) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (!paths.count) return;
    NSString *lp = [paths[0] stringByAppendingPathComponent:@"vip_hook.log"];
    NSData *d = [[msg stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:lp];
    if (!fh) { [[NSFileManager defaultManager] createFileAtPath:lp contents:nil attributes:nil];
               fh = [NSFileHandle fileHandleForWritingAtPath:lp]; }
    if (fh) { [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile]; }
}

// 安全读一个指针（8字节）。失败返回 0。
static uintptr_t _readPtr(const void *p) {
    if (!p) return 0;
    uint64_t val = 0;
    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
        (vm_address_t)p, sizeof(uint64_t), (vm_address_t)&val, &outSize);
    if (kr != KERN_SUCCESS || outSize != sizeof(uint64_t)) return 0;
    return (uintptr_t)val;
}
// 安全读 int32
static int32_t _readI32(const void *p) {
    if (!p) return 0;
    int32_t val = 0;
    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
        (vm_address_t)p, sizeof(int32_t), (vm_address_t)&val, &outSize);
    if (kr != KERN_SUCCESS || outSize != sizeof(int32_t)) return 0;
    return val;
}
// 安全读 uint16
static uint16_t _readU16(const void *p) {
    if (!p) return 0;
    uint16_t val = 0;
    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
        (vm_address_t)p, sizeof(uint16_t), (vm_address_t)&val, &outSize);
    if (kr != KERN_SUCCESS || outSize != sizeof(uint16_t)) return 0;
    return val;
}
// 安全读 uint32
static uint32_t _readU32(const void *p) {
    if (!p) return 0;
    uint32_t val = 0;
    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
        (vm_address_t)p, sizeof(uint32_t), (vm_address_t)&val, &outSize);
    if (kr != KERN_SUCCESS || outSize != sizeof(uint32_t)) return 0;
    return val;
}
// 页是否可读（用于字符串/结构边界判断）
static BOOL _readable(const void *p) {
    if (!p) return NO;
    vm_address_t addr = (vm_address_t)p;
    vm_size_t sz = 0;
    vm_region_submap_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
    uint32_t depth = 16;
    kern_return_t kr = vm_region_recurse_64(mach_task_self(), &addr, &sz, &depth,
                                     (vm_region_recurse_info_t)&info, &cnt);
    if (kr != KERN_SUCCESS) return NO;
    return (info.protection & VM_PROT_READ) != 0;
}
// 安全 C 字符串
static NSString* _cstr(uintptr_t p) {
    if (!p || !_readable((void*)p)) return @"-";
    // 限制长度，逐字节确认可读
    char buf[256]; int i = 0;
    const char *s = (const char*)p;
    for (; i < 255; i++) {
        if (!_readable(s + i)) { buf[i]=0; break; }
        char c = s[i];
        if (c == 0) { buf[i]=0; break; }
        // 可打印 ASCII 或常见
        if (c < 9 || (c > 13 && c < 32) || c > 126) { buf[i]=0; break; }
        buf[i] = c;
    }
    if (i == 256) buf[255]=0;
    if (i == 0) return @"-";
    return [NSString stringWithUTF8String:buf] ?: @"-";
}
// relative direct pointer: target = (base+off) + sext(int32@(base+off))
static uintptr_t _rel(uintptr_t base, uint32_t off) {
    int32_t disp = _readI32((void*)(base + off));
    return base + off + disp;
}

static void _dumpClass(Class cls) {
    NSString *cname = NSStringFromClass(cls);
    const char *sup = class_getSuperclass(cls) ? class_getName(class_getSuperclass(cls)) : "-";
    _log([NSString stringWithFormat:@"\n### %@  super=%s", cname, sup]);

    // ObjC methods（安全，runtime API）
    unsigned mc=0; Method *ms=class_copyMethodList(cls,&mc);
    for (unsigned i=0;i<mc;i++) _log([@"  objcM: " stringByAppendingString:NSStringFromSelector(method_getName(ms[i]))]);
    free(ms);

    uintptr_t meta = (uintptr_t)cls;
    // description 指针在 metadata+0x38（arm64 Swift ClassMetadata）
    uintptr_t desc = _readPtr((void*)(meta + 0x38));
    if (!desc || !_readable((void*)desc)) { _log(@"  (no readable swift descriptor @0x38)"); return; }
    // TypeContextDescriptor: name rel@8, fieldDescriptor rel@16
    uintptr_t namePtr = _rel(desc, 8);
    _log([NSString stringWithFormat:@"  swiftName=%@", _cstr(namePtr)]);

    uintptr_t fieldDesc = _rel(desc, 16);
    if (fieldDesc && _readable((void*)fieldDesc)) {
        uint16_t recSize = _readU16((void*)(fieldDesc + 10));
        uint32_t numFields = _readU32((void*)(fieldDesc + 12));
        _log([NSString stringWithFormat:@"  FIELDS(%u recSize=%u):", numFields, recSize]);
        if (numFields > 0 && numFields < 400) {
            uint32_t step = recSize ? recSize : 12;
            uintptr_t rec = fieldDesc + 16;
            for (uint32_t i=0;i<numFields;i++){
                if (!_readable((void*)(rec+8))) break;
                uintptr_t fnamePtr = _rel(rec, 8);
                _log([NSString stringWithFormat:@"    - %@", _cstr(fnamePtr)]);
                rec += step;
            }
        }
    } else {
        _log(@"  (no field descriptor)");
    }

    // vtable @ metadata+0x40，安全读前 24 项 + dladdr
    _log(@"  vtable:");
    for (int i=0;i<24;i++){
        uintptr_t fp = _readPtr((void*)(meta + 0x40 + i*8));
        if (!fp || !_readable((void*)fp)) break;
        Dl_info info; memset(&info,0,sizeof(info));
        NSString *sym=@"?";
        if (dladdr((void*)fp,&info) && info.dli_sname && _readable(info.dli_sname))
            sym=[NSString stringWithUTF8String:info.dli_sname] ?: @"?";
        _log([NSString stringWithFormat:@"    vt[%2d]=%lx %@", i, (unsigned long)fp, sym]);
    }
}

__attribute__((constructor))
static void _init(void){
    @try {
        _log(@"\n======== probe v3b (safe swift metadata) ========");
        NSArray *want = @[@"Jinx.VIPManager",@"Jinx.RealPaidVIPManager",@"Jinx.StoreKitManager",
                          @"Jinx.PurchaseStatusManager",@"Jinx.RealPaidVIPSharedStore"];
        for (int r=0;r<8;r++){
            BOOL any=NO; for (NSString*n in want) if(NSClassFromString(n)) any=YES;
            if (any) break; usleep(300000);
        }
        for (NSString *n in want){
            Class c=NSClassFromString(n);
            if (c) _dumpClass(c); else _log([n stringByAppendingString:@" = NIL"]);
        }
        unsigned cc=0; Class *all=objc_copyClassList(&cc);
        int hit=0; NSMutableString *list=[NSMutableString string];
        for (unsigned i=0;i<cc;i++){
            const char *cn=class_getName(all[i]);
            if (strncmp(cn,"Jinx.",5)==0){ [list appendFormat:@"%s\n",cn]; hit++; }
        }
        _log([NSString stringWithFormat:@"---- all Jinx.* classes (%d) ----\n%@", hit, list]);
        free(all);
        _log(@"======== probe v3b done ========");
    } @catch (NSException *e) {
        _log([@"!!! EXCEPTION: " stringByAppendingString:e.reason ?: @"?"]);
    }
}
