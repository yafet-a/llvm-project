; RUN: opt < %s -disable-output -passes='print<da>' \
; RUN:   -da-enable-dependence-test=all 2>&1 | FileCheck %s

@a = global [1000 x double] zeroinitializer, !array.dims !0

; The subscript n*i+j is injective when j has exactly n iterations, n is
; positive, both recurrences do not wrap, and j advances by one.
define void @mixed_radix(i64 %n) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'mixed_radix':
; CHECK:       Src: store double 0.000000e+00, ptr %gep, align 8 --> Dst: store double 0.000000e+00, ptr %gep, align 8
; CHECK-NEXT:    da analyze - none!
entry:
  %n.positive = icmp sgt i64 %n, 0
  call void @llvm.assume(i1 %n.positive)
  br label %outer

outer:
  %i = phi i64 [ 0, %entry ], [ %i.next, %outer.latch ]
  br label %inner

inner:
  %j = phi i64 [ 0, %outer ], [ %j.next, %inner ]
  %mul = mul nsw i64 %n, %i
  %subscript = add nsw i64 %mul, %j
  %inrange = icmp ult i64 %subscript, 1000
  call void @llvm.assume(i1 %inrange)
  %gep = getelementptr double, ptr @a, i64 %subscript
  store double 0.0, ptr %gep
  %j.next = add nuw nsw i64 %j, 1
  %j.exit = icmp eq i64 %j.next, %n
  br i1 %j.exit, label %outer.latch, label %inner

outer.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.exit = icmp eq i64 %i.next, 10
  br i1 %i.exit, label %return, label %outer

return:
  ret void
}

; Signed assumptions are also sufficient to validate the recovered subscript.
define void @mixed_radix_signed_range(i64 %n) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'mixed_radix_signed_range':
; CHECK:       Src: store double 0.000000e+00, ptr %gep, align 8 --> Dst: store double 0.000000e+00, ptr %gep, align 8
; CHECK-NEXT:    da analyze - none!
entry:
  %n.positive = icmp sgt i64 %n, 0
  call void @llvm.assume(i1 %n.positive)
  br label %outer

outer:
  %i = phi i64 [ 0, %entry ], [ %i.next, %outer.latch ]
  br label %inner

inner:
  %j = phi i64 [ 0, %outer ], [ %j.next, %inner ]
  %mul = mul nsw i64 %n, %i
  %subscript = add nsw i64 %mul, %j
  %lower = icmp sge i64 %subscript, 0
  %upper = icmp slt i64 %subscript, 1000
  call void @llvm.assume(i1 %lower)
  call void @llvm.assume(i1 %upper)
  %gep = getelementptr double, ptr @a, i64 %subscript
  store double 0.0, ptr %gep
  %j.next = add nuw nsw i64 %j, 1
  %j.exit = icmp eq i64 %j.next, %n
  br i1 %j.exit, label %outer.latch, label %inner

outer.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.exit = icmp eq i64 %i.next, 10
  br i1 %i.exit, label %return, label %outer

return:
  ret void
}

; Without a positive radix, the signed mixed-radix proof is not available.
define void @mixed_radix_without_positive_fact(i64 %n) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'mixed_radix_without_positive_fact':
; CHECK:       Src: store double 0.000000e+00, ptr %gep, align 8 --> Dst: store double 0.000000e+00, ptr %gep, align 8
; CHECK-NEXT:    da analyze - output [* *]!
entry:
  br label %outer

outer:
  %i = phi i64 [ 0, %entry ], [ %i.next, %outer.latch ]
  br label %inner

inner:
  %j = phi i64 [ 0, %outer ], [ %j.next, %inner ]
  %mul = mul nsw i64 %n, %i
  %subscript = add nsw i64 %mul, %j
  %inrange = icmp ult i64 %subscript, 1000
  call void @llvm.assume(i1 %inrange)
  %gep = getelementptr double, ptr @a, i64 %subscript
  store double 0.0, ptr %gep
  %j.next = add nuw nsw i64 %j, 1
  %j.exit = icmp eq i64 %j.next, %n
  br i1 %j.exit, label %outer.latch, label %inner

outer.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.exit = icmp eq i64 %i.next, 10
  br i1 %i.exit, label %return, label %outer

return:
  ret void
}

; A non-unit inner recurrence is outside the proof.
define void @mixed_radix_non_unit_inner(i64 %n) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'mixed_radix_non_unit_inner':
; CHECK:       Src: store double 0.000000e+00, ptr %gep, align 8 --> Dst: store double 0.000000e+00, ptr %gep, align 8
; CHECK-NEXT:    da analyze - output [* *]!
entry:
  %n.positive = icmp sgt i64 %n, 0
  call void @llvm.assume(i1 %n.positive)
  br label %outer

outer:
  %i = phi i64 [ 0, %entry ], [ %i.next, %outer.latch ]
  br label %inner

inner:
  %j = phi i64 [ 0, %outer ], [ %j.next, %inner ]
  %mul = mul nsw i64 %n, %i
  %twice.j = mul nsw i64 %j, 2
  %subscript = add nsw i64 %mul, %twice.j
  %inrange = icmp ult i64 %subscript, 1000
  call void @llvm.assume(i1 %inrange)
  %gep = getelementptr double, ptr @a, i64 %subscript
  store double 0.0, ptr %gep
  %j.next = add nuw nsw i64 %j, 1
  %j.exit = icmp eq i64 %j.next, %n
  br i1 %j.exit, label %outer.latch, label %inner

outer.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.exit = icmp eq i64 %i.next, 10
  br i1 %i.exit, label %return, label %outer

return:
  ret void
}

; The arithmetic no-wrap facts are required even when explicit range
; assumptions happen to validate the recovered subscript.
define void @mixed_radix_without_nsw(i64 %n) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'mixed_radix_without_nsw':
; CHECK:       Src: store double 0.000000e+00, ptr %gep, align 8 --> Dst: store double 0.000000e+00, ptr %gep, align 8
; CHECK-NEXT:    da analyze - output [* *]!
entry:
  %n.positive = icmp sgt i64 %n, 0
  call void @llvm.assume(i1 %n.positive)
  br label %outer

outer:
  %i = phi i64 [ 0, %entry ], [ %i.next, %outer.latch ]
  br label %inner

inner:
  %j = phi i64 [ 0, %outer ], [ %j.next, %inner ]
  %mul = mul i64 %n, %i
  %subscript = add i64 %mul, %j
  %inrange = icmp ult i64 %subscript, 1000
  call void @llvm.assume(i1 %inrange)
  %gep = getelementptr double, ptr @a, i64 %subscript
  store double 0.0, ptr %gep
  %j.next = add nuw nsw i64 %j, 1
  %j.exit = icmp eq i64 %j.next, %n
  br i1 %j.exit, label %outer.latch, label %inner

outer.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.exit = icmp eq i64 %i.next, 10
  br i1 %i.exit, label %return, label %outer

return:
  ret void
}

; A radix that varies in an enclosing loop is not one fixed mixed-radix
; encoding across the analyzed iteration space.
define void @mixed_radix_loop_variant_radix() {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'mixed_radix_loop_variant_radix':
; CHECK:       Src: store double 0.000000e+00, ptr %gep, align 8 --> Dst: store double 0.000000e+00, ptr %gep, align 8
; CHECK-NEXT:    da analyze - output [* * *]!
entry:
  br label %parent

parent:
  %p = phi i64 [ 0, %entry ], [ %p.next, %parent.latch ]
  %radix = add nuw nsw i64 %p, 1
  br label %outer

outer:
  %i = phi i64 [ 0, %parent ], [ %i.next, %outer.latch ]
  br label %inner

inner:
  %j = phi i64 [ 0, %outer ], [ %j.next, %inner ]
  %mul = mul nsw i64 %radix, %i
  %subscript = add nsw i64 %mul, %j
  %inrange = icmp ult i64 %subscript, 1000
  call void @llvm.assume(i1 %inrange)
  %gep = getelementptr double, ptr @a, i64 %subscript
  store double 0.0, ptr %gep
  %j.next = add nuw nsw i64 %j, 1
  %j.exit = icmp eq i64 %j.next, %radix
  br i1 %j.exit, label %outer.latch, label %inner

outer.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.exit = icmp eq i64 %i.next, 4
  br i1 %i.exit, label %parent.latch, label %outer

parent.latch:
  %p.next = add nuw nsw i64 %p, 1
  %p.exit = icmp eq i64 %p.next, 4
  br i1 %p.exit, label %return, label %parent

return:
  ret void
}

declare void @llvm.assume(i1 noundef)

!0 = !{i64 1000}
