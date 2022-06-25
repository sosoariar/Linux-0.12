;;;; 磁盘引导块程序 ;;;;
; 该文件代码的可执行二进制文件,驻留在磁盘的第一扇区,即引导扇区
; 该程序是如何写入第一扇区呢? 类似U盘装机的时候,需要在U盘写入Boot
; BIOS 把第一扇区MBR的bootsect可执行代码, 加载到0x7C00内存处, BIOS 会把CS:IP也指向该位置,并开始执行bootsect代码逻辑
; 将bootsect 的可执行代码移动到 0x90000处
; bootsect的功能: 从磁盘将2~5扇区的 setup可执行代码(由setup.s编译而成, 一共4个扇区)
; 利用BIOS中断0x13,显示 Loading System 字样
; 读取磁盘 setup 模块后面的 system模块加载到内存 0x10000 开始的地方
; 确定根文件系统设备号,若没有指定,则根据所保存的引导盘的每磁道扇区数 判别出盘的类型和种类(是 1.44M A盘吗？) 并保存设备号于 root_dev 处
; 最后长跳转到setup开始处(0x90200)去执行 setup 程序
; 于0x30000bytes=192KB，对于当前的版本空间已足够了。
; 该头文件里定义了内核用到的一些常数符号和Linus自己使用的默认硬盘默认参数块。

#include <linux/config.h>

SYSSIZE = DEF_SYSSIZE 	; 系统模块大小为0x3000节

; .globl 使得连接程序（ld）能够看到symbl。如果你的局部程序中定义了symbl，那么，与这个局部程序连接的其他局部程序也能存取symbl
; .text  包含程序的代码,它是只读节
; .data  已初始化的数据,包含具有初值的那些变量 读／写节
; .bss 这个节包含程序还未初始化的数据，也就是说，包含没有初值的那些变量。当操作系统装入这个程序时将把这些变量都置为0 读／写节

.globl begtext, begdata, begbss, endtext, enddata, endbss
.text
begtext:
.data
begdata:
.bss
begbss:

;;;; 代码段内容 ;;;;
.text

SETUPLEN = 4					; setup.s    的可执行二进制代码在【磁盘】扇占用的区数 4*512B = 2KB
BOOTSEG  = 0x07c0				; bootsect.s 的可执行二进制代码被加载到【内存】实物理地址 0x7c00
INITSEG  = DEF_INITSEG			; bootsect.s 的可执行二进制代码在加载到0x7c00后,自身的代码逻辑会再移动一次代码到此处,为了避开系统模块占用处
SETUPSEG = DEF_SETUPSEG			; setup.s    的可执行二进制代码被加载到【内存】实物理地址 0x9020
SYSSEG   = DEF_SYSSEG			; system.s   的可执行二进制代码被加载到【内存】实物理地址 0x10000
ENDSEG   = SYSSEG + SYSSIZE		; 为了保护实际物理内存中的其他内容不被改写, 定义了物理内存的边界, 停止加载的段地址

; 还没遇到变量的使用场景,含义待定
; ROOT_DEV 根文件系统设备号, 根文件系统是个逻辑上的抽象,代表这块存储是核心的内容
; BIOS 在初始化后扫描硬件后, 后续的程序就可以通过设备号来定位物理设备,即设备有了自己的ID
ROOT_DEV = 0

; 还没遇到变量的使用场景,含义待定
; 用作内存换出的设备
SWAP_DEV = 0

; 伪指令 entry 用于指定汇编程序的入口点
; 告知链接程序, 程序从start标号处开始执行
entry start
start:
;;;; operator-01 将【实地址0x7c00】256字(512B)移动到【实地址0x90000】处 ;;;;
    mov	ax,#BOOTSEG
    mov	ds,ax
    mov	ax,#INITSEG
    mov	es,ax
    mov	cx,#256     ; 设置计数器 = 256
    sub	si,si       ; 清零操作si=0x0000, 与ds组合成源地址, 即 ds:si = 0x07c0:0x0000
    sub	di,di       ; 清零操作si=0x0000, 与di组合成目标地址, 即 es:di = 0x9000:0x0000
    rep             ; rep 重复后面的指令, 即 movw 逐word移动, 该指令包装的移动所需的寄存器即 从 ds 到 es
    movw            ; 此处结束后，代码已经成功移动到0x90000
    jmpi go,INITSEG ; 段间跳转(Jump Intersegment),跳转到INITSEG:go(段地址:段内偏移)处,目的即跳过同一段代码的迁移逻辑,从go标号处开始执行代码

