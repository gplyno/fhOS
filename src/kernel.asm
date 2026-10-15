; =====================================================================
;  fhOS - ядро (kernel) с минимальным GUI и файловой системой
; ---------------------------------------------------------------------
;  Загружается по адресу 1000:0000 (ядро начинается со смещения 0x0200),
;  работает в 16-битном реальном режиме.
;
;  Графика  : видеорежим VGA 13h (320x200, 256 цветов); шрифт 8x8
;             берётся из ROM BIOS (INT 10h/11h).
;  Клавиатура: PS/2, опрос портов 0x60/0x64 напрямую.
;  ФС       : простая файловая система в оперативной памяти.
; =====================================================================
BITS 16
ORG 0x0200                     ; ядро загружается сразу за stage 1

MAXLINE equ 128

; ---- геометрия экрана ----
SCREEN_W  equ 320
SCREEN_H  equ 200
TASKBAR_H equ 14

WIN_X equ 4
WIN_Y equ 20
WIN_W equ 312
WIN_H equ 170

CON_COLS equ 38
CON_ROWS equ 19
CON_X0   equ WIN_X+4           ; 8
CON_Y0   equ WIN_Y+14          ; 34

CLK_X equ 252

; ---- индексы цветов палитры ----
C_WALL   equ 0                 ; обои (просто цвет)
C_TASK   equ 1                 ; панель задач
C_WINBG  equ 2                 ; фон окна/консоли
C_TITLE  equ 3                 ; заголовок окна
C_BORDER equ 4                 ; рамка окна
C_TEXT   equ 5                 ; текст
C_ACCENT equ 6
C_DIM    equ 7

; ---- файловая система ----
FS_MAX  equ 24                 ; максимум файлов
FS_NLEN equ 16                 ; длина имени
FS_DLEN equ 200                ; максимум данных на файл

; =====================================================================
;  ТОЧКА ВХОДА
; =====================================================================
start:
    cli
    mov ax, 0x1000
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0xFF00             ; стек в конце сегмента
    sti

    call kbd_init
    call gui_init              ; режим 13h, палитра, шрифт, рабочий стол

    mov si, banner
    call puts
    mov si, subtitle
    call puts
    call fs_seed               ; демонстрационные файлы
    call con_refresh

; ---------------------------------------------------------------------
;  Главный цикл оболочки
; ---------------------------------------------------------------------
shell_loop:
    mov si, prompt
    call puts
    call con_refresh
    call read_line
    call execute
    call con_refresh
    jmp shell_loop

; =====================================================================
;  ГРАФИКА (режим 13h, кадровый буфер A000:0000)
; =====================================================================

; ---------------------------------------------------------------------
; fill_rect - заливка прямоугольника
;   r_x, r_y, r_w, r_h - координаты и размер (слова), r_color - цвет
; ---------------------------------------------------------------------
fill_rect:
    pusha
    push es
    mov ax, 0xA000
    mov es, ax
    mov ax, [r_y]
    mov cx, SCREEN_W
    mul cx
    add ax, [r_x]
    mov di, ax
    mov cx, [r_h]
    test cx, cx
    jz .done
    mov al, [r_color]
    cld
.row:
    push cx
    push di
    mov cx, [r_w]
    test cx, cx
    jz .skiprow
    rep stosb
.skiprow:
    pop di
    pop cx
    add di, SCREEN_W
    loop .row
.done:
    pop es
    popa
    ret

; ---------------------------------------------------------------------
; draw_char - нарисовать символ шрифта BIOS
;   AL = символ, CX = X (пиксели), DX = Y (пиксели), BL = цвет
; ---------------------------------------------------------------------
draw_char:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push bp
    push ds
    push es

    push ax
    mov ax, 0x1000
    mov ds, ax
    pop ax

    and ax, 0x007F
    mov di, ax
    shl di, 3
    add di, font_buf           ; DI -> глиф (8 байт)

    mov ax, dx                 ; Y
    mov si, SCREEN_W
    mul si                     ; DX:AX = Y*320
    add ax, cx                 ; + X
    mov bp, ax                 ; BP = смещение в кадровом буфере

    mov ax, 0xA000
    mov es, ax

    mov cx, 8                  ; 8 строк глифа
.row:
    mov al, [di]
    inc di
    xor si, si
.bit:
    shl al, 1
    jnc .skip
    mov [es:bp+si], bl
.skip:
    inc si
    cmp si, 8
    jb .bit
    add bp, SCREEN_W
    loop .row

    pop es
    pop ds
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ---------------------------------------------------------------------
; draw_text - нарисовать строку, завершённую нулём
;   SI = строка, gt_x, gt_y - позиция, gt_color - цвет
; ---------------------------------------------------------------------
draw_text:
    pusha
.loop:
    lodsb
    test al, al
    jz .done
    mov bl, [gt_color]
    mov cx, [gt_x]
    mov dx, [gt_y]
    call draw_char
    add word [gt_x], 8
    jmp .loop
.done:
    popa
    ret

; ---------------------------------------------------------------------
; set_palette - загрузить палитру, SI -> 16*3 байт (R,G,B по 0..63)
; ---------------------------------------------------------------------
set_palette:
    pusha
    push dx
    xor al, al
    mov dx, 0x3C8
    out dx, al
    inc dx                     ; DX = 0x3C9 (данные)
    mov cx, 48
.loop:
    lodsb
    out dx, al
    loop .loop
    pop dx
    popa
    ret

; ---------------------------------------------------------------------
; get_font - скопировать шрифт 8x8 из ROM BIOS в font_buf
; ---------------------------------------------------------------------
get_font:
    pusha
    push ds
    push es
    mov ax, 0x1130             ; "получить указатель на шрифт"
    mov bh, 0x03               ; ROM 8x8, символы 0..127
    int 0x10                   ; ES:BP = шрифт
    mov ax, es
    test ax, ax
    jnz .ok
    mov word [font_seg], 0xF000
    mov word [font_off], 0xFA6E
    jmp .copy
.ok:
    mov [font_seg], ax
    mov [font_off], bp
.copy:
    mov ax, 0x1000
    mov es, ax
    mov ds, ax                 ; DS = сегмент ядра
    mov si, [font_off]         ; читаем смещение шрифта ДО смены DS
    mov di, font_buf
    mov cx, 512                ; 512 слов = 1024 байта (128 символов)
    mov ax, [font_seg]
    mov ds, ax                 ; DS = сегмент шрифта
    cld
    rep movsw
    pop es
    pop ds
    popa
    ret

