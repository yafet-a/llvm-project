; RUN: opt < %s -passes=loop-interchange \
; RUN:   -loop-interchange-profitabilities=ignore \
; RUN:   -loop-interchange-allow-inner-invariant-loads \
; RUN:   -pass-remarks='loop-interchange' \
; RUN:   -pass-remarks-missed='loop-interchange' \
; RUN:   -pass-remarks-output=- -disable-output 2>/dev/null | FileCheck %s
; RUN: opt < %s -passes=loop-interchange \
; RUN:   -loop-interchange-profitabilities=ignore \
; RUN:   -loop-interchange-allow-inner-invariant-loads -S | \
; RUN:   FileCheck %s --check-prefix=IR

@A = global [32 x [32 x i32]] zeroinitializer
@B = global [32 x i32] zeroinitializer

; Repeating the load after interchange is safe: its address is invariant in the
; inner loop, and the inner loop cannot modify the distinct global B.
;
; CHECK:      --- !Passed
; CHECK:      Name:            Interchanged
; CHECK:      Function:        safe_invariant_load

define void @safe_invariant_load() {
entry:
  br label %i.header

i.header:
  %i = phi i64 [ 0, %entry ], [ %i.next, %i.latch ]
  %b.ptr = getelementptr [32 x i32], ptr @B, i64 0, i64 %i
  %b = load i32, ptr %b.ptr
  br label %j.header

j.header:
  %j = phi i64 [ 0, %i.header ], [ %j.next, %j.header ]
  %a.ptr = getelementptr [32 x [32 x i32]], ptr @A, i64 0, i64 %j, i64 %i
  store i32 %b, ptr %a.ptr
  %j.next = add nuw nsw i64 %j, 1
  %j.done = icmp eq i64 %j.next, 32
  br i1 %j.done, label %i.latch, label %j.header

i.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.done = icmp eq i64 %i.next, 32
  br i1 %i.done, label %exit, label %i.header

exit:
  ret void
}

; Even unordered atomic loads are observable and must not be repeated.
;
; IR-LABEL: define void @atomic_invariant_load()
; IR:       entry:
; IR-NEXT:    br label %i.header
; IR:       i.header:
; IR:         load atomic i32
; IR:         br label %j.header

define void @atomic_invariant_load() {
entry:
  br label %i.header

i.header:
  %i = phi i64 [ 0, %entry ], [ %i.next, %i.latch ]
  %b.ptr = getelementptr [32 x i32], ptr @B, i64 0, i64 %i
  %b = load atomic i32, ptr %b.ptr unordered, align 4
  br label %j.header

j.header:
  %j = phi i64 [ 0, %i.header ], [ %j.next, %j.header ]
  %a.ptr = getelementptr [32 x [32 x i32]], ptr @A, i64 0, i64 %j, i64 %i
  store i32 %b, ptr %a.ptr
  %j.next = add nuw nsw i64 %j, 1
  %j.done = icmp eq i64 %j.next, 32
  br i1 %j.done, label %i.latch, label %j.header

i.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.done = icmp eq i64 %i.next, 32
  br i1 %i.done, label %exit, label %i.header

exit:
  ret void
}

; The inner store may modify the loaded location, so repeating the load could
; observe values written by an earlier inner-loop iteration.
;
; CHECK:      --- !Missed
; CHECK:      Name:            Dependence
; CHECK:      Function:        aliasing_inner_store

define void @aliasing_inner_store() {
entry:
  br label %i.header

i.header:
  %i = phi i64 [ 0, %entry ], [ %i.next, %i.latch ]
  %load.ptr = getelementptr [32 x [32 x i32]], ptr @A, i64 0, i64 0, i64 %i
  %value = load i32, ptr %load.ptr
  br label %j.header

j.header:
  %j = phi i64 [ 0, %i.header ], [ %j.next, %j.header ]
  %store.ptr = getelementptr [32 x [32 x i32]], ptr @A, i64 0, i64 %j, i64 %i
  store i32 %value, ptr %store.ptr
  %j.next = add nuw nsw i64 %j, 1
  %j.done = icmp eq i64 %j.next, 32
  br i1 %j.done, label %i.latch, label %j.header

i.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.done = icmp eq i64 %i.next, 32
  br i1 %i.done, label %exit, label %i.header

exit:
  ret void
}

; Volatile loads are observable and must never be repeated.
;
; IR-LABEL: define void @volatile_invariant_load()
; IR:       entry:
; IR-NEXT:    br label %i.header
; IR:       i.header:
; IR:         load volatile i32
; IR:         br label %j.header

define void @volatile_invariant_load() {
entry:
  br label %i.header

i.header:
  %i = phi i64 [ 0, %entry ], [ %i.next, %i.latch ]
  %b.ptr = getelementptr [32 x i32], ptr @B, i64 0, i64 %i
  %b = load volatile i32, ptr %b.ptr
  br label %j.header

j.header:
  %j = phi i64 [ 0, %i.header ], [ %j.next, %j.header ]
  %a.ptr = getelementptr [32 x [32 x i32]], ptr @A, i64 0, i64 %j, i64 %i
  store i32 %b, ptr %a.ptr
  %j.next = add nuw nsw i64 %j, 1
  %j.done = icmp eq i64 %j.next, 32
  br i1 %j.done, label %i.latch, label %j.header

i.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.done = icmp eq i64 %i.next, 32
  br i1 %i.done, label %exit, label %i.header

exit:
  ret void
}