;;;; operator-02 0x9000 处开始执行的第一句代码,上述的 jmpi 指令会将CPU的CS:IP指向此处
go:	mov	ax,cs       ; 将段寄存器 DS ES SS 设置为 0x9000
    mov	dx,#0xfef4	; 栈指针从上往下,堆从下往上,堆从0开始,栈从尽可能大的位置往下,根据当时物理容量实际情况,选择从:0x9fef4为栈指针,sp:dx被设置成了0xff00-12(参数表长度)，即sp = 0xfef4。
    mov	ds,ax
    mov	es,ax
    ;push   ax		; 临时保存段值(0x9000)，供后面使用。
    ;; 初始化栈指针
    mov	ss,ax
    mov	sp,dx

/*
 *  BIOS在校验硬件时, 可以得到有多少扇区可以操作;
 *	Many BIOS's default disk parameter tables will not recognize multi-sector reads beyond the maximum sector number ;
 *	specified in the default diskette parameter tables - this may
 *	mean 7 sectors in some cases.
 *
 *	Since single sector reads are slow and out of the question,
 *	we must take care of this by creating new parameter tables
 *	(for the first disk) in RAM.  We will set the maximum sector
 *	count to 18 - the most we will encounter on an HD 1.44.
 *
 *	High doesn't hurt.  Low does.
 */

;;;;; 修改软驱参数表 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; BIOS中断0x1e的中断向量值是软驱参数表地址。该向量值位于内存0x1e*4=0x78处。这段代码首先从内
; 存0x0000:0x0078处复制原软驱参数表到0x9000:0xfef4处，然后修改表中的每磁道最大扇区数为18。

    push	#0
    pop		fs
    mov	bx,	#0x78		; fs:bx is parameter table address

    seg fs              ; seg fs只影响接下来的一条语句，表示下一条语句的操作数在fs所指的段中
    lgs	si,(bx)			! gs:si is source       ; 将fs:bx赋值给gs:si 0x0000:0x0078
    mov	di,dx			! es:di is destination  ;                   0x9000:0xfef4
    mov	cx,#6			! copy 12 bytes
    cld

    rep
    seg gs
    movw

    mov	di,dx
    movb 4(di),*18		! patch sector count ;修改新表的最大扇区数为18

    seg fs 				; 让中断向量0x1e的值指向新表
    mov	(bx),di
    seg fs
    mov	2(bx),es

    mov ax,cs           ; pop ax	! ax = 0x9000
    mov	fs,ax
    mov	gs,ax

    xor	ah,ah			! reset FDC ; 复位软盘控制器，让其采用新参数。
    xor	dl,dl 			! dl = 0    ; 第1个软驱
    int 0x13

! load the setup-sectors directly after the bootblock.
! Note that 'es' is already set up.
; 在bootsect程序块后紧跟着加载setup模块的代码数据。
; 在移动代码时，es的值已被设置好。

;;;;; 2. 加载setup模块到0x90200开始处，共读4个扇区 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; 如果读出错，显示磁盘上出错扇区位置，则复位驱动器，并重试，没有退路。
load_setup:
    xor	dx, dx					! drive 0, head 0
    mov	cx,#0x0002				! sector 2, track 0
    mov	bx,#0x0200				! address = 512, in INITSEG
    mov	ax,#0x0200+SETUPLEN		! service 2, nr of sectors
    int	0x13					! read it
    jnc	ok_load_setup 			! ok - continue ;jnc - jump not cf

    push	ax			! dump error code
    call	print_nl
    mov	bp, sp
    call	print_hex
    pop	ax

    xor	dl, dl			! reset FDC ;复位磁盘控制器，重试。
    xor	ah, ah
    int	0x13
    j	load_setup 		; j - jmp

ok_load_setup:

! Get disk drive parameters, specifically nr of sectors/track
; 这段代码取磁盘驱动器的参数，特别是每道的扇区数量，并保存在位置sectors处。
    xor	dl,dl
    mov	ah,#0x08        ! AH=8 is get drive parameters
    int	0x13
    xor	ch,ch
    seg cs
    mov	sectors,cx      ; 保存每磁道扇区数。
    mov	ax,#INITSEG
    mov	es,ax           ; 上面取磁盘参数中断改了es的值，这里需要改回来

! Print some inane message
; 在显示一些信息('Loading\r\n'，共9个字符)。
    mov	ah,#0x03        ! read cursor pos
    xor	bh,bh
    int	0x10

    mov	cx,#9
    mov	bx,#0x0007      ! page 0, attribute 7 (normal)
    mov	bp,#msg1
    mov	ax,#0x1301      ! write string, move cursor
    int	0x10
! ok, we've written the message, now

! we want to load the system (at 0x10000)
;;;;; 3. 将system模块加载到0x10000(64K)处 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    mov	ax,#SYSSEG
    mov	es,ax			! segment of 0x010000
    call	read_it 	; 读磁盘上system模块
    call	kill_motor 	; 关闭驱动器马达
    call	print_nl

! After that we check which root-device to use. If the device is
! defined (!= 0), nothing is done and the given device is used.
! Otherwise, either /dev/PS0 (2,28) or /dev/at0 (2,8), depending
! on the number of sectors that the BIOS reports currently.
; 此后，我们检查要使用哪个根文件系统设备。如果已经指定了设备(!=0)就直接使用给定
; 的设备。否则就需要根据BIOS报告的每磁道扇区数来确定到底使用/dev/PS0(2,28)
; 还是/dev/at0(2,8)。
; 在Linux中，软驱的主设备号是2，次设备号 = type << 2 + nr，
;       type    软驱的类型（2->1.2M或7->1.44M等）。
;       nr      0-3分别对应软驱A、B、C或D；

    seg cs
    mov	ax,root_dev
    or	ax,ax
    jne	root_defined
    seg cs              ; 取出sectors的值(每磁道扇区数)
    mov	bx,sectors      
    mov	ax,#0x0208      ! /dev/PS0 - 1.2Mb
    cmp	bx,#15          ; sectors=15则说明是1.2MB的软驱
    je	root_defined
    mov	ax,#0x021c      ! /dev/PS0 - 1.44Mb
    cmp	bx,#18          ; sectors=18则说明是1.44MB的软驱
    je	root_defined
undef_root:
    jmp undef_root
root_defined:
    seg cs
    mov	root_dev,ax

! after that (everyting loaded), we jump to
! the setup-routine loaded directly after
! the bootblock:

;;;;; 4. 到此，所有程序都加载完毕，我们就跳转到setup程序去 ;;;;;;;;;;;;;;;;;;;;;;;;;
    jmpi	0,SETUPSEG

;;;;; bootsect.S程序到此就结束了 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; 下面是几个子程序:
; read_it 用于读取磁盘上的system模块
; kill_motor 用于关闭软驱电动机
; 还有一些屏幕显示子程序

! This routine loads the system at address 0x10000, making sure
! no 64kB boundaries are crossed. We try to load it as fast as
! possible, loading whole tracks whenever we can.
!
! in:	es - starting address segment (normally 0x1000)
!
; 该子程序将系统模块system加载到内存地址0x10000处，并确定没有跨越64KB的内存边界。
sread:	.word 1+SETUPLEN	! sectors read of current track
                            ; 当前磁道的已读扇区数（bootsect + setup）
head:	.word 0				! current head  ;当前磁头号
track:	.word 0				! current track ;当前磁道号

read_it:
; 首先测试输入的段值。必须位于内存地址64KB边界处，否则进入死循环。
    mov ax,es
    test ax,#0x0fff
die:
    jne die			! es must be at 64kB boundary   ; es值必须位于64KB地址边界。
    xor bx,bx		! bx is starting address within segment
rp_read:
    mov ax,es
    cmp ax,#ENDSEG		! have we loaded all yet? ; 是否已经加载了全部数据？
    jb ok1_read
    ret
ok1_read:
    ; 计算和验证当前磁道需要读取的扇区数，放在ax寄存器中。
    seg cs
    mov ax,sectors
    sub ax,sread
    mov cx,ax
    shl cx,#9
    add cx,bx
    jnc ok2_read
    je ok2_read
    xor ax,ax
    sub ax,bx
    shr ax,#9
ok2_read:
    call read_track ; 读当前磁道上指定扇区和需读扇区数的数据
    mov cx,ax
    add ax,sread
    seg cs
    cmp ax,sectors
    jne ok3_read
    mov ax,#1
    sub ax,head
    jne ok4_read
    inc track
ok4_read:
    mov head,ax
    xor ax,ax