; =====================================================================
;  ГРАФИЧЕСКАЯ КОНСОЛЬ
; =====================================================================

; ---------------------------------------------------------------------
; con_clear_grid - очистить текстовую сетку консоли
; ---------------------------------------------------------------------
con_clear_grid:
    pusha
    push es
    mov ax, 0x1000
    mov es, ax
    mov di, cgrid
    mov cx, CON_COLS*CON_ROWS
    mov al, ' '
    cld
    rep stosb
    mov byte [con_row], 0
    mov byte [con_col], 0
    pop es
    popa
    ret

; ---------------------------------------------------------------------
; con_index -> DI = con_row*CON_COLS + con_col
; ---------------------------------------------------------------------
con_index:
    push ax
    push dx
    mov al, [con_row]
    xor ah, ah
    mov dx, CON_COLS
    mul dx
    mov dl, [con_col]
    xor dh, dh
    add ax, dx
    mov di, ax
    pop dx
    pop ax
    ret

; ---------------------------------------------------------------------
; con_scroll_check - прокрутка сетки, если вышли за нижнюю строку
; ---------------------------------------------------------------------
con_scroll_check:
    pusha
    push es
    push ds
    cmp byte [con_row], CON_ROWS
    jb .done
    mov ax, 0x1000
    mov es, ax
    mov ds, ax
    mov si, cgrid + CON_COLS
    mov di, cgrid
    mov cx, CON_COLS*(CON_ROWS-1)
    cld
    rep movsb
    mov al, ' '
    mov cx, CON_COLS
    rep stosb
    mov byte [con_row], CON_ROWS-1
.done:
    pop ds
    pop es
    popa
    ret

; ---------------------------------------------------------------------
; con_putchar - записать символ AL в сетку (и зеркалить на COM1)
; ---------------------------------------------------------------------
con_putchar:
    pusha
    mov bx, ax                 ; BL = символ

    mov ah, 0x01               ; дублируем на COM1 (отладка)
    mov al, bl
    xor dx, dx
    int 0x14

    cmp bl, 13
    je .cr
    cmp bl, 10
    je .lf
    cmp bl, 8
    je .bs

    call con_index
    mov al, bl
    mov [cgrid+di], al
    inc byte [con_col]
    mov al, [con_col]
    cmp al, CON_COLS
    jb .done
    mov byte [con_col], 0
    inc byte [con_row]
    call con_scroll_check
    jmp .done
.cr:
    mov byte [con_col], 0
    jmp .done
.lf:
    mov byte [con_col], 0
    inc byte [con_row]
    call con_scroll_check
    jmp .done
.bs:
    cmp byte [con_col], 0
    jbe .done
    dec byte [con_col]
    call con_index
    mov byte [cgrid+di], ' '
.done:
    popa
    ret

; ---------------------------------------------------------------------
; con_refresh - перерисовать всю область консоли из сетки
; ---------------------------------------------------------------------
con_refresh:
    pusha
    ; фон консоли
    mov word [r_x], CON_X0
    mov word [r_y], CON_Y0
    mov word [r_w], CON_COLS*8
    mov word [r_h], CON_ROWS*8
    mov al, C_WINBG
    mov [r_color], al
    call fill_rect

    mov byte [cr_row], 0
.row:
    mov byte [cr_col], 0
.col:
    mov al, [cr_row]
    xor ah, ah
    mov dx, CON_COLS
    mul dx
    mov dl, [cr_col]
    xor dh, dh
    add ax, dx
    mov di, ax
    mov al, [cgrid+di]

    mov cl, [cr_col]
    xor ch, ch
    shl cx, 3
    add cx, CON_X0
    mov dl, [cr_row]
    xor dh, dh
    shl dx, 3
    add dx, CON_Y0
    mov bl, [c_text]
    call draw_char

    inc byte [cr_col]
    mov al, [cr_col]
    cmp al, CON_COLS
    jb .col
    inc byte [cr_row]
    mov al, [cr_row]
    cmp al, CON_ROWS
    jb .row

    call con_draw_cursor
    popa
    ret

; ---------------------------------------------------------------------
; con_draw_cursor - полоска-курсор под текущей позицией
; ---------------------------------------------------------------------
con_draw_cursor:
    pusha
    mov cl, [con_col]
    xor ch, ch
    shl cx, 3
    add cx, CON_X0
    mov dl, [con_row]
    xor dh, dh
    shl dx, 3
    add dx, CON_Y0
    add dx, 7
    mov [r_x], cx
    mov [r_y], dx
    mov word [r_w], 8
    mov word [r_h], 1
    mov al, [c_text]
    mov [r_color], al
    call fill_rect
    popa
    ret

; =====================================================================
;  РАБОЧИЙ СТОЛ (GUI)
; =====================================================================

; ---------------------------------------------------------------------
; apply_theme - загрузить палитру текущей темы
; ---------------------------------------------------------------------
apply_theme:
    push si
    mov si, pal_dark
    cmp byte [theme], 0
    je .go
    mov si, pal_light
.go:
    call set_palette
    pop si
    ret

; ---------------------------------------------------------------------
; draw_clock - часы на панели задач
; ---------------------------------------------------------------------
draw_clock:
    pusha
    ; очистить область часов
    mov word [r_x], CLK_X-2
    mov word [r_y], 2
    mov word [r_w], 66
    mov word [r_h], 10
    mov al, C_TASK
    mov [r_color], al
    call fill_rect

    call rtc_read
    mov di, clk_buf
    mov al, [tm_h]
    call fmt2
    mov byte [di], ':'
    inc di
    mov al, [tm_m]
    call fmt2
    mov byte [di], ':'
    inc di
    mov al, [tm_s]
    call fmt2
    mov byte [di], 0

    mov word [gt_x], CLK_X
    mov word [gt_y], 3
    mov al, C_TEXT
    mov [gt_color], al
    mov si, clk_buf
    call draw_text
    popa
    ret

; ---------------------------------------------------------------------
; maybe_clock - обновить часы, если сменилась секунда (вызывается в idle)
; ---------------------------------------------------------------------
maybe_clock:
    pusha
    call rtc_read
    mov al, [tm_s]
    cmp al, [clk_last]
    je .done
    mov [clk_last], al
    call draw_clock
