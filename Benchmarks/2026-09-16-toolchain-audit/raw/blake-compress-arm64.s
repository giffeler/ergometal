
_$s4main10Blake2b256O8compress33_2A6AF8E31042FF2525A5CD903B7E1D2CLL_5block5count5finalys11InlineArrayVy$7_s6UInt64VGz_s4SpanVys5UInt8VGALSbtFZTf4nnnnd_n: ; @"$s4main10Blake2b256O8compress33_2A6AF8E31042FF2525A5CD903B7E1D2CLL_5block5count5finalys11InlineArrayVy$7_s6UInt64VGz_s4SpanVys5UInt8VGALSbtFZTf4nnnnd_n"
; %bb.0:
	sub	sp, sp, #336
	stp	x28, x27, [sp, #240]            ; 16-byte Folded Spill
	stp	x26, x25, [sp, #256]            ; 16-byte Folded Spill
	stp	x24, x23, [sp, #272]            ; 16-byte Folded Spill
	stp	x22, x21, [sp, #288]            ; 16-byte Folded Spill
	stp	x20, x19, [sp, #304]            ; 16-byte Folded Spill
	stp	x29, x30, [sp, #320]            ; 16-byte Folded Spill
	add	x29, sp, #320
                                        ; kill: def $w4 killed $w4 def $x4
Lloh198:
	adrp	x8, ___stack_chk_guard@GOTPAGE
Lloh199:
	ldr	x8, [x8, ___stack_chk_guard@GOTPAGEOFF]
Lloh200:
	ldr	x8, [x8]
	stur	x8, [x29, #-96]
	movi.2d	v0, #0000000000000000
	stp	q0, q0, [sp, #192]
	stp	q0, q0, [sp, #160]
	stp	q0, q0, [sp, #128]
	stp	q0, q0, [sp, #96]
	subs	x8, x2, #8
	b.lo	LBB94_6
; %bb.1:
	mov	x9, #0                          ; =0x0
	lsr	x10, x2, #3
	add	x11, sp, #96
LBB94_2:                                ; =>This Inner Loop Header: Depth=1
	cmp	x2, x9
	b.lo	LBB94_46
; %bb.3:                                ;   in Loop: Header=BB94_2 Depth=1
	cmp	x9, x8
	b.gt	LBB94_46
; %bb.4:                                ;   in Loop: Header=BB94_2 Depth=1
	cmp	x9, #128
	b.eq	LBB94_48
; %bb.5:                                ;   in Loop: Header=BB94_2 Depth=1
	ldr	x12, [x1, x9]
	str	x12, [x11, x9]
	add	x9, x9, #8
	subs	x10, x10, #1
	b.ne	LBB94_2
LBB94_6:
	and	x10, x2, #0x7ffffffffffffff8
	cmp	x10, x2
	b.eq	LBB94_10
; %bb.7:
	lsl	x8, x2, #3
	and	x8, x8, #0xffffffffffffffc0
	add	x9, sp, #96
LBB94_8:                                ; =>This Inner Loop Header: Depth=1
	sub	x11, x10, #128
	cmn	x11, #135
	b.lo	LBB94_47
; %bb.9:                                ;   in Loop: Header=BB94_8 Depth=1
	ldrb	w11, [x1, x10]
	sxtb	w12, w10
	ubfx	w12, w12, #12, #3
	add	w12, w10, w12
	add	x10, x10, #1
	and	x13, x8, #0x38
	lsl	x11, x11, x13
	sxtb	w12, w12
	ubfx	x12, x12, #3, #8
	ldr	x13, [x9, x12, lsl #3]
	orr	x11, x11, x13
	str	x11, [x9, x12, lsl #3]
	add	x8, x8, #8
	cmp	x2, x10
	b.ne	LBB94_8
LBB94_10:
	ldp	x21, x7, [x0]
	ldp	x1, x24, [x0, #16]
	ldp	x10, x5, [x0, #32]
	mov	x8, #33489                      ; =0x82d1
	movk	x8, #44518, lsl #16
	movk	x8, #21119, lsl #32
	movk	x8, #20750, lsl #48
	eor	x23, x3, x8
	sbfx	x8, x4, #0, #1
	mov	x9, #48491                      ; =0xbd6b
	movk	x9, #64321, lsl #16
	movk	x9, #55723, lsl #32
	movk	x9, #8067, lsl #48
	eor	x2, x8, x9
	mov	x8, #8569                       ; =0x2179
	movk	x8, #4990, lsl #16
	movk	x8, #52505, lsl #32
	movk	x8, #23520, lsl #48
	stp	x8, x10, [sp, #80]              ; 16-byte Folded Spill
	mov	x19, #27679                     ; =0x6c1f
	movk	x19, #11070, lsl #16
	movk	x19, #26764, lsl #32
	movk	x19, #39685, lsl #48
	mov	x25, #14065                     ; =0x36f1
	movk	x25, #24349, lsl #16
	movk	x25, #62778, lsl #32
	movk	x25, #42319, lsl #48
	ldp	x3, x4, [x0, #48]
	stp	x21, x0, [sp, #8]               ; 16-byte Folded Spill
	mov	x26, #63531                     ; =0xf82b
	movk	x26, #65172, lsl #16
	movk	x26, #62322, lsl #32
	movk	x26, #15470, lsl #48
	mov	x22, #42811                     ; =0xa73b
	movk	x22, #33994, lsl #16
	movk	x22, #44677, lsl #32
	movk	x22, #47975, lsl #48
	mov	x20, #51464                     ; =0xc908
	movk	x20, #62396, lsl #16
	movk	x20, #58983, lsl #32
	movk	x20, #27145, lsl #48
Lloh201:
	adrp	x9, _$s4main10Blake2b256O5sigma33_2A6AF8E31042FF2525A5CD903B7E1D2CLLs11InlineArrayVy$11_AGy$15_SiGGvpZ@PAGE+64
Lloh202:
	add	x9, x9, _$s4main10Blake2b256O5sigma33_2A6AF8E31042FF2525A5CD903B7E1D2CLLs11InlineArrayVy$11_AGy$15_SiGGvpZ@PAGEOFF+64
	mov	w11, #12                        ; =0xc
LBB94_11:                               ; =>This Inner Loop Header: Depth=1
	ldur	x10, [x9, #-64]
	cmp	x10, #15
	b.hi	LBB94_30
; %bb.12:                               ;   in Loop: Header=BB94_11 Depth=1
	ldur	x28, [x9, #-56]
	cmp	x28, #15
	b.hi	LBB94_31
; %bb.13:                               ;   in Loop: Header=BB94_11 Depth=1
	ldur	x16, [x9, #-48]
	cmp	x16, #15
	b.hi	LBB94_32
; %bb.14:                               ;   in Loop: Header=BB94_11 Depth=1
	ldur	x15, [x9, #-40]
	cmp	x15, #15
	b.hi	LBB94_33
; %bb.15:                               ;   in Loop: Header=BB94_11 Depth=1
	ldur	x13, [x9, #-32]
	cmp	x13, #15
	b.hi	LBB94_34
; %bb.16:                               ;   in Loop: Header=BB94_11 Depth=1
	ldur	x14, [x9, #-24]
	cmp	x14, #15
	b.hi	LBB94_35
; %bb.17:                               ;   in Loop: Header=BB94_11 Depth=1
	ldur	x12, [x9, #-16]
	cmp	x12, #15
	b.hi	LBB94_36
; %bb.18:                               ;   in Loop: Header=BB94_11 Depth=1
	ldur	x0, [x9, #-8]
	cmp	x0, #15
	b.hi	LBB94_37
; %bb.19:                               ;   in Loop: Header=BB94_11 Depth=1
	ldr	x8, [x9]
	cmp	x8, #15
	b.hi	LBB94_38
; %bb.20:                               ;   in Loop: Header=BB94_11 Depth=1
	ldr	x30, [x9, #8]
	cmp	x30, #15
	b.hi	LBB94_39
; %bb.21:                               ;   in Loop: Header=BB94_11 Depth=1
	ldr	x27, [x9, #16]
	cmp	x27, #15
	b.hi	LBB94_40
; %bb.22:                               ;   in Loop: Header=BB94_11 Depth=1
	str	x30, [sp, #72]                  ; 8-byte Folded Spill
	ldr	x30, [x9, #24]
	cmp	x30, #15
	b.hi	LBB94_41
; %bb.23:                               ;   in Loop: Header=BB94_11 Depth=1
	ldr	x17, [x9, #32]
	cmp	x17, #15
	b.hi	LBB94_42
; %bb.24:                               ;   in Loop: Header=BB94_11 Depth=1
	ldr	x6, [x9, #40]
	cmp	x6, #15
	b.hi	LBB94_43
; %bb.25:                               ;   in Loop: Header=BB94_11 Depth=1
	str	x17, [sp, #64]                  ; 8-byte Folded Spill
	ldr	x17, [x9, #48]
	cmp	x17, #15
	b.hi	LBB94_44
; %bb.26:                               ;   in Loop: Header=BB94_11 Depth=1
	stp	x6, x17, [sp, #40]              ; 16-byte Folded Spill
	mov	x17, x1
	ldr	x1, [x9, #56]
	str	x1, [sp, #56]                   ; 8-byte Folded Spill
	cmp	x1, #15
	b.hi	LBB94_45
; %bb.27:                               ;   in Loop: Header=BB94_11 Depth=1
	mov	x6, x2
	add	x9, x9, #128
	str	x20, [sp, #24]                  ; 8-byte Folded Spill
	mov	x20, x24
	add	x24, sp, #96
	ldr	x16, [x24, x16, lsl #3]
	add	x7, x5, x7
	add	x16, x7, x16
	ldr	x10, [x24, x10, lsl #3]
	eor	x7, x16, x19
	ror	x19, x7, #32
	add	x22, x19, x22
	eor	x5, x22, x5
	ror	x5, x5, #24
	ldr	x15, [x24, x15, lsl #3]
	ldr	x2, [sp, #88]                   ; 8-byte Folded Reload
	add	x7, x2, x21
	add	x10, x7, x10
	add	x15, x15, x16
	ldr	x13, [x24, x13, lsl #3]
	add	x16, x3, x17
	add	x13, x16, x13
	ldr	x14, [x24, x14, lsl #3]
	eor	x16, x13, x6
	ror	x16, x16, #32
	add	x21, x16, x26
	eor	x1, x21, x3
	ror	x6, x1, #24
	ldr	x12, [x24, x12, lsl #3]
	add	x1, x4, x20
	add	x12, x1, x12
	ldr	x0, [x24, x0, lsl #3]
	ldr	x17, [sp, #80]                  ; 8-byte Folded Reload
	eor	x1, x12, x17
	str	x11, [sp, #32]                  ; 8-byte Folded Spill
	ror	x11, x1, #32
	add	x14, x14, x13
	add	x3, x11, x25
	eor	x13, x3, x4
	ror	x7, x13, #24
	add	x20, x0, x12
	ldr	x12, [x24, x28, lsl #3]
	eor	x13, x10, x23
	ror	x13, x13, #32
	ldr	x17, [sp, #24]                  ; 8-byte Folded Reload
	add	x17, x13, x17
	eor	x0, x17, x2
	ror	x0, x0, #24
	add	x10, x12, x10
	add	x28, x10, x0
	eor	x10, x28, x13
	ror	x1, x10, #16
	add	x23, x15, x5
	eor	x10, x23, x19
	ror	x2, x10, #16
	add	x10, x2, x22
	eor	x12, x10, x5
	ror	x13, x12, #63
	add	x4, x14, x6
	eor	x12, x4, x16
	ror	x12, x12, #16
	add	x14, x12, x21
	eor	x15, x14, x6
	ror	x6, x15, #63
	add	x16, x20, x7
	eor	x11, x16, x11
	ror	x15, x11, #16
	ldr	x8, [x24, x8, lsl #3]
	ldr	x11, [x24, x27, lsl #3]
	ldr	x19, [x24, x30, lsl #3]
	add	x5, x13, x28
	add	x20, x5, x8
	add	x8, x6, x23
	add	x11, x8, x11
	eor	x8, x11, x1
	ror	x5, x8, #32
	add	x8, x15, x3
	eor	x7, x8, x7
	add	x8, x5, x8
	eor	x3, x8, x6
	ror	x3, x3, #24
	add	x6, x19, x11
	ror	x11, x7, #63
	ldr	x7, [sp, #64]                   ; 8-byte Folded Reload
	ldr	x7, [x24, x7, lsl #3]
	add	x4, x11, x4
	add	x4, x4, x7
	add	x17, x1, x17
	eor	x0, x17, x0
	ldr	x1, [sp, #40]                   ; 8-byte Folded Reload
	ldr	x1, [x24, x1, lsl #3]
	eor	x2, x4, x2
	ror	x2, x2, #32
	add	x17, x2, x17
	eor	x11, x17, x11
	ror	x11, x11, #24
	add	x1, x1, x4
	ror	x0, x0, #63
	ldr	x4, [sp, #48]                   ; 8-byte Folded Reload
	ldr	x4, [x24, x4, lsl #3]
	add	x16, x16, x0
	add	x16, x16, x4
	ldr	x4, [sp, #72]                   ; 8-byte Folded Reload
	ldr	x4, [x24, x4, lsl #3]
	eor	x15, x20, x15
	ror	x15, x15, #32
	add	x14, x15, x14
	eor	x13, x14, x13
	ror	x13, x13, #24
	add	x4, x4, x20
	add	x21, x4, x13
	eor	x15, x21, x15
	ror	x4, x15, #16
	ldr	x15, [sp, #56]                  ; 8-byte Folded Reload
	ldr	x15, [x24, x15, lsl #3]
	eor	x12, x16, x12
	ror	x12, x12, #32
	add	x10, x12, x10
	eor	x0, x10, x0
	ror	x0, x0, #24
	add	x15, x15, x16
	str	x4, [sp, #80]                   ; 8-byte Folded Spill
	add	x26, x4, x14
	eor	x13, x26, x13
	add	x7, x6, x3
	eor	x14, x7, x5
	add	x1, x1, x11
	eor	x16, x1, x2
	ror	x23, x14, #16
	ror	x19, x16, #16
	add	x25, x23, x8
	eor	x8, x25, x3
	add	x20, x19, x17
	eor	x11, x20, x11
	add	x24, x15, x0
	ror	x5, x13, #63
	eor	x12, x24, x12
	ror	x3, x8, #63
	ror	x2, x12, #16
	add	x22, x2, x10
	eor	x8, x22, x0
	ror	x4, x11, #63
	ldr	x11, [sp, #32]                  ; 8-byte Folded Reload
	ror	x8, x8, #63
	str	x8, [sp, #88]                   ; 8-byte Folded Spill
	subs	x11, x11, #1
	b.ne	LBB94_11
; %bb.28:
	ldp	x8, x11, [sp, #8]               ; 16-byte Folded Reload
	eor	x8, x21, x8
	eor	x8, x8, x20
	ldp	x9, x10, [x11, #8]
	eor	x9, x7, x9
	eor	x9, x9, x22
	stp	x8, x9, [x11]
	eor	x8, x10, x1
	eor	x8, x26, x8
	ldp	x9, x10, [x11, #24]
	eor	x9, x9, x24
	eor	x9, x25, x9
	stp	x8, x9, [x11, #16]
	eor	x8, x23, x10
	ldr	x9, [sp, #88]                   ; 8-byte Folded Reload
	eor	x8, x8, x9
	ldp	x9, x10, [x11, #40]
	eor	x9, x9, x19
	eor	x9, x5, x9
	stp	x8, x9, [x11, #32]
	eor	x8, x10, x2
	eor	x8, x3, x8
	ldr	x9, [x11, #56]
	ldr	x10, [sp, #80]                  ; 8-byte Folded Reload
	eor	x9, x10, x9
	eor	x9, x9, x4
	stp	x8, x9, [x11, #48]
	ldur	x8, [x29, #-96]
Lloh203:
	adrp	x9, ___stack_chk_guard@GOTPAGE
Lloh204:
	ldr	x9, [x9, ___stack_chk_guard@GOTPAGEOFF]
Lloh205:
	ldr	x9, [x9]
	cmp	x9, x8
	b.ne	LBB94_49
; %bb.29:
	ldp	x29, x30, [sp, #320]            ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #304]            ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #288]            ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #272]            ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #256]            ; 16-byte Folded Reload
	ldp	x28, x27, [sp, #240]            ; 16-byte Folded Reload
	add	sp, sp, #336
	ret
LBB94_30:
	brk	#0x1
LBB94_31:
	brk	#0x1
LBB94_32:
	brk	#0x1
LBB94_33:
	brk	#0x1
LBB94_34:
	brk	#0x1
LBB94_35:
	brk	#0x1
LBB94_36:
	brk	#0x1
LBB94_37:
	brk	#0x1
LBB94_38:
	brk	#0x1
LBB94_39:
	brk	#0x1
LBB94_40:
	brk	#0x1
LBB94_41:
	brk	#0x1
LBB94_42:
	brk	#0x1
LBB94_43:
	brk	#0x1
LBB94_44:
	brk	#0x1
LBB94_45:
	brk	#0x1
LBB94_46:
	brk	#0x1
LBB94_47:
	brk	#0x1
LBB94_48:
	brk	#0x1
LBB94_49:
	bl	___stack_chk_fail
	.loh AdrpLdrGotLdr	Lloh198, Lloh199, Lloh200
	.loh AdrpAdd	Lloh201, Lloh202
	.loh AdrpLdrGotLdr	Lloh203, Lloh204, Lloh205
                                        