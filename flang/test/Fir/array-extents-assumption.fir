// Test that the base of an array access states the extents of the array, which
// Fortran requires the subscripts of a conforming program to stay within.

// RUN: tco --enable-array-extents-assumption %s | FileCheck %s

func.func @load_2d(%addr : !fir.ref<!fir.array<10x20xi32>>, %i : index, %j : index) -> i32 {
  %c10 = arith.constant 10 : index
  %c20 = arith.constant 20 : index
  %shape = fir.shape %c10, %c20 : (index, index) -> !fir.shape<2>
  %ref = fir.array_coor %addr(%shape) %i, %j : (!fir.ref<!fir.array<10x20xi32>>, !fir.shape<2>, index, index) -> !fir.ref<i32>
  %val = fir.load %ref : !fir.ref<i32>
  return %val : i32
}

// The extents are listed in the order a Fortran declaration gives them.
// CHECK-LABEL: define i32 @load_2d(
// CHECK: %[[BASE:.*]] = call ptr @llvm.assume.chained.p0(ptr %0) [ "array.extents"(i64 10, i64 20) ]
// CHECK: getelementptr {{.*}}, ptr %[[BASE]],

func.func @store_2d(%addr : !fir.ref<!fir.array<10x20xi32>>, %i : index, %j : index, %v : i32) {
  %c10 = arith.constant 10 : index
  %c20 = arith.constant 20 : index
  %shape = fir.shape %c10, %c20 : (index, index) -> !fir.shape<2>
  %ref = fir.array_coor %addr(%shape) %i, %j : (!fir.ref<!fir.array<10x20xi32>>, !fir.shape<2>, index, index) -> !fir.ref<i32>
  fir.store %v to %ref : !fir.ref<i32>
  return
}

// CHECK-LABEL: define void @store_2d(
// CHECK: call ptr @llvm.assume.chained.p0(ptr %0) [ "array.extents"(i64 10, i64 20) ]

func.func @load_dynamic(%addr : !fir.ref<!fir.array<?x?xi32>>, %n : index, %m : index, %i : index, %j : index) -> i32 {
  %shape = fir.shape %n, %m : (index, index) -> !fir.shape<2>
  %ref = fir.array_coor %addr(%shape) %i, %j : (!fir.ref<!fir.array<?x?xi32>>, !fir.shape<2>, index, index) -> !fir.ref<i32>
  %val = fir.load %ref : !fir.ref<i32>
  return %val : i32
}

// CHECK-LABEL: define i32 @load_dynamic(
// CHECK-SAME: i64 %[[N:[0-9]+]], i64 %[[M:[0-9]+]],
// CHECK: call ptr @llvm.assume.chained.p0(ptr %0) [ "array.extents"(i64 %[[N]], i64 %[[M]]) ]

// Identical calls on one base merge into a single call at their nearest common
// dominator.
func.func @merge_identical(%addr : !fir.ref<!fir.array<10x20xi32>>, %i : index, %j : index, %c : i1) -> i32 {
  %c10 = arith.constant 10 : index
  %c20 = arith.constant 20 : index
  %shape = fir.shape %c10, %c20 : (index, index) -> !fir.shape<2>
  cf.cond_br %c, ^bb1, ^bb2
^bb1:
  %r1 = fir.array_coor %addr(%shape) %i, %j : (!fir.ref<!fir.array<10x20xi32>>, !fir.shape<2>, index, index) -> !fir.ref<i32>
  %v1 = fir.load %r1 : !fir.ref<i32>
  cf.br ^bb3(%v1 : i32)
^bb2:
  %r2 = fir.array_coor %addr(%shape) %j, %i : (!fir.ref<!fir.array<10x20xi32>>, !fir.shape<2>, index, index) -> !fir.ref<i32>
  %v2 = fir.load %r2 : !fir.ref<i32>
  cf.br ^bb3(%v2 : i32)
^bb3(%v : i32):
  return %v : i32
}

// CHECK-LABEL: define i32 @merge_identical(
// CHECK: call ptr @llvm.assume.chained.p0(ptr %0) [ "array.extents"(i64 10, i64 20) ]
// CHECK: br i1
// CHECK-NOT: llvm.assume.chained
// CHECK: ret i32

// A boxed base carries its extents and byte strides in the descriptor.
func.func @load_boxed(%box : !fir.box<!fir.array<?x?xi32>>, %i : index, %j : index) -> i32 {
  %ref = fir.array_coor %box %i, %j : (!fir.box<!fir.array<?x?xi32>>, index, index) -> !fir.ref<i32>
  %val = fir.load %ref : !fir.ref<i32>
  return %val : i32
}

// CHECK-LABEL: define i32 @load_boxed(
// CHECK: call ptr @llvm.assume.chained.p0(ptr %{{.*}}) [ "array.extents"(i64 %{{.*}}, i64 %{{.*}}), "array.strides"(i64 %{{.*}}, i64 %{{.*}}) ]

// An assumed-size dimension has no extent for a subscript to stay within.
func.func @load_assumed_size(%addr : !fir.ref<!fir.array<?xi32>>, %idx : index) -> i32 {
  %ext = fir.assumed_size_extent : index
  %shape = fir.shape %ext : (index) -> !fir.shape<1>
  %ref = fir.array_coor %addr(%shape) %idx : (!fir.ref<!fir.array<?xi32>>, !fir.shape<1>, index) -> !fir.ref<i32>
  %val = fir.load %ref : !fir.ref<i32>
  return %val : i32
}

// CHECK-LABEL: define i32 @load_assumed_size(
// CHECK-NOT: llvm.assume.chained
// CHECK: ret i32

// An element passed on may be the start of a sequence the callee walks past
// the element's own dimension.
func.func private @take(!fir.ref<i32>)
func.func @pass_element(%addr : !fir.ref<!fir.array<10x20xi32>>, %i : index, %j : index) {
  %c10 = arith.constant 10 : index
  %c20 = arith.constant 20 : index
  %shape = fir.shape %c10, %c20 : (index, index) -> !fir.shape<2>
  %ref = fir.array_coor %addr(%shape) %i, %j : (!fir.ref<!fir.array<10x20xi32>>, !fir.shape<2>, index, index) -> !fir.ref<i32>
  fir.call @take(%ref) : (!fir.ref<i32>) -> ()
  return
}

// CHECK-LABEL: define void @pass_element(
// CHECK-NOT: llvm.assume.chained
// CHECK: ret void