.done:
    popa
    ret

; ---------------------------------------------------------------------
; draw_desktop - обои, панель задач сверху, окно, консоль
; ---------------------------------------------------------------------
draw_desktop:
    ; обои - просто цвет
    mov word [r_x], 0
    mov word [r_y], 0
    mov word [r_w], SCREEN_W
    mov word [r_h], SCREEN_H
    mov al, C_WALL
    mov [r_color], al
    call fill_rect

    ; панель задач сверху
    mov word [r_x], 0
    mov word [r_y], 0
    mov word [r_w], SCREEN_W
    mov word [r_h], TASKBAR_H
    mov al, C_TASK
    mov [r_color], al
    call fill_rect

    ; окно: рамка
    mov word [r_x], WIN_X
    mov word [r_y], WIN_Y
    mov word [r_w], WIN_W
    mov word [r_h], WIN_H
    mov al, C_BORDER
    mov [r_color], al
    call fill_rect

    ; окно: внутренняя область
    mov word [r_x], WIN_X+1
    mov word [r_y], WIN_Y+1
    mov word [r_w], WIN_W-2
    mov word [r_h], WIN_H-2
    mov al, C_WINBG
    mov [r_color], al
    call fill_rect

    ; заголовок окна
    mov word [r_x], WIN_X+1
    mov word [r_y], WIN_Y+1
    mov word [r_w], WIN_W-2
    mov word [r_h], 11
    mov al, C_TITLE
    mov [r_color], al
    call fill_rect

    mov word [gt_x], WIN_X+5
    mov word [gt_y], WIN_Y+4
    mov al, C_TEXT
    mov [gt_color], al
    mov si, title_str
    call draw_text

    ; надпись на панели задач
    mov word [gt_x], 4
    mov word [gt_y], 3
    mov al, C_TEXT
    mov [gt_color], al
    mov si, os_name
    call draw_text

    ; индикатор темы
    mov word [gt_x], 140
    mov word [gt_y], 3
    mov al, C_DIM
    mov [gt_color], al
    mov si, theme_dark
    cmp byte [theme], 0
    je .th
    mov si, theme_light
.th:
    call draw_text

    call draw_clock
    call con_refresh
    ret

; ---------------------------------------------------------------------
; gui_init - инициализация графики и рабочего стола
; ---------------------------------------------------------------------
gui_init:
    call get_font
    mov ax, 0x0013             ; VGA 320x200x256 (режим 13h)
    int 0x10
    mov byte [theme], 0
    call apply_theme
    call con_clear_grid
    call draw_desktop
    ret

; =====================================================================
;  КЛАВИАТУРА PS/2
; =====================================================================

; ---------------------------------------------------------------------
; kbd_init - отключаем мышь, маскируем IRQ1/IRQ12
; ---------------------------------------------------------------------
kbd_init:
    mov cx, 0xFFFF
.wait1:
    in al, 0x64
    test al, 2
    jz .cmd1
    loop .wait1
.cmd1:
    mov al, 0xA7
    out 0x64, al

    mov cx, 0xFFFF
.wait2:
    in al, 0x64
    test al, 2
    jz .cmd2
    loop .wait2
.cmd2:
    mov al, 0xAE
    out 0x64, al

    in al, 0x21
    or al, 0x02
    out 0x21, al
    in al, 0xA1
    or al, 0x10
    out 0xA1, al
    ret

; ---------------------------------------------------------------------
; kbd_getchar -> AL = ASCII (0, если данных нет)
; ---------------------------------------------------------------------
kbd_getchar:
    push bx
    push cx
    push dx
    push si
    push ds
    mov ax, 0x1000
    mov ds, ax

    in al, 0x64
    test al, 1
    jz .none
    mov bl, al                 ; статус
    in al, 0x60                ; скан-код
    test bl, 0x20              ; данные от мыши?
    jnz .none

    test al, 0x80
    jz .make
    and al, 0x7F               ; код отпускания
    cmp al, 0x2A
    je .shift_off
    cmp al, 0x36
    je .shift_off
    jmp .none
.shift_off:
    mov byte [shift], 0
    jmp .none

.make:
    cmp al, 0x2A
    je .shift_on
    cmp al, 0x36
    je .shift_on
    xor ah, ah
    mov si, sc_normal
    cmp byte [shift], 0
    je .sel
    mov si, sc_shift
.sel:
    add si, ax
    mov al, [si]
    test al, al
    jz .none
    jmp .ret
.shift_on:
    mov byte [shift], 1
.none:
    xor al, al
.ret:
    pop ds
    pop si
    pop dx
    pop cx
    pop bx
    ret

; =====================================================================
;  ОБОЛОЧКА
; =====================================================================

; ---------------------------------------------------------------------
; read_line - читает строку в cmd_buf, отражая её в консоли
; ---------------------------------------------------------------------
read_line:
    pusha
    mov di, cmd_buf
.wait:
    call kbd_getchar
    test al, al
    jnz .have
    call maybe_clock
    jmp .wait
.have:
    cmp al, 13
    je .enter
    cmp al, 8
    je .back
    cmp al, 32
    jb .wait
    cmp al, 126
    ja .wait
    mov bx, di
    sub bx, cmd_buf
    cmp bx, MAXLINE-1
    jae .wait
    stosb
    call con_putchar
    call con_refresh
    jmp .wait
.back:
    mov bx, di
    sub bx, cmd_buf
    test bx, bx
    jz .wait
    dec di
    mov byte [di], 0
    mov al, 8
    call con_putchar
    call con_refresh
    jmp .wait
.enter:
    mov byte [di], 0
    mov al, 13
    call con_putchar
    mov al, 10
    call con_putchar
    call con_refresh
    popa
    ret

; ---------------------------------------------------------------------
; skip_spaces - пропускает пробелы, SI
; ---------------------------------------------------------------------
skip_spaces:
    push ax
.loop:
    cmp byte [si], ' '
    jne .done
    inc si
    jmp .loop
.done:
    pop ax
    ret

; ---------------------------------------------------------------------
; copy_token - копирует слово из SI в DI (до пробела/нуля), NUL-термин.
;             SI остаётся на разделителе.
; ---------------------------------------------------------------------
copy_token:
    push ax
    push cx
    xor cx, cx
