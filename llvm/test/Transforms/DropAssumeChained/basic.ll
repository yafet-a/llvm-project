; RUN: opt -passes=drop-assume-chained -S < %s | FileCheck %s
; RUN: opt -passes='default<O3>' -print-pipeline-passes -disable-output < %s \
; RUN:   | FileCheck %s --check-prefix=PIPELINE

; Every llvm.assume.chained call is erased and its users are rewritten to use
; the original pointer.

define double @drop(ptr %a, i64 %n, i64 %m, i64 %i) {
; CHECK-LABEL: define double @drop(
; CHECK-NOT:     llvm.assume.chained
; CHECK:         %p = getelementptr inbounds double, ptr %a, i64 %i
; CHECK-NEXT:    %q = getelementptr inbounds double, ptr %a, i64 %n
; CHECK-NOT:     llvm.assume.chained
; CHECK:         ret double
entry:
  %c = call ptr @llvm.assume.chained.p0(ptr %a)
      [ "array.extents"(i64 %n, i64 %m), "array.strides"(i64 8, i64 %n) ]
  %p = getelementptr inbounds double, ptr %c, i64 %i
  %c2 = call ptr @llvm.assume.chained.p0(ptr %a)
      [ "array.extents"(i64 %m) ]
  %q = getelementptr inbounds double, ptr %c2, i64 %n
  %x = load double, ptr %p
  %y = load double, ptr %q
  %s = fadd double %x, %y
  ret double %s
}

; The facts are needed only by loop interchange, so the calls are dropped
; right after it.
; PIPELINE: loop-interchange)
; PIPELINE-SAME: ,drop-assume-chained,

declare ptr @llvm.assume.chained.p0(ptr)
