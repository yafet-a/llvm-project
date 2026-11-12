; RUN: opt < %s -disable-output -passes="print<da>" 2>&1 | FileCheck %s

@pop = global [1000000 x double] zeroinitializer

; The physical dimensions are 1000 x 1000 even though each source coordinate
; is itself linearized with the runtime radix %ny. Recovering the physical
; shape separates the two inner loops without claiming that the outer
; expressions are injective.
define void @linearized_coordinates(i64 %ny) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'linearized_coordinates':
; CHECK: Src: store double 0.000000e+00, ptr %gep, align 8 --> Dst: store double 0.000000e+00, ptr %gep, align 8
; CHECK-NEXT: da analyze - output [* * 0 0]!
entry:
  %ny.pos = icmp sgt i64 %ny, 0
  br i1 %ny.pos, label %il, label %return
il:
  %il.iv = phi i64 [ 0, %entry ], [ %il.next, %il.latch ]
  br label %jl
jl:
  %jl.iv = phi i64 [ 0, %il ], [ %jl.next, %jl.latch ]
  br label %i
i:
  %i.iv = phi i64 [ 0, %jl ], [ %i.next, %i.latch ]
  br label %j
j:
  %j.iv = phi i64 [ 0, %i ], [ %j.next, %j ]
  %y.mul = mul nuw nsw i64 %il.iv, %ny
  %y = add nuw nsw i64 %y.mul, %jl.iv
  %x.mul = mul nuw nsw i64 %i.iv, %ny
  %x = add nuw nsw i64 %x.mul, %j.iv
  %row = mul nuw nsw i64 %y, 1000
  %offset = add nuw nsw i64 %row, %x
  %gep = getelementptr nusw nuw double, ptr @pop, i64 %offset
  call void @llvm.assume(i1 true) [ "array.extents"(ptr %gep, ptr @pop, i64 1000, i64 1000) ]
  store double 0.0, ptr %gep
  %j.next = add nuw nsw i64 %j.iv, 1
  %j.done = icmp eq i64 %j.next, %ny
  br i1 %j.done, label %i.latch, label %j
i.latch:
  %i.next = add nuw nsw i64 %i.iv, 1
  %i.done = icmp eq i64 %i.next, %ny
  br i1 %i.done, label %jl.latch, label %i
jl.latch:
  %jl.next = add nuw nsw i64 %jl.iv, 1
  %jl.done = icmp eq i64 %jl.next, %ny
  br i1 %jl.done, label %il.latch, label %jl
il.latch:
  %il.next = add nuw nsw i64 %il.iv, 1
  %il.done = icmp eq i64 %il.next, %ny
  br i1 %il.done, label %return, label %il
return:
  ret void
}

declare void @llvm.assume(i1 noundef)
