/*
 *  linux/init/main.c
 *  (C) 1991  Linus Torvalds
 *
 *
 */

#define __LIBRARY__  // 与内联汇编有关,如何与有关文件关联起来?
#include <unistd.h>  //
#include <time.h>

/* 堆栈 内核空间 写时复制技术了。*/

_syscall0(int, fork)                        // 创建一个进程
_syscall0(int, pause)                       // 暂停进程的执行，直到收到一个信号
_syscall1(int, setup, void *, BIOS)         // 系统调用：仅用于linux初始化(仅在这个程序中被调用)
_syscall0(int, sync)                        // 系统调用：更新文件系统

#include <linux/tty.h>                      // 串行通信
#include <linux/sched.h>                    // 进程调度
#include <linux/head.h>                     // 段描述符简单结构
#include <asm/system.h>                     // 设置或修改描述符
#include <asm/io.h>                         // IO端口操作
#include <stddef.h>                         //
#include <stdarg.h>                         // 定义变量参数列表
#include <unistd.h>
#include <fcntl.h>                          // 用于文件及其描述符的操作控制常数符号的定义
#include <sys/types.h>                      // 类型头文件,定义了基本的系统数据类型
#include <linux/fs.h>                       // 定义文件表结构
#include <string.h>                         // 定义有关内存或字符串操作的嵌入函数
#include <linux/log_print.h> 	            // 打印日志文件

static char printbuf[1024];		            /* 静态字符串数组,用作内核显示信息的缓存。*/

extern char *strcpy();
extern int vsprintf();
extern void init(void);
extern void blk_dev_init(void);					/* 块设备初始化    blk_drv/ll_re_blk.c */
extern void chr_dev_init(void);					/* 字符设备初始化  chr_drv/tty_io.c */
extern void hd_init(void);						/* 硬盘初始化      blk_drv/hd.c */
extern void floppy_init(void);					/* 软驱初始化      blk_drv/floppy.c */
extern void mem_init(long start, long end);		/* 内存管理初始化  mm/memory.c */
extern long rd_init(long mem_start, int length);/* 虚拟盘初始化    blk_drv/ramdisk.c */
extern long kernel_mktime(struct tm * tm);		/* 计算系统开机启动时间(秒) */

/* 产生格式化信息并输出到指定缓冲区str中 */
static int sprintf(char * str, const char *fmt, ...)
{
	va_list args;
	int i;

	va_start(args, fmt);
	i = vsprintf(str, fmt, args);
	va_end(args);
	return i;
}

// 变量可以获得指定内存位置的内容
#define EXT_MEM_K (*(unsigned short *)0x90002)			/* 1MB以后的扩展内存大小(KB) */
#define CON_ROWS ((*(unsigned short *)0x9000e) & 0xff)	/* 选定的控制台屏幕的行数 */
#define CON_COLS (((*(unsigned short *)0x9000e) & 0xff00) >> 8)	/* ...列数 */
#define DRIVE_INFO (*(struct drive_info *)0x90080)		/* 硬盘参数表32字节内容 */
#define ORIG_ROOT_DEV (*(unsigned short *)0x901FC)		/* 根文件系统所在设备号 */
#define ORIG_SWAP_DEV (*(unsigned short *)0x901FA)		/* 交换文件所在设备号 */

/* 读取CMOS实时时钟数据。outb_p和inb_p是include/asm/io.h中定义的端口输入输出宏 */
#define CMOS_READ(addr) ({		\
	outb_p(0x80 | addr, 0x70);	\
	inb_p(0x71); 				\
})

/* 将BCD码转换成二进制数值 */
#define BCD_TO_BIN(val)	((val)=((val)&15) + ((val)>>4)*10)

// 取 CMOS 实时钟信息作为开机时间,保存到全局变量 startup_time
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
	time.tm_mon--;
	startup_time = kernel_mktime(&time);
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

/*
 * 内核初始化主程序
 * 此时中断还被禁止的,做完必要的设置后就将其开启。
 */
int main(void){

	ROOT_DEV = ORIG_ROOT_DEV;                   // 保存根文件系统设备号
	SWAP_DEV = ORIG_SWAP_DEV;                   // 保存交换文件设备号
	sprintf(term, "TERM=con%dx%d", CON_COLS, CON_ROWS);
	envp[1] = term;
	envp_rc[1] = term;
	drive_info = DRIVE_INFO;

	/*
	 * 机器物理内存容量 memory_end
	 * 设置高速缓冲区  buffer_memory_end
	 * 设置主内存区的起始地址 main_memory_start
	 */
	memory_end = (1 << 20) + (EXT_MEM_K << 10);
	memory_end &= 0xfffff000;
	if (memory_end > 16 * 1024 * 1024) {
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

// 如果在 Makefile 中定义了内存虚拟盘符号,则需要初始化虚拟盘
#ifdef RAMDISK
	main_memory_start += rd_init(main_memory_start, RAMDISK*1024);
#endif

/* 以下是内核进行所有方面的初始化工作 */
	mem_init(main_memory_start, memory_end);            /* 主内存区初始化 */
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
	move_to_user_mode();                    // 切换到用户模式
	if (!fork()) {
		init();                             // 在新建子进程中执行
	}

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

/*
 *	如何对shell环境初始化,并执行shell程序
*/
void init(void)
{
	int pid, i;

	setup((void *) &drive_info);    // 分区表信息,加载虚拟盘,安装根文件系统设备 kernel/blk_drv/hd.c

	(void) open("/dev/tty1", O_RDWR, 0);	/* stdin */
	(void) dup(0);							/* stdout */
	(void) dup(0);							/* stderr */

	printf("%d buffers = %d bytes buffer space\n\r", NR_BUFFERS, NR_BUFFERS * BLOCK_SIZE);
	printf("Free mem: %d bytes\n\r", memory_end - main_memory_start);

	/*
	 * task2 即fork出的新进程
	 * 为什么 stdin 重定向到 /etc/rc 文件
	 */
	if (!(pid = fork())) {
		close(0);
		if (open("/etc/rc", O_RDONLY, 0)) {
			_exit(1);
		}
		execve("/bin/sh", argv_rc, envp_rc);
		_exit(2);
	}

	if (pid > 0) {
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
