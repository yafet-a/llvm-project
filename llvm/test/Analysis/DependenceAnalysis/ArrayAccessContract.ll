; RUN: opt < %s -disable-output -passes="print<da>" 2>&1 | FileCheck %s

@common = global [400 x double] zeroinitializer
@pop = global [1000000 x double] zeroinitializer
@flat = global [200 x i32] zeroinitializer
@a = global [200 x double] zeroinitializer

; Distinct array views in one flattened allocation do not alias. The proof is
; based on their declared bases and complete constant extents, not the name or
; layout of @common.
define void @disjoint_subobjects() {
; CHECK-LABEL: 'Dependence Analysis' for function 'disjoint_subobjects':
; CHECK: Src: store double 0.000000e+00, ptr %a.gep, align 8 --> Dst: store double 1.000000e+00, ptr %b.gep, align 8
; CHECK-NEXT: da analyze - none!
entry:
  %a.base = getelementptr inbounds [400 x double], ptr @common, i64 0, i64 0
  %b.base = getelementptr inbounds [400 x double], ptr @common, i64 0, i64 200
  %a = call ptr @llvm.assume.chained.p0(ptr %a.base)
      [ "array.extents"(i64 10, i64 20) ]
  %b = call ptr @llvm.assume.chained.p0(ptr %b.base)
      [ "array.extents"(i64 10, i64 20) ]
  br label %outer
outer:
  %j = phi i64 [ 0, %entry ], [ %j.next, %outer.latch ]
  br label %inner
inner:
  %i = phi i64 [ 0, %outer ], [ %i.next, %inner ]
  %row = mul nuw nsw i64 %j, 10
  %offset = add nuw nsw i64 %row, %i
  %a.gep = getelementptr nusw nuw double, ptr %a, i64 %offset
  store double 0.0, ptr %a.gep
  %b.gep = getelementptr nusw nuw double, ptr %b, i64 %offset
  store double 1.0, ptr %b.gep
  %i.next = add nuw nsw i64 %i, 1
  %i.done = icmp eq i64 %i.next, 10
  br i1 %i.done, label %outer.latch, label %inner
outer.latch:
  %j.next = add nuw nsw i64 %j, 1
  %j.done = icmp eq i64 %j.next, 20
  br i1 %j.done, label %exit, label %outer
exit:
  ret void
}

; Overlapping views must remain MayAlias.
define void @overlapping_subobjects() {
; CHECK-LABEL: 'Dependence Analysis' for function 'overlapping_subobjects':
; CHECK: Src: store double 0.000000e+00, ptr %a.gep, align 8 --> Dst: store double 1.000000e+00, ptr %b.gep, align 8
; CHECK-NEXT: da analyze - output
entry:
  %a.base = getelementptr inbounds [400 x double], ptr @common, i64 0, i64 0
  %b.base = getelementptr inbounds [400 x double], ptr @common, i64 0, i64 100
  %a = call ptr @llvm.assume.chained.p0(ptr %a.base)
      [ "array.extents"(i64 10, i64 20) ]
  %b = call ptr @llvm.assume.chained.p0(ptr %b.base)
      [ "array.extents"(i64 10, i64 20) ]
  br label %outer
outer:
  %j = phi i64 [ 0, %entry ], [ %j.next, %outer.latch ]
  br label %inner
inner:
  %i = phi i64 [ 0, %outer ], [ %i.next, %inner ]
  %row = mul nuw nsw i64 %j, 10
  %offset = add nuw nsw i64 %row, %i
  %a.gep = getelementptr nusw nuw double, ptr %a, i64 %offset
  store double 0.0, ptr %a.gep
  %b.gep = getelementptr nusw nuw double, ptr %b, i64 %offset
  store double 1.0, ptr %b.gep
  %i.next = add nuw nsw i64 %i, 1
  %i.done = icmp eq i64 %i.next, 10
  br i1 %i.done, label %outer.latch, label %inner
outer.latch:
  %j.next = add nuw nsw i64 %j, 1
  %j.done = icmp eq i64 %j.next, 20
  br i1 %j.done, label %exit, label %outer
exit:
  ret void
}

