;	setup.s		(C) 1991 Linus Torvalds

; setup.s 主要功能是加载操作系统可执行程序, 利用 BIOS 提供的与硬件交互的能力,即 BIOS 中断, 并将这些数据保存到0x90000开始的位置,覆盖掉 bootsect.bin 程序所在的地方
; 将 system.bin 从 0x10000-0x8ffff 整块向下移动到内存绝对地址 0x0000
; 在进入保护模式之前, 加载【中断描述符表寄存器 IDTR】, 指令 LLDT SLFT  用于访问 LDTR 寄存器
; 在进入保护模式之前, 加载【全局描述符表寄存器 GDTR】, 指令 LGDT SGDT  用于访问 GDTR 寄存器
; 开启 A20 地址线
; 设置中断控制芯片 8259A, 硬件中断号重新设置为 0x20 - 0x2f
; 设置 CPU 控制寄存器( CR0 机器状态字)
; 进入32位保护模式, 保护模式是 CPU 提供的一种使用方式,设置适当的参数开启
; 跳转到位于 system 模块最前面部分的 head.bin 继续运行
; 多次调用 ROM BIOS 中断服务, 开始涉及一些对硬件端口的访问操作

#include <linux/config.h>

INITSEG  = DEF_INITSEG	; 0x9000
SYSSEG   = DEF_SYSSEG	; system.bin 模块加载到 0x10000
SETUPSEG = DEF_SETUPSEG	; 0x9020 本程序,即该程序段所在地址

.globl begtext, begdata, begbss, endtext, enddata, endbss
.text
begtext:
.data
begdata:
.bss
begbss:
.text

entry start
start:

	mov	ax,#INITSEG
	mov	ds,ax

;;;;;;;;;; step 01 通过BIOS提供的与硬件交互的能力, 读有需要的硬件参数 ;;;;;;;;;;
; 内存地址	 ; 字节 ; 内容				 ;
; 0x90000	; 2	;   光标位置			;
; 0x90002	; 2	;	扩展内存大小 		 ;
; 0x90004	; 2	;	显示页面			;
; 0x90006	; 1 ;	显示模式			;
; 0x90007	; 1 ;	字符列数			;
; 0x90008	; 2	;	??				   ;
; 0x9000A	; 1	;	安装的显示内存		 ;
; 0x9000B	; 1	;	显示状态(彩色/单色)	 ;
; 0x9000C	; 2	;	显示卡特性参数		 ;
; 0x9000E	; 1	;	屏幕当前行值		 ;
; 0x9000F	; 1	;	屏幕当前列值		 ;
; ...								   ;
; 0x90080	; 16;	第1个硬盘的参数表	  ;
; 0x90090	; 16;	第2个硬盘的参数表	  ;
; 0x901FC	; 2 ;	根文件系统所在的设备号（bootsec.s中设置）;

;;;; 扩展内存大小(KB) ;;;;
; 0X15 功能号 ah=0x88 取得系统所含扩展内存大小并保存在内存 0x90002 处
	mov	ah,#0x88
	int	0x15
	mov	[2],ax

;;;; 显示器 EGA/VGA 配置参数 ;;;;
; 调用 BIOS 中断 ox10 功能号 0x12(视频子系统配置) 取EBA配置信息
; 返回值对应的数,分别存储
; bh 显示状态
; bl 安装的显示内存
; cx 显示卡特性参数
	mov	ah,#0x12
	mov	bl,#0x10
	int	0x10
	mov	[8],ax
	mov	[10],bx
	mov	[12],cx

; 显示器硬件的行列值
	mov	ax,#0x5019
	cmp	bl,#0x10 
	je	novga
	call	chsvga

; 使用 BIOS 中断 0x10, 功能号 0x03 取屏幕当前光标位置,并保存在内存 0x90000 处
; 在之后的应用中, 控制台初始化程序 console.c 会在此处读取该值
;
novga:	
	mov	[14],ax
	mov	ah,#0x03
	xor	bh,bh
	int	0x10
	mov	[0],dx		; 光标位置存储到 0x90000.
	
;;;; Get video-card data ;;;;
; 取显示卡当前显示模式
; 0x90004 存放当前页, 0x90006 存放显示模式, 0x90007 存放字符列数
	mov	ah,#0x0f
	int	0x10
	mov	[4],bx
	mov	[6],ax

