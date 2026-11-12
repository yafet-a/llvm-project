; RUN: opt < %s -passes=loop-interchange -disable-output \
; RUN:     -loop-interchange-profitabilities=ignore \
; RUN:     -loop-interchange-max-mem-instr-ratio=4 \
; RUN:     -pass-remarks=loop-interchange -pass-remarks-missed=loop-interchange \
; RUN:     2>&1 | FileCheck %s --check-prefix=RATIO-4
; RUN: opt < %s -passes=loop-interchange -disable-output \
; RUN:     -loop-interchange-profitabilities=ignore \
; RUN:     -loop-interchange-max-mem-instr-ratio=5 \
; RUN:     -pass-remarks=loop-interchange -pass-remarks-missed=loop-interchange \
; RUN:     2>&1 | FileCheck %s --check-prefix=RATIO-5

; The nest has 20 instructions other than llvm.assume and 10 stores, so the
; guard requires a ratio of at least 10 * 10 / 20 = 5. The 10 assumes do not
; count: with them the nest would have 30 instructions and pass a ratio of 4.

; RATIO-4: Number of loads/stores exceeded
; RATIO-4-NOT: Loop interchanged

; RATIO-5-NOT: Number of loads/stores exceeded
; RATIO-5: Loop interchanged with enclosing loop.

define void @f(ptr noalias %A) {
entry:
  br label %loop.i.header

loop.i.header:
  %i = phi i64 [ 0, %entry ], [ %i.inc, %loop.i.latch ]
  br label %loop.j

loop.j:
  %j = phi i64 [ 0, %loop.i.header ], [ %j.inc, %loop.j ]
  %gep = getelementptr [10 x i8], ptr %A, i64 %j, i64 %i
  call void @llvm.assume(i1 true)
  store i8 0, ptr %gep
  call void @llvm.assume(i1 true)
  store i8 0, ptr %gep
  call void @llvm.assume(i1 true)
  store i8 0, ptr %gep
  call void @llvm.assume(i1 true)
  store i8 0, ptr %gep
  call void @llvm.assume(i1 true)
  store i8 0, ptr %gep
  call void @llvm.assume(i1 true)
  store i8 0, ptr %gep
  call void @llvm.assume(i1 true)
  store i8 0, ptr %gep
  call void @llvm.assume(i1 true)
  store i8 0, ptr %gep
  call void @llvm.assume(i1 true)
  store i8 0, ptr %gep
  call void @llvm.assume(i1 true)
  store i8 0, ptr %gep
  %j.inc = add i64 %j, 1
  %ec.j = icmp eq i64 %j.inc, 10
  br i1 %ec.j, label %loop.i.latch, label %loop.j

loop.i.latch:
  %i.inc = add i64 %i, 1
  %ec.i = icmp eq i64 %i.inc, 10
  br i1 %ec.i, label %exit, label %loop.i.header

exit:
  ret void
}

declare void @llvm.assume(i1)