.loop:
    mov al, [si]
    cmp al, ' '
    je .end
    test al, al
    jz .end
    cmp cx, FS_NLEN-1
    jae .skipstore
    mov [di], al
    inc di
    inc cx
.skipstore:
    inc si
    jmp .loop
.end:
    mov byte [di], 0
    pop cx
    pop ax
    ret

; ---------------------------------------------------------------------
; execute - разбирает и выполняет команду из cmd_buf
; ---------------------------------------------------------------------
execute:
    pusha
    mov si, cmd_buf
    call skip_spaces
    cmp byte [si], 0
    je .done

    mov di, si
.find_end:
    mov al, [di]
    test al, al
    jz .noargs
    cmp al, ' '
    je .found
    inc di
    jmp .find_end
.found:
    inc di
.skip:
    cmp byte [di], ' '
    jne .save
    inc di
    jmp .skip
.save:
    mov [args], di
    jmp .match
.noargs:
    mov word [args], empty

.match:
    mov bx, cmd_table
.next:
    mov ax, [bx]
    test ax, ax
    jz .unknown
    mov si, cmd_buf
    call skip_spaces
    mov di, ax
    call match_cmd
    jc .do
    add bx, 4
    jmp .next
.do:
    mov ax, [bx+2]
    call ax
    jmp .done
.unknown:
    mov si, msg_unknown
    call puts
.done:
    popa
    ret

; ---------------------------------------------------------------------
; match_cmd - сравнить имя (DI) с первым словом строки (SI); CF=1 при
;             совпадении
; ---------------------------------------------------------------------
match_cmd:
    push si
    push di
.loop:
    mov al, [di]
    test al, al
    jz .end_name
    mov ah, [si]
    cmp al, ah
    jne .no
    inc si
    inc di
    jmp .loop
.end_name:
    mov al, [si]
    cmp al, 0
    je .yes
    cmp al, ' '
    je .yes
.no:
    pop di
    pop si
    clc
    ret
.yes:
    pop di
    pop si
    stc
    ret

; =====================================================================
;  КОМАНДЫ
; =====================================================================

do_help:
    pusha
    mov si, help_text
    call puts
    popa
    ret

do_clear:
    call con_clear_grid
    ret

do_about:
    pusha
    mov si, about_text
    call puts
    popa
    ret

do_ver:
    pusha
    mov si, ver_text
    call puts
    popa
    ret

do_echo:
    pusha
    mov si, [args]
    call puts
    mov si, msg_nl
    call puts
    popa
    ret

; --- theme: переключение тёмной и светлой темы ---
do_theme:
    pusha
    xor byte [theme], 1
    call apply_theme
    call draw_desktop
    mov si, msg_theme
    call puts
    call con_refresh
    popa
    ret

; --- time: часы реального времени ---
do_time:
    pusha
    call rtc_read
    mov si, time_text
    call puts
    mov al, [tm_h]
    call print_dec2
    mov al, ':'
    call putchar
    mov al, [tm_m]
    call print_dec2
    mov al, ':'
    call putchar
    mov al, [tm_s]
    call print_dec2
    mov si, msg_nl
    call puts
    popa
    ret

; --- mem: размер основной памяти ---
do_mem:
    pusha
    push ds
    int 0x12
    pop ds
    mov si, mem_text1
    call puts
    call print_dec
    mov si, mem_text2
    call puts
    popa
    ret

; --- beep ---
do_beep:
    pusha
    mov al, 0xB6
    out 0x43, al
    mov ax, 1000
    out 0x42, al
    mov al, ah
    out 0x42, al
    in al, 0x61
    or al, 3
    out 0x61, al
    mov cx, 0x0800
.outer:
    mov dx, 0xFFFF
.inner:
    dec dx
    jnz .inner
    dec cx
    jnz .outer
    in al, 0x61
    and al, 0xFC
    out 0x61, al
    popa
    ret

; --- color N: сменить цвет текста консоли ---
do_color:
    pusha
    mov si, [args]
    mov al, [si]
    test al, al
    jz .bad
    call hex_digit
    cmp al, 0xFF
    je .bad
    mov [c_text], al
    mov si, color_ok
    call puts
    popa
    ret
.bad:
    mov si, color_bad
    call puts
    popa
    ret

; --- reboot ---
do_reboot:
    pusha
    mov si, msg_reboot
    call puts
    mov cx, 0x0010
.d1:
    mov dx, 0xFFFF
.d2:
    dec dx
    jnz .d2
    dec cx
    jnz .d1
    cli
    mov al, 0xFE
    out 0x64, al
    mov ax, 0xFFFF
    mov ds, ax
    jmp 0xFFFF:0x0000

; --- halt: выключение машины (ACPI), с откатом на остановку CPU ---
do_halt:
    pusha
    mov si, msg_halt
    call puts
    call con_refresh
    popa
    cli
    call acpi_shutdown         ; попытка выключить питание
.h:
    hlt                        ; если не вышло - просто стоим
    jmp .h

; =====================================================================
;  ФАЙЛОВАЯ СИСТЕМА (в оперативной памяти)
; =====================================================================

; ---------------------------------------------------------------------
; fs_dataptr - AX = индекс -> DI = адрес данных файла
; ---------------------------------------------------------------------
fs_dataptr:
    push ax
    push dx
    mov dx, FS_DLEN
    mul dx
    add ax, fs_data
    mov di, ax
    pop dx
    pop ax
    ret

; ---------------------------------------------------------------------
; str_eq - DI и SI: CF=1, если строки равны
; ---------------------------------------------------------------------
str_eq:
    push ax
    push si
    push di
.loop:
    mov al, [si]
    mov ah, [di]
    cmp al, ah
    jne .no
    test al, al
    jz .yes
    inc si
    inc di
    jmp .loop
.no:
    pop di
    pop si
    pop ax
    clc
    ret
.yes:
    pop di
    pop si
    pop ax
    stc
    ret

; ---------------------------------------------------------------------
; str_copy_lim - копировать SI->DI не более BX байт, NUL-термин.
; ---------------------------------------------------------------------
str_copy_lim:
    push ax
    push cx
    xor cx, cx
.loop:
    mov al, [si]
    test al, al
    jz .end
    cmp cx, bx
    jae .end
    mov [di], al
    inc di
    inc si
    inc cx
    jmp .loop
