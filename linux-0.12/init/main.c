/*
 *  linux/init/main.c
 *
 *  (C) 1991  Linus Torvalds
 *
 *  系统根文件设备号
 *  内存全局变量
 *  主内存区的开始地址
 *  系统所拥有的内存容量
 *  高速缓冲区内存的末端地址
 *  高速缓冲以 1KB 为一个数据块单位
 *  主内存区以 4KB 为一个内存页单位
 *  设置中断标记开启中断
 *
 *  内核完成初始化,内核将执行控制权切换到用户模式(任务0),CPU从处理【特权级0】切换到【特权级3】
 *  main.c 工作在任务0, 第一次创建进程 fork(), 用于运行init() 子进程
 *
 *  init 程序将继续进行应用环境的初始化并执行 shell 登录程序, 原进程0会在系统空闲时被调度执行
 *
 *  init() 函数功能可以分为4个部分:
 *
 *  1. 安装根文件系统,首先调用系统 setup(), 用来收集硬盘设备分区表信息并安装根文件系统,
 *  在安装根文件系统之前,系统会先判断是否需要先建立虚拟盘
 *
 *  2. 显示系统信息, init() 打开一个终端设备 tty0, 标准输入 stdin 标准输出 stdout 错误输出 stderr 设备
 *  高速缓冲区中缓冲块总数,主内存区空闲内存总字节等
 *
 *  3. 运行系统初始化资源配置文件 rc 中的命令,
 *
 *  4. 执行用户登录 shell 程序
 *
 */

#define __LIBRARY__  // 与内联汇编有关
#include <unistd.h>  //
#include <time.h>

/* 堆栈 内核空间 写时复制技术了。*/

// int fork() 系统调用：创建进程
_syscall0(int, fork)
// int pause() 系统调用：暂停进程的执行，直到收到一个信号
_syscall0(int, pause)
// int setup(void * BIOS) 系统调用：仅用于linux初始化(仅在这个程序中被调用)
_syscall1(int, setup, void *, BIOS)
// int sync() 系统调用：更新文件系统
_syscall0(int, sync)

#include <linux/tty.h>
#include <linux/sched.h>
#include <linux/head.h>
#include <asm/system.h>
#include <asm/io.h>

#include <stddef.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/types.h>

#include <linux/fs.h>

#include <string.h>

#include <linux/log_print.h> 	/* 日志打印功能 */

static char printbuf[1024];		/* 静态字符串数组，用作内核显示信息的缓存。*/

extern char *strcpy();
extern int vsprintf();
extern void init(void);							/* 初始化 */
extern void blk_dev_init(void);					/* 块设备初始化blk_drv/ll_re_blk.c */
extern void chr_dev_init(void);					/* 字符设备初始化chr_drv/tty_io.c */
extern void hd_init(void);						/* 硬盘初始化blk_drv/hd.c */
extern void floppy_init(void);					/* 软驱初始化blk_drv/floppy.c */
extern void mem_init(long start, long end);		/* 内存管理初始化mm/memory.c */
extern long rd_init(long mem_start, int length);/* 虚拟盘初始化blk_drv/ramdisk.c */
extern long kernel_mktime(struct tm * tm);		/* 计算系统开机启动时间(秒) */

/* 内核专用sprintf()函数，产生格式化信息并输出到指定缓冲区str中 */
static int sprintf(char * str, const char *fmt, ...)
{
	va_list args;
	int i;

	va_start(args, fmt);
	i = vsprintf(str, fmt, args);
	va_end(args);
	return i;
}

/*
 * This is set up by the setup-routine at boot-time
 */
/* 
 * 这些数据由内核引导期间的setup.s程序设置。
 */
#define EXT_MEM_K (*(unsigned short *)0x90002)			/* 1MB以后的扩展内存大小(KB) */
#define CON_ROWS ((*(unsigned short *)0x9000e) & 0xff)	/* 选定的控制台屏幕的行数 */
#define CON_COLS (((*(unsigned short *)0x9000e) & 0xff00) >> 8)	/* ...列数 */
#define DRIVE_INFO (*(struct drive_info *)0x90080)		/* 硬盘参数表32字节内容 */
#define ORIG_ROOT_DEV (*(unsigned short *)0x901FC)		/* 根文件系统所在设备号 */
#define ORIG_SWAP_DEV (*(unsigned short *)0x901FA)		/* 交换文件所在设备号 */