;;;; 复制两个硬盘的参数表 ;;;;
; 第一个硬盘参数的首地址存储在 BIOS 的 0x41 中断向量
; 第二个硬盘参数的首地址存储在 BIOS 的 0x46 中断向量
; 复制 ROM BIOS 中有关两个硬盘参数到
; 0x90080 处存放第一个硬盘表
; 0x90090 存放在第二个硬盘的表
; hd0 参数
	mov	ax,#0x0000
	mov	ds,ax
	lds	si,[4*0x41]			; 取中断向量0x41的值，即hd0参数表的地址--ds:si
	mov	ax,#INITSEG
	mov	es,ax
	mov	di,#0x0080			; 传输目的地址: 0x9000:0x0080 --es:di
	mov	cx,#0x10
	rep
	movsb

; hd1 参数
	mov	ax,#0x0000
	mov	ds,ax
	lds	si,[4*0x46]			; 取中断向量0x46的值，即hd1参数表的地址--ds:si
	mov	ax,#INITSEG
	mov	es,ax
	mov	di,#0x0090			; 传输目的地址: 0x9000:0x0090 --es:di
	mov	cx,#0x10
	rep
	movsb

;;;; 检查系统是否存在第2个硬盘，如果不存在则第2个表清零 ;;;;
; 0x13 中断, 功能号 0x15
; 输入 dl = 驱动器号 0x8* 表示硬盘, 0x80是第一个硬盘, 0x81 是第2个硬盘
; 输出 ah = 类型码, 00- 盘不存在, 01-软驱 没有 change-line 支持, 02-软驱 其他可移动设备 03-硬盘

	mov	ax,#0x01500
	mov	dl,#0x81
	int	0x13
	jc	no_disk1
	cmp	ah,#3
	je	is_disk1		; 比较输出的类型码,等于03 表示硬盘

; 不存在第二个硬盘时,对0x90090处清零
no_disk1:
	mov	ax,#INITSEG
	mov	es,ax
	mov	di,#0x0090
	mov	cx,#0x10
	mov	ax,#0x00
	rep
	stosb

;;;; 进入保护模式 ;;;;
is_disk1:

; no interrupts allowed 这里开始不允许任何中断
	cli

;;;;;;;;;;; 把整个system模块移动到0x00000位置 ;;;;;;;;;;;
; bootsect 引导程序会把 system 模块读入到内存 0x10000(64KB) 起始的位置
; 当时认为system的大小不会超过, 0x80000(512KB) 即末端不会炒锅内存地址0x90000
; bootsect 在上面结论的基础上, 把自己移动到 0x90000 开始的地方,并把 setup 加载到它的后面
; 为了容纳更多的代码, 把system模块移动到0x00000位置
	mov	ax,#0x0000
	cld					! 'direction' = 0, movs moves forward
do_move:
	mov	es,ax			! destination segment ; es:di是目的地址(初始为0x0:0x0)

	; 判断是否移动完成
	add	ax,#0x1000
	cmp	ax,#0x9000
	jz	end_move

	mov	ds,ax			! source segment
	sub	di,di
	sub	si,si
	mov cx,#0x8000 		; 移动0x8000个字
	rep
	movsw
	jmp	do_move
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;; 加载段描述符表(临时gdt ldt表) ;;;;;;;;;;;
; 进入保护模式之前,需要首先设置好需要使用的段描述符表, 如全局描述符表 GDT 和 中断描述符表 IDT
;
end_move:
	mov	ax,#SETUPSEG	; right, forgot this at first. didn't work :-)
	mov	ds,ax
	lidt	idt_48		; load idt with 0,0					 ; 加载IDT寄存器
	lgdt	gdt_48		; load gdt with whatever appropriate ; 加载GDT寄存器


;;;;;;;;;;; 为了能访问1MB以上的内存,需要开启A20地址线 ;;;;;;;;;;;
; 测试 8042 状态寄存器, 等待输入缓冲区空,只有输入缓冲器为空时,才可以对其执行写指令
	call empty_8042
	mov al,#0xD1
	out #0x64,al 		; 位1用于A20线的选通
	call empty_8042
	mov al,#0xDF		; A20 on
	out	#0x60,al
	call empty_8042     ; 若此时输入缓冲器为空,则表示A20线已经选通

