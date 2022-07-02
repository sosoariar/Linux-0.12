/*
 *  linux/boot/head.s
 *
 *  (C) 1991  Linus Torvalds
 */

.text
.globl idt, gdt, pg_dir, tmp_floppy_area

/*
 * PageDirect 是什么?
 * 下面起始地址是 0x00000000
 * 这个程序已经运行在 32位模式下
 */
pg_dir:

# 下列主要完成4件事
# 1. 系统堆栈的起始位置,指向 stack_start
# 2. 重新加载 LDT GDT, 当前为空, 由后续程序补充,段限长从8MB到16MB
# 3. 初始化页目录表和4个内核专属的页表
# 4. 通过ret跳转到init/main.c中的main运行

# 0x10 现在是一个【选择符】,硬件会通过【选择符】定位到【段描述符】,段描述符中包括了16位段寄存器需要的地址
# 0x10 含义: 请求特权级0, 全局描述符表, 表中第二项(第一项为空,第二项为数据段)
.globl startup_32
startup_32:
    movl $0x10, %eax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    lss stack_start, %esp   # 设置系统堆栈

    call setup_idt          # 设置中断描述符表
    call setup_gdt          # 设置全局描述符表
    
# 运行需要的数据都在代码段, 数据段, 栈段中, 设置 IDT,GDT的过程中, DS ES FS GS 的值已经改变了
# 因此重新装载所有的段寄存器
    movl $0x10, %eax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    lss stack_start, %esp

# 下面代码用于测试A20地址线是否已经开启
# 采用的方法是向内存地址0x000000处写入任意一个数值, 然后看内存地址0x100000(1M)处是否也是这个数值。
# 如果一直相同的话（表示地址A20线没有选通），就一直比较下去，即死循环。
    xorl %eax, %eax
1:	incl %eax
    movl %eax, 0x000000
    cmpl %eax, 0x100000
    je 1b

 # 下面这段程序用于检查数学协处理器芯片是否存在
 # 方法是修改控制寄存器CR0, 复位协处理器存在标志MP(位1)。
    movl %cr0, %eax						# check math chip
    andl $0x80000011, %eax				# Save PG,PE,ET
    orl $2, %eax						# set MP
    movl %eax, %cr0
    call check_x87
    jmp after_page_tables

/*
 * 我们依赖于ET标志的正确性来检测287/387存在与否.
 */
# fninit向协处理器发出初始化命令，它会把协处理器置于一个末受以前操作影响的已和状态，设置其控制字为默认值，
# 清除状态字和所有浮点栈式寄存器。非等待形式的这条指令(fninit)还会让协处理器终止执行当前正在执行的任何
# 先前的算术操作。
# fstsw指令取协处理器的状态字。
# 如果系统中存在协处理器的话，那么在执行了fninit指令后其状态字低字节肯定为0。

check_x87:
    fninit
    fstsw %ax
    cmpb $0, %al
    je 1f
    movl %cr0, %eax
    xorl $6, %eax
    movl %eax, %cr0
    ret

# 按4字节方式对齐内存地址,为了提高32位CPU访问内存中代码或数据的速度和效率
.align 4

1:	.byte 0xDB,0xE4
    ret

/*
 * 256个表项,每个表项 8 Byte, 共2KB
 *
 * 如何设置IDT呢？
 * ignore_int 中断门, 功能是在屏幕上打印C字符, 表示该中断项未被使用,或者初始化
 * 取 ignore_int 的地址到edx,
 */

setup_idt:
    lea ignore_int, %edx        # lea 指令取有效偏移地址到 edx 寄存器中
    movl $0x00080000, %eax
    movw %dx,%ax
    movw $0x8E00, %dx

    lea idt, %edi				# idt是中断描述符表的地址
    mov $256, %ecx
rp_sidt:
    movl %eax, (%edi)			# 将哑中断门描述符存入表中
    movl %edx, 4(%edi)
    addl $8, %edi				# edi指向表中下一项
    dec %ecx
    jne rp_sidt
    lidt idt_descr				# 加载中断描述符表寄存器值
    ret

