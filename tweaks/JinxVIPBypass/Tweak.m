// Jinx 探针 v3：Swift ClassMetadata 解析 —— dump 字段名(field descriptor) + vtable
// 通用能力：对 SwiftObject 纯 Swift 类也能读出结构（App Store 包保留 fieldmd）
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <string.h>

static void _log(NSString *msg) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *lp = [paths[0] stringByAppendingPathComponent:@"vip_hook.log"];
    NSData *d = [[msg stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:lp];
    if (!fh) { [[NSFileManager defaultManager] createFileAtPath:lp contents:nil attributes:nil];
               fh = [NSFileHandle fileHandleForWritingAtPath:lp]; }
    if (fh) { [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile]; }
}
// relative direct pointer: int32 at (base+off), target = (base+off) + sext(disp)
static void* _rel(void* base, uint32_t off) {
    int32_t disp = *(int32_t*)((uint8_t*)base + off);
    return (uint8_t*)base + off + disp;
}

// dump one Swift/ObjC class
static void _dumpClass(Class cls) {
    NSString *cname = NSStringFromClass(cls);
    const char *sup = class_getSuperclass(cls) ? class_getName(class_getSuperclass(cls)) : "-";
    _log([NSString stringWithFormat:@"\n### %@  super=%s", cname, sup]);

    // ObjC methods/properties (works for @objc members even on SwiftObject)
    unsigned mc=0; Method *ms=class_copyMethodList(cls,&mc);
    for (unsigned i=0;i<mc;i++) _log([@"  objcM: " stringByAppendingString:NSStringFromSelector(method_getName(ms[i]))]);
    free(ms);

    // Swift ClassMetadata: description (ClassContextDescriptor) at metadata+0x38 on arm64
    uint8_t *meta = (__bridge void*)cls;
    void **descSlot = (void**)(meta + 0x38);
    void *desc = *descSlot;
    if (!desc) { _log(@"  (no swift descriptor)"); return; }
    // TypeContextDescriptor: name@8 rel, accessFn@12, fieldDescriptor@16 rel
    const char *name = (const char*)_rel(desc, 8);
    _log([NSString stringWithFormat:@"  swiftName=%s", name?name:"-"]);
    void *fieldDesc = _rel(desc, 16);
    if (fieldDesc) {
        // FieldDescriptor: kind@8 u16, recordSize@10 u16, numFields@12 u32, records@16
        uint32_t numFields = *(uint32_t*)((uint8_t*)fieldDesc + 12);
        uint16_t recSize = *(uint16_t*)((uint8_t*)fieldDesc + 10);
        _log([NSString stringWithFormat:@"  FIELDS(%u, recSize=%u):", numFields, recSize]);
        uint8_t *rec = (uint8_t*)fieldDesc + 16;
        for (uint32_t i=0;i<numFields;i++){
            // FieldRecord: flags@0, mangledType@4 rel, fieldName@8 rel
            const char *fname = (const char*)_rel(rec, 8);
            _log([NSString stringWithFormat:@"    - %s", fname?fname:"?"]);
            rec += (recSize ? recSize : 12);
        }
    }
    // vtable starts at metadata+0x40; dump first entries with dladdr names
    _log(@"  vtable(addr -> nearest symbol):");
    void **vt = (void**)(meta + 0x40);
    for (int i=0;i<24;i++){
        void *fp = vt[i];
        if (!fp || ((uintptr_t)fp & 3)) break;
        Dl_info info; memset(&info,0,sizeof(info));
        NSString *sym=@"?";
        if (dladdr(fp,&info) && info.dli_sname) sym=[NSString stringWithUTF8String:info.dli_sname];
        _log([NSString stringWithFormat:@"    vt[%2d]=%p %@", i, fp, sym]);
    }
}

__attribute__((constructor))
static void _init(void){
    _log(@"\n======== probe v3 (swift metadata) ========");
    NSArray *want = @[@"Jinx.VIPManager",@"Jinx.RealPaidVIPManager",@"Jinx.StoreKitManager",
                      @"Jinx.PurchaseStatusManager",@"Jinx.RealPaidVIPSharedStore"];
    for (int r=0;r<8;r++){
        BOOL any=NO; for (NSString*n in want) if(NSClassFromString(n)) any=YES;
        if (any) break; usleep(300000);
    }
    for (NSString *n in want){ Class c=NSClassFromString(n); if(c) _dumpClass(c); else _log([n stringByAppendingString:@" = NIL"]); }

    // 额外：列出运行时所有 Jinx.* 类名（建立全量类清单）
    unsigned cc=0; Class *all=objc_copyClassList(&cc);
    int hit=0;
    NSMutableString *list=[NSMutableString string];
    for (unsigned i=0;i<cc;i++){
        const char *cn=class_getName(all[i]);
        if (strncmp(cn,"Jinx.",5)==0){ [list appendFormat:@"%s\n",cn]; hit++; }
    }
    _log([NSString stringWithFormat:@"---- all Jinx.* classes (%d) ----\n%@", hit, list]);
    free(all);
    _log(@"======== probe v3 done ========");
}