;;;;;;;;;;; 重新对8259A芯片进行编程, 不是需要理解的重点, 不做具体介绍 ;;;;;;;;;;;
; 在 Linux0.12 编写时, 使用2个可编程中断控制器 8259A 芯片
; 8259 芯片主片端口 0x20 - 0x21
; 8259 从片端口 0xA0 - 0xA1
;
	mov	al,#0x11
	out	#0x20,al                ; 主芯片的端口地址 0x20
	.word	0x00eb,0x00eb		; jmp $+2, jmp $+2 	; $ 表示当前指令的地址，
	out	#0xA0,al		        ; and to 8259A-2
	.word	0x00eb,0x00eb
	mov	al,#0x20		; start of hardware int's (0x20)
	out	#0x21,al
	.word	0x00eb,0x00eb
	mov	al,#0x28		; start of hardware int's 2 (0x28)
	out	#0xA1,al
	.word	0x00eb,0x00eb
	mov	al,#0x04		; 8259-1 is master
	out	#0x21,al
	.word	0x00eb,0x00eb
	mov	al,#0x02		; 8259-2 is slave
	out	#0xA1,al
	.word	0x00eb,0x00eb
	mov	al,#0x01		; 8086 mode for both
	out	#0x21,al
	.word	0x00eb,0x00eb
	out	#0xA1,al
	.word	0x00eb,0x00eb
	mov	al,#0xFF		; mask off all interrupts for now
	out	#0x21,al
	.word	0x00eb,0x00eb
	out	#0xA1,al

; 进入保护模式时，我们只需要简单地跳转到绝对地址0x00000处就好。 
; 这里设置进入32位保护模式运行。首先加载机器状态字(控制寄存器CR0),将其位0置1将导致CPU工作在保护模式。
; 注：在Intel公司的手册上建议80386或以上CPU应该使用指令“mov cr0,ax”切换到保护模式。

;;;;;;;;;;; 开启保护模式 ;;;;;;;;;;;
	mov	ax,#0x0001	; protected mode (PE) bit
	lmsw	ax		; 将CR0的位0置1开启保护模式
	jmpi	0,8
	; 偏移地址是0，因为system模块已被移动到0x00000处了。
	; 段值8则是保护模式下的段选择符。
	; 段选择符长度为16位（2字节）：
	; 	位0-1	- 表示请求的特权级0-3 ，linux0.12只用到两级：0级（系统级）和3级（用户级）
	;	位2		- 用于选择全局描述符表(0)还是局部描述符表(1)
	; 	位3-15	- 描述符表项的索引
	; 段选择符8(0000,0000,0000,1000)表示请求特权级0、使用全局描述符表gdt中的第1项（该项指出代码
	; 的基地址是0），因此这里的跳转指令就会去执行system中的代码。
;;;;;;;;;;; setup程序到这就结束了 ;;;;;;;;;;;

;;;;;;;;;;; 下面这个子程序检查键盘命令队列是否为空,这里不使用超时方法,如果死机,说明pc有问题,我们没有办法再处理下去了 ;;;;;;;;;;;
empty_8042:
	.word	0x00eb,0x00eb
	in	al,#0x64		; 8042 status port		; 读AT键盘控制器状态寄存器
	test	al,#2		; is input buffer full? ; 测试位1,输入缓冲器满?
	jnz	empty_8042		; yes - loop
	ret

;;;;; 以下代码牵涉到众多显卡端口信息，比较复杂。但跟内核运行关系不大，所以可以跳过不看 ;;;
chsvga:	cld
	push	ds
	push	cs
	pop	ds
	mov 	ax,#0xc000
	mov	es,ax
	lea	si,msg1
	call	prtstr
nokey:	
	in	al,#0x60
	cmp	al,#0x82
	jb	nokey
	cmp	al,#0xe0
	ja	nokey
	cmp	al,#0x9c
	je	svga
	mov	ax,#0x5019
	pop	ds
	ret
svga:	lea 	si,idati		; Check ATI 'clues'
	mov	di,#0x31
	mov 	cx,#0x09
	repe
	cmpsb
	jne	noati
	lea	si,dscati
	lea	di,moati
	lea	cx,selmod
	jmp	cx
