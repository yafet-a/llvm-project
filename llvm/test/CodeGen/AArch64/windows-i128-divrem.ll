
; RUN: llc -mtriple=aarch64-pc-windows-msvc < %s | FileCheck %s --check-prefix=WINDOWS
; RUN: llc -mtriple=arm64ec-pc-windows-msvc < %s | FileCheck %s --check-prefix=ARM64EC

; Windows on Arm does not provide the compiler-rt i128 div/rem entry points,
; while Arm64EC does provide them with its usual mangling.

define i128 @sdiv_i128(i128 %x, i128 %y) {
; WINDOWS-LABEL: sdiv_i128:
; WINDOWS-NOT: __divti3
; WINDOWS: ret
;
; ARM64EC-LABEL: "#sdiv_i128":
; ARM64EC: bl "#__divti3"
; ARM64EC: ret
  %result = sdiv i128 %x, %y
  ret i128 %result
}

define i128 @udiv_i128(i128 %x, i128 %y) {
; WINDOWS-LABEL: udiv_i128:
; WINDOWS-NOT: __udivti3
; WINDOWS: ret
;
; ARM64EC-LABEL: "#udiv_i128":
; ARM64EC: bl "#__udivti3"
; ARM64EC: ret
  %result = udiv i128 %x, %y
  ret i128 %result
}

define i128 @srem_i128(i128 %x, i128 %y) {
; WINDOWS-LABEL: srem_i128:
; WINDOWS-NOT: __modti3
; WINDOWS: ret
;
; ARM64EC-LABEL: "#srem_i128":
; ARM64EC: bl "#__modti3"
; ARM64EC: ret
  %result = srem i128 %x, %y
  ret i128 %result
}

define i128 @urem_i128(i128 %x, i128 %y) {
; WINDOWS-LABEL: urem_i128:
; WINDOWS-NOT: __umodti3
; WINDOWS: ret
;
; ARM64EC-LABEL: "#urem_i128":
; ARM64EC: bl "#__umodti3"
; ARM64EC: ret
  %result = urem i128 %x, %y
  ret i128 %result
}
