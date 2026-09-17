import Foundation
import Darwin

// v2.9.207：mach C API 直调（dlsym + @convention(c)）
// 背景：原实现用 @_silgen_name 在 DeviceProbe class method 上桥接 C 函数（tm_task_info /
//       tm_mach_vm_read_overwrite）。@_silgen_name 用于实例方法属未定义行为——Swift 编译器
//       可能按 Swift 调用约定生成调用（thick 方法 self/寄存器约定），与 C 函数 ABI 不完全一致，
//       task_for_pid 侥幸兼容（纯标量参数），但 task_info 的指针/count 参数组合下调用约定偏差
//       会导致内核收到错误参数 → KERN_FAILURE(4)。TrollDecrypt 是 ObjC 直接调 task_info，
//       无此层。这里用 dlsym 取 C 符号 + unsafeBitCast 到 @convention(c) 函数指针，
//       与 ObjC 直调 ABI 完全一致。
enum MachRaw {
    typealias TaskInfoFn = @convention(c) (UInt32, Int32, UnsafeMutableRawPointer, UnsafeMutablePointer<UInt32>) -> Int32
    typealias VMReadOverwriteFn = @convention(c) (UInt32, UInt64, UInt64, UInt64, UnsafeMutablePointer<UInt64>) -> Int32
    typealias VMRegionFn = @convention(c) (UInt32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>, Int32, UnsafeMutableRawPointer, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> Int32

    private static let rtlDefault = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT

    static let taskInfoFn: TaskInfoFn? = {
        guard let p = dlsym(rtlDefault, "task_info") else { return nil }
        return unsafeBitCast(p, to: TaskInfoFn.self)
    }()

    static let vmReadOverwriteFn: VMReadOverwriteFn? = {
        guard let p = dlsym(rtlDefault, "mach_vm_read_overwrite") else { return nil }
        return unsafeBitCast(p, to: VMReadOverwriteFn.self)
    }()

    static let vmRegionFn: VMRegionFn? = {
        guard let p = dlsym(rtlDefault, "mach_vm_region") else { return nil }
        return unsafeBitCast(p, to: VMRegionFn.self)
    }()

    /// 直调 task_info（与 ObjC 同 ABI）。返回 KERN_SUCCESS(0) 且 count 由内核回写实际写入数。
    static func taskInfo(task: UInt32, flavor: Int32, info: UnsafeMutableRawPointer,
                         count: UnsafeMutablePointer<UInt32>) -> Int32 {
        guard let f = taskInfoFn else { return -999 }
        return f(task, flavor, info, count)
    }

    /// 直调 mach_vm_read_overwrite。data 为输出缓冲的整型地址（与 ObjC (mach_vm_address_t)buffer 一致）。
    static func vmReadOverwrite(task: UInt32, address: UInt64, size: UInt64,
                                data: UInt64, outsize: UnsafeMutablePointer<UInt64>) -> Int32 {
        guard let f = vmReadOverwriteFn else { return -999 }
        return f(task, address, size, data, outsize)
    }

    /// 直调 mach_vm_region（查区域权限/大小，诊断用）。
    static func vmRegion(task: UInt32, address: UnsafeMutablePointer<UInt64>, size: UnsafeMutablePointer<UInt64>,
                         flavor: Int32, info: UnsafeMutableRawPointer, infoCount: UnsafeMutablePointer<UInt32>,
                         objectName: UnsafeMutablePointer<UInt32>) -> Int32 {
        guard let f = vmRegionFn else { return -999 }
        return f(task, address, size, flavor, info, infoCount, objectName)
    }
}