noati:	mov	ax,#0x200f		; Check Ahead 'clues'
	mov	dx,#0x3ce
	out	dx,ax
	inc	dx
	in	al,dx
	cmp	al,#0x20
	je	isahed
	cmp	al,#0x21
	jne	noahed
isahed:	lea	si,dscahead
	lea	di,moahead
	lea	cx,selmod
	jmp	cx
noahed:	mov	dx,#0x3c3		; Check Chips & Tech. 'clues'
	in	al,dx
	or	al,#0x10
	out	dx,al
	mov	dx,#0x104		
	in	al,dx
	mov	bl,al
	mov	dx,#0x3c3
	in	al,dx
	and	al,#0xef
	out	dx,al
	cmp	bl,[idcandt]
	jne	nocant
	lea	si,dsccandt
	lea	di,mocandt
	lea	cx,selmod
	jmp	cx
nocant:	mov	dx,#0x3d4		; Check Cirrus 'clues'
	mov	al,#0x0c
	out	dx,al
	inc	dx
	in	al,dx
	mov	bl,al
	xor	al,al
	out	dx,al
	dec	dx
	mov	al,#0x1f
	out	dx,al
	inc	dx
	in	al,dx
	mov	bh,al
	xor	ah,ah
	shl	al,#4
	mov	cx,ax
	mov	al,bh
	shr	al,#4
	add	cx,ax
	shl	cx,#8
	add	cx,#6
	mov	ax,cx
	mov	dx,#0x3c4
	out	dx,ax
	inc	dx
	in	al,dx
	and	al,al
	jnz	nocirr
	mov	al,bh
	out	dx,al
	in	al,dx
	cmp	al,#0x01
	jne	nocirr
	call	rst3d4	
	lea	si,dsccirrus
	lea	di,mocirrus
	lea	cx,selmod
	jmp	cx
rst3d4:	mov	dx,#0x3d4
	mov	al,bl
	xor	ah,ah
	shl	ax,#8
	add	ax,#0x0c
	out	dx,ax
	ret	
nocirr:	call	rst3d4			; Check Everex 'clues'
	mov	ax,#0x7000
	xor	bx,bx
	int	0x10
	cmp	al,#0x70
	jne	noevrx
	shr	dx,#4
	cmp	dx,#0x678
	je	istrid
	cmp	dx,#0x236
	je	istrid
	lea	si,dsceverex
	lea	di,moeverex
	lea	cx,selmod
	jmp	cx
istrid:	lea	cx,ev2tri
	jmp	cx
noevrx:	lea	si,idgenoa		; Check Genoa 'clues'
	xor 	ax,ax
	seg es
	mov	al,[0x37]
	mov	di,ax
	mov	cx,#0x04
	dec	si
	dec	di
l1:	inc	si
	inc	di
	mov	al,(si)
	seg es
	and	al,(di)
	cmp	al,(si)
	loope 	l1
	cmp	cx,#0x00
	jne	nogen
	lea	si,dscgenoa
	lea	di,mogenoa
	lea	cx,selmod
	jmp	cx
nogen:	lea	si,idparadise		; Check Paradise 'clues'
	mov	di,#0x7d
	mov	cx,#0x04
	repe
	cmpsb
	jne	nopara
	lea	si,dscparadise
	lea	di,moparadise
	lea	cx,selmod
	jmp	cx
nopara:	mov	dx,#0x3c4		; Check Trident 'clues'
	mov	al,#0x0e
	out	dx,al
	inc	dx
	in	al,dx
	xchg	ah,al
	mov	al,#0x00
	out	dx,al
	in	al,dx
	xchg	al,ah
	mov	bl,al		; Strange thing ... in the book this wasn't 				'
	and	bl,#0x02	; necessary but it worked on my card which
	jz	setb2		; is a trident. Without it the screen goes
	and	al,#0xfd	; blurred ...
	jmp	clrb2		;
setb2:	or	al,#0x02	;
clrb2:	out	dx,al
	and	ah,#0x0f
	cmp	ah,#0x02
	jne	notrid
ev2tri:	lea	si,dsctrident
	lea	di,motrident
	lea	cx,selmod
	jmp	cx
