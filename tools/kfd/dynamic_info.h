/*
 * dynamic_info.h — kfd kern_versions[] 现成偏移表（kopen 建立内核读写原语用）
 * 供 TrollAgent kfd_helper 编译时覆盖 felix-pb/kfd 的 libkfd/info/dynamic_info.h。
 *
 * 组成（全部为现成开源数据，非真机实测）:
 *   - iOS 16.3, A12–A16 (xnu-8792.82.2): Lrdsnow/kfd_offsets
 *   - iOS 16.6 (xnu-8796.122.4/142.1/141.3): felix-pb/kfd 原版
 * libkfd 运行时读当前设备 kern.version 自动匹配对应条目。
 * 字段偏移随 iOS 版本、kernelcache 全局地址随芯片(A12=T8020…A16=T8120)。
 * 整合时间: 2026-09-26
 */
#ifndef dynamic_info_h
#define dynamic_info_h

struct dynamic_info {
    const char* kern_version;
    bool kread_kqueue_workloop_ctl_supported;
    bool perf_supported;
    // struct fileglob
    u64 fileglob__fg_ops;
    u64 fileglob__fg_data;
    // struct fileops
    u64 fileops__fo_kqfilter;
    // struct fileproc
    // u64 fileproc__fp_iocount;
    // u64 fileproc__fp_vflags;
    // u64 fileproc__fp_flags;
    // u64 fileproc__fp_guard_attrs;
    // u64 fileproc__fp_glob;
    // u64 fileproc__fp_guard;
    // u64 fileproc__object_size;
    // struct fileproc_guard
    u64 fileproc_guard__fpg_guard;
    // struct kqworkloop
    u64 kqworkloop__kqwl_state;
    u64 kqworkloop__kqwl_p;
    u64 kqworkloop__kqwl_owner;
    u64 kqworkloop__kqwl_dynamicid;
    u64 kqworkloop__object_size;
    // struct pmap
    u64 pmap__tte;
    u64 pmap__ttep;
    // struct proc
    u64 proc__p_list__le_next;
    u64 proc__p_list__le_prev;
    u64 proc__p_pid;
    u64 proc__p_fd__fd_ofiles;
    u64 proc__object_size;
    // struct pseminfo
    u64 pseminfo__psem_usecount;
    u64 pseminfo__psem_uid;
    u64 pseminfo__psem_gid;
    u64 pseminfo__psem_name;
    u64 pseminfo__psem_semobject;
    // struct psemnode
    // u64 psemnode__pinfo;
    // u64 psemnode__padding;
    // u64 psemnode__object_size;
    // struct semaphore
    u64 semaphore__owner;
    // struct specinfo
    u64 specinfo__si_rdev;
    // struct task
    u64 task__map;
    u64 task__threads__next;
    u64 task__threads__prev;
    u64 task__itk_space;
    u64 task__object_size;
    // struct thread
    u64 thread__task_threads__next;
    u64 thread__task_threads__prev;
    u64 thread__map;
    u64 thread__thread_id;
    u64 thread__object_size;
    // struct uthread
    u64 uthread__object_size;
    // struct vm_map_entry
    u64 vm_map_entry__links__prev;
    u64 vm_map_entry__links__next;
    u64 vm_map_entry__links__start;
    u64 vm_map_entry__links__end;
    u64 vm_map_entry__store__entry__rbe_left;
    u64 vm_map_entry__store__entry__rbe_right;
    u64 vm_map_entry__store__entry__rbe_parent;
    // struct vnode
    u64 vnode__v_un__vu_specinfo;
    // struct _vm_map
    u64 _vm_map__hdr__links__prev;
    u64 _vm_map__hdr__links__next;
    u64 _vm_map__hdr__links__start;
    u64 _vm_map__hdr__links__end;
    u64 _vm_map__hdr__nentries;
    u64 _vm_map__hdr__rb_head_store__rbh_root;
    u64 _vm_map__pmap;
    u64 _vm_map__hint;
    u64 _vm_map__hole_hint;
    u64 _vm_map__holes_list;
    u64 _vm_map__object_size;
    // kernelcache static addresses
    u64 kernelcache__kernel_base;
    u64 kernelcache__cdevsw;
    u64 kernelcache__gPhysBase;
    u64 kernelcache__gPhysSize;
    u64 kernelcache__gVirtBase;
    u64 kernelcache__perfmon_devices;
    u64 kernelcache__perfmon_dev_open;
    u64 kernelcache__ptov_table;
    u64 kernelcache__vm_first_phys_ppnum;
    u64 kernelcache__vm_pages;
    u64 kernelcache__vm_page_array_beginning_addr;
    u64 kernelcache__vm_page_array_ending_addr;
    u64 kernelcache__vn_kqfilter;
};

