; =====================================================================
;  fhOS - ядро (kernel)
; ---------------------------------------------------------------------
;  Загружается по адресу 1000:0000, работает в 16-битном реальном режиме.
;  Общается с видеопамятью VGA (0xB8000) и клавиатурой PS/2 (порт 0x60)
;  напрямую, без сервисов BIOS.
; =====================================================================
BITS 16
ORG 0x0200                     ; ядро загружается сразу за stage 1

MAXLINE equ 128

; =====================================================================
;  ТОЧКА ВХОДА
; =====================================================================
start:
    cli
    mov ax, 0x1000
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0xFF00                 ; стек в конце сегмента
    sti

    call kbd_init
    call clear_screen

    mov byte [cur_attr], 0x0B      ; светлый циан для баннера
    mov si, banner
    call puts
    mov byte [cur_attr], 0x07      ; дальше серый
    mov si, subtitle
    call puts

; ---------------------------------------------------------------------
;  Главный цикл оболочки
; ---------------------------------------------------------------------
shell_loop:
    mov byte [cur_attr], 0x0F      ; приглашение - ярко-белое
    mov si, prompt
    call puts
    mov byte [cur_attr], 0x07
    call read_line
    call execute
    jmp shell_loop

; =====================================================================
;  ВИДЕО
; =====================================================================

; ---------------------------------------------------------------------
; clear_screen - очистка экрана текущим атрибутом
; ---------------------------------------------------------------------
clear_screen:
    pusha
    push es
    mov ax, 0xB800
    mov es, ax
    xor di, di
    mov cx, 80*25
    mov al, ' '
    mov ah, [cur_attr]
    cld
    rep stosw
    mov byte [cur_row], 0
    mov byte [cur_col], 0
    call update_cursor
    pop es
    popa
    ret

; ---------------------------------------------------------------------
; update_cursor - аппаратный курсор через CRTC (порты 3D4h/3D5h)
; ---------------------------------------------------------------------
update_cursor:
    pusha
    mov al, [cur_row]
    xor ah, ah
    mov cx, 80
    mul cx
    mov dl, [cur_col]
    xor dh, dh
    add ax, dx
    mov bx, ax
    mov dx, 0x3D4
    mov al, 0x0F                   ; младший байт позиции
    out dx, al
    inc dx
    mov al, bl
    out dx, al
    dec dx
    mov al, 0x0E                   ; старший байт позиции
    out dx, al
    inc dx
    mov al, bh
    out dx, al
    popa
    ret

; ---------------------------------------------------------------------
; calc_offset -> DI = (cur_row*80 + cur_col) * 2
; ---------------------------------------------------------------------
calc_offset:
    push ax
    push dx
    push cx
    mov al, [cur_row]
    xor ah, ah
    mov cx, 80
    mul cx
    mov dl, [cur_col]
    xor dh, dh
    add ax, dx
    shl ax, 1
    mov di, ax
    pop cx
    pop dx
    pop ax
    ret

; ---------------------------------------------------------------------
; check_scroll - прокрутка экрана вверх, если курсор ушёл ниже строки 24
; ---------------------------------------------------------------------
check_scroll:
    pusha
    push es
    push ds
    cmp byte [cur_row], 25
    jb .done
    mov bl, [cur_attr]
    mov ax, 0xB800
    mov es, ax
    mov ds, ax
    mov si, 160                    ; строка 1
    xor di, di                     ; строка 0
    mov cx, 80*24                  ; 24 строки
    cld
    rep movsw
    mov al, ' '
    mov ah, bl
    mov cx, 80
    rep stosw                      ; очищаем последнюю строку
    pop ds
    pop es
    mov byte [cur_row], 24
    popa
    ret
.done:
    pop ds
    pop es
    popa
    ret

; ---------------------------------------------------------------------
; putchar - вывод символа AL с обработкой CR/LF/BS
; ---------------------------------------------------------------------
putchar:
    pusha
    push es
    mov bl, al                     ; BL = символ
    mov ax, 0xB800
    mov es, ax
    cmp bl, 13
    je .cr
    cmp bl, 10
    je .lf
    cmp bl, 8
    je .bs

    call calc_offset
    mov ah, [cur_attr]
    mov al, bl
    mov [es:di], ax
    inc byte [cur_col]
    cmp byte [cur_col], 80
    jb .upd
    mov byte [cur_col], 0
    inc byte [cur_row]
    call check_scroll
    jmp .upd
.cr:
    mov byte [cur_col], 0
    jmp .upd
.lf:
    mov byte [cur_col], 0
    inc byte [cur_row]
    call check_scroll
    jmp .upd
.bs:
    cmp byte [cur_col], 0
    jbe .upd
    dec byte [cur_col]
    call calc_offset
    mov ah, [cur_attr]
    mov al, ' '
    mov [es:di], ax
.upd:
    call update_cursor
    mov ah, 0x01                   ; дублируем символ на COM1 (отладка)
    mov al, bl
    xor dx, dx
    int 0x14
    pop es
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

; =====================================================================
;  КЛАВИАТУРА PS/2
; =====================================================================

; ---------------------------------------------------------------------
; kbd_init - отключаем мышь и маскируем IRQ1/IRQ12, чтобы обработчик
;            клавиатуры BIOS не забирал скан-коды из порта 0x60.
;            После этого ОС читает клавиатуру напрямую.
; ---------------------------------------------------------------------
kbd_init:
    mov cx, 0xFFFF
.wait1:
    in al, 0x64
    test al, 2                     ; входной буфер 8042 занят?
    jz .cmd1
    loop .wait1
.cmd1:
    mov al, 0xA7                   ; отключаем AUX-порт (мышь)
    out 0x64, al

    mov cx, 0xFFFF
.wait2:
    in al, 0x64
    test al, 2
    jz .cmd2
    loop .wait2
.cmd2:
    mov al, 0xAE                   ; включаем клавиатуру
    out 0x64, al

    in al, 0x21                    ; маска IRQ1 (клавиатура)
    or al, 0x02
    out 0x21, al
    in al, 0xA1                    ; маска IRQ12 (мышь)
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
    mov bl, al                     ; статус
    in al, 0x60                    ; скан-код
    test bl, 0x20                  ; данные от мыши?
    jnz .none                      ; игнорируем

    test al, 0x80
    jz .make
    and al, 0x7F                   ; код отпускания
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
; read_line - читает строку в cmd_buf
; ---------------------------------------------------------------------
read_line:
    pusha
    mov di, cmd_buf
.wait:
    call kbd_getchar
    test al, al
    jz .wait
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
    call putchar
    jmp .wait
.back:
    mov bx, di
    sub bx, cmd_buf
    test bx, bx
    jz .wait
    dec di
    mov byte [di], 0
    mov al, 8
    call putchar
    jmp .wait
.enter:
    mov byte [di], 0
    mov al, 13
    call putchar
    mov al, 10
    call putchar
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
; execute - разбирает и выполняет команду из cmd_buf
; ---------------------------------------------------------------------
execute:
    pusha
    mov si, cmd_buf
    call skip_spaces
    cmp byte [si], 0
    je .done                       ; пустая строка

    mov di, si                     ; ищем конец первого слова
.find_end:
    mov al, [di]
    test al, al
    jz .noargs
    cmp al, ' '
    je .found
    inc di
    jmp .find_end
.found:
    inc di                         ; пропускаем пробелы до аргумента
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
; match_cmd - сравнить имя (DI) с первым словом строки (SI)
;             CF=1 при совпадении
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
    call clear_screen
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

; --- time: часы реального времени (CMOS RTC, порты 0x70/0x71) ---
do_time:
    pusha

    ; ждём окончания обновления RTC (регистр 0x0A, бит 7)
    mov cx, 0xFFFF
.w:
    mov al, 0x0A
    out 0x70, al
    in al, 0x71
    test al, 0x80
    jz .ready
    loop .w
.ready:
    mov al, 0x00                   ; секунды
    out 0x70, al
    in al, 0x71
    mov [tm_s], al
    mov al, 0x02                   ; минуты
    out 0x70, al
    in al, 0x71
    mov [tm_m], al
    mov al, 0x04                   ; часы
    out 0x70, al
    in al, 0x71
    mov [tm_hr], al
    mov al, 0x0B                   ; регистр B (формат данных)
    out 0x70, al
    in al, 0x71
    mov bl, al

    mov al, [tm_s]                 ; секунды -> двоичные
    test bl, 0x04
    jnz .s_ok
    call bcd2bin
    mov [tm_s], al
.s_ok:
    mov al, [tm_m]                 ; минуты -> двоичные
    test bl, 0x04
    jnz .m_ok
    call bcd2bin
    mov [tm_m], al