notrid:	mov	dx,#0x3cd		; Check Tseng 'clues'
	in	al,dx			; Could things be this simple ; :-)
	mov	bl,al
	mov	al,#0x55
	out	dx,al
	in	al,dx
	mov	ah,al
	mov	al,bl
	out	dx,al
	cmp	ah,#0x55
 	jne	notsen
	lea	si,dsctseng
	lea	di,motseng
	lea	cx,selmod
	jmp	cx
notsen:	mov	dx,#0x3cc		; Check Video7 'clues'
	in	al,dx
	mov	dx,#0x3b4
	and	al,#0x01
	jz	even7
	mov	dx,#0x3d4
even7:	mov	al,#0x0c
	out	dx,al
	inc	dx
	in	al,dx
	mov	bl,al
	mov	al,#0x55
	out	dx,al
	in	al,dx
	dec	dx
	mov	al,#0x1f
	out	dx,al
	inc	dx
	in	al,dx
	mov	bh,al
	dec	dx
	mov	al,#0x0c
	out	dx,al
	inc	dx
	mov	al,bl
	out	dx,al
	mov	al,#0x55
	xor	al,#0xea
	cmp	al,bh
	jne	novid7
	lea	si,dscvideo7
	lea	di,movideo7
selmod:	push	si
	lea	si,msg2
	call	prtstr
	xor	cx,cx
	mov	cl,(di)
	pop	si
	push	si
	push	cx
tbl:	pop	bx
	push	bx
	mov	al,bl
	sub	al,cl
	call	dprnt
	call	spcing
	lodsw
	xchg	al,ah
	call	dprnt
	xchg	ah,al
	push	ax
	mov	al,#0x78
	call	prnt1
	pop	ax
	call	dprnt
	call	docr
	loop	tbl
	pop	cx
	call	docr
	lea	si,msg3
	call	prtstr
	pop	si
	add	cl,#0x80
nonum:	in	al,#0x60	; Quick and dirty...
	cmp	al,#0x82
	jb	nonum
	cmp	al,#0x8b
	je	zero
	cmp	al,cl
	ja	nonum
	jmp	nozero
zero:	sub	al,#0x0a
nozero:	sub	al,#0x80
	dec	al
	xor	ah,ah
	add	di,ax
	inc	di
	push	ax
	mov	al,(di)
	int 	0x10
	pop	ax
	shl	ax,#1
	add	si,ax
	lodsw
	pop	ds
	ret
; 若都不是上面检测地显示卡，我们就只好采用默认地80*25的标准行列值。
novid7:	pop	ds	; Here could be code to support standard 80x50,80x30
	mov	ax,#0x5019	
	ret

; Routine that 'tabs' to next col.

spcing:	mov	al,#0x2e
	call	prnt1
	mov	al,#0x20
	call	prnt1	
	mov	al,#0x20
	call	prnt1	
	mov	al,#0x20
	call	prnt1	
	mov	al,#0x20
	call	prnt1
	ret	

; Routine to print asciiz-string at DS:SI

prtstr:	lodsb
	and	al,al
	jz	fin
	call	prnt1
	jmp	prtstr
fin:	ret

; Routine to print a decimal value on screen, the value to be
; printed is put in al (i.e 0-255).

dprnt:	push	ax
	push	cx
	mov	ah,#0x00		
	mov	cl,#0x0a
	idiv	cl
	cmp	al,#0x09
	jbe	lt100
	call	dprnt
	jmp	skip10
lt100:	add	al,#0x30
	call	prnt1
skip10:	mov	al,ah
	add	al,#0x30
	call	prnt1	
	pop	cx
	pop	ax
	ret

; Part of above routine, this one just prints ascii al

prnt1:	push	ax
	push	cx
	mov	bh,#0x00
	mov	cx,#0x01
	mov	ah,#0x0e
	int	0x10
	pop	cx
	pop	ax
	ret

; Prints <CR> + <LF>

docr:	push	ax
	push	cx
	mov	bh,#0x00
	mov	ah,#0x0e
	mov	al,#0x0a
	mov	cx,#0x01
	int	0x10
	mov	al,#0x0d
	int	0x10
	pop	cx
	pop	ax
	ret	
