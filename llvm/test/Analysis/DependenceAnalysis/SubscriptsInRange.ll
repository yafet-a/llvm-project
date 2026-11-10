; RUN: opt < %s -disable-output -passes="print<da>" 2>&1 | FileCheck %s

; The accesses walk a two-dimensional array whose extents are known, but the
; loops that generate the subscripts are bounded by arguments. Nothing rules out
; a subscript running past its own dimension and into the next, so the shape of
; the array cannot be recovered from the flattened address and the dependence
; has to be described conservatively.
;
; An 'llvm.assume.chained' call on the array base states that the subscripts do
; stay within their dimensions, which is what a language such as Fortran
; requires of a conforming program, and the shape follows from it. Its
; "array.extents" bundle lists the extents of those dimensions, from the
; fastest-varying to the slowest; the extents are compared against the shape
; delinearization arrived at, so that a claim describing some other array is
; passed over rather than believed.

@a = local_unnamed_addr global [150 x [100 x double]] zeroinitializer, align 8

; CHECK-LABEL: 'Dependence Analysis' for function 'unmarked'
; CHECK: da analyze - input [* *]
; CHECK: da analyze - anti [* *|<]
; CHECK: da analyze - output [* *]

define void @unmarked(i32 %n, i32 %m) {
entry:
  %n.pos = icmp sgt i32 %n, 0
  %m.pos = icmp sgt i32 %m, 0
  %enter = and i1 %n.pos, %m.pos
  br i1 %enter, label %preheader, label %exit

preheader:
  %nx = zext nneg i32 %n to i64
  %mx = zext nneg i32 %m to i64
  br label %outer

outer:
  %i = phi i64 [ 0, %preheader ], [ %i.next, %outer.latch ]
  %row = getelementptr inbounds nuw [8 x i8], ptr @a, i64 %i
  br label %inner

inner:
  %j = phi i64 [ 0, %outer ], [ %j.next, %inner ]
  %elt = getelementptr inbounds nuw [800 x i8], ptr %row, i64 %j
  %v = load double, ptr %elt, align 8
  %mul = fmul double %v, 2.000000e+00
  store double %mul, ptr %elt, align 8
  %j.next = add nuw nsw i64 %j, 1
  %j.done = icmp eq i64 %j.next, %mx
  br i1 %j.done, label %outer.latch, label %inner

outer.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.done = icmp eq i64 %i.next, %nx
  br i1 %i.done, label %exit, label %outer

exit:
  ret void
}

; CHECK-LABEL: 'Dependence Analysis' for function 'marked'
; CHECK: da analyze - none!
; CHECK: da analyze - anti [0 0|<]
; CHECK: da analyze - none!

define void @marked(i32 %n, i32 %m) {
entry:
  %n.pos = icmp sgt i32 %n, 0
  %m.pos = icmp sgt i32 %m, 0
  %enter = and i1 %n.pos, %m.pos
  br i1 %enter, label %preheader, label %exit

preheader:
  %nx = zext nneg i32 %n to i64
  %mx = zext nneg i32 %m to i64
  %a.c = call ptr @llvm.assume.chained.p0(ptr @a)
      [ "array.extents"(i64 100, i64 150) ]
  br label %outer

outer:
  %i = phi i64 [ 0, %preheader ], [ %i.next, %outer.latch ]
  %row = getelementptr inbounds nuw [8 x i8], ptr %a.c, i64 %i
  br label %inner

inner:
  %j = phi i64 [ 0, %outer ], [ %j.next, %inner ]
  %elt = getelementptr inbounds nuw [800 x i8], ptr %row, i64 %j
  %v = load double, ptr %elt, align 8
  %mul = fmul double %v, 2.000000e+00
  store double %mul, ptr %elt, align 8
  %j.next = add nuw nsw i64 %j, 1
  %j.done = icmp eq i64 %j.next, %mx
  br i1 %j.done, label %outer.latch, label %inner

outer.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.done = icmp eq i64 %i.next, %nx
  br i1 %i.done, label %exit, label %outer

exit:
  ret void
}

; The extents do not match the shape the address arithmetic walks, so the
; claim is passed over.

; CHECK-LABEL: 'Dependence Analysis' for function 'marked_other_shape'
; CHECK: da analyze - input [* *]!
; CHECK: da analyze - anti [* *|<]!
; CHECK: da analyze - output [* *]!

define void @marked_other_shape(i32 %n, i32 %m) {
entry:
  %n.pos = icmp sgt i32 %n, 0
  %m.pos = icmp sgt i32 %m, 0
  %enter = and i1 %n.pos, %m.pos
  br i1 %enter, label %preheader, label %exit

preheader:
  %nx = zext nneg i32 %n to i64
  %mx = zext nneg i32 %m to i64
  %a.c = call ptr @llvm.assume.chained.p0(ptr @a)
      [ "array.extents"(i64 150, i64 100) ]
  br label %outer

outer:
  %i = phi i64 [ 0, %preheader ], [ %i.next, %outer.latch ]
  %row = getelementptr inbounds nuw [8 x i8], ptr %a.c, i64 %i
  br label %inner

inner:
  %j = phi i64 [ 0, %outer ], [ %j.next, %inner ]
  %elt = getelementptr inbounds nuw [800 x i8], ptr %row, i64 %j
  %v = load double, ptr %elt, align 8
  %mul = fmul double %v, 2.000000e+00
  store double %mul, ptr %elt, align 8
  %j.next = add nuw nsw i64 %j, 1
  %j.done = icmp eq i64 %j.next, %mx
  br i1 %j.done, label %outer.latch, label %inner

outer.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.done = icmp eq i64 %i.next, %nx
  br i1 %i.done, label %exit, label %outer

exit:
  ret void
}

; Extents only known at run time that cannot be shown to equal the recovered
; shape are passed over as well.

; CHECK-LABEL: 'Dependence Analysis' for function 'marked_runtime_extents'
; CHECK: da analyze - input [* *]!
; CHECK: da analyze - anti [* *|<]!
; CHECK: da analyze - output [* *]!

define void @marked_runtime_extents(i32 %n, i32 %m) {
entry:
  %n.pos = icmp sgt i32 %n, 0
  %m.pos = icmp sgt i32 %m, 0
  %enter = and i1 %n.pos, %m.pos
  br i1 %enter, label %preheader, label %exit

preheader:
  %nx = zext nneg i32 %n to i64
  %mx = zext nneg i32 %m to i64
  %a.c = call ptr @llvm.assume.chained.p0(ptr @a)
      [ "array.extents"(i64 %nx, i64 %mx) ]
  br label %outer

outer:
  %i = phi i64 [ 0, %preheader ], [ %i.next, %outer.latch ]
  %row = getelementptr inbounds nuw [8 x i8], ptr %a.c, i64 %i
  br label %inner

inner:
  %j = phi i64 [ 0, %outer ], [ %j.next, %inner ]
  %elt = getelementptr inbounds nuw [800 x i8], ptr %row, i64 %j
  %v = load double, ptr %elt, align 8
  %mul = fmul double %v, 2.000000e+00
  store double %mul, ptr %elt, align 8
  %j.next = add nuw nsw i64 %j, 1
  %j.done = icmp eq i64 %j.next, %mx
  br i1 %j.done, label %outer.latch, label %inner

outer.latch:
  %i.next = add nuw nsw i64 %i, 1
  %i.done = icmp eq i64 %i.next, %nx
  br i1 %i.done, label %exit, label %outer

exit:
  ret void
}

declare ptr @llvm.assume.chained.p0(ptr)
