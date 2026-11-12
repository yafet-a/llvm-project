; RUN: opt < %s -disable-output -passes='inline,print<da>' 2>&1 | FileCheck %s

; The side-band access operand is cloned with the GEP during inlining, so the
; caller retains the same exact access-to-contract association.

define internal void @kernel(ptr %base, i64 %outer.end,
                             i64 %inner.end) alwaysinline {
entry:
  br label %outer

outer:
  %j = phi i64 [ 0, %entry ], [ %j.next, %outer.latch ]
  br label %inner

inner:
  %i = phi i64 [ 0, %outer ], [ %i.next, %inner ]
  %row = mul nsw i64 %j, 10
  %offset = add nsw i64 %row, %i
  %gep = getelementptr nusw nuw double, ptr %base, i64 %offset
  call void @llvm.assume(i1 true) [ "array.extents"(ptr %gep, ptr %base, i64 10, i64 20) ]
  store double 0.0, ptr %gep
  %i.next = add nuw nsw i64 %i, 1
  %i.done = icmp eq i64 %i.next, %inner.end
  br i1 %i.done, label %outer.latch, label %inner

outer.latch:
  %j.next = add nuw nsw i64 %j, 1
  %j.done = icmp eq i64 %j.next, %outer.end
  br i1 %j.done, label %return, label %outer

return:
  ret void
}

define void @caller(ptr %base, i64 %outer.end, i64 %inner.end) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'caller':
; CHECK: Src: store double 0.000000e+00, ptr %gep.i, align 8 --> Dst: store double 0.000000e+00, ptr %gep.i, align 8
; CHECK-NEXT: da analyze - none!
entry:
  call void @kernel(ptr %base, i64 %outer.end, i64 %inner.end)
  ret void
}

declare void @llvm.assume(i1 noundef)