.m_ok:
    mov al, [tm_hr]                ; часы: убрать бит PM
    mov cl, al
    and al, 0x7F
    test bl, 0x04
    jnz .h_ok
    call bcd2bin
.h_ok:
    test bl, 0x02                  ; 24-часовой режим?
    jnz .h_store
    test cl, 0x80                  ; PM?
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

; --- mem: размер основной памяти через INT 12h ---
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

; --- beep: звук через таймер 8253 и динамик ---
do_beep:
    pusha
    mov al, 0xB6
    out 0x43, al
    mov ax, 1000                   ; делитель частоты
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

; --- color N: смена цвета текста ---
do_color:
    pusha
    mov si, [args]
    mov al, [si]
    test al, al
    jz .bad
    call hex_digit
    cmp al, 0xFF
    je .bad
    mov [cur_attr], al
    mov si, color_ok
    call puts
    popa
    ret
.bad:
    mov si, color_bad
    call puts
    popa
    ret

; --- reboot: перезагрузка через контроллер клавиатуры ---
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
    out 0x64, al                   ; сброс CPU
    mov ax, 0xFFFF                 ; запасной путь - вектор сброса BIOS
    mov ds, ax
    jmp 0xFFFF:0x0000

; --- halt: остановка процессора ---
do_halt:
    pusha
    mov si, msg_halt
    call puts
    popa
.h:
    cli
    hlt
    jmp .h

; =====================================================================
;  ВСПОМОГАТЕЛЬНЫЕ ПРОЦЕДУРЫ
; =====================================================================

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
    mov dl, ah                     ; единицы
    add al, '0'
    call putchar                   ; десятки
    mov al, dl
    add al, '0'
    call putchar
    popa
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
; hex_digit - AL (ASCII) -> AL (0..15) или 0xFF при ошибке
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
    dw c_time,   do_time
    dw c_mem,    do_mem
    dw c_color,  do_color
    dw c_beep,   do_beep
    dw c_reboot, do_reboot
    dw c_halt,   do_halt
    dw 0, 0

c_help   db 'help', 0
c_clear  db 'clear', 0
c_about  db 'about', 0
c_ver    db 'ver', 0
c_echo   db 'echo', 0
c_time   db 'time', 0
c_mem    db 'mem', 0
c_color  db 'color', 0
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

; --- строки интерфейса ---
banner:
    db 13,10
    db '  +---------------------------------------+',13,10
    db '  |                f h O S                |',13,10
    db '  |      minimal x86 operating system      |',13,10
    db '  +---------------------------------------+',13,10,13,10,0
subtitle db '  Type "help" to list the commands.',13,10,13,10,0
prompt   db 'fhos> ',0
msg_nl   db 13,10,0
msg_unknown db 'Unknown command. Type "help".',13,10,0

help_text:
    db 'Available commands:',13,10
    db '  help     - this help',13,10
    db '  clear    - clear screen',13,10
    db '  about    - about fhOS',13,10
    db '  ver      - version',13,10
    db '  echo X   - print text X',13,10
    db '  time     - hardware clock (RTC)',13,10
    db '  mem      - conventional memory size',13,10
    db '  color N  - text color, N = 0..F',13,10
    db '  beep     - beep',13,10
    db '  reboot   - restart',13,10
    db '  halt     - stop the CPU',13,10,0

about_text:
    db 'fhOS - a tiny 16-bit OS written in NASM.',13,10
    db 'Loaded from an El Torito ISO image by a custom boot',13,10
    db 'sector. It talks to the VGA text buffer and the PS/2',13,10
    db 'keyboard directly, without any operating-system BIOS.',13,10,0

ver_text    db 'fhOS 1.0 (16-bit real mode)',13,10,0
mem_text1   db 'Conventional memory: ',0
mem_text2   db ' KB',13,10,0
time_text   db 'RTC time (HH:MM:SS): ',0
color_ok    db 'Text color changed.',13,10,0
color_bad   db 'Usage: color <0-F>',13,10,0
msg_reboot  db 'Rebooting...',13,10,0
msg_halt    db 'System halted. Close the VM window.',13,10,0
empty       db 0

; --- переменные ---
cur_row  db 0
cur_col  db 0
cur_attr db 0x07
shift    db 0
tm_h     db 0
tm_m     db 0
tm_s     db 0
tm_hr    db 0
args     dw 0
cmd_buf  times MAXLINE db 0