# 加载全局描述符表寄存器(全局描述符表内容已设置好)
setup_gdt:
    lgdt gdt_descr
    ret

/*
 * I put the kernel page tables right after the page directory,
 * using 4 of them to span 16 Mb of physical memory. People with
 * more than 16MB will have to expand this.
 */
/*
 * Linus将内核的内存页表直接放在页目录之后，使用了4个表来寻址16MB的物理内存。如果你有
 * 多于16MB的内存，就需要在这里进行扩充修改。
 */

 # 每个页表长为4KB字节(1页内存页面)
.org 0x1000		# 从偏移0x1000处开始存放第1个页表
pg0:

.org 0x2000
pg1:

.org 0x3000
pg2:

.org 0x4000
pg3:

.org 0x5000
/*
 * tmp_floppy_area is used by the floppy-driver when DMA cannot
 * reach to a buffer-block. It needs to be aligned, so that it isn't
 * on a 64kB border.
 */
/*
 * 当DMA不能访问缓冲块时，下面的tmp_floppy_area内存块就可供软盘
 * 驱动程序使用。其地址需要对齐调整，这样就不会跨越64KB边界。
 */

tmp_floppy_area:
    .fill 1024,1,0

/***** 为跳转到init/main.c中的main()函数作准备工作 *****/
# 前面3个入栈0值应该分别表示envp，argv指针和argc的值（main()没有用到）
# pushl $L6    压入返回地址
# pushl $main  压入main函数的入口地址
# 当head.s最后执行ret指令时就会弹出main()的地址
after_page_tables:
    pushl $0						# These are the parameters to main :-)
    pushl $0						# 这些是调用main程序的参数(指init/main.c).
    pushl $0
    pushl $L6						# return address for main, if it decides to.
    pushl $main
    jmp setup_paging				# 跳转至setup_paging
L6:
    jmp L6							# main should never return here, but
                                    # just in case, we know what happens.
                                    # main程序绝对不应该返回到这里，不过为了以防万一，所以
                                    # 添加了该语句。这样我们就知道发生什么问题了。

/* This is the default interrupt "handler" :-) */
/* 下面是默认的中断"向量句柄" */
int_msg:
    .asciz "Unknown interrupt\n\r"

.align 4
ignore_int:
    pushl %eax
    pushl %ecx
    pushl %edx
    push %ds
    push %es
    push %fs
    
    movl $0x10, %eax				# 设置段选择符(使ds，es，fs指向gdt表中的数据段)
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    pushl $int_msg
    call printk						# 该函数在kernel/printk.c中
    popl %eax
    
    pop %fs
    pop %es
    pop %ds
    popl %edx
    popl %ecx
    popl %eax
    iret							# 中断返回

/*
 * Setup_paging
 *
 * This routine sets up paging by setting the page bit
 * in cr0. The page tables are set up, identity-mapping
 * the first 16MB. The pager assumes that no illegal
 * addresses are produced (ie >4Mb on a 4Mb machine).
 *
 * NOTE! Although all physical memory should be identity
 * mapped by this routine, only the kernel page functions
 * use the >1Mb addresses directly. All "normal" functions
 * use just the lower 1Mb, or the local data space, which
 * will be mapped to some other place - mm keeps track of
 * that.
 *
 * For those with more memory than 16 Mb - tough luck. I've
 * not got it, why should you :-) The source is here. Change
 * it. (Seriously - it shouldn't be too difficult. Mostly
 * change some constants etc. I left it at 16Mb, as my machine
 * even cannot be extended past that (ok, but it was cheap :-)
 * I've tried to show which constants to change by having
 * some kind of marker at them (search for "16Mb"), but I
 * won't guarantee that's all :-( )
 */