; The physical dimensions are 1000 x 1000 even though each source coordinate
; is itself linearized with the runtime radix %ny.
define void @linearized_coordinates(i64 %ny) {
; CHECK-LABEL: 'Dependence Analysis' for function 'linearized_coordinates':
; CHECK: Src: store double 0.000000e+00, ptr %gep, align 8 --> Dst: store double 0.000000e+00, ptr %gep, align 8
; CHECK-NEXT: da analyze - output [* * 0 0]!
entry:
  %pop.c = call ptr @llvm.assume.chained.p0(ptr @pop)
      [ "array.extents"(i64 1000, i64 1000) ]
  %ny.pos = icmp sgt i64 %ny, 0
  br i1 %ny.pos, label %il, label %exit
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
  %gep = getelementptr nusw nuw double, ptr %pop.c, i64 %offset
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
  br i1 %il.done, label %exit, label %il
exit:
  ret void
}

; In-range coordinates do not make i+j injective.
define void @noninjective_i_plus_j() {
; CHECK-LABEL: 'Dependence Analysis' for function 'noninjective_i_plus_j':
; CHECK: Src: store i32 0, ptr %gep, align 4 --> Dst: store i32 0, ptr %gep, align 4
; CHECK-NEXT: da analyze - output [* *]!
entry:
  %flat.c = call ptr @llvm.assume.chained.p0(ptr @flat)
      [ "array.extents"(i64 20) ]
  br label %outer
outer:
  %i = phi i64 [ 0, %entry ], [ %i.next, %outer.latch ]
  br label %inner
inner:
  %j = phi i64 [ 0, %outer ], [ %j.next, %inner ]
  %offset = add nuw nsw i64 %i, %j
  %gep = getelementptr nusw nuw i32, ptr %flat.c, i64 %offset
  store i32 0, ptr %gep
  %j.next = add nuw nsw i64 %j, 1
  %j.done = icmp eq i64 %j.next, 10
  br i1 %j.done, label %outer.latch, label %inner
outer.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.done = icmp eq i64 %i.next, 10
  br i1 %i.done, label %exit, label %outer
exit:
  ret void
}

; A start loaded in the outer loop varies across outer iterations just like i
; does, so a unit-stride inner subscript is still not injective.
define void @noninjective_loaded_start(ptr %idx) {
; CHECK-LABEL: 'Dependence Analysis' for function 'noninjective_loaded_start':
; CHECK: Src: store i32 0, ptr %gep, align 4 --> Dst: store i32 0, ptr %gep, align 4
; CHECK-NEXT: da analyze - output [* *]!
entry:
  %flat.c = call ptr @llvm.assume.chained.p0(ptr @flat)
      [ "array.extents"(i64 20) ]
  br label %outer
outer:
  %i = phi i64 [ 0, %entry ], [ %i.next, %outer.latch ]
  %idx.gep = getelementptr inbounds i64, ptr %idx, i64 %i
  %start = load i64, ptr %idx.gep
  br label %inner
inner:
  %j = phi i64 [ 0, %outer ], [ %j.next, %inner ]
  %offset = add nuw nsw i64 %start, %j
  %gep = getelementptr nusw nuw i32, ptr %flat.c, i64 %offset
  store i32 0, ptr %gep
  %j.next = add nuw nsw i64 %j, 1
  %j.done = icmp eq i64 %j.next, 10
  br i1 %j.done, label %outer.latch, label %inner
outer.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.done = icmp eq i64 %i.next, 10
  br i1 %i.done, label %exit, label %outer
exit:
  ret void
}