.end:
    mov byte [di], 0
    pop cx
    pop ax
    ret

; ---------------------------------------------------------------------
; fs_find - SI = имя -> AX = индекс (CF=0) | CF=1 (не найдено)
; ---------------------------------------------------------------------
fs_find:
    push bx
    push cx
    push dx
    push si
    push di
    xor cx, cx
.loop:
    cmp cx, FS_MAX
    jae .no
    mov bx, cx
    cmp byte [fs_used+bx], 0
    je .next
    mov ax, cx
    mov dx, FS_NLEN
    mul dx
    add ax, fs_name
    mov di, ax
    push si
    push cx
    call str_eq
    pop cx
    pop si
    jc .yes
.next:
    inc cx
    jmp .loop
.yes:
    mov ax, cx
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    clc
    ret
.no:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    stc
    ret

; ---------------------------------------------------------------------
; fs_alloc - SI = имя -> AX = индекс (CF=0) | CF=1 (нет места)
;            создаёт файл, если его нет
; ---------------------------------------------------------------------
fs_alloc:
    push bx
    push cx
    push dx
    push si
    push di
    xor cx, cx
.search:
    cmp cx, FS_MAX
    jae .findfree
    mov bx, cx
    cmp byte [fs_used+bx], 0
    je .searchnext
    mov ax, cx
    mov dx, FS_NLEN
    mul dx
    add ax, fs_name
    mov di, ax
    push si
    push cx
    call str_eq
    pop cx
    pop si
    jc .found
.searchnext:
    inc cx
    jmp .search
.findfree:
    xor cx, cx
.ff:
    cmp cx, FS_MAX
    jae .fail
    mov bx, cx
    cmp byte [fs_used+bx], 0
    je .alloc
    inc cx
    jmp .ff
.alloc:
    mov bx, cx
    mov byte [fs_used+bx], 1
    mov ax, cx
    mov dx, FS_NLEN
    mul dx
    add ax, fs_name
    mov di, ax
    mov bx, FS_NLEN-1
    call str_copy_lim
    mov bx, cx
    add bx, bx
    mov word [fs_size+bx], 0
.found:
    mov ax, cx
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    clc
    ret
.fail:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    stc
    ret

; ---------------------------------------------------------------------
; fs_put - SI = имя, BP = текст; создать/перезаписать файл
; ---------------------------------------------------------------------
fs_put:
    pusha
    call fs_alloc
    jc .done
    mov [tmpi], ax             ; сохраняем индекс (AX затрётся в цикле)
    call fs_dataptr            ; DI = данные (AX = индекс)
    mov si, bp
    xor cx, cx
.copy:
    mov al, [si]
    test al, al
    jz .end
    cmp cx, FS_DLEN-1
    jae .end
    mov [di], al
    inc di
    inc si
    inc cx
    jmp .copy
.end:
    mov byte [di], 0
    mov bx, [tmpi]
    add bx, bx
    mov [fs_size+bx], cx
.done:
    popa
    ret

; ---------------------------------------------------------------------
; print_pad - выровнять имя в колонке 14 символов
; ---------------------------------------------------------------------
print_pad:
    pusha
    mov cx, 0
.len:
    cmp byte [si], 0
    je .got
    inc si
    inc cx
    jmp .len
.got:
    mov bx, 14
    sub bx, cx
    jbe .done
.sp:
    mov al, ' '
    call putchar
    dec bx
    jnz .sp
.done:
    popa
    ret

; --- ls ---
do_ls:
    pusha
    mov word [fs_count], 0
    mov word [tmpi], 0
.loop:
    mov bx, [tmpi]
    cmp bx, FS_MAX
    jae .end
    cmp byte [fs_used+bx], 0
    je .next
    inc word [fs_count]
    mov ax, bx
    mov cx, FS_NLEN
    mul cx
    add ax, fs_name
    mov si, ax
    call puts
    call print_pad
    mov bx, [tmpi]
    add bx, bx
    mov ax, [fs_size+bx]
    call print_dec
    mov si, msg_bytes
    call puts
.next:
    inc word [tmpi]
    jmp .loop
.end:
    mov si, msg_files
    call puts
    mov ax, [fs_count]
    call print_dec
    mov si, msg_nl
    call puts
    popa
    ret

; --- cat NAME ---
do_cat:
    pusha
    mov si, [args]
    call skip_spaces
    mov di, namebuf
    call copy_token
    cmp byte [namebuf], 0
    je .usage
    mov si, namebuf
    call fs_find
    jc .notfound
    call fs_dataptr
    mov si, di
    call puts
    mov si, msg_nl
    call puts
    popa
    ret
.notfound:
    mov si, msg_nofile
    call puts
    popa
    ret
.usage:
    mov si, msg_usage_cat
    call puts
    popa
    ret

; --- touch NAME ---
do_touch:
    pusha
    mov si, [args]
    call skip_spaces
    mov di, namebuf
    call copy_token
    cmp byte [namebuf], 0
    je .usage
    mov si, namebuf
    call fs_alloc
    jc .nospace
    mov si, msg_touched
    call puts
    popa
    ret
.nospace:
    mov si, msg_nospace
    call puts
    popa
    ret
.usage:
    mov si, msg_usage_touch
    call puts
    popa
    ret

; --- rm NAME ---
do_rm:
    pusha
    mov si, [args]
    call skip_spaces
    mov di, namebuf
    call copy_token
    cmp byte [namebuf], 0
    je .usage
    mov si, namebuf
    call fs_find
    jc .notfound
    mov bx, ax
    mov byte [fs_used+bx], 0
    mov si, msg_removed
    call puts
    popa
    ret
.notfound:
    mov si, msg_nofile
    call puts
    popa
    ret
.usage:
    mov si, msg_usage_rm
    call puts
    popa
    ret

; --- write NAME TEXT ---
do_write:
    pusha
    mov si, [args]
    call skip_spaces
    mov di, namebuf
    call copy_token
    cmp byte [namebuf], 0
    je .usage
    call skip_spaces
    mov [tmpptr], si
    mov si, namebuf
    call fs_alloc
    jc .nospace
    mov [tmpi], ax
    call fs_dataptr
    mov si, [tmpptr]
    xor cx, cx