;;;;; 跟显示卡相关代码至此结束 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;; 全局描述符表（临时，每个描述符项长8个字节）
gdt:
	.word	0,0,0,0		; dummy	;第1个描述符，不用

	; 在GDT表的偏移量是0x08。它是内核代码段选择符的值。
	.word	0x07FF		; 8Mb - limit=2047 (2048*4096=8Mb)
	.word	0x0000		; base address=0
	.word	0x9A00		; code read/exec		; 代码段为只读，可执行
	.word	0x00C0		; granularity=4096, 386 ; 颗粒度4K，32位

	.word	0x07FF		; 8Mb - limit=2047 (2048*4096=8Mb)
	.word	0x0000		; base address=0
	.word	0x9200		; data read/write		; 数据段为可读可写
	.word	0x00C0		; granularity=4096, 386	; 颗粒度4K，32位

; 加载中断描述符表寄存器指令lidt要求的6字节操作数。
; 注：CPU要求在进入保护模式之前需设置idt表，因此这里先设置一个长度为0的空表。
idt_48:
	.word	0			; idt limit=0	; idt的限长
	.word	0,0			; idt base=0L	; idt表在线性地址空间中的32位基地址

; 加载全局描述符表寄存器指令lgdt要求的6字节操作数。
gdt_48:
	.word	0x800		; gdt limit=2048, 256 GDT entries
						; 表限长2k
	.word	512+gdt,0x9	; gdt base = 0X9xxxx
						; （线性地址空间）基地址：0x90200 + gdt

;;;;; 以下跟显示卡相关（可以不看） ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
msg1:		.ascii	"Press <RETURN> to see SVGA-modes available or any other key to continue."
		db	0x0d, 0x0a, 0x0a, 0x00
msg2:		.ascii	"Mode:  COLSxROWS:"
		db	0x0d, 0x0a, 0x0a, 0x00
msg3:		.ascii	"Choose mode by pressing the corresponding number."
		db	0x0d, 0x0a, 0x00
		
idati:		.ascii	"761295520"
idcandt:	.byte	0xa5
idgenoa:	.byte	0x77, 0x00, 0x66, 0x99
idparadise:	.ascii	"VGA="

; Manufacturer:	  Numofmodes:	Mode:
; 厂家：			模式数量：		模式列表：
moati:		.byte	0x02,	0x23, 0x33 
moahead:	.byte	0x05,	0x22, 0x23, 0x24, 0x2f, 0x34
mocandt:	.byte	0x02,	0x60, 0x61
mocirrus:	.byte	0x04,	0x1f, 0x20, 0x22, 0x31
moeverex:	.byte	0x0a,	0x03, 0x04, 0x07, 0x08, 0x0a, 0x0b, 0x16, 0x18, 0x21, 0x40
mogenoa:	.byte	0x0a,	0x58, 0x5a, 0x60, 0x61, 0x62, 0x63, 0x64, 0x72, 0x74, 0x78
moparadise:	.byte	0x02,	0x55, 0x54
motrident:	.byte	0x07,	0x50, 0x51, 0x52, 0x57, 0x58, 0x59, 0x5a
motseng:	.byte	0x05,	0x26, 0x2a, 0x23, 0x24, 0x22
movideo7:	.byte	0x06,	0x40, 0x43, 0x44, 0x41, 0x42, 0x45

;			msb = Cols lsb = Rows:
;			高字节 = 列数 低字节 = 行数
dscati:		.word	0x8419, 0x842c
dscahead:	.word	0x842c, 0x8419, 0x841c, 0xa032, 0x5042
dsccandt:	.word	0x8419, 0x8432
dsccirrus:	.word	0x8419, 0x842c, 0x841e, 0x6425
dsceverex:	.word	0x5022, 0x503c, 0x642b, 0x644b, 0x8419, 0x842c, 0x501e, 0x641b, 0xa040, 0x841e
dscgenoa:	.word	0x5020, 0x642a, 0x8419, 0x841d, 0x8420, 0x842c, 0x843c, 0x503c, 0x5042, 0x644b
dscparadise:	.word	0x8419, 0x842b
dsctrident:	.word 	0x501e, 0x502b, 0x503c, 0x8419, 0x841e, 0x842b, 0x843c
dsctseng:	.word	0x503c, 0x6428, 0x8419, 0x841c, 0x842c
dscvideo7:	.word	0x502b, 0x503c, 0x643c, 0x8419, 0x842c, 0x841c
;;;;;; 显示卡相关 到这结束 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

.text
endtext:
.data
enddata:
.bss
endbss:
