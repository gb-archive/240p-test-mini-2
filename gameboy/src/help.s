;
; Help and menu engine for 240p test suite
; Copyright 2018 Damian Yerrick
;
; This program is free software; you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation; either version 2 of the License, or
; (at your option) any later version.
;
; This program is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; GNU General Public License for more details.
;
; You should have received a copy of the GNU General Public License along
; with this program; if not, write to the Free Software Foundation, Inc.,
; 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
;
include "src/gb.inc"
include "src/global.inc"

WALL_TILE EQU $80
ARROW_SPRITE_TILE EQU $80
WINDOW_TL_TILE EQU $82
WINDOW_LEFT_TILE EQU $85
WINDOW_BL_TILE EQU $83
WINDOW_HLINE_TILE EQU $84
WHITE_TILE EQU $8A
WALLBOTTOM_TILE EQU $8B
FLOORTOP_TILE EQU $90
FLOOR_TILE EQU $91
WALL_HEIGHT EQU 12  ; Height of back wall including bottom border
WINDOW_WIDTH EQU 14  ; Width of window in tiles not including left border
WXBASE = 167 - ((WINDOW_WIDTH + 1) * 8)
CHARACTER_Y EQU 4
CHARACTER_OBJ_COUNT EQU 16
HELP_CURSOR_Y_BASE EQU 24
MENU_INDENT_WIDTH EQU 6

LF EQU 10
GL_RIGHT EQU $84
GL_LEFT EQU $85
GL_UP EQU $86
GL_DOWN EQU $87

section "helpvars",WRAM0
help_line_buffer:: ds 32
wnd_x: ds 1
wnd_progress: ds 1
help_allowed_keys: ds 1
help_cur_doc: ds 1
help_wanted_page:: ds 1

help_cur_page: ds 1
help_bg_loaded:: ds 1
help_show_cursor: ds 1
help_cursor_y:: ds 1
help_height: ds 1

section "helptiles",ROM0,align[5]
helptiles: incbin "obj/gb/helptiles.chrgb16.pb16"
sizeof_helptiles equ 672
helptiles_gbc: incbin "obj/gb/helptiles-gbc.chrgb16.pb16"
sizeof_helptiles_gbc equ 960
helpattrmap_gbc:
  db $21,$23,$23,$03,$03,$01
  db $21,$23,$23,$03,$03,$01
  db $21,$24,$24,$04,$04,$01
  db $21,$24,$24,$04,$04,$01
  db $25,$25,$25,$05,$05,$05
  db $25,$25,$25,$05,$05,$05
  db $25,$25,$25,$05,$05,$05
  db $26,$25,$25,$05,$05,$06
  db $27,$24,$25,$05,$04,$07
  db $27,$27,$26,$06,$07,$07
  db $22,$27,$27,$07,$07,$02
  db $22,$22,$22,$02,$02,$02

helpbgpalette_gbc::
  ; Palette 0: Window
  drgb $99FF99
  drgb $776600
  drgb $FFFFFF
  drgb $000000
  ; Palette 1: Back wall
  drgb $99FF99
  drgb $000000
  drgb $335533
  drgb $66AA66
  ; Palette 2: Floor
  drgb $776600
  drgb $000000
  drgb $282000
  drgb $504000
  ; Palette 3: Gus's cap in front of wall
  drgb $99FF99
  drgb $000000
  drgb $222280
  drgb $4444FF
  ; Palette 4: Gus's skin in front of wall
  drgb $99FF99
  drgb $000000
  drgb $aa8877
  drgb $ffbbaa
  ; Palette 5: Gus's shirt in front of wall
  drgb $99FF99
  drgb $000000
  drgb $AAAA55
  drgb $FFFF99
  ; Palette 6: Gus's skin and shirt
  drgb $FFFF99
  drgb $000000
  drgb $aa8877
  drgb $ffbbaa
  ; Palette 7: Gus's skin in front of floor
  drgb $776600
  drgb $000000
  drgb $aa8877
  drgb $ffbbaa