.copy:
    mov al, [si]
    test al, al
    jz .end
    cmp cx, FS_DLEN-1
    jae .end
    mov [di], al
    inc di
    inc si
    inc cx
    jmp .copy
.end:
    mov byte [di], 0
    mov bx, [tmpi]
    add bx, bx
    mov [fs_size+bx], cx
    mov si, msg_written
    call puts
    popa
    ret
.nospace:
    mov si, msg_nospace
    call puts
    popa
    ret
.usage:
    mov si, msg_usage_write
    call puts
    popa
    ret

; --- fsinfo ---
do_fsinfo:
    pusha
    mov word [fs_count], 0
    mov word [fs_bytes], 0
    xor bx, bx
.loop:
    cmp bx, FS_MAX
    jae .end
    cmp byte [fs_used+bx], 0
    je .next
    inc word [fs_count]
    mov ax, bx
    add ax, ax
    mov si, ax
    mov ax, [fs_size+si]
    add [fs_bytes], ax
.next:
    inc bx
    jmp .loop
.end:
    mov si, msg_fsinfo1
    call puts
    mov ax, [fs_count]
    call print_dec
    mov si, msg_fsinfo2
    call puts
    mov ax, [fs_bytes]
    call print_dec
    mov si, msg_bytes
    call puts
    popa
    ret

; ---------------------------------------------------------------------
; fs_seed - создать демонстрационные файлы при старте
; ---------------------------------------------------------------------
fs_seed:
    pusha
    mov si, seed_r_name
    mov bp, seed_r_data
    call fs_put
    mov si, seed_h_name
    mov bp, seed_h_data
    call fs_put
    mov si, seed_n_name
    mov bp, seed_n_data
    call fs_put
    popa
    ret

; =====================================================================
;  ВСПОМОГАТЕЛЬНЫЕ ПРОЦЕДУРЫ
; =====================================================================

; ---------------------------------------------------------------------
; acpi_shutdown - выключить питание через ACPI (S5)
;   Возвращает управление, если выключить не удалось.
; ---------------------------------------------------------------------
acpi_shutdown:
    pusha
    push ds
    push es
    call find_fadt             ; -> DX = порт PM1a_CNT (если таблицы внизу)
    jc .fallback
    mov [acpi_port], dx
    mov ax, 0x3400             ; SLP_TYP=5 (S5) | SLP_EN
    mov dx, [acpi_port]
    out dx, ax
    pop es
    pop ds
    popa
    clc
    ret
.fallback:
    ; ACPI-таблицы недоступны из real mode (лежат выше 1М).
    ; Пробуем стандартные порты PM1a_CNT эмуляторов.
    mov dx, 0x4004             ; VirtualBox
    mov ax, 0x3400
    out dx, ax
    mov ax, 0x2000
    out dx, ax
    mov dx, 0x0604             ; QEMU
    mov ax, 0x3400
    out dx, ax
    mov ax, 0x2000
    out dx, ax
    mov dx, 0xB004             ; Bochs
    mov ax, 0x3400
    out dx, ax
    mov ax, 0x2000
    out dx, ax
    pop es
    pop ds
    popa
    stc
    ret

; ---------------------------------------------------------------------
; find_fadt - найти таблицу FADT (FACP) через RSDP/RSDT/XSDT
;   CF=0 и DX = порт PM1a_CNT_BLK при успехе
; ---------------------------------------------------------------------
find_fadt:
    push ds
    push es
    ; 1) найти RSDP: сигнатура "RSD PTR " в 0x80000..0xFFFF0
    mov bx, 0x8000
.rsdp:
    mov es, bx
    mov si, rsdp_sig
    xor di, di
    mov cx, 8
.rsdpc:
    mov al, [es:di]
    cmp al, [si]
    jne .rsdpn
    inc di
    inc si
    loop .rsdpc
    jmp .rsdp_ok
.rsdpn:
    inc bx
    test bx, bx
    jnz .rsdp
    pop es
    pop ds
    stc
    ret
.rsdp_ok:
    mov es, bx
    ; 2) RSDT по смещению 16, иначе XSDT по смещению 24
    mov word [entry_stride], 4
    mov ax, [es:16]
    mov dx, [es:18]
    mov cx, ax
    or cx, dx
    jnz .have
    mov word [entry_stride], 8
    mov ax, [es:24]
    mov dx, [es:26]
.have:
    call phys_es_bx            ; ES:BX -> RSDT/XSDT
    mov cx, [es:bx+4]          ; длина таблицы
    cmp cx, 36
    jb .fail
    sub cx, 36
    cmp word [entry_stride], 8
    jne .c4
    shr cx, 1
.c4:
    shr cx, 2
    add bx, 36
.ent:
    test cx, cx
    jz .fail
    mov ax, [es:bx]
    mov dx, [es:bx+2]
    push bx
    push cx
    call fadt_port2            ; -> DX = порт
    pop cx
    pop bx
    jc .next
    pop es
    pop ds
    clc
    ret
.next:
    add bx, word [entry_stride]
    dec cx
    jmp .ent
.fail:
    pop es
    pop ds
    stc
    ret

; ---------------------------------------------------------------------
; phys_es_bx - DX:AX (адрес <1М) -> ES:BX
; ---------------------------------------------------------------------
phys_es_bx:
    push ax
    push cx
    mov cx, ax
    shr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
    and cx, 0x0F
    mov es, ax
    mov bx, cx
    pop cx
    pop ax
    ret

; ---------------------------------------------------------------------
; fadt_port2 - DX:AX = адрес таблицы; если это FADT (FACP), то CF=0 и
;              DX = порт PM1a_CNT_BLK
; ---------------------------------------------------------------------
fadt_port2:
    push es
    push si
    push ax
    call phys_es_bx            ; ES:BX -> таблица
    mov si, facp_sig
    mov al, [es:bx+0]
    cmp al, [si+0]
    jne .no
    mov al, [es:bx+1]
    cmp al, [si+1]
    jne .no
    mov al, [es:bx+2]
    cmp al, [si+2]
    jne .no
    mov al, [es:bx+3]
    cmp al, [si+3]
    jne .no
    mov dx, [es:bx+0x40]       ; PM1a_CNT_BLK
    pop ax
    pop si
    pop es
    clc
    ret
.no:
    pop ax
    pop si
    pop es
    stc
    ret

