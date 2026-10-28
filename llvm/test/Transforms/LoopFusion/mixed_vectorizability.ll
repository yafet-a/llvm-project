; RUN: opt -passes=loop-fusion -disable-output -pass-remarks=loop-fusion -pass-remarks-missed=loop-fusion < %s 2>&1 | FileCheck %s

; CHECK: [mixed_vectorizability]{{.*}}Fusion would merge a vectorizable loop with a non-vectorizable loop
; CHECK: [both_non_vectorizable]{{.*}}Loops fused
; CHECK: [strided_partner]{{.*}}Loops fused

; Both loops reuse src[i]. The first loop is vectorizable, but the second
; carries a distance-1 recurrence through acc, so fusion would place the first
; loop's statement into a loop LoopVectorize cannot widen.
define void @mixed_vectorizability(ptr noalias %src, ptr noalias %dst,
                                   ptr noalias %acc, i64 %n) {
entry:
  br label %loop0

loop0:
  %i0 = phi i64 [ 1, %entry ], [ %i0.next, %loop0 ]
  %src.ptr0 = getelementptr inbounds i32, ptr %src, i64 %i0
  %value0 = load i32, ptr %src.ptr0, align 4
  %dst.ptr = getelementptr inbounds i32, ptr %dst, i64 %i0
  store i32 %value0, ptr %dst.ptr, align 4
  %i0.next = add nuw nsw i64 %i0, 1
  %cmp0 = icmp ult i64 %i0.next, %n
  br i1 %cmp0, label %loop0, label %loop1.preheader

loop1.preheader:
  br label %loop1

loop1:
  %i1 = phi i64 [ 1, %loop1.preheader ], [ %i1.next, %loop1 ]
  %src.ptr1 = getelementptr inbounds i32, ptr %src, i64 %i1
  %value1 = load i32, ptr %src.ptr1, align 4
  %prev.index = add nsw i64 %i1, -1
  %prev.ptr = getelementptr inbounds i32, ptr %acc, i64 %prev.index
  %prev = load i32, ptr %prev.ptr, align 4
  %sum = add i32 %prev, %value1
  %acc.ptr = getelementptr inbounds i32, ptr %acc, i64 %i1
  store i32 %sum, ptr %acc.ptr, align 4
  %i1.next = add nuw nsw i64 %i1, 1
  %cmp1 = icmp ult i64 %i1.next, %n
  br i1 %cmp1, label %loop1, label %exit

exit:
  ret void
}

; Neither loop is vectorizable, so fusion loses no vectorization and the
; src[i] reuse still makes it profitable.
define void @both_non_vectorizable(ptr noalias %src, ptr noalias %acc0,
                                   ptr noalias %acc1, i64 %n) {
entry:
  br label %loop0

loop0:
  %i0 = phi i64 [ 1, %entry ], [ %i0.next, %loop0 ]
  %src.ptr0 = getelementptr inbounds i32, ptr %src, i64 %i0
  %value0 = load i32, ptr %src.ptr0, align 4
  %prev.index0 = add nsw i64 %i0, -1
  %prev.ptr0 = getelementptr inbounds i32, ptr %acc0, i64 %prev.index0
  %prev0 = load i32, ptr %prev.ptr0, align 4
  %sum0 = add i32 %prev0, %value0
  %acc.ptr0 = getelementptr inbounds i32, ptr %acc0, i64 %i0
  store i32 %sum0, ptr %acc.ptr0, align 4
  %i0.next = add nuw nsw i64 %i0, 1
  %cmp0 = icmp ult i64 %i0.next, %n
  br i1 %cmp0, label %loop0, label %loop1.preheader

loop1.preheader:
  br label %loop1

loop1:
  %i1 = phi i64 [ 1, %loop1.preheader ], [ %i1.next, %loop1 ]
  %src.ptr1 = getelementptr inbounds i32, ptr %src, i64 %i1
  %value1 = load i32, ptr %src.ptr1, align 4
  %prev.index1 = add nsw i64 %i1, -1
  %prev.ptr1 = getelementptr inbounds i32, ptr %acc1, i64 %prev.index1
  %prev1 = load i32, ptr %prev.ptr1, align 4
  %sum1 = add i32 %prev1, %value1
  %acc.ptr1 = getelementptr inbounds i32, ptr %acc1, i64 %i1
  store i32 %sum1, ptr %acc.ptr1, align 4
  %i1.next = add nuw nsw i64 %i1, 1
  %cmp1 = icmp ult i64 %i1.next, %n
  br i1 %cmp1, label %loop1, label %exit

exit:
  ret void
}

; Like TSVC s233: the first loop carries a recurrence, and the second loop is
; memory-vectorizable but only through stride-64 accesses, which need gathers
; and scatters rather than interleave groups. Both loops are treated as
; non-vectorizable, so the src[64*i] reuse is kept.
define void @strided_partner(ptr noalias %src, ptr noalias %dst,
                             ptr noalias %acc, i64 %n) {
entry:
  br label %loop0

loop0:
  %i0 = phi i64 [ 1, %entry ], [ %i0.next, %loop0 ]
  %src.index0 = shl nuw nsw i64 %i0, 6
  %src.ptr0 = getelementptr inbounds i32, ptr %src, i64 %src.index0
  %value0 = load i32, ptr %src.ptr0, align 4
  %prev.index = add nsw i64 %i0, -1
  %prev.ptr = getelementptr inbounds i32, ptr %acc, i64 %prev.index
  %prev = load i32, ptr %prev.ptr, align 4
  %sum = add i32 %prev, %value0
  %acc.ptr = getelementptr inbounds i32, ptr %acc, i64 %i0
  store i32 %sum, ptr %acc.ptr, align 4
  %i0.next = add nuw nsw i64 %i0, 1
  %cmp0 = icmp ult i64 %i0.next, %n
  br i1 %cmp0, label %loop0, label %loop1.preheader

loop1.preheader:
  br label %loop1

loop1:
  %i1 = phi i64 [ 1, %loop1.preheader ], [ %i1.next, %loop1 ]
  %src.index1 = shl nuw nsw i64 %i1, 6
  %src.ptr1 = getelementptr inbounds i32, ptr %src, i64 %src.index1
  %value1 = load i32, ptr %src.ptr1, align 4
  %dst.ptr = getelementptr inbounds i32, ptr %dst, i64 %src.index1
  store i32 %value1, ptr %dst.ptr, align 4
  %i1.next = add nuw nsw i64 %i1, 1
  %cmp1 = icmp ult i64 %i1.next, %n
  br i1 %cmp1, label %loop1, label %exit

exit:
  ret void
}