/*
 * 这个子程序通过设置控制寄存器cr0的标志(PG位31)来启动对内存的分页处理功能，并设置各个页表项
 * 的内容，以恒等映射前16MB的物理内存。分页器假定不会产生非法的地址映射(也即在只有4MB的机器上
 * 设置出大于4MB的内存地址)
 *
 * 注意！尽管所有的物理地址都应该由这个子程序进行恒等映射，但只有内核页面管理函数能直接使用>1MB
 * 的地址。所有"普通"函数仅使用低于1MB的地址空间，或者是使用局部数据空间，该地址空间将被映射到
 * 其他一些地方去--mm(内存管理程序)会管理这些事的.
 *
 */
 # 上面英文注释第2段的含义是指在机器物理内存中大于1MB的内存空间主要被用于主内存区。主内存区空间
 # 由mm模块管理，它涉及页面映射操作。内核中所有其它函数就是这里指的"普通"函数。


# 初始化页目录表前4项和4个页表
.align 4
setup_paging:
    movl $1024 * 5, %ecx				/* 5 pages - pg_dir+4 page tables */
    xorl %eax, %eax
    xorl %edi, %edi						/* pg_dir is at 0x000 */	
                                        # 页目录从0x0000地址开始
    cld;rep;stosl						# eax内容存到es:edi所指内存位置处,且edi增4.

     # 设置页目录表中的前4个页目录项
     # 例如第1个页目录项：
     #      页表所在地址 = 0x00001007 & 0xfffff000 = 0x1000
     #      页表属性标志 = 0x00001007 & 0x00000fff = 0x07    表示该页存在,用户可读写.
    movl $pg0 + 7, pg_dir				/* set present bit/user r/w */
    movl $pg1 + 7, pg_dir + 4			/*  --------- " " --------- */
    movl $pg2 + 7, pg_dir + 8			/*  --------- " " --------- */
    movl $pg3 + 7, pg_dir + 12			/*  --------- " " --------- */

    # 设置4个页表中所有项的内容（共4096项），从最后一个页表的最后一项开始按倒退顺序填写
    movl $pg3 + 4092, %edi			# edi->最后一页的最后一项.
    movl $0xfff007, %eax			/* 16Mb - 4096 + 7 (r/w user,p) */
    std								# 方向位置位，edi值递减(4字节)
1:	stosl							/* fill pages backwards - more efficient :-) */
    subl $0x1000, %eax				# 每填好一项，物理地址值减0x1000。
    jge 1b							# 如果小于0则说明全填写好了
    cld
    # 设置页目录表基地址寄存器cr3（保存页目录表的物理地址）
    xorl %eax, %eax					/* pg_dir is at 0x0000 */
    movl %eax, %cr3					/* cr3 - page directory start */
    # 设置启动使用分页处理(cr0的PG标志，位31)
    movl %cr0, %eax
    orl $0x80000000, %eax			# 添上PG标志
    movl %eax, %cr0					/* set paging (PG) bit */
    ret								/* this also flushes prefetch-queue */

# 在改变分页处理标志后要求使用转移指令刷新预取指令队列，这里用的是返回指令ret。
# 该返回指令ret的另一个作用并跳转到/init/main.c程序去运行。

.align 4

# 256项8字节中断描述符表
.word 0
idt_descr:
    .word 256 * 8 - 1
    .long idt
.align 4

# 256项8字节全局描述符表
.word 0
gdt_descr:
    .word 256 * 8 - 1
    .long gdt

.align 8


# 中断描述符表填充内容,实际执行内容后续补充
idt:	.fill 256, 8, 0

# 全局描述符表,实际执行内容后续补充
gdt:
    .quad 0x0000000000000000			#空项
    .quad 0x00c09a0000000fff			#内核代码段, 长度16MB
    .quad 0x00c0920000000fff			#内核数据段, 长度16MB
    .quad 0x0000000000000000			#系统调用段描述符,没有使用
    .fill 252, 8, 0						#256-4=252 放置 LDT TSS