; ---------------------------------------------------------------------
; rtc_read - прочитать часы CMOS в tm_h, tm_m, tm_s (двоичные)
; ---------------------------------------------------------------------
rtc_read:
    pusha
    mov cx, 0xFFFF
.w:
    mov al, 0x0A
    out 0x70, al
    in al, 0x71
    test al, 0x80
    jz .ready
    loop .w
.ready:
    mov al, 0x00
    out 0x70, al
    in al, 0x71
    mov [tm_s], al
    mov al, 0x02
    out 0x70, al
    in al, 0x71
    mov [tm_m], al
    mov al, 0x04
    out 0x70, al
    in al, 0x71
    mov [tm_hr], al
    mov al, 0x0B
    out 0x70, al
    in al, 0x71
    mov bl, al

    mov al, [tm_s]
    test bl, 0x04
    jnz .s_ok
    call bcd2bin
    mov [tm_s], al
.s_ok:
    mov al, [tm_m]
    test bl, 0x04
    jnz .m_ok
    call bcd2bin
    mov [tm_m], al
.m_ok:
    mov al, [tm_hr]
    mov cl, al
    and al, 0x7F
    test bl, 0x04
    jnz .h_ok
    call bcd2bin
.h_ok:
    test bl, 0x02
    jnz .h_store
    test cl, 0x80
    jz .am
    cmp al, 12
    je .h_store
    add al, 12
    jmp .h_store
.am:
    cmp al, 12
    jne .h_store
    xor al, al
.h_store:
    mov [tm_h], al
    popa
    ret

; ---------------------------------------------------------------------
; puts - вывод строки, SI = указатель
; ---------------------------------------------------------------------
puts:
    pusha
.next:
    lodsb
    test al, al
    jz .done
    call putchar
    jmp .next
.done:
    popa
    ret

; ---------------------------------------------------------------------
; putchar - синоним con_putchar (для команд)
; ---------------------------------------------------------------------
putchar:
    jmp con_putchar

; ---------------------------------------------------------------------
; puthex - вывод AX как 4 шестнадцатеричных цифры
; ---------------------------------------------------------------------
puthex:
    pusha
    mov bx, ax
    mov cx, 4
.l:
    rol bx, 4
    mov al, bl
    and al, 0x0F
    cmp al, 10
    jb .d
    add al, 'a'-10
    jmp .p
.d:
    add al, '0'
.p:
    call putchar
    loop .l
    popa
    ret

; ---------------------------------------------------------------------
; print_dec - вывод AX как десятичного числа
; ---------------------------------------------------------------------
print_dec:
    pusha
    mov cx, 0
    mov bx, 10
.div:
    xor dx, dx
    div bx
    push dx
    inc cx
    test ax, ax
    jnz .div
.out:
    pop ax
    add al, '0'
    call putchar
    loop .out
    popa
    ret

; ---------------------------------------------------------------------
; print_dec2 - вывод AL (0..99) двумя цифрами с ведущим нулём
; ---------------------------------------------------------------------
print_dec2:
    pusha
    mov ah, 0
    mov bl, 10
    div bl
    mov dl, ah
    add al, '0'
    call putchar
    mov al, dl
    add al, '0'
    call putchar
    popa
    ret

; ---------------------------------------------------------------------
; fmt2 - записать AL двумя цифрами по адресу DI, DI += 2
; ---------------------------------------------------------------------
fmt2:
    push ax
    push bx
    mov ah, 0
    mov bl, 10
    div bl
    add al, '0'
    add ah, '0'
    mov [di], al
    mov [di+1], ah
    add di, 2
    pop bx
    pop ax
    ret

; ---------------------------------------------------------------------
; bcd2bin - AL (BCD) -> AL (двоичное)
; ---------------------------------------------------------------------
bcd2bin:
    push bx
    push cx
    mov bl, al
    and bl, 0x0F
    mov bh, al
    shr bh, 4
    mov al, bh
    mov ah, 0
    mov cx, 10
    mul cx
    xor bh, bh
    add ax, bx
    pop cx
    pop bx
    ret

; ---------------------------------------------------------------------
; hex_digit - AL (ASCII) -> AL (0..15) или 0xFF
; ---------------------------------------------------------------------
hex_digit:
    cmp al, '0'
    jb .bad
    cmp al, '9'
    jbe .num
    or al, 0x20
    cmp al, 'a'
    jb .bad
    cmp al, 'f'
    ja .bad
    sub al, 'a'-10
    ret
.num:
    sub al, '0'
    ret
.bad:
    mov al, 0xFF
    ret

; =====================================================================
;  ДАННЫЕ
; =====================================================================
cmd_table:
    dw c_help,   do_help
    dw c_clear,  do_clear
    dw c_about,  do_about
    dw c_ver,    do_ver
    dw c_echo,   do_echo
    dw c_theme,  do_theme
    dw c_time,   do_time
    dw c_mem,    do_mem
    dw c_color,  do_color
    dw c_ls,     do_ls
    dw c_cat,    do_cat
    dw c_write,  do_write
    dw c_touch,  do_touch
    dw c_rm,     do_rm
    dw c_fsinfo, do_fsinfo
    dw c_beep,   do_beep
    dw c_reboot, do_reboot
    dw c_halt,   do_halt
    dw 0, 0

c_help   db 'help', 0
c_clear  db 'clear', 0
c_about  db 'about', 0
c_ver    db 'ver', 0
c_echo   db 'echo', 0
c_theme  db 'theme', 0
c_time   db 'time', 0
c_mem    db 'mem', 0
c_color  db 'color', 0
c_ls     db 'ls', 0
c_cat    db 'cat', 0
c_write  db 'write', 0
c_touch  db 'touch', 0
c_rm     db 'rm', 0
c_fsinfo db 'fsinfo', 0
c_beep   db 'beep', 0
c_reboot db 'reboot', 0
c_halt   db 'halt', 0

; --- таблицы скан-кодов клавиатуры (set 1) ---
sc_normal:
    db 0, 27
    db '1','2','3','4','5','6','7','8','9','0'
    db '-','='
    db 8, 9
    db 'q','w','e','r','t','y','u','i','o','p'
    db '[',']'
    db 13
    db 0
    db 'a','s','d','f','g','h','j','k','l'
    db ';', 39, '`'
    db 0
    db 92
    db 'z','x','c','v','b','n','m'
    db ',','.','/'
    db 0, '*', 0
    db ' '
    db 0
    times 128-($-sc_normal) db 0