/*
 * Yeah, yeah, it's ugly, but I cannot find how to do this correctly
 * and this seems to work. I anybody has more info on the real-time
 * clock I'd be interested. Most of this was trial and error, and some
 * bios-listing reading. Urghh.
 */
/* 这段宏读取CMOS实时时钟数据。outb_p和inb_p是include/asm/io.h中定义的端口输入输出宏 */
#define CMOS_READ(addr) ({		\
	outb_p(0x80 | addr, 0x70);	\
	inb_p(0x71); 				\
})

/* 将BCD码转换成二进制数值 */
#define BCD_TO_BIN(val)	((val)=((val)&15) + ((val)>>4)*10)

/* CMOS的访问时间很慢。为了减小时间误差，在读取了下面循环中所有数值后，若此时CMOS中秒值
 发生了变化，则重新读取。这样能控制误差在1s内 */
static void time_init(void)
{
	struct tm time;

	do {
		time.tm_sec = CMOS_READ(0);
		time.tm_min = CMOS_READ(2);
		time.tm_hour = CMOS_READ(4);
		time.tm_mday = CMOS_READ(7);
		time.tm_mon = CMOS_READ(8);		/* 当前月份(1~12) */
		time.tm_year = CMOS_READ(9);
	} while (time.tm_sec != CMOS_READ(0));
	BCD_TO_BIN(time.tm_sec);
	BCD_TO_BIN(time.tm_min);
	BCD_TO_BIN(time.tm_hour);
	BCD_TO_BIN(time.tm_mday);
	BCD_TO_BIN(time.tm_mon);
	BCD_TO_BIN(time.tm_year);
	time.tm_mon--;						/* ti_mon中的月份范围是 0 ~ 11 */
	startup_time = kernel_mktime(&time);/* 计算开机时间。*/
}

static long memory_end = 0;				/* 机器所具有的物理内存容量 */
static long buffer_memory_end = 0;		/* 高速缓冲区末端地址 */
static long main_memory_start = 0;		/* 主内存开始的位置 */
static char term[32];					/* 终端设置字符串 */

/* 读取并执行/etc/rc文件时所使用的命令行参数和环境参数 */
static char * argv_rc[] = { "/bin/sh", NULL };
static char * envp_rc[] = { "HOME=/", NULL ,NULL };

/* 运行登录shell时所使用的命令行和环境参数 */
/* argv[0]中的字符“-”是传递shell程序sh的一个标示位，通过这个标示位，sh程序会作为shell程序执行 */
static char * argv[] = { "-/bin/sh", NULL };
static char * envp[] = { "HOME=/usr/root", NULL, NULL };

/* 用于存放硬盘参数表 */
struct drive_info { char dummy[32]; } drive_info;