ok3_read:
    mov sread,ax
    shl cx,#9
    add bx,cx
    jnc rp_read
    mov ax,es
    add ah,#0x10
    mov es,ax
    xor bx,bx
    jmp rp_read

; 读当前磁道上指定开始扇区和需读扇区数的数据到es:bx开始处。
read_track:
    pusha			; push all
    pusha
    mov	ax, #0xe2e 	! loading... message 2e = .
    mov	bx, #7
    int	0x10
    popa
    ; 开始进行磁道扇区读操作
    mov dx,track
    mov cx,sread
    inc cx
    mov ch,dl
    mov dx,head
    mov dh,dl
    and dx,#0x0100 
    mov ah,#2

    push	dx      ! save for error dump
    push	cx      ; 保留出错情况
    push	bx
    push	ax

    int 0x13
    jc bad_rt
    add	sp, #8      ; 若没有出错，丢弃为出错情况保存的信息
    popa
    ret

; 读磁盘操作出错
bad_rt:
    push	ax          ! save error code
    call	print_all   ! ah = error, al = read

    xor ah,ah
    xor dl,dl
    int 0x13

    add	sp, #10
    popa
    jmp read_track

/*
 *	print_all is for debugging purposes.
 *	It will print out all of the registers.  The assumption is that this is
 *	called from a routine, with a stack frame like
 *	dx
 *	cx
 *	bx
 *	ax
 *	error
 *	ret <- sp
 *
*/
; print_all 用于调试目的，前提是从一个子程序中调用。栈帧结构如上所示
print_all:
    mov	cx, #5          ! error code + 4 registers
    mov	bp, sp          ; 保存当前栈指针sp.

print_loop:
    push	cx          ! save count left
    call	print_nl    ! nl for readability
    jae		no_reg      ! see if register name is needed

    ; 下面几行用于显示寄存器号，例如："AX:", 0x45 - E
    mov	ax, #0xe05 + 0x41 - 1 ; ah = 功能号(0x0e)；al = 字符(0x05 + 0x41 - 1)
    sub	al, cl
    int	0x10

    mov	al, #0x58       ! X
    int	0x10

    mov	al, #0x3a       ! :
    int	0x10
; 显示寄存器bp所指栈中的内容
no_reg:
    add	bp, #2          ! next register
    call	print_hex   ! print it
    pop	cx
    loop	print_loop
    ret

; 显示回车换行
print_nl:
    mov	ax, #0xe0d      ! CR
    int		0x10
    mov	al, #0xa        ! LF
    int 	0x10
    ret

/*
 *	print_hex is for debugging purposes, and prints the word
 *	pointed to by ss:bp in hexadecmial.
*/
/* 子程序print_hex用于调试目的.它使用十六进制在屏幕上显示出ss:bp指向的字 */
print_hex:
    mov	cx, #4      ! 4 hex digits
    mov	dx, (bp)    ! load word into dx

; 先显示高字节，因此需要把dx中值左旋4位，此时高4位在dx的低4位中
print_digit:
    rol	dx, #4      ! rotate so that lowest 4 bits are used ;左旋4位
    mov	ah, #0xe
    mov	al, dl      ! mask off so we have only next nibble
    and	al, #0xf    ; 只取低四位显示
    add	al, #0x30   ! convert to 0 based digit, '0'
    cmp	al, #0x39   ! check for overflow ; 大于9的处理，转换成A-F
    jbe	good_digit
    add	al, #0x41 - 0x30 - 0xa  ! 'A' - '0' - 0xa

good_digit:
    int	0x10
    loop	print_digit
    ret

/*
 * This procedure turns off the floppy drive motor, so
 * that we enter the kernel in a known state, and
 * don't have to worry about it later.					'
 */
; 这个子程序用于关闭软驱的马达，这样我们进入内核后它处于已知状态，以后也就无须担心它了。
kill_motor:
    push dx
    mov dx,#0x3f2
    xor al, al
    outb
    pop dx
    ret

sectors:
    .word 0

msg1:
    .byte 13,10
    .ascii "Loading"

.org 506
; swap_dev在第506开始的2个字节中，root_dev在第508开始的2个字节中
swap_dev:
    .word SWAP_DEV
root_dev:
    .word ROOT_DEV

; 下面2个字节是有效引导扇区的标志（必须位于引导扇区的最后两个字节中）
boot_flag:
    .word 0xAA55

.text
endtext:
.data
enddata:
.bss
endbss:
