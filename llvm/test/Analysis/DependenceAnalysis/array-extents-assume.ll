; RUN: opt < %s -disable-output -passes='print<da>' 2>&1 | FileCheck %s

@a = global [200 x double] zeroinitializer
@b = global [200 x double] zeroinitializer
@common = global [400 x double] zeroinitializer

; A dominating carrier supplies the complete shape and the subscript range
; guarantee, which validates the recovered mixed-radix access.
define void @dominating_carrier(i64 %outer.end, i64 %inner.end) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'dominating_carrier':
; CHECK: Src: store double 0.000000e+00, ptr %gep, align 8 --> Dst: store double 0.000000e+00, ptr %gep, align 8
; CHECK-NEXT: da analyze - none!
entry:
  br label %outer
outer:
  %j = phi i64 [ 0, %entry ], [ %j.next, %outer.latch ]
  br label %inner
inner:
  %i = phi i64 [ 0, %outer ], [ %i.next, %inner ]
  %row = mul nsw i64 %j, 10
  %offset = add nsw i64 %row, %i
  %gep = getelementptr nusw nuw double, ptr @a, i64 %offset
  call void @llvm.assume(i1 true) [ "array.extents"(ptr %gep, ptr @a, i64 10, i64 20), "array.strides"(ptr %gep, i64 8, i64 80) ]
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

; SCEV reduces a COMMON-block subobject to the enclosing allocation. The
; access-scoped lookup must still find the shape declared for that subobject.
define void @common_subobject(i64 %outer.end, i64 %inner.end) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'common_subobject':
; CHECK: Src: store double 0.000000e+00, ptr %gep, align 8 --> Dst: store double 0.000000e+00, ptr %gep, align 8
; CHECK-NEXT: da analyze - none!
entry:
  %array = getelementptr [400 x double], ptr @common, i64 0, i64 200
  br label %outer
outer:
  %j = phi i64 [ 0, %entry ], [ %j.next, %outer.latch ]
  br label %inner
inner:
  %i = phi i64 [ 0, %outer ], [ %i.next, %inner ]
  %row = mul nsw i64 %j, 10
  %offset = add nsw i64 %row, %i
  %gep = getelementptr nusw nuw double, ptr %array, i64 %offset
  call void @llvm.assume(i1 true) [ "array.extents"(ptr %gep, ptr %array, i64 10, i64 20) ]
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
; the extent contract can validate delinearization.
define void @noncontiguous_strides(i64 %outer.end, i64 %inner.end) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'noncontiguous_strides':
; CHECK: Src: store double 0.000000e+00, ptr %gep, align 8 --> Dst: store double 0.000000e+00, ptr %gep, align 8
; CHECK-NEXT: da analyze - output [* *]!
entry:
  br label %outer
outer:
  %j = phi i64 [ 0, %entry ], [ %j.next, %outer.latch ]
  br label %inner
inner:
  %i = phi i64 [ 0, %outer ], [ %i.next, %inner ]
  %row = mul nsw i64 %j, 10
  %offset = add nsw i64 %row, %i
  %gep = getelementptr double, ptr @a, i64 %offset
  call void @llvm.assume(i1 true) [ "array.extents"(ptr %gep, ptr @a, i64 10, i64 20), "array.strides"(ptr %gep, i64 8, i64 88) ]
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

; The range guarantee validates delinearization without GEP no-wrap flags,
; which earlier passes routinely drop, and without proving the runtime extents
; positive or their product representable: an in-range access to a validly
; allocated array stays inside the object, so the store collides with itself
; only in the same iteration.
define void @runtime_extent_plain_gep(ptr noalias %base, i64 %m, i64 %n) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'runtime_extent_plain_gep':
; CHECK: Src: store double 0.000000e+00, ptr %p, align 8 --> Dst: store double 0.000000e+00, ptr %p, align 8
; CHECK-NEXT: da analyze - none!
entry:
  %ext = call i64 @llvm.smax.i64(i64 %m, i64 0)
  br label %outer
outer:
  %i = phi i64 [ 1, %entry ], [ %i.next, %outer.latch ]
  %im1 = add nsw i64 %i, -1
  %off = mul nsw i64 %im1, %ext
  %row = getelementptr [8 x i8], ptr %base, i64 %off
  br label %inner
inner:
  %j = phi i64 [ 1, %outer ], [ %j.next, %inner ]
  %jm1 = add nsw i64 %j, -1
  %p = getelementptr [8 x i8], ptr %row, i64 %jm1
  call void @llvm.assume(i1 true) [ "array.extents"(ptr %p, ptr %base, i64 %ext, i64 %n) ]
  store double 0.0, ptr %p, align 8
  %j.next = add nuw nsw i64 %j, 1
  %j.done = icmp eq i64 %j, %m
  br i1 %j.done, label %outer.latch, label %inner
outer.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.done = icmp eq i64 %i, %n
  br i1 %i.done, label %return, label %outer
return:
  ret void
}

; Runtime extents may validate a parametric shape when SCEV proves that the
; recovered inner size is the same SSA value.
define void @runtime_extent(ptr noalias %base, i64 %m, i64 %n) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'runtime_extent':
; CHECK: Src: %v = load double, ptr %p, align 8 --> Dst: %v = load double, ptr %p, align 8
; CHECK-NEXT: da analyze - none!
; CHECK: Src: %v = load double, ptr %p, align 8 --> Dst: store double %w, ptr %p, align 8
; CHECK-NEXT: da analyze - anti [0 0|<]!
entry:
  %ext = call i64 @llvm.smax.i64(i64 %m, i64 0)
  br label %outer
outer:
  %i = phi i64 [ 1, %entry ], [ %i.next, %outer.latch ]
  %im1 = add nsw i64 %i, -1
  %off = mul nuw nsw i64 %im1, %ext
  %row = getelementptr nusw [8 x i8], ptr %base, i64 %off
  br label %inner
inner:
  %j = phi i64 [ 1, %outer ], [ %j.next, %inner ]
  %jm1 = add nsw i64 %j, -1
  %p = getelementptr nusw [8 x i8], ptr %row, i64 %jm1
  call void @llvm.assume(i1 true) [ "array.extents"(ptr %p, ptr %base, i64 %ext, i64 %n) ]
  %v = load double, ptr %p, align 8
  %w = fmul double %v, 2.0
  store double %w, ptr %p, align 8
  %j.next = add nuw nsw i64 %j, 1
  %j.done = icmp eq i64 %j, %m
  br i1 %j.done, label %outer.latch, label %inner
outer.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.done = icmp eq i64 %i, %n
  br i1 %i.done, label %return, label %outer
return:
  ret void
}

; In-range subscripts do not make a mismatched linearization injective.
; Iterations (i, 19) and (i + 1, 0) alias because the row stride is 19 while
; the stated inner extent is 20.
define void @mismatched_linearization(ptr %base) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'mismatched_linearization':
; CHECK: Src: store i32 0, ptr %gep, align 4 --> Dst: store i32 0, ptr %gep, align 4
; CHECK-NEXT: da analyze - output [* *]!
entry:
  br label %outer
outer:
  %i = phi i64 [ 0, %entry ], [ %i.next, %outer.latch ]
  br label %inner
inner:
  %j = phi i64 [ 0, %outer ], [ %j.next, %inner ]
  %row = mul nuw nsw i64 %i, 19
  %offset = add nuw nsw i64 %row, %j
  %gep = getelementptr i32, ptr %base, i64 %offset
  call void @llvm.assume(i1 true) [ "array.extents"(ptr %gep, ptr %base, i64 20, i64 10) ]
  store i32 0, ptr %gep
  %j.next = add nuw nsw i64 %j, 1
  %j.done = icmp eq i64 %j.next, 20
  br i1 %j.done, label %outer.latch, label %inner
outer.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.done = icmp eq i64 %i.next, 10
  br i1 %i.done, label %return, label %outer
return:
  ret void
}

; A carrier for another base must not validate this access.
define void @different_base(i64 %outer.end, i64 %inner.end) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'different_base':
; CHECK: Src: store double 0.000000e+00, ptr %gep, align 8 --> Dst: store double 0.000000e+00, ptr %gep, align 8
; CHECK-NEXT: da analyze - output [* *]!
entry:
  br label %outer
outer:
  %j = phi i64 [ 0, %entry ], [ %j.next, %outer.latch ]
  br label %inner
inner:
  %i = phi i64 [ 0, %outer ], [ %i.next, %inner ]
  %row = mul nsw i64 %j, 10
  %offset = add nsw i64 %row, %i
  %gep = getelementptr double, ptr @a, i64 %offset
  call void @llvm.assume(i1 true) [ "array.extents"(ptr %gep, ptr @b, i64 10, i64 20) ]
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

; A transparent all-zero GEP does not change the addressed element, so the
; exact-access contract remains applicable.
define void @transparent_access_cast(i64 %outer.end, i64 %inner.end) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'transparent_access_cast':
; CHECK: Src: store double 0.000000e+00, ptr %alias, align 8 --> Dst: store double 0.000000e+00, ptr %alias, align 8
; CHECK-NEXT: da analyze - none!
entry:
  br label %outer
outer:
  %j = phi i64 [ 0, %entry ], [ %j.next, %outer.latch ]
  br label %inner
inner:
  %i = phi i64 [ 0, %outer ], [ %i.next, %inner ]
  %row = mul nsw i64 %j, 10
  %offset = add nsw i64 %row, %i
  %gep = getelementptr nusw nuw double, ptr @a, i64 %offset
  %alias = getelementptr nusw nuw i8, ptr %gep, i64 0
  call void @llvm.assume(i1 true) [ "array.extents"(ptr %gep, ptr @a, i64 10, i64 20) ]
  store double 0.0, ptr %alias
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

; A non-zero GEP is a different access. It must not inherit the source
; subscript guarantee merely because it is derived from the scoped pointer.
define void @derived_access_does_not_inherit(i64 %outer.end, i64 %inner.end) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'derived_access_does_not_inherit':
; CHECK: Src: store double 0.000000e+00, ptr %derived, align 8 --> Dst: store double 0.000000e+00, ptr %derived, align 8
; CHECK-NEXT: da analyze - output [* *]!
entry:
  br label %outer
outer:
  %j = phi i64 [ 0, %entry ], [ %j.next, %outer.latch ]
  br label %inner
inner:
  %i = phi i64 [ 0, %outer ], [ %i.next, %inner ]
  %row = mul nsw i64 %j, 10
  %offset = add nsw i64 %row, %i
  %gep = getelementptr nusw nuw double, ptr @a, i64 %offset
  %derived = getelementptr nusw nuw double, ptr %gep, i64 1
  call void @llvm.assume(i1 true) [ "array.extents"(ptr %gep, ptr @a, i64 10, i64 20) ]
  store double 0.0, ptr %derived
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

; Two COMMON-block subobjects may have different contracts. Access-first
; lookup keeps the declarations separate even though both reduce to @common.
define void @distinct_common_subobjects(i64 %outer.end, i64 %inner.end) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'distinct_common_subobjects':
; CHECK: Src: store double 0.000000e+00, ptr %a.gep, align 8 --> Dst: store double 0.000000e+00, ptr %a.gep, align 8
; CHECK-NEXT: da analyze - none!
; CHECK: Src: store double 0.000000e+00, ptr %a.gep, align 8 --> Dst: store double 1.000000e+00, ptr %b.gep, align 8
; CHECK-NEXT: da analyze - none!
; CHECK: Src: store double 1.000000e+00, ptr %b.gep, align 8 --> Dst: store double 1.000000e+00, ptr %b.gep, align 8
; CHECK-NEXT: da analyze - none!
entry:
  %a.base = getelementptr inbounds [400 x double], ptr @common, i64 0, i64 0
  %b.base = getelementptr inbounds [400 x double], ptr @common, i64 0, i64 200
  br label %outer
outer:
  %j = phi i64 [ 0, %entry ], [ %j.next, %outer.latch ]
  br label %inner
inner:
  %i = phi i64 [ 0, %outer ], [ %i.next, %inner ]
  %a.row = mul nsw i64 %j, 10
  %a.offset = add nsw i64 %a.row, %i
  %a.gep = getelementptr nusw nuw double, ptr %a.base, i64 %a.offset
  call void @llvm.assume(i1 true) [ "array.extents"(ptr %a.gep, ptr %a.base, i64 10, i64 20) ]
  store double 0.0, ptr %a.gep
  %b.row = mul nsw i64 %j, 5
  %b.offset = add nsw i64 %b.row, %i
  %b.gep = getelementptr nusw nuw double, ptr %b.base, i64 %b.offset
  call void @llvm.assume(i1 true) [ "array.extents"(ptr %b.gep, ptr %b.base, i64 5, i64 40) ]
  store double 1.0, ptr %b.gep
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

; Access-scoped contracts must not disambiguate overlapping COMMON subobjects.
define void @overlapping_common_subobjects(i64 %outer.end, i64 %inner.end) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'overlapping_common_subobjects':
; CHECK: Src: store double 0.000000e+00, ptr %a.gep, align 8 --> Dst: store double 1.000000e+00, ptr %b.gep, align 8
; CHECK-NEXT: da analyze - output
entry:
  %a.base = getelementptr inbounds [400 x double], ptr @common, i64 0, i64 0
  %b.base = getelementptr inbounds [400 x double], ptr @common, i64 0, i64 100
  br label %outer
outer:
  %j = phi i64 [ 0, %entry ], [ %j.next, %outer.latch ]
  br label %inner
inner:
  %i = phi i64 [ 0, %outer ], [ %i.next, %inner ]
  %row = mul nsw i64 %j, 10
  %offset = add nsw i64 %row, %i
  %a.gep = getelementptr nusw nuw double, ptr %a.base, i64 %offset
  call void @llvm.assume(i1 true) [ "array.extents"(ptr %a.gep, ptr %a.base, i64 10, i64 20) ]
  store double 0.0, ptr %a.gep
  %b.gep = getelementptr nusw nuw double, ptr %b.base, i64 %offset
  call void @llvm.assume(i1 true) [ "array.extents"(ptr %b.gep, ptr %b.base, i64 10, i64 20) ]
  store double 1.0, ptr %b.gep
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

; Conflicting declarations for one exact access invalidate the contract.
define void @conflicting_access_contracts(i64 %outer.end, i64 %inner.end) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'conflicting_access_contracts':
; CHECK: Src: store double 0.000000e+00, ptr %gep, align 8 --> Dst: store double 0.000000e+00, ptr %gep, align 8
; CHECK-NEXT: da analyze - output [* *]!
entry:
  br label %outer
outer:
  %j = phi i64 [ 0, %entry ], [ %j.next, %outer.latch ]
  br label %inner
inner:
  %i = phi i64 [ 0, %outer ], [ %i.next, %inner ]
  %row = mul nsw i64 %j, 10
  %offset = add nsw i64 %row, %i
  %gep = getelementptr nusw nuw double, ptr @a, i64 %offset
  call void @llvm.assume(i1 true) [ "array.extents"(ptr %gep, ptr @a, i64 10, i64 20) ]
  call void @llvm.assume(i1 true) [ "array.extents"(ptr %gep, ptr @a, i64 5, i64 40) ]
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

; An access-scoped range fact does not make a non-injective i+j
; linearization safe.
define void @noninjective_i_plus_j() {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'noninjective_i_plus_j':
; CHECK: Src: store double 0.000000e+00, ptr %gep, align 8 --> Dst: store double 0.000000e+00, ptr %gep, align 8
; CHECK-NEXT: da analyze - output [* *]!
entry:
  br label %outer
outer:
  %i = phi i64 [ 0, %entry ], [ %i.next, %outer.latch ]
  br label %inner
inner:
  %j = phi i64 [ 0, %outer ], [ %j.next, %inner ]
  %offset = add nuw nsw i64 %i, %j
  %gep = getelementptr nusw nuw double, ptr @a, i64 %offset
  call void @llvm.assume(i1 true) [ "array.extents"(ptr %gep, ptr @a, i64 20, i64 20) ]
  store double 0.0, ptr %gep
  %j.next = add nuw nsw i64 %j, 1
  %j.done = icmp eq i64 %j.next, 20
  br i1 %j.done, label %outer.latch, label %inner
outer.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.done = icmp eq i64 %i.next, 20
  br i1 %i.done, label %return, label %outer
return:
  ret void
}

; A start loaded in the outer loop varies across outer iterations just like i
; does, so a unit-stride inner subscript is still not injective.
define void @noninjective_loaded_start(ptr %idx) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'noninjective_loaded_start':
; CHECK: Src: store double 0.000000e+00, ptr %gep, align 8 --> Dst: store double 0.000000e+00, ptr %gep, align 8
; CHECK-NEXT: da analyze - output [* *]!
entry:
  br label %outer
outer:
  %i = phi i64 [ 0, %entry ], [ %i.next, %outer.latch ]
  %idx.gep = getelementptr inbounds i64, ptr %idx, i64 %i
  %start = load i64, ptr %idx.gep
  br label %inner
inner:
  %j = phi i64 [ 0, %outer ], [ %j.next, %inner ]
  %offset = add nuw nsw i64 %start, %j
  %gep = getelementptr nusw nuw double, ptr @a, i64 %offset
  call void @llvm.assume(i1 true) [ "array.extents"(ptr %gep, ptr @a, i64 20, i64 20) ]
  store double 0.0, ptr %gep
  %j.next = add nuw nsw i64 %j, 1
  %j.done = icmp eq i64 %j.next, 20
  br i1 %j.done, label %outer.latch, label %inner
outer.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.done = icmp eq i64 %i.next, 20
  br i1 %i.done, label %return, label %outer
return:
  ret void
}

; Likewise, two consecutive iterations of i/2 select the same element.
define void @noninjective_i_div_2() {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'noninjective_i_div_2':
; CHECK: Src: store double 0.000000e+00, ptr %gep, align 8 --> Dst: store double 0.000000e+00, ptr %gep, align 8
; CHECK-NEXT: da analyze - output [*]!
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %offset = udiv i64 %i, 2
  %gep = getelementptr nusw nuw double, ptr @a, i64 %offset
  call void @llvm.assume(i1 true) [ "array.extents"(ptr %gep, ptr @a, i64 20) ]
  store double 0.0, ptr %gep
  %i.next = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %i.next, 20
  br i1 %done, label %return, label %loop
return:
  ret void
}

; The start of j varies with the parent loop, so different parent iterations
; may reach one element in different j iterations. Only the k loop, whose
; start is invariant in the nest, is proved equal.
define void @dynamic_outer_start(ptr %a, ptr %steps) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'dynamic_outer_start':
; CHECK: Src: store double 0.000000e+00, ptr %gep, align 8 --> Dst: store double 0.000000e+00, ptr %gep, align 8
; CHECK-NEXT: da analyze - output [* * 0]!
entry:
  br label %parent

parent:
  %p = phi i64 [ 0, %entry ], [ %p.next, %parent.latch ]
  %base = phi i64 [ 1, %entry ], [ %base.next, %parent.latch ]
  %j.end = add nsw i64 %base, 150
  br label %middle

middle:
  %j = phi i64 [ %base, %parent ], [ %j.next, %middle.latch ]
  br label %inner

inner:
  %k = phi i64 [ 0, %middle ], [ %k.next, %inner ]
  %j.zero = add nsw i64 %j, -1
  %j.bytes = mul nsw i64 %j.zero, 8
  %k.bytes = mul nsw i64 %k, 1200
  %offset = add nsw i64 %j.bytes, %k.bytes
  %gep = getelementptr i8, ptr %a, i64 %offset
  call void @llvm.assume(i1 true) [ "array.extents"(ptr %gep, ptr %a, i64 150, i64 33) ]
  store double 0.0, ptr %gep, align 8
  %k.next = add nuw nsw i64 %k, 1
  %k.exit = icmp eq i64 %k.next, 33
  br i1 %k.exit, label %middle.latch, label %inner

middle.latch:
  %j.next = add nuw nsw i64 %j, 1
  %j.exit = icmp eq i64 %j.next, %j.end
  br i1 %j.exit, label %parent.latch, label %middle

parent.latch:
  %step.ptr = getelementptr i64, ptr %steps, i64 %p
  %step = load i64, ptr %step.ptr, align 8
  %base.next = add nsw i64 %base, %step
  %p.next = add nuw nsw i64 %p, 1
  %p.exit = icmp eq i64 %p.next, 2
  br i1 %p.exit, label %return, label %parent

return:
  ret void
}

declare void @llvm.assume(i1 noundef)
declare i64 @llvm.smax.i64(i64, i64)