/* 内核初始化主程序 （void -> int 去除编译警告，实际为void） */
int main(void)		/* This really is void, no error here. */
					/* 这里真的是 void，没有问题 */
{					/* The startup routine assumes (well, ...) this */
					/* 因为在 head.s 就是这么假设的(把 main 的地址压入堆栈的时候) */
/*
 * Interrupts are still disabled. Do necessary setups, then enable them
 */
/*
 * 此时中断还被禁止的，做完必要的设置后就将其开启。
 */
	ROOT_DEV = ORIG_ROOT_DEV;
	SWAP_DEV = ORIG_SWAP_DEV;
	sprintf(term, "TERM=con%dx%d", CON_COLS, CON_ROWS);
	envp[1] = term;
	envp_rc[1] = term;
	drive_info = DRIVE_INFO;

	/* 根据机器物理内存容量设置高速缓冲区和主内存区的起始地址 */
	memory_end = (1 << 20) + (EXT_MEM_K << 10); /* 1M + 扩展内存大小 */
	memory_end &= 0xfffff000;					/* 忽略不到4K(1页)的内存 */
	if (memory_end > 16 * 1024 * 1024) {		/* 最多管理16M内存 */
		memory_end = 16 * 1024 * 1024;
	}

	if (memory_end > 12 * 1024 * 1024) {
		buffer_memory_end = 4 * 1024 * 1024;
	} else if (memory_end > 6 * 1024 * 1024) {
		buffer_memory_end = 2 * 1024 * 1024;
	} else {
		buffer_memory_end = 1 * 1024 * 1024;
	}
	main_memory_start = buffer_memory_end;
#ifdef RAMDISK	/* 如果定义了虚拟盘，则主内存还得相应减少 */
	main_memory_start += rd_init(main_memory_start, RAMDISK*1024);
#endif

/* 以下是内核进行所有方面的初始化工作 */
	mem_init(main_memory_start, memory_end);/* 主内存区初始化 */
	trap_init();							/* 陷阱门初始化 */
	blk_dev_init();							/* 块设备初始化 */
	chr_dev_init();							/* 字符设备初始化 */
	tty_init();								/* tty初始化 */
	time_init();							/* 设置开机启动时间 */
	sched_init();							/* 调度程序初始化 */
	buffer_init(buffer_memory_end);			/* 缓冲管理初始化 */
	hd_init();								/* 硬盘初始化 */
	floppy_init();							/* 软驱初始化 */

	sti();									/* 开启中断 */
	move_to_user_mode();
	if (!fork()) {							/* we count on this going ok */
		/* 创建任务1（init进程） */
		init();
	}
/*
 *   NOTE!!   For any other task 'pause()' would mean we have to get a
 * signal to awaken, but task0 is the sole exception (see 'schedule()')
 * as task 0 gets activated at every idle moment (when no other tasks
 * can run). For task0 'pause()' just means we go check if some other
 * task can run, and if not we return here.
 */
/*
 * 注意!! 对于任何其他的任务，“pause()”将意味着我们必须等待收到信号才会返回就绪态，但任务0
 * 是唯一例外的情况(参见“schedule()”)，因为任务0在任何空闲时间里都会被激活，因此对于任务
 * 0 “pause()”仅意味着我们返回来查看是否有其他任务可以运行，如果没有的话，我们就在这里一直循
 * 环执行。
 */

	/* 调度函数发现系统中没有其他程序可以运行就会切换到任务0 */
	for(;;) {
		__asm__("int $0x80"::"a" (__NR_pause));
	}
}


int printf(const char *fmt, ...)
{
	va_list args;
	int i;

	va_start(args, fmt);
	write(1, printbuf, i = vsprintf(printbuf, fmt, args));
	va_end(args);
	return i;
}

/* init()函数主要完成4件事：
 *		1. 安装根文件系统
 *		2. 显示系统信息
 *		3. 运行系统初始资源配置文件rc中的命令
 *		4. 执行用户登录shell程序
*/
void init(void)
{
	int pid, i;

	setup((void *) &drive_info);

	(void) open("/dev/tty1", O_RDWR, 0);	/* stdin */
	(void) dup(0);							/* stdout */
	(void) dup(0);							/* stderr */

	printf("%d buffers = %d bytes buffer space\n\r", NR_BUFFERS, NR_BUFFERS * BLOCK_SIZE);
	printf("Free mem: %d bytes\n\r", memory_end - main_memory_start);

	/* fork出任务2 */
	if (!(pid = fork())) {
		/* 将stdin重定向到/etc/rc文件，shell程序会在运行完/etc/rc中设置的命令后退出 */
		close(0);
		if (open("/etc/rc", O_RDONLY, 0)) {
			_exit(1);
		}
		execve("/bin/sh", argv_rc, envp_rc);
		_exit(2);
	}

	if (pid > 0) {	/* init进程等待任务2退出 */
		while (pid != wait(&i)) {
			/* nothing */;
		}
	}
	/* 系统将始终在这个循环中 */
	while (1) {
		if ((pid = fork()) < 0) {
			printf("Fork failed in init\r\n");
			continue;
		}
		/* 新的子进程，关闭句柄（0，1，2），新创建一个会话并设置进程组号，然后重新打开/dev/tty0作
		 为stdin，并复制成stdout和stderr。以登录方式再次执行/bin/sh */
		if (!pid) {
			close(0);close(1);close(2);
			setsid();
			(void) open("/dev/tty1", O_RDWR, 0);
			(void) dup(0);
			(void) dup(0);
			_exit(execve("/bin/sh", argv, envp));
		}
		/* 然后父进程再次运行wait()等待 */
		while (1) {
			if (pid == wait(&i)) {
				break;
			}
		}
		printf("\n\rchild %d died with code %04x\n\r", pid, i);
		sync();
	}
	_exit(0);	/* NOTE! _exit, not exit() */
	/* _exit和exit都能用于正常终止一个函数。但_exit()直接是一个sys_exit的系统调用，而exit()则
	 是普通函数库中的一个函数。它会先进行一些清除操作，例如调用执行各终止处理程序，关闭所有标
	 准IO等，然后调用sys_exit。*/
}