helpbgpalette_gbc_end:
helpobjpalette_gbc:
  ; Palette 0: Vest and arrow
  drgb $FF00FF
  drgb $AA5500
  drgb $AA8877
  drgb $000000
  ; Palette 1: Bottom of sack
  drgb $FF00FF
  drgb $131F7F
  drgb $B2B2B2
  drgb $FFFFFF
helpobjpalette_gbc_end:

section "helpcode",ROM0

;;
; Clears several variables belonging to the help system.
help_init::
  xor a
  ld [help_wanted_page],a
  ld [help_bg_loaded],a
  ld [help_cursor_y],a
  dec a
  ld [help_cur_page],a
  ret

;;
; Reads the controller, and if the Start button was pressed,
; show help screen B and set Z. Otherwise, set NZ so that
; the activity can JP NZ back to its VRAM init.
read_pad_help_check::
  ; Read the controller
  push bc
  call read_pad
  pop bc

  ; If Start not pressed, return
  ld a,[new_keys]
  bit PADB_START,a
  ret z

  ; Turn off audio in an activity's help screen
  xor a
  ldh [rNR52],A

  ; Call help
  ld a,PADF_A|PADF_B|PADF_START|PADF_LEFT|PADF_RIGHT
  call helpscreen
  or a,$FF
  ret

activity_about::
  ld a,PADF_A|PADF_B|PADF_START|PADF_LEFT|PADF_RIGHT
  ld b,helpsect_about
  jr helpscreen

activity_credits::
  ld a,PADF_A|PADF_B|PADF_START|PADF_LEFT|PADF_RIGHT
  ld b,helpsect_144p_test_suite
  ; Fall through to helpscreen

;;
; Views a help page.
; @param A The keys that the menu responds to
;   Usually includes PADF_LEFT|PADF_RIGHT if the document may have
;   multiple pages.
;   For menu selection, use PADF_UP|PADF_DOWN|PADF_A|PADF_START
;   For going back, use PADF_B.  If going back is not possible,
;   it shows machine type instead.
; @param B Document ID to view
; @return A: Number of page within document;
;   help_cursor_y: cursor position
helpscreen::
  ld [help_allowed_keys],a
  ld a,b
  ld [help_cur_doc],a

  ; If not within this document, move to the first page and move
  ; the cursor (if any) to the top
  ld a,bank(helppages)
  ld [rMBC1BANK1],a
  call help_get_doc_bounds
  ld a,[help_wanted_page]
  cp a,d
  jr c,.movetofirstpage
  cp a,e
  jr c,.nomovetofirstpage
.movetofirstpage:
  ld a,d
  ld [help_wanted_page],a
  xor a
  ld [help_cursor_y],a
.nomovetofirstpage:

  ; If the help VRAM needs to be reloaded, reload its tiles
  ; from the tiles bank and rebuild its tile map.
  ld a,[help_bg_loaded]
  or a
  jr nz,.bg_already_loaded
    call help_load_bg

    ; Invalidate the current page, which schedules
    ; loading the wanted page
    ld a,$FF
    ld [help_cur_page],a

    ; Schedule inward transition
    xor a
    jr .have_initial_wnd_progress
  .bg_already_loaded:
  
    ; If BG CHR and map are loaded, and not changing pages,
    ; don't change the transition.
    ld a,[help_cur_page]
    ld b,a
    ld a,[help_wanted_page]
    xor b
    jr z,.same_doc

    ; If changing pages while BG CHR and map are loaded,
    ; schedule an out-load-in sequence and hide the cursor
    ; until the new page comes in.
    xor a
    ld [help_show_cursor],a
    ld a,256-(wnd_x_sequence_last-wnd_x_sequence)
  .have_initial_wnd_progress:
  ld [wnd_progress],a
.same_doc:

  ld a,bank(helppages)
  ld [rMBC1BANK1],a

.loop:
  call read_pad
  ld b,PADF_UP|PADF_DOWN
  call autorepeat

  ; Start to handle keypresses
  ld a,[new_keys]
  ld b,a
  ld a,[help_allowed_keys]
  and b
  ld b,a

  ; Page to page navigation
  call help_get_doc_bounds
  ld a,[help_wanted_page]
  bit PADB_LEFT,b
  jr z,.not_left
    dec a
  .not_left:
  bit PADB_RIGHT,b
  jr z,.not_right
    inc a
  .not_right:
  cp d
  jr c,.new_page_out_of_range
  cp e
  jr nc,.new_page_out_of_range
    ld [help_wanted_page],a
  .new_page_out_of_range:

  ; Up and down navigation based on page's line count
  ld a,[help_height]
  ld c,a
  ld a,[help_cursor_y]
  bit PADB_UP,b
  jr z,.not_up
    or a
    jr z,.new_y_out_of_range
    dec a
  .not_up:
  bit PADB_DOWN,b
  jr z,.not_down
    inc a
    cp c
    jr nc,.new_y_out_of_range
  .not_down:
  ld [help_cursor_y],a
  .new_y_out_of_range:

  ; If an exit key is pressed while the showing page is the
  ; wanted page, stop
  ld a,[help_wanted_page]
  ld c,a
  ld a,[help_cur_page]
  xor c
  jr nz,.not_on_wanted_page
    ld a,PADF_B|PADF_A|PADF_START
    and b
    jr z,.not_exit
    call help_get_doc_bounds
    ld a,[help_cur_page]
    sub d
    ret

  ; If the showing and wanted pages differ, and a transition
  ; isn't already started, start one
  .not_on_wanted_page:
    ld hl,wnd_progress
    ld a,[hl]
    or a
    jr nz, .not_slid_completely_off
      call help_draw_wanted_page
      jr .not_exit
    .not_slid_completely_off:
    cp 128
    jr nc,.no_start_transition
    cp wnd_x_sequence_last-wnd_x_sequence
    jr c,.no_start_transition
      ld [hl],256-(wnd_x_sequence_last-wnd_x_sequence)
    .no_start_transition:
  .not_exit:

  ; Animate the window
  call help_move_window

  ; Draw sprites
  ld a,4*CHARACTER_OBJ_COUNT
  ld [oam_used],a

  ; Draw arrow if up/down navigation allowed
  ld a,[help_show_cursor]
  or a
  jr z,.nodrawarrow
  ld a,[oam_used]
  ld l,a
  ld h,high(SOAM)
  ld a,[help_cursor_y]
  add a
  add a
  add a
  add HELP_CURSOR_Y_BASE
  ld [hl+],a
  ld a,[wnd_x]
  add 6+1
  ld [hl+],a
  ld a,ARROW_SPRITE_TILE
  ld [hl+],a
  xor a
  ld [hl+],a
  ld a,l
  ld [oam_used],a
.nodrawarrow:
  call lcd_clear_oam

  ; Wait for next frame
  call wait_vblank_irq
  call run_dma
  ld a,[wnd_x]
  ldh [rWX],a
  jp .loop

; VRAM preparation ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;
; Loads the background used by the help page.
help_load_bg:
  call lcd_off

  ; Load tiles used by menu
  ld de,helptiles
  ld b,sizeof_helptiles/16
  ld a,[initial_a]
  cp $11
  jr nz,.notgbc1
    ld de,helptiles_gbc
    ld b,sizeof_helptiles_gbc/16
  .notgbc1:
  ld hl,CHRRAM1
  call pb16_unpack_block

  ; Set default window scroll position
  ld a,167
  ld [wnd_x],a
  ldh [rWX],a
  xor a
  ldh [rWY],a
  ldh [rSCX],a
  ldh [rSCY],a

  ; Clear VWF canvas in pattern table
  ld e,0
  ld a,[initial_a]
  cp $11
  jr nz,.notgbc2
    dec e
  .notgbc2:
  ld hl,CHRRAM0
  call clear_canvas
  ld hl,CHRRAM2
  call clear_canvas

  ; Background map: Draw back wall
  ld a,20
  ld de,32
  .bgcolloop:
    dec a
    ld l,a
    ; Back wall
    ld h,high(_SCRN0)
    ld a,WALL_TILE
    ld c,WALL_HEIGHT-1
    .wallloop:
      ld [hl],a
      add hl,de
      dec c
      jr nz,.wallloop

    ; Border between wall and floor
    ld [hl],WALLBOTTOM_TILE
    add hl,de
    ld [hl],FLOORTOP_TILE

    ; Floor
    ld a,FLOOR_TILE
    ld c,18-WALL_HEIGHT-1
    .floorloop:
      add hl,de
      ld [hl],a
      dec c
      jr nz,.floorloop

    ; Move to top of column and stop if it's the first
    ld a,l
    and $1F
    jr nz,.bgcolloop
    
  ; Background map: Draw right half of character
  ld hl,_SCRN0+32*CHARACTER_Y+3
  ld a,$86
  ld c,12/2
  call .righthalfcol
  ld hl,_SCRN0+32*CHARACTER_Y+4
  ld a,$88
  ld c,12/2
  call .righthalfcol
  ld hl,_SCRN0+32*(CHARACTER_Y+4)+5
  ld a,$96
  ld c,8/2
  call .righthalfcol

  ; Window map: Divider column at left
  ld hl,_SCRN1
  ld [hl],WINDOW_TL_TILE
  ld hl,_SCRN1+32
  ld c,16
  ld a,WINDOW_LEFT_TILE
  call .solidcol
  ld [hl],WINDOW_BL_TILE

  ; Window map: Overscroll bounce margin
  ld hl,_SCRN1+WINDOW_WIDTH+1
  ld c,18
  call .whitecol

  ; Window map: Draw text area
  ld b,0  ; b: rownumber
  .textrowloop:
    ; Destination address is
    ; (_SCRN1 / 32 + row + (row>=1) + (row>=15)) * 32 + 1
    ld a,b
    cp 15
    jr c,.textrowloop_addrcalc1
      inc a
    .textrowloop_addrcalc1:
    cp 1
    jr c,.textrowloop_addrcalc2
      inc a
    .textrowloop_addrcalc2:
    add low(_SCRN1/32)
    ld l,a
    ld h,high(_SCRN1/32)
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    inc l

    ; Tile number is (row << 4) & 0x70
    ld a,b
    swap a
    and $70

    ld c,WINDOW_WIDTH
    .texttileloop:
      ld [hl+],a
      inc a
      dec c
      jr nz,.texttileloop

    inc b
    ld a,16
    cp b
    jr nz,.textrowloop

  ; Mark the background as having been loaded and cleared
  xor a
  ld [help_height],a
  inc a
  ld [help_bg_loaded],a

  ; Window map: Draw top and bottom horizontal bars
  ld hl,_SCRN1+1*32+1
  call .draw_wnd_hbar
  ld hl,_SCRN1+16*32+1
  call .draw_wnd_hbar
  
  ld a,[initial_a]
  cp $11
  jr nz,.notgbcfinal
    call .load_gbc_only
    jr .donegbcfinal
  .notgbcfinal:
    call .load_mono_only
  .donegbcfinal:
  call lcd_clear_oam
  call run_dma

  ld a,LCDCF_ON|BG_CHR01|OBJ_8X16|BG_NT0|WINDOW_NT1
  ldh [rLCDC],a
  ld [vblank_lcdc_value],a
  ld a,LCDCF_ON|BG_CHR21|OBJ_8X16|BG_NT0|WINDOW_NT1
  ld [stat_lcdc_value],a
  ld a,72
  ldh [rLYC],a
  ld a,STAT_LYCIRQ
  ld [rSTAT],a
  ld a,IEF_VBLANK|IEF_LCDC
  ldh [rIE],a  ; enable rSTAT IRQ
  ret

.load_mono_only:
  ; Background map: Cut out area for left half of character
  ; so that it can be drawn with flipped tiles
  ld hl,_SCRN0+32*(CHARACTER_Y+4)+0
  ld c,8
  ld a,WHITE_TILE
  call .whitecol
  ld hl,_SCRN0+32*CHARACTER_Y+1
  ld c,12
  call .solidcol
  ld hl,_SCRN0+32*CHARACTER_Y+2
  ld c,12
  call .solidcol

  ; Load static sprites
  ld a,OAMF_XFLIP
  ldh [Lspriterect_attr],a
  ld hl,SOAM
  ld bc,($86*256) + 12/2
  ld de,(CHARACTER_Y*8+16)*256+16+8
  call .objcol
  ld bc,($88*256) + 12/2
  ld de,(CHARACTER_Y*8+16)*256+8+8
  call .objcol
  ld bc,($96*256) + 8/2
  ld de,(CHARACTER_Y*8+16+32)*256+0+8
  call .objcol
  ld a,l
  ld [oam_used],a

  ; Load palette
  ld a,%01101100
  call set_bgp
  ld a,%01101100
  call set_obp0

  ret

.load_gbc_only:
  ; Fill BG attribute with back wall palette number
  ld a,1
  ldh [rVBK],a

  ld de,_SCRN0
  ld bc,32*WALL_HEIGHT
  ld h,1  ; back wall palette
  call memset
  ld bc,32*(18 - WALL_HEIGHT)
  ld h,2  ; floor palette
  call memset

  ; Fill window attribute
  ld de,_SCRN1
  ld bc,32*18
  ld h,0
  call memset

  ; Draw palette and flipping for character
  ld de,_SCRN0+32*CHARACTER_Y+0
  ld bc,6*256+12
  ld hl,helpattrmap_gbc
  call load_nam

  ; Return to plane 0
  xor a
  ldh [rVBK],a

  ; Background map: Draw left half of character
  ld hl,_SCRN0+32*CHARACTER_Y+2
  ld a,$86
  ld c,12/2
  call .righthalfcol
  ld hl,_SCRN0+32*CHARACTER_Y+1
  ld a,$88
  ld c,12/2
  call .righthalfcol
  ld hl,_SCRN0+32*(CHARACTER_Y+4)+0
  ld a,$96
  ld c,8/2
  call .righthalfcol

  ; TODO: Draw sprite overlay
  ld hl,SOAM
  
  ; Vest left half
  ld a,OAMF_XFLIP|0
  ldh [Lspriterect_attr],a
  ld bc,($AA*256) + 6/2
  ld de,(CHARACTER_Y*8+40)*256+16+8
  call .objcol
  ld bc,($AC*256) + 6/2
  ld de,(CHARACTER_Y*8+40)*256+8+8
  call .objcol

  ; Vest right half
  xor a
  ldh [Lspriterect_attr],a
  ld bc,($AA*256) + 6/2
  ld de,(CHARACTER_Y*8+40)*256+24+8
  call .objcol
  ld bc,($AC*256) + 6/2
  ld de,(CHARACTER_Y*8+40)*256+32+8
  call .objcol

  ; Bottom
  ld a,CHARACTER_Y*8+90
  ld [hl+],a
  ld a,8+8
  ld [hl+],a
  ld a,$AE
  ld [hl+],a
  ld a,OAMF_XFLIP|1
  ld [hl+],a
  ld a,CHARACTER_Y*8+90
  ld [hl+],a
  ld a,16+8
  ld [hl+],a
  ld a,$B4
  ld [hl+],a
  ld a,OAMF_XFLIP|1
  ld [hl+],a
  ld a,CHARACTER_Y*8+90
  ld [hl+],a
  ld a,24+8
  ld [hl+],a
  ld a,$B4
  ld [hl+],a
  ld a,1
  ld [hl+],a
  ld a,CHARACTER_Y*8+90
  ld [hl+],a
  ld a,32+8
  ld [hl+],a
  ld a,$AE
  ld [hl+],a
  ld a,1
  ld [hl+],a

  ld a,l
  ld [oam_used],a

  ; Load palette
  ld hl,helpbgpalette_gbc
  ld bc,(helpobjpalette_gbc-helpbgpalette_gbc) * 256 + low(rBCPS)
  ld a,$80
  call set_gbc_palette
  ld bc,(helpobjpalette_gbc_end-helpobjpalette_gbc) * 256 + low(rOCPS)
  ld a,$80
  call set_gbc_palette

  ret

.draw_wnd_hbar:
  ld c,WINDOW_WIDTH
  ld a,WINDOW_HLINE_TILE
  .wnd_hbar_loop:
    ld [hl+],a
    dec c
    jr nz, .wnd_hbar_loop
  ret

.whitecol:
  ld a,WHITE_TILE
.solidcol:
  ld de,32
  .objcutoutcol_loop:
    ld [hl],a
    add hl,de
    dec c
    jr nz,.objcutoutcol_loop
  ret

.righthalfcol:
  ld de,32
  .righthalfcol_loop:
    ld [hl],a
    add hl,de
    inc a
    ld [hl],a
    add hl,de
    add a,5
    dec c
    jr nz,.righthalfcol_loop
  ret

.objcol:
  ld a,d  ; Y coordinate
  ld [hl+],a
  add 16
  ld d,a
  ld a,e  ; X coordinate
  ld [hl+],a
  ld a,b  ; tile number
  ld [hl+],a
  add 6
  ld b,a
  ldh a,[Lspriterect_attr]
  ld [hl+],a
  dec c
  jr nz,.objcol
  ret

;;
; Clear 2048 bytes of VWF canvas to plane1 = 0, plane1 = E
; @param HL starting address
clear_canvas:
  ld bc,-1024
  xor a
  .loop:
    ld [hl+],a
    xor e
    ld [hl+],a
    xor e
    inc c
    jr nz,.loop
    inc b
    jr nz,.loop
  ret

; Window movement ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

help_move_window:
  ; Decide when it's fully offscreen whether to hide or show
  ; the cursor
  ld hl,wnd_progress
  ld a,[hl]
  or a
  jr nz,.not_cursor_check
    ; If this doc should show a cursor, show it
    ld a,[help_allowed_keys]
    and PADF_DOWN
    ld [help_show_cursor],a
    ld a,[hl]
  .not_cursor_check:

  ; Is a transition in progress?
  cp wnd_x_sequence_peak-wnd_x_sequence
  jr nz,.not_peak_transition
    ; This transition is at its "peak", and its retraction to the
    ; locked position can be shortcut if a transition is needed
    ld a,[help_wanted_page]
    ld b,a
    ld a,[help_cur_page]
    xor b
    jr z,.not_peak_transition
    ld [hl],256-(wnd_x_sequence_peak-wnd_x_sequence)
  .not_peak_transition:

  ld a,[hl]
  cp 128
  jr nc,.is_leaving
  cp wnd_x_sequence_last-wnd_x_sequence
  jr c,.is_entering
  ld a,WXBASE
  jr .have_wnd_x

  .is_leaving:
    cpl
  .is_entering:
  cp wnd_x_sequence_last-wnd_x_sequence
  jr c,.notfin
    ld a,wnd_x_sequence_last-wnd_x_sequence
  .notfin:

  ; Clock the sequence forward one step
  inc [hl]

  ; Look up wnd_x_sequence[a]
  ld e,a
  ld d,0
  ld hl,wnd_x_sequence
  add hl,de
  ld a,[hl]
.have_wnd_x:
  ld [wnd_x],a
  ret

; Make sure not to include 166 (only 1 pixel showing) in this
; sequence, as the mono GB has bugs showing it
wnd_x_sequence:
  db 167
;  db WXBASE+120
  db WXBASE+108
  db WXBASE+88
  db WXBASE+70
  db WXBASE+54
  db WXBASE+40
  db WXBASE+28
  db WXBASE+18
  db WXBASE+10
  db WXBASE+4
  db WXBASE+0
  db WXBASE-2
  db WXBASE-3
  db WXBASE-4
wnd_x_sequence_peak:
  db WXBASE-4
  db WXBASE-3
  db WXBASE-1
wnd_x_sequence_last:
  db WXBASE+0

; Help text drawing ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; The NES version uses a state machine that loads one line per frame.
; This is needed because the NES PPU has no hblank (mode 0); instead,
; it proceeds directly from one mode 3 to the next.  In addition, its
; vblank is long enough to upload both OAM and an entire line of text
; (128 bytes at roughly 9 cycles per byte), unlike the Game Boy whose
; vblank is only 10 lines.  Thus the Game Boy version draws each line
; and uploads it over the next 14 hblanks.

help_draw_wanted_page:
  ; Draw the document's title
  call vwfClearBuf
  ld a,[help_cur_doc]
  ld de,helptitles
  call de_index_a
  ld b,$00  ; X position
  call vwfPuts
  ld hl,CHRRAM0+$000
  ld c,WINDOW_WIDTH
  call vwfPutBufHBlank

  ; Look up the address of the start of this page's text
  ld a,[help_wanted_page]
  ld [help_cur_page],a
  ld de,helppages
  call de_index_a
  ; fall through to help_draw_multiline

;;
; Draws the page
help_draw_multiline:
; HL: text pointer
; B: line number (1-14)
  ld b, 1
.lineloop:
  push bc
  push hl
  call vwfClearBuf  ; Clear the buffer
  pop hl
  ld de,help_line_buffer
  call undte_line  ; Decompress a line of text

  ; Draw the line of text to the buffer
  push hl
  ld a,[help_allowed_keys]
  and PADF_DOWN
  jr z,.not_menu_indent
    ld a,MENU_INDENT_WIDTH
  .not_menu_indent:
  ld b,a
  ld hl,help_line_buffer
  call vwfPuts
  pop hl
  pop bc
  dec hl
  ; HL: pointer to last character, B: line n

  ; Now draw the tile buffer to the screen
  push bc
  push hl
  call help_putlineb
  pop hl
  pop bc

  ; If at a NUL terminator, stop.  At any other control
  ; character, continue to next line
  ld a,[hl+]
  cp 0
  jr z,.textdone

  ; If not below the screen, continue
  inc b
  ld a,b
  cp 15
  jr c,.lineloop
  dec b
.textdone:

  ; B is the height of this page.  Move the cursor up if needed.
  ld a,[help_cursor_y]
  cp b
  jr c,.no_move_help_cursor
  ld a,b
  dec a
  ld [help_cursor_y],a
.no_move_help_cursor:

  ; Save help height for up/down functions and clearing trailing
  ; lines
  ld a,[help_height]
  ld c,a
  ld a,b
  ld [help_height],a

  ; Clear lines used by this page but not the last one
  ; C = height of last page; B = height of this page
  push bc
  call vwfClearBuf
  pop bc
  jr .erase_trailing_check
.erase_trailing:
  inc b
  push bc
  call help_putlineb
  pop bc
.erase_trailing_check:
  ld a,b
  cp c
  jr c,.erase_trailing
  ; fall through to help_draw_status_line

