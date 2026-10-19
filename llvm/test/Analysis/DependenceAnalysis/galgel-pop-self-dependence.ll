; RUN: opt < %s -disable-output -passes='print<da>' \
; RUN:   -da-enable-dependence-test=all 2>&1 | FileCheck %s
; RUN: opt < %s -disable-output -passes='print<da>' \
; RUN:   -da-enable-dependence-test=all \
; RUN:   -da-disable-delinearization-checks 2>&1 | FileCheck %s \
; RUN:   --check-prefix=UNCHECKED

; Reduced form of the Galgel POP store:
;
;   pop(ny * i + j, ny * il + jl) = ...
;
; The array shape and assumptions allow checked delinearization to recover two
; MIV subscripts. Each is a mixed-radix recurrence whose outer step is the
; exact inner trip count, so the self-access is one-to-one in all four loops.
; This refinement must not apply when delinearization validation is disabled.

@pop = global [1000 x [1000 x double]] zeroinitializer, !array.dims !0

define void @pop_self_dependence(i64 %nx, i64 %ny) {
; CHECK-LABEL: Printing analysis 'Dependence Analysis' for function 'pop_self_dependence':
; CHECK:       Src: store double 0.000000e+00, ptr %gep, align 8 --> Dst: store double 0.000000e+00, ptr %gep, align 8
; CHECK-NEXT:    da analyze - none!
; UNCHECKED-LABEL: Printing analysis 'Dependence Analysis' for function 'pop_self_dependence':
; UNCHECKED:       Src: store double 0.000000e+00, ptr %gep, align 8 --> Dst: store double 0.000000e+00, ptr %gep, align 8
; UNCHECKED-NEXT:    da analyze - output [* * * *]!
;
entry:
  %ny.positive = icmp sgt i64 %ny, 0
  call void @llvm.assume(i1 %ny.positive)
  br label %i.loop

i.loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %i.latch ]
  br label %j.loop

j.loop:
  %j = phi i64 [ 0, %i.loop ], [ %j.next, %j.latch ]
  %first.mul = mul nsw i64 %ny, %i
  %first = add nsw i64 %first.mul, %j
  %first.one = add nsw i64 %first, 1
  %first.nonzero = icmp ne i64 %first.one, 0
  %first.upper = icmp samesign ult i64 %first.one, 1001
  call void @llvm.assume(i1 %first.nonzero)
  call void @llvm.assume(i1 %first.upper)
  br label %il.loop

il.loop:
  %il = phi i64 [ 0, %j.loop ], [ %il.next, %il.latch ]
  br label %jl.loop

jl.loop:
  %jl = phi i64 [ 0, %il.loop ], [ %jl.next, %jl.loop ]
  %second.mul = mul nsw i64 %ny, %il
  %second = add nsw i64 %second.mul, %jl
  %second.one = add nsw i64 %second, 1
  %second.nonzero = icmp ne i64 %second.one, 0
  %second.upper = icmp samesign ult i64 %second.one, 1001
  call void @llvm.assume(i1 %second.nonzero)
  call void @llvm.assume(i1 %second.upper)

  %second.stride = mul nsw i64 %second, 1000
  %offset = add nsw i64 %second.stride, %first
  %gep = getelementptr double, ptr @pop, i64 %offset
  store double 0.0, ptr %gep, align 8

  %jl.next = add nuw nsw i64 %jl, 1
  %jl.exit = icmp eq i64 %jl.next, %ny
  br i1 %jl.exit, label %il.latch, label %jl.loop

il.latch:
  %il.next = add nuw nsw i64 %il, 1
  %il.exit = icmp eq i64 %il.next, %nx
  br i1 %il.exit, label %j.latch, label %il.loop

j.latch:
  %j.next = add nuw nsw i64 %j, 1
  %j.exit = icmp eq i64 %j.next, %ny
  br i1 %j.exit, label %i.latch, label %j.loop

i.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.exit = icmp eq i64 %i.next, %nx
  br i1 %i.exit, label %exit, label %i.loop

exit:
  ret void
}

declare void @llvm.assume(i1 noundef)

!0 = !{i64 1000, i64 1000}