struct dynamic_info kern_versions[] = {
{
        .kern_version = "Darwin Kernel Version 22.3.0: Wed Jan  4 21:24:51 PST 2023; root:xnu-8792.82.2~1/RELEASE_ARM64_T8020",
                .kread_kqueue_workloop_ctl_supported = true,
                .perf_supported = true,
        .fileglob__fg_ops = 0x0,
        .fileglob__fg_data = 0x40 - 8,
        .fileops__fo_kqfilter = 0x30,
        // .fileproc__fp_iocount = 0x0000,
        // .fileproc__fp_vflags = 0x0004,
        // .fileproc__fp_flags = 0x0008,
        // .fileproc__fp_guard_attrs = 0x000a,
        // .fileproc__fp_glob = 0x0010,
        // .fileproc__fp_guard = 0x0018,
        // .fileproc__object_size = 0x0020,
        .fileproc_guard__fpg_guard = 0x8,
        .kqworkloop__kqwl_state = 0x10,
        .kqworkloop__kqwl_p = 0x18,
        .kqworkloop__kqwl_owner = 0xd0,
        .kqworkloop__kqwl_dynamicid = 0xd0 + 0x18,
        .kqworkloop__object_size = 0x108,
        .pmap__tte = 0x0,
        .pmap__ttep = 0x8,
        .proc__p_list__le_next = 0x0,
        .proc__p_list__le_prev = 0x8,
        .proc__p_pid = 0x60,
        .proc__p_fd__fd_ofiles = 0x0,
        .proc__object_size = 0x538,
        .pseminfo__psem_usecount = 0x04,
        .pseminfo__psem_uid = 0x0c,
        .pseminfo__psem_gid = 0x10,
        .pseminfo__psem_name = 0x14,
        .pseminfo__psem_semobject = 0x38,
        // .psemnode__pinfo = 0x0000,
        // .psemnode__padding = 0x0008,
        // .psemnode__object_size = 0x0010,
        .semaphore__owner = 0x28,
        .specinfo__si_rdev = 0x18,
        .task__map = 0x28,
        .task__threads__next = 0x80 - 0x28,
        .task__threads__prev = 0x80 - 0x28 + 8,
        .task__itk_space = 0x300,
        .task__object_size = 0x628,
        .thread__task_threads__next = 0x368 - 0x18,
        .thread__task_threads__prev = 0x368 - 0x18 + 8,
        .thread__map = 0x368,
        .thread__thread_id = 0x400,
        .thread__object_size = 0x4a8,
        .uthread__object_size = 0xfffffffffffffb58,
        .vm_map_entry__links__prev = 0x00,
        .vm_map_entry__links__next = 0x08,
        .vm_map_entry__links__start = 0x10,
        .vm_map_entry__links__end = 0x18,
        .vm_map_entry__store__entry__rbe_left = 0x20,
        .vm_map_entry__store__entry__rbe_right = 0x28,
        .vm_map_entry__store__entry__rbe_parent = 0x30,
        .vnode__v_un__vu_specinfo = 0x78,
        ._vm_map__hdr__links__prev = 0x00 + 0x10,
        ._vm_map__hdr__links__next = 0x08 + 0x10,
        ._vm_map__hdr__links__start = 0x10 + 0x10,
        ._vm_map__hdr__links__end = 0x18 + 0x10,
        ._vm_map__hdr__nentries = 0x30,
        ._vm_map__hdr__rb_head_store__rbh_root = 0x38,
        ._vm_map__pmap = 0x40,
        ._vm_map__hint = 0x90 + 0x08,
        ._vm_map__hole_hint = 0x90 + 0x10,
        ._vm_map__holes_list = 0x90 + 0x18,
        ._vm_map__object_size = 0x0,
        .kernelcache__kernel_base = 0xfffffff007004000,
        .kernelcache__cdevsw = 0xfffffff00a0f5178,
        .kernelcache__gPhysBase = 0xfffffff0077ffd48,
        .kernelcache__gPhysSize = 0xfffffff0077ffd48 + 8,
        .kernelcache__gVirtBase = 0xfffffff0077fdf28,
        .kernelcache__perfmon_devices = 0xfffffff00a130380,
        .kernelcache__perfmon_dev_open = 0xfffffff007e3b398,
        .kernelcache__ptov_table = 0xfffffff0077b3288,
        .kernelcache__vm_first_phys_ppnum = 0xfffffff00a12f800,
        .kernelcache__vm_pages = 0xfffffff0077b00c0,
        .kernelcache__vm_page_array_beginning_addr = 0xfffffff0077b2248,
        .kernelcache__vm_page_array_ending_addr = 0xfffffff00a12f7f8,
        .kernelcache__vn_kqfilter = 0xfffffff007e8da20,
    },
{
        .kern_version = "Darwin Kernel Version 22.3.0: Wed Jan  4 21:25:00 PST 2023; root:xnu-8792.82.2~1/RELEASE_ARM64_T8030",
                .kread_kqueue_workloop_ctl_supported = true,
                .perf_supported = true,
        .fileglob__fg_ops = 0x0,
        .fileglob__fg_data = 0x40 - 8,
        .fileops__fo_kqfilter = 0x30,
        // .fileproc__fp_iocount = 0x0000,
        // .fileproc__fp_vflags = 0x0004,
        // .fileproc__fp_flags = 0x0008,
        // .fileproc__fp_guard_attrs = 0x000a,
        // .fileproc__fp_glob = 0x0010,
        // .fileproc__fp_guard = 0x0018,
        // .fileproc__object_size = 0x0020,
        .fileproc_guard__fpg_guard = 0x8,
        .kqworkloop__kqwl_state = 0x10,
        .kqworkloop__kqwl_p = 0x18,
        .kqworkloop__kqwl_owner = 0xd0,
        .kqworkloop__kqwl_dynamicid = 0xd0 + 0x18,
        .kqworkloop__object_size = 0x108,
        .pmap__tte = 0x0,
        .pmap__ttep = 0x8,
        .proc__p_list__le_next = 0x0,
        .proc__p_list__le_prev = 0x8,
        .proc__p_pid = 0x60,
        .proc__p_fd__fd_ofiles = 0x0,
        .proc__object_size = 0x538,
        .pseminfo__psem_usecount = 0x04,
        .pseminfo__psem_uid = 0x0c,
        .pseminfo__psem_gid = 0x10,
        .pseminfo__psem_name = 0x14,
        .pseminfo__psem_semobject = 0x38,
        // .psemnode__pinfo = 0x0000,
        // .psemnode__padding = 0x0008,
        // .psemnode__object_size = 0x0010,
        .semaphore__owner = 0x28,
        .specinfo__si_rdev = 0x18,
        .task__map = 0x28,
        .task__threads__next = 0x80 - 0x28,
        .task__threads__prev = 0x80 - 0x28 + 8,
        .task__itk_space = 0x300,
        .task__object_size = 0x628,
        .thread__task_threads__next = 0x378 - 0x18,
        .thread__task_threads__prev = 0x378 - 0x18 + 8,
        .thread__map = 0x378,
        .thread__thread_id = 0x410,
        .thread__object_size = 0x4b8,
        .uthread__object_size = 0xfffffffffffffb48,
        .vm_map_entry__links__prev = 0x00,
        .vm_map_entry__links__next = 0x08,
        .vm_map_entry__links__start = 0x10,
        .vm_map_entry__links__end = 0x18,
        .vm_map_entry__store__entry__rbe_left = 0x20,
        .vm_map_entry__store__entry__rbe_right = 0x28,
        .vm_map_entry__store__entry__rbe_parent = 0x30,
        .vnode__v_un__vu_specinfo = 0x78,
        ._vm_map__hdr__links__prev = 0x00 + 0x10,
        ._vm_map__hdr__links__next = 0x08 + 0x10,
        ._vm_map__hdr__links__start = 0x10 + 0x10,
        ._vm_map__hdr__links__end = 0x18 + 0x10,
        ._vm_map__hdr__nentries = 0x30,
        ._vm_map__hdr__rb_head_store__rbh_root = 0x38,
        ._vm_map__pmap = 0x40,
        ._vm_map__hint = 0x90 + 0x08,
        ._vm_map__hole_hint = 0x90 + 0x10,
        ._vm_map__holes_list = 0x90 + 0x18,
        ._vm_map__object_size = 0x0,
        .kernelcache__kernel_base = 0xfffffff007004000,
        .kernelcache__cdevsw = 0xfffffff00a35d178,
        .kernelcache__gPhysBase = 0xfffffff00786fc80,
        .kernelcache__gPhysSize = 0xfffffff00786fc80 + 8,
        .kernelcache__gVirtBase = 0xfffffff00786de60,
        .kernelcache__perfmon_devices = 0xfffffff00a398370,
        .kernelcache__perfmon_dev_open = 0xfffffff007ed8be8,
        .kernelcache__ptov_table = 0xfffffff0078232a0,
        .kernelcache__vm_first_phys_ppnum = 0xfffffff00a397800,
        .kernelcache__vm_pages = 0xfffffff0078200c8,
        .kernelcache__vm_page_array_beginning_addr = 0xfffffff007822250,
        .kernelcache__vm_page_array_ending_addr = 0xfffffff00a3977f8,
        .kernelcache__vn_kqfilter = 0xfffffff007f2af14,
    },
{
        .kern_version = "Darwin Kernel Version 22.3.0: Wed Jan  4 21:24:52 PST 2023; root:xnu-8792.82.2~1/RELEASE_ARM64_T8101",
                .kread_kqueue_workloop_ctl_supported = true,
                .perf_supported = true,
        .fileglob__fg_ops = 0x0,
        .fileglob__fg_data = 0x40 - 8,
        .fileops__fo_kqfilter = 0x30,
        // .fileproc__fp_iocount = 0x0000,
        // .fileproc__fp_vflags = 0x0004,
        // .fileproc__fp_flags = 0x0008,
        // .fileproc__fp_guard_attrs = 0x000a,
        // .fileproc__fp_glob = 0x0010,
        // .fileproc__fp_guard = 0x0018,
        // .fileproc__object_size = 0x0020,
        .fileproc_guard__fpg_guard = 0x8,
        .kqworkloop__kqwl_state = 0x10,
        .kqworkloop__kqwl_p = 0x18,
        .kqworkloop__kqwl_owner = 0xd0,
        .kqworkloop__kqwl_dynamicid = 0xd0 + 0x18,
        .kqworkloop__object_size = 0x108,
        .pmap__tte = 0x0,
        .pmap__ttep = 0x8,
        .proc__p_list__le_next = 0x0,
        .proc__p_list__le_prev = 0x8,
        .proc__p_pid = 0x60,
        .proc__p_fd__fd_ofiles = 0x0,
        .proc__object_size = 0x538,
        .pseminfo__psem_usecount = 0x04,
        .pseminfo__psem_uid = 0x0c,
        .pseminfo__psem_gid = 0x10,
        .pseminfo__psem_name = 0x14,
        .pseminfo__psem_semobject = 0x38,
        // .psemnode__pinfo = 0x0000,
        // .psemnode__padding = 0x0008,
        // .psemnode__object_size = 0x0010,
        .semaphore__owner = 0x28,
        .specinfo__si_rdev = 0x18,
        .task__map = 0x28,
        .task__threads__next = 0x80 - 0x28,
        .task__threads__prev = 0x80 - 0x28 + 8,
        .task__itk_space = 0x300,
        .task__object_size = 0x630,
        .thread__task_threads__next = 0x378 - 0x18,
        .thread__task_threads__prev = 0x378 - 0x18 + 8,
        .thread__map = 0x378,
        .thread__thread_id = 0x418,
        .thread__object_size = 0x4c0,
        .uthread__object_size = 0xfffffffffffffb40,
        .vm_map_entry__links__prev = 0x00,
        .vm_map_entry__links__next = 0x08,
        .vm_map_entry__links__start = 0x10,
        .vm_map_entry__links__end = 0x18,
        .vm_map_entry__store__entry__rbe_left = 0x20,
        .vm_map_entry__store__entry__rbe_right = 0x28,
        .vm_map_entry__store__entry__rbe_parent = 0x30,
        .vnode__v_un__vu_specinfo = 0x78,
        ._vm_map__hdr__links__prev = 0x00 + 0x10,
        ._vm_map__hdr__links__next = 0x08 + 0x10,
        ._vm_map__hdr__links__start = 0x10 + 0x10,
        ._vm_map__hdr__links__end = 0x18 + 0x10,
        ._vm_map__hdr__nentries = 0x30,
        ._vm_map__hdr__rb_head_store__rbh_root = 0x38,
        ._vm_map__pmap = 0x40,
        ._vm_map__hint = 0x90 + 0x08,
        ._vm_map__hole_hint = 0x90 + 0x10,
        ._vm_map__holes_list = 0x90 + 0x18,
        ._vm_map__object_size = 0x0,
        .kernelcache__kernel_base = 0xfffffff007004000,
        .kernelcache__cdevsw = 0xfffffff00a3b1190,
        .kernelcache__gPhysBase = 0xfffffff00784c1b0,
        .kernelcache__gPhysSize = 0xfffffff00784c1b0 + 8,
        .kernelcache__gVirtBase = 0xfffffff00784a390,
        .kernelcache__perfmon_devices = 0xfffffff00a3ec3b0,
        .kernelcache__perfmon_dev_open = 0xfffffff007ed00f4,
        .kernelcache__ptov_table = 0xfffffff0077ff3b8,
        .kernelcache__vm_first_phys_ppnum = 0xfffffff00a3eb800,
        .kernelcache__vm_pages = 0xfffffff0077fc0d0,
        .kernelcache__vm_page_array_beginning_addr = 0xfffffff0077fe368,
        .kernelcache__vm_page_array_ending_addr = 0xfffffff00a3eb7f8,
        .kernelcache__vn_kqfilter = 0xfffffff007f226a0,
    },
{
        .kern_version = "Darwin Kernel Version 22.3.0: Wed Jan  4 21:25:19 PST 2023; root:xnu-8792.82.2~1/RELEASE_ARM64_T8110",
                .kread_kqueue_workloop_ctl_supported = true,
                .perf_supported = true,
        .fileglob__fg_ops = 0x0,
        .fileglob__fg_data = 0x40 - 8,
        .fileops__fo_kqfilter = 0x30,
        // .fileproc__fp_iocount = 0x0000,
        // .fileproc__fp_vflags = 0x0004,
        // .fileproc__fp_flags = 0x0008,
        // .fileproc__fp_guard_attrs = 0x000a,
        // .fileproc__fp_glob = 0x0010,
        // .fileproc__fp_guard = 0x0018,
        // .fileproc__object_size = 0x0020,
        .fileproc_guard__fpg_guard = 0x8,
        .kqworkloop__kqwl_state = 0x10,
        .kqworkloop__kqwl_p = 0x18,
        .kqworkloop__kqwl_owner = 0xd0,
        .kqworkloop__kqwl_dynamicid = 0xd0 + 0x18,
        .kqworkloop__object_size = 0x108,
        .pmap__tte = 0x0,
        .pmap__ttep = 0x8,
        .proc__p_list__le_next = 0x0,
        .proc__p_list__le_prev = 0x8,
        .proc__p_pid = 0x60,
        .proc__p_fd__fd_ofiles = 0x0,
        .proc__object_size = 0x538,
        .pseminfo__psem_usecount = 0x04,
        .pseminfo__psem_uid = 0x0c,
        .pseminfo__psem_gid = 0x10,
        .pseminfo__psem_name = 0x14,
        .pseminfo__psem_semobject = 0x38,
        // .psemnode__pinfo = 0x0000,
        // .psemnode__padding = 0x0008,
        // .psemnode__object_size = 0x0010,
        .semaphore__owner = 0x28,
        .specinfo__si_rdev = 0x18,
        .task__map = 0x28,
        .task__threads__next = 0x80 - 0x28,
        .task__threads__prev = 0x80 - 0x28 + 8,
        .task__itk_space = 0x300,
        .task__object_size = 0x648,
        .thread__task_threads__next = 0x380 - 0x18,
        .thread__task_threads__prev = 0x380 - 0x18 + 8,
        .thread__map = 0x380,
        .thread__thread_id = 0x420,
        .thread__object_size = 0x4c8,
        .uthread__object_size = 0xfffffffffffffb38,
        .vm_map_entry__links__prev = 0x00,
        .vm_map_entry__links__next = 0x08,
        .vm_map_entry__links__start = 0x10,
        .vm_map_entry__links__end = 0x18,
        .vm_map_entry__store__entry__rbe_left = 0x20,
        .vm_map_entry__store__entry__rbe_right = 0x28,
        .vm_map_entry__store__entry__rbe_parent = 0x30,
        .vnode__v_un__vu_specinfo = 0x78,
        ._vm_map__hdr__links__prev = 0x00 + 0x10,
        ._vm_map__hdr__links__next = 0x08 + 0x10,
        ._vm_map__hdr__links__start = 0x10 + 0x10,
        ._vm_map__hdr__links__end = 0x18 + 0x10,
        ._vm_map__hdr__nentries = 0x30,
        ._vm_map__hdr__rb_head_store__rbh_root = 0x38,
        ._vm_map__pmap = 0x40,
        ._vm_map__hint = 0x90 + 0x08,
        ._vm_map__hole_hint = 0x90 + 0x10,
        ._vm_map__holes_list = 0x90 + 0x18,
        ._vm_map__object_size = 0x0,
        .kernelcache__kernel_base = 0xfffffff007004000,
        .kernelcache__cdevsw = 0xfffffff00a381190,
        .kernelcache__gPhysBase = 0xfffffff0078581b0,
        .kernelcache__gPhysSize = 0xfffffff0078581b0 + 8,
        .kernelcache__gVirtBase = 0xfffffff007856390,
        .kernelcache__perfmon_devices = 0xfffffff00a3bc3b0,
        .kernelcache__perfmon_dev_open = 0xfffffff007ed905c,
        .kernelcache__ptov_table = 0xfffffff00780b3b0,
        .kernelcache__vm_first_phys_ppnum = 0xfffffff00a3bb800,
        .kernelcache__vm_pages = 0xfffffff0078080d8,
        .kernelcache__vm_page_array_beginning_addr = 0xfffffff00780a370,
        .kernelcache__vm_page_array_ending_addr = 0xfffffff00a3bb7f8,
        .kernelcache__vn_kqfilter = 0xfffffff007f29074,
    },
{
        .kern_version = "Darwin Kernel Version 22.3.0: Wed Jan  4 21:25:01 PST 2023; root:xnu-8792.82.2~1/RELEASE_ARM64_T8120",
                .kread_kqueue_workloop_ctl_supported = true,
                .perf_supported = true,
        .fileglob__fg_ops = 0x0,
        .fileglob__fg_data = 0x40 - 8,
        .fileops__fo_kqfilter = 0x30,
        // .fileproc__fp_iocount = 0x0000,
        // .fileproc__fp_vflags = 0x0004,
        // .fileproc__fp_flags = 0x0008,
        // .fileproc__fp_guard_attrs = 0x000a,
        // .fileproc__fp_glob = 0x0010,
        // .fileproc__fp_guard = 0x0018,
        // .fileproc__object_size = 0x0020,
        .fileproc_guard__fpg_guard = 0x8,
        .kqworkloop__kqwl_state = 0x10,
        .kqworkloop__kqwl_p = 0x18,
        .kqworkloop__kqwl_owner = 0xd0,
        .kqworkloop__kqwl_dynamicid = 0xd0 + 0x18,
        .kqworkloop__object_size = 0x108,
        .pmap__tte = 0x0,
        .pmap__ttep = 0x8,
        .proc__p_list__le_next = 0x0,
        .proc__p_list__le_prev = 0x8,
        .proc__p_pid = 0x60,
        .proc__p_fd__fd_ofiles = 0x0,
        .proc__object_size = 0x538,
        .pseminfo__psem_usecount = 0x04,
        .pseminfo__psem_uid = 0x0c,
        .pseminfo__psem_gid = 0x10,
        .pseminfo__psem_name = 0x14,
        .pseminfo__psem_semobject = 0x38,
        // .psemnode__pinfo = 0x0000,
        // .psemnode__padding = 0x0008,
        // .psemnode__object_size = 0x0010,
        .semaphore__owner = 0x28,
        .specinfo__si_rdev = 0x18,
        .task__map = 0x28,
        .task__threads__next = 0x80 - 0x28,
        .task__threads__prev = 0x80 - 0x28 + 8,
        .task__itk_space = 0x300,
        .task__object_size = 0x648,
        .thread__task_threads__next = 0x380 - 0x18,
        .thread__task_threads__prev = 0x380 - 0x18 + 8,
        .thread__map = 0x380,
        .thread__thread_id = 0x420,
        .thread__object_size = 0x4c8,
        .uthread__object_size = 0xfffffffffffffb38,
        .vm_map_entry__links__prev = 0x00,
        .vm_map_entry__links__next = 0x08,
        .vm_map_entry__links__start = 0x10,
        .vm_map_entry__links__end = 0x18,
        .vm_map_entry__store__entry__rbe_left = 0x20,
        .vm_map_entry__store__entry__rbe_right = 0x28,
        .vm_map_entry__store__entry__rbe_parent = 0x30,
        .vnode__v_un__vu_specinfo = 0x78,
        ._vm_map__hdr__links__prev = 0x00 + 0x10,
        ._vm_map__hdr__links__next = 0x08 + 0x10,
        ._vm_map__hdr__links__start = 0x10 + 0x10,
        ._vm_map__hdr__links__end = 0x18 + 0x10,
        ._vm_map__hdr__nentries = 0x30,
        ._vm_map__hdr__rb_head_store__rbh_root = 0x38,
        ._vm_map__pmap = 0x40,
        ._vm_map__hint = 0x90 + 0x08,
        ._vm_map__hole_hint = 0x90 + 0x10,
        ._vm_map__holes_list = 0x90 + 0x18,
        ._vm_map__object_size = 0x0,
        .kernelcache__kernel_base = 0xfffffff007004000,
        .kernelcache__cdevsw = 0xfffffff00a32d190,
        .kernelcache__gPhysBase = 0xfffffff0078540c0,
        .kernelcache__gPhysSize = 0xfffffff0078540c0 + 8,
        .kernelcache__gVirtBase = 0xfffffff0078522a0,
        .kernelcache__perfmon_devices = 0xfffffff00a368390,
        .kernelcache__perfmon_dev_open = 0xfffffff007ecce10,
        .kernelcache__ptov_table = 0xfffffff007807410,
        .kernelcache__vm_first_phys_ppnum = 0xfffffff00a367800,
        .kernelcache__vm_pages = 0xfffffff0078040d0,
        .kernelcache__vm_page_array_beginning_addr = 0xfffffff0078063d0,
        .kernelcache__vm_page_array_ending_addr = 0xfffffff00a3677f8,
        .kernelcache__vn_kqfilter = 0xfffffff007f1ce28,
    },
{
        .kern_version = "Darwin Kernel Version 22.5.0: Mon Apr 24 21:09:28 PDT 2023; root:xnu-8796.122.4~1/RELEASE_ARM64_T8120",
        .kread_kqueue_workloop_ctl_supported = false,
        .perf_supported = true,
        .proc__p_list__le_prev = 0x0008,
        .proc__p_pid = 0x0060,
        .proc__p_fd__fd_ofiles = 0x00f8,
        .proc__object_size = 0x0730,
        .task__map = 0x0028,
        .thread__thread_id = 0,
        .kernelcache__cdevsw = 0xfffffff00a419208,
        .kernelcache__gPhysBase = 0xfffffff007934010,
        .kernelcache__gPhysSize = 0xfffffff007934018,
        .kernelcache__gVirtBase = 0xfffffff0079321e8,
        .kernelcache__perfmon_dev_open = 0xfffffff007eecfc0,
        .kernelcache__perfmon_devices = 0xfffffff00a457500,
        .kernelcache__ptov_table = 0xfffffff0078e7178,
        .kernelcache__vn_kqfilter = 0xfffffff007f39b28,
    },
{
        .kern_version = "Darwin Kernel Version 22.6.0: Wed Jun 28 20:50:15 PDT 2023; root:xnu-8796.142.1~1/RELEASE_ARM64_T8101",
        .kread_kqueue_workloop_ctl_supported = false,
        .perf_supported = true,
        .proc__p_list__le_prev = 0x0008,
        .proc__p_pid = 0x0060,
        .proc__p_fd__fd_ofiles = 0x00f8,
        .proc__object_size = 0x0730,
        .task__map = 0x0028,
        .thread__thread_id = 0,
        .kernelcache__cdevsw = 0xfffffff00a4a5288,
        .kernelcache__gPhysBase = 0xfffffff0079303b8,
        .kernelcache__gPhysSize = 0xfffffff0079303c0,
        .kernelcache__gVirtBase = 0xfffffff00792e570,
        .kernelcache__perfmon_dev_open = 0xfffffff007ef4278,
        .kernelcache__perfmon_devices = 0xfffffff00a4e5320,
        .kernelcache__ptov_table = 0xfffffff0078e38f0,
        .kernelcache__vn_kqfilter = 0xfffffff007f42f40,
    },
{
        .kern_version = "Darwin Kernel Version 22.6.0: Wed Jul  5 22:17:35 PDT 2023; root:xnu-8796.141.3~6/RELEASE_ARM64_T8112",
        .kread_kqueue_workloop_ctl_supported = false,
        .perf_supported = false,
        .proc__p_list__le_prev = 0x0008,
        .proc__p_pid = 0x0060,
        .proc__p_fd__fd_ofiles = 0x00f8,
        .proc__object_size = 0x0778,
        .task__map = 0x0028,
        .thread__thread_id = 0,
        .kernelcache__cdevsw = 0,
        .kernelcache__gPhysBase = 0,
        .kernelcache__gPhysSize = 0,
        .kernelcache__gVirtBase = 0,
        .kernelcache__perfmon_dev_open = 0,
        .kernelcache__perfmon_devices = 0,
        .kernelcache__ptov_table = 0,
        .kernelcache__vn_kqfilter = 0,
    },
};

#endif /* dynamic_info_h */
