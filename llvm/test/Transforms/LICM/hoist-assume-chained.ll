; RUN: opt -passes=licm -S < %s | FileCheck %s

; llvm.assume.chained has no side effects despite its operand bundles, so a
; call with loop-invariant operands is hoisted out of the loop, and it does not
; stop the loop-invariant load from being hoisted either.

define void @hoist(ptr noalias %a, ptr noalias %n.ref, i64 %m) {
; CHECK-LABEL: define void @hoist(
; CHECK:       entry:
; CHECK-NEXT:    %n = load i64, ptr %n.ref
; CHECK-NEXT:    %c = call ptr @llvm.assume.chained.p0(ptr %a) [ "array.extents"(i64 %n, i64 %m) ]
; CHECK:       loop:
; CHECK-NOT:     llvm.assume.chained
; CHECK:         store double 0.000000e+00
entry:
  br label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %n = load i64, ptr %n.ref
  %c = call ptr @llvm.assume.chained.p0(ptr %a)
      [ "array.extents"(i64 %n, i64 %m) ]
  %p = getelementptr inbounds double, ptr %c, i64 %i
  store double 0.0, ptr %p
  %i.next = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %i.next, %m
  br i1 %done, label %exit, label %loop

exit:
  ret void
}
