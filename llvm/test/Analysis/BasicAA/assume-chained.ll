; RUN: opt < %s -aa-pipeline=basic-aa -passes=aa-eval -print-all-alias-modref-info -disable-output 2>&1 | FileCheck %s

; llvm.assume.chained returns its operand, so accesses through its result
; alias exactly as accesses through the operand do, and a noalias argument
; stays distinct from other objects.

; CHECK-LABEL: Function: same_base
; CHECK: MustAlias: double* %p.base, double* %p.chained
; CHECK: NoAlias: double* %p.chained, double* %q
define void @same_base(ptr %a, i64 %n) {
  %c = call ptr @llvm.assume.chained.p0(ptr %a)
      [ "array.extents"(i64 %n, i64 20) ]
  %p.chained = getelementptr inbounds double, ptr %c, i64 3
  %p.base = getelementptr inbounds double, ptr %a, i64 3
  %q = getelementptr inbounds double, ptr %a, i64 4
  load double, ptr %p.chained
  load double, ptr %p.base
  load double, ptr %q
  ret void
}

; CHECK-LABEL: Function: noalias_args
; CHECK: NoAlias: double* %b, double* %c
define void @noalias_args(ptr noalias %a, ptr noalias %b) {
  %c = call ptr @llvm.assume.chained.p0(ptr %a)
      [ "array.extents"(i64 10, i64 20) ]
  load double, ptr %c
  load double, ptr %b
  ret void
}

; The call reads and writes no memory despite its operand bundles.
; CHECK-LABEL: Function: no_mod_ref
; CHECK: NoModRef:  Ptr: double* %b <->  %c = call ptr @llvm.assume.chained.p0(ptr %a) [ "array.extents"(i64 10, i64 20) ]
define void @no_mod_ref(ptr %a, ptr %b) {
  %c = call ptr @llvm.assume.chained.p0(ptr %a)
      [ "array.extents"(i64 10, i64 20) ]
  load double, ptr %c
  load double, ptr %b
  ret void
}