; Two consecutive iterations select the same element.
define void @noninjective_i_div_2() {
; CHECK-LABEL: 'Dependence Analysis' for function 'noninjective_i_div_2':
; CHECK: Src: store i32 0, ptr %gep, align 4 --> Dst: store i32 0, ptr %gep, align 4
; CHECK-NEXT: da analyze - output
entry:
  %flat.c = call ptr @llvm.assume.chained.p0(ptr @flat)
      [ "array.extents"(i64 20) ]
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %offset = udiv i64 %i, 2
  %gep = getelementptr nusw nuw i32, ptr %flat.c, i64 %offset
  store i32 0, ptr %gep
  %i.next = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %i.next, 20
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

; The row stride is smaller than the declared inner extent, so adjacent rows
; overlap even though every stated source coordinate is in range.
define void @mismatched_stride() {
; CHECK-LABEL: 'Dependence Analysis' for function 'mismatched_stride':
; CHECK: Src: store i32 0, ptr %gep, align 4 --> Dst: store i32 0, ptr %gep, align 4
; CHECK-NEXT: da analyze - output
entry:
  %flat.c = call ptr @llvm.assume.chained.p0(ptr @flat)
      [ "array.extents"(i64 20, i64 10) ]
  br label %outer
outer:
  %i = phi i64 [ 0, %entry ], [ %i.next, %outer.latch ]
  br label %inner
inner:
  %j = phi i64 [ 0, %outer ], [ %j.next, %inner ]
  %row = mul nuw nsw i64 %i, 19
  %offset = add nuw nsw i64 %row, %j
  %gep = getelementptr nusw nuw i32, ptr %flat.c, i64 %offset
  store i32 0, ptr %gep
  %j.next = add nuw nsw i64 %j, 1
  %j.done = icmp eq i64 %j.next, 20
  br i1 %j.done, label %outer.latch, label %inner
outer.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.done = icmp eq i64 %i.next, 10
  br i1 %i.done, label %exit, label %outer
exit:
  ret void
}

; SCEV reduces a COMMON-block subobject to the enclosing allocation. The shape
; declared for that subobject must still apply.
define void @common_subobject(i64 %outer.end, i64 %inner.end) {
; CHECK-LABEL: 'Dependence Analysis' for function 'common_subobject':
; CHECK: Src: store double 0.000000e+00, ptr %gep, align 8 --> Dst: store double 0.000000e+00, ptr %gep, align 8
; CHECK-NEXT: da analyze - none!
entry:
  %array = getelementptr [400 x double], ptr @common, i64 0, i64 200
  %array.c = call ptr @llvm.assume.chained.p0(ptr %array)
      [ "array.extents"(i64 10, i64 20) ]
  br label %outer
outer:
  %j = phi i64 [ 0, %entry ], [ %j.next, %outer.latch ]
  br label %inner
inner:
  %i = phi i64 [ 0, %outer ], [ %i.next, %inner ]
  %row = mul nsw i64 %j, 10
  %offset = add nsw i64 %row, %i
  %gep = getelementptr nusw nuw double, ptr %array.c, i64 %offset
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

; Descriptor strides must agree with the contiguous mixed-radix shape before
; the extents can validate delinearization.
define void @noncontiguous_strides(i64 %outer.end, i64 %inner.end) {
; CHECK-LABEL: 'Dependence Analysis' for function 'noncontiguous_strides':
; CHECK: Src: store double 0.000000e+00, ptr %gep, align 8 --> Dst: store double 0.000000e+00, ptr %gep, align 8
; CHECK-NEXT: da analyze - output [* *]!
entry:
  %a.c = call ptr @llvm.assume.chained.p0(ptr @a)
      [ "array.extents"(i64 10, i64 20), "array.strides"(i64 8, i64 88) ]
  br label %outer
outer:
  %j = phi i64 [ 0, %entry ], [ %j.next, %outer.latch ]
  br label %inner
inner:
  %i = phi i64 [ 0, %outer ], [ %i.next, %inner ]
  %row = mul nsw i64 %j, 10
  %offset = add nsw i64 %row, %i
  %gep = getelementptr double, ptr %a.c, i64 %offset
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

declare ptr @llvm.assume.chained.p0(ptr)