sc_shift:
    db 0, 27
    db '!','@','#','$','%','^','&','*','(',')'
    db '_','+'
    db 8, 9
    db 'Q','W','E','R','T','Y','U','I','O','P'
    db '{','}'
    db 13
    db 0
    db 'A','S','D','F','G','H','J','K','L'
    db ':', 34, '~'
    db 0
    db '|'
    db 'Z','X','C','V','B','N','M'
    db '<','>','?'
    db 0, '*', 0
    db ' '
    db 0
    times 128-($-sc_shift) db 0

; --- палитры тем (16 цветов по R,G,B, значения 0..63) ---
pal_dark:
    db  6, 7, 9                ; 0 обои
    db 12,15,24                ; 1 панель задач
    db  4, 5, 7                ; 2 фон окна
    db 14,22,40                ; 3 заголовок
    db 21,26,35                ; 4 рамка
    db 56,58,62                ; 5 текст
    db 21,37,57                ; 6 акцент
    db 34,38,46                ; 7 приглушённый
    times 8*3 db 0             ; 8..15

pal_light:
    db 49,52,56                ; 0 обои
    db 17,30,50                ; 1 панель задач
    db 61,62,63                ; 2 фон окна
    db 23,36,54                ; 3 заголовок
    db 30,37,47                ; 4 рамка
    db  6, 7,10                ; 5 текст
    db 15,30,52                ; 6 акцент
    db 22,25,30                ; 7 приглушённый
    times 8*3 db 0

; --- строки интерфейса ---
banner   db 'fhOS 1.1 - graphical shell',13,10,0
subtitle db 'Filesystem ready. Type "help" for commands.',13,10,13,10,0
prompt   db 'fhos> ',0
title_str db 'Terminal',0
os_name  db 'fhOS',0
theme_dark  db 'theme: dark',0
theme_light db 'theme: light',0
msg_nl   db 13,10,0
msg_unknown db 'Unknown command. Type "help".',13,10,0

help_text:
    db 'Commands:',13,10
    db '  help          - this help',13,10
    db '  clear         - clear window',13,10
    db '  theme         - dark/light theme',13,10
    db '  about, ver    - about / version',13,10
    db '  echo X        - print X',13,10
    db '  time, mem     - clock / memory',13,10
    db '  color N       - text color 0..F',13,10
    db '  ls            - list files',13,10
    db '  cat NAME      - show a file',13,10
    db '  write N TEXT  - save text to file',13,10
    db '  touch NAME    - create empty file',13,10
    db '  rm NAME       - delete a file',13,10
    db '  fsinfo        - filesystem usage',13,10
    db '  beep, reboot, halt',13,10,0

about_text:
    db 'fhOS - a tiny 16-bit OS written in NASM.',13,10
    db 'It has a minimal GUI (VGA mode 13h): a top',13,10
    db 'taskbar, a solid-color wallpaper, two themes',13,10
    db 'and a terminal window. It also provides an',13,10
    db 'in-memory filesystem: ls, cat, write, touch,',13,10
    db 'rm, fsinfo. Graphics and the PS/2 keyboard',13,10
    db 'are driven directly, without an OS beneath.',13,10,0

ver_text    db 'fhOS 1.1 (16-bit real mode, GUI)',13,10,0
mem_text1   db 'Conventional memory: ',0
mem_text2   db ' KB',13,10,0
time_text   db 'RTC time (HH:MM:SS): ',0
color_ok    db 'Text color changed.',13,10,0
color_bad   db 'Usage: color <0-F>',13,10,0
msg_theme   db 'Theme switched.',13,10,0
msg_reboot  db 'Rebooting...',13,10,0
msg_halt    db 'Power off (ACPI)...',13,10,0
rsdp_sig    db 'RSD PTR ',0
facp_sig    db 'FACP',0

msg_files      db 'Files: ',0
msg_bytes      db ' bytes',13,10,0
msg_fsinfo1    db 'Files: ',0
msg_fsinfo2    db ', used ',0
msg_written    db 'Saved.',13,10,0
msg_removed    db 'Deleted.',13,10,0
msg_touched    db 'Created.',13,10,0
msg_nofile     db 'No such file.',13,10,0
msg_nospace    db 'Filesystem full.',13,10,0
msg_usage_cat   db 'Usage: cat <name>',13,10,0
msg_usage_write db 'Usage: write <name> <text>',13,10,0
msg_usage_touch db 'Usage: touch <name>',13,10,0
msg_usage_rm    db 'Usage: rm <name>',13,10,0
empty db 0

; --- демонстрационные файлы ---
seed_r_name db 'readme.txt',0
seed_r_data db 'Welcome to fhOS!',13,10
            db 'This is an in-memory filesystem.',13,10
            db 'Try: ls, cat readme.txt, write a.txt hi',0
seed_h_name db 'hello.txt',0
seed_h_data db 'Hello from the fhOS GUI.',0
seed_n_name db 'notes.txt',0
seed_n_data db 'Type "theme" to switch dark/light.',0

; --- переменные ---
theme    db 0
c_text   db C_TEXT
con_row  db 0
con_col  db 0
cr_row   db 0
cr_col   db 0
shift    db 0
tm_h     db 0
tm_m     db 0
tm_s     db 0
tm_hr    db 0
clk_last db 0xFF
font_seg dw 0
font_off dw 0
acpi_port dw 0
entry_stride dw 4
args     dw 0
tmpi     dw 0
tmpptr   dw 0
fs_count dw 0
fs_bytes dw 0

r_x      dw 0
r_y      dw 0
r_w      dw 0
r_h      dw 0
r_color  db 0
gt_x     dw 0
gt_y     dw 0
gt_color db 0

cmd_buf  times MAXLINE db 0
namebuf  times FS_NLEN db 0
clk_buf  times 10 db 0
cgrid    times CON_COLS*CON_ROWS db ' '
font_buf times 128*8 db 0

; --- файловая система ---
fs_used  times FS_MAX db 0
fs_name  times FS_MAX*FS_NLEN db 0
fs_size  times FS_MAX*2 db 0
fs_data  times FS_MAX*FS_DLEN db 0