help_draw_status_line:
  ; If at least 2 pages, draw page count
  call help_get_doc_bounds
  ld a,e
  sub d
  cp 2
  jr c,.fewer_than_two_pages
    ld hl,help_line_buffer
    ld a,GL_LEFT
    ld [hl+],a
    ld a,[help_cur_page]
    sub a,d
    inc a
    call help_put2dig
    ld a,"/"
    ld [hl+],a
    ld a,e
    sub d
    call help_put2dig
    ld a,GL_RIGHT
    ld [hl+],a
    ld [hl],0
    ld b,0
    ld hl,help_line_buffer
    call vwfPuts
  .fewer_than_two_pages:

  ; If Down arrow enabled, draw Up/Down/A controls
  ld a,[help_allowed_keys]
  bit PADB_DOWN,a
  jr z,.no_updowna
    ld hl,updowna_msg
    ld b,36
    call vwfPuts
  .no_updowna:

  ; If B button enabled, draw Up/Down/A controls.
  ; Otherwise draw machine_type string.
  ld hl,b_exit_msg
  ld a,[help_allowed_keys]
  bit PADB_B,a
  jr nz,.have_type_hl
  
  ; Display machine type
  ld a,[is_sgb]
  ld c,a
  ld a,[initial_b]
  ld b,a
  ld a,[initial_a]
  ; A=$11: Game Boy Color/Advance; $FF: Game Boy Pocket/SGB2;
  ; others: original/Super Game Boy
  cp $11
  jr z,.not_mono
  cp $FF
  jr nz,.dmg_or_sgb
  
  ; is_sgb distinguishes SGB2 from GB Pocket
  ld hl,gbp_msg
  xor a
  xor c
  jr z,.have_type_hl
  ld hl,sgb2_msg
  jr .have_type_hl

.dmg_or_sgb:
  ; is_sgb distinguishes SGB from GB
  ld hl,gb_msg
  xor a
  xor c
  jr z,.have_type_hl
  ld hl,sgb_msg
  jr .have_type_hl

.not_mono:
  ; B bit 0 distinguishes GBA from GBC
  ld hl,gbc_msg
  bit 0,b
  jr z,.have_type_hl
  ld hl,gba_msg
.have_type_hl:
  ld a,[hl+]
  ld b,a
  call vwfPuts

  ld b,15
  ; fall through to help_putlineb

help_putlineb:
  ; Calculate destination address:
  ; $8000, $8100, ..., $8700, $9000, $9100, ...
  ld a,b
  and $08  ; 0, 0, ..., 0, 8, 8, ...
  add b    ; $00, $01, ..., $07, $10, $11, ...
  add high(CHRRAM0)  ; $80, $81, ..., $87, $90, $91, ...
  ld h,a
  ld l,0
  ld c,14  ; tile count
  jp vwfPutBufHBlank

help_put2dig:
  or a  ; clear halfcarry
  daa
  cp 10
  jr c,.less_than_ten
    push af
    swap a
    and $0F
    add "0"
    ld [hl+],a
    pop af
  .less_than_ten:
  and $0F
  add "0"
  ld [hl+],a
  ret

; Navigation of page ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;
; Gets the current document's page range.
; @param help_cur_doc which document
; @return D: first page of this document;
;   E: first page after those of this document
help_get_doc_bounds:
  ld hl,help_cumul_pages
  ld a,[help_cur_doc]
  ld e,a
  ld d,0
  add hl,de
  ld a,[hl+]
  ld e,[hl]
  ld d,a
  ret

;;
; Reads element A of an array of unsigned short *.
; @param A the index
; @param DE pointer to the array
; @return HL the value at [DE+A*2]
de_index_a::
  ld l,a
  ld h,0
  add hl,hl
  add hl,de
  ld a,[hl+]
  ld h,[hl]
  ld l,a
  ret


; Text loading engine ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Usually text is changed while the window is scrolled off.

section "helptext",ROM0,align[1]

updowna_msg:  db $86,$87,"A: Go",0
b_exit_msg:   db 82, "B: Exit",0
gb_msg:       db 96, "GB",0
sgb_msg:      db 90, "SGB",0
gbp_msg:      db 90, "GBP",0
sgb2_msg:     db 85, "SGB2",0
gbc_msg:      db 90, "GBC",0
gba_msg:      db 90, "GBA",0

