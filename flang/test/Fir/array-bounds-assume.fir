// Test that array bounds assumes are generated for fir.array_coor operations.
// This tests that Flang emits llvm.assume intrinsics for array bounds constraints.

// RUN: tco --enable-array-extents-assumption %s | FileCheck %s
// RUN: tco --enable-array-extents-assumption -O1 %s | FileCheck %s --check-prefix=O1

// O1-NOT: "array.extents"

// Test 1D array with constant shape.
func.func @array_coor_1d(%addr : !fir.ref<!fir.array<10xi32>>, %idx : index) -> i32 {
  %c10 = arith.constant 10 : index
  %shape = fir.shape %c10 : (index) -> !fir.shape<1>
  %ref = fir.array_coor %addr(%shape) %idx : (!fir.ref<!fir.array<10xi32>>, !fir.shape<1>, index) -> !fir.ref<i32>
  %val = fir.load %ref : !fir.ref<i32>
  return %val : i32
}

// CHECK-LABEL: define i32 @array_coor_1d
// CHECK: call void @llvm.assume(i1 true) [ "array.extents"(ptr %[[ACCESS:[0-9]+]], ptr %[[BASE:[0-9]+]], i64 10) ]

// Test 2D array with constant shape.
func.func @array_coor_2d(%addr : !fir.ref<!fir.array<10x20xi32>>, %i : index, %j : index) -> i32 {
  %c10 = arith.constant 10 : index
  %c20 = arith.constant 20 : index
  %shape = fir.shape %c10, %c20 : (index, index) -> !fir.shape<2>
  %ref = fir.array_coor %addr(%shape) %i, %j : (!fir.ref<!fir.array<10x20xi32>>, !fir.shape<2>, index, index) -> !fir.ref<i32>
  %val = fir.load %ref : !fir.ref<i32>
  return %val : i32
}

// CHECK-LABEL: define i32 @array_coor_2d
// CHECK: call void @llvm.assume(i1 true) [ "array.extents"(ptr %[[ACCESS:[0-9]+]], ptr %[[BASE:[0-9]+]], i64 10, i64 20) ]

// Runtime extents are ordinary bundle operands.
func.func @array_coor_dynamic(%addr : !fir.ref<!fir.array<?x?xi32>>, %n : index, %m : index, %i : index, %j : index) -> i32 {
  %shape = fir.shape %n, %m : (index, index) -> !fir.shape<2>
  %ref = fir.array_coor %addr(%shape) %i, %j : (!fir.ref<!fir.array<?x?xi32>>, !fir.shape<2>, index, index) -> !fir.ref<i32>
  %val = fir.load %ref : !fir.ref<i32>
  return %val : i32
}

// CHECK-LABEL: define i32 @array_coor_dynamic
// CHECK-SAME: i64 %[[N:[0-9]+]], i64 %[[M:[0-9]+]],
// CHECK: call void @llvm.assume(i1 true) [ "array.extents"(ptr %[[ACCESS:[0-9]+]], ptr %[[BASE:[0-9]+]], i64 %[[N]], i64 %[[M]]) ]

// A boxed base gets its runtime extents from the descriptor. The bundle refers
// to the extracted data pointer, not to the descriptor.
func.func @array_coor_boxed(%box : !fir.box<!fir.array<?x?xi32>>, %i : index, %j : index) -> i32 {
  %ref = fir.array_coor %box %i, %j : (!fir.box<!fir.array<?x?xi32>>, index, index) -> !fir.ref<i32>
  %val = fir.load %ref : !fir.ref<i32>
  return %val : i32
}

// CHECK-LABEL: define i32 @array_coor_boxed
// CHECK: call void @llvm.assume(i1 true) [ "array.extents"(ptr %[[ACCESS:[0-9]+]], ptr %[[BASE:[0-9]+]], i64 %[[E0:[0-9]+]], i64 %[[E1:[0-9]+]]), "array.strides"(ptr %[[ACCESS]], i64 %[[S0:[0-9]+]], i64 %[[S1:[0-9]+]]) ]

// Test array with shifted lower bounds.
func.func @array_coor_shifted(%addr : !fir.ref<!fir.array<10xi32>>, %idx : index) -> i32 {
  %c5 = arith.constant 5 : index
  %c10 = arith.constant 10 : index
  %shape = fir.shape_shift %c5, %c10 : (index, index) -> !fir.shapeshift<1>
  %ref = fir.array_coor %addr(%shape) %idx : (!fir.ref<!fir.array<10xi32>>, !fir.shapeshift<1>, index) -> !fir.ref<i32>
  %val = fir.load %ref : !fir.ref<i32>
  return %val : i32
}

// CHECK-LABEL: define i32 @array_coor_shifted
// The carrier describes the zero-based lowered access despite the source
// lower bound being five.
// CHECK: call void @llvm.assume(i1 true) [ "array.extents"(ptr %[[ACCESS:[0-9]+]], ptr %[[BASE:[0-9]+]], i64 10) ]

// Assumed-size arrays must not get bounds assumes.
func.func @array_coor_assumed_size(%addr : !fir.ref<!fir.array<?xf32>>, %idx : index) -> f32 {
  %extent = fir.assumed_size_extent : index
  %shape = fir.shape %extent : (index) -> !fir.shape<1>
  %ref = fir.array_coor %addr(%shape) %idx : (!fir.ref<!fir.array<?xf32>>, !fir.shape<1>, index) -> !fir.ref<f32>
  %val = fir.load %ref : !fir.ref<f32>
  return %val : f32
}

// CHECK-LABEL: define float @array_coor_assumed_size
// CHECK-NOT: call void @llvm.assume

// The in-range guarantee is scoped to the exact element address, so an escaping
// pointer may still carry a contract. Accesses derived from it do not inherit
// that guarantee.
func.func private @take(!fir.ref<i32>)
func.func @array_coor_escape(%addr : !fir.ref<!fir.array<10x20xi32>>, %i : index, %j : index) {
  %c10 = arith.constant 10 : index
  %c20 = arith.constant 20 : index
  %shape = fir.shape %c10, %c20 : (index, index) -> !fir.shape<2>
  %ref = fir.array_coor %addr(%shape) %i, %j : (!fir.ref<!fir.array<10x20xi32>>, !fir.shape<2>, index, index) -> !fir.ref<i32>
  fir.call @take(%ref) : (!fir.ref<i32>) -> ()
  return
}

// CHECK-LABEL: define void @array_coor_escape
// CHECK: %[[ACCESS:.*]] = getelementptr
// CHECK: call void @llvm.assume(i1 true) [ "array.extents"(ptr %[[ACCESS]], ptr %{{.*}}, i64 10, i64 20) ]
// CHECK: ret void

// Boxed element addresses use the same exact-access scoping.
func.func @array_coor_boxed_escape(%box : !fir.box<!fir.array<?x?xi32>>, %i : index, %j : index) {
  %ref = fir.array_coor %box %i, %j : (!fir.box<!fir.array<?x?xi32>>, index, index) -> !fir.ref<i32>
  fir.call @take(%ref) : (!fir.ref<i32>) -> ()
  return
}

// CHECK-LABEL: define void @array_coor_boxed_escape
// CHECK: %[[BOX_ACCESS:.*]] = getelementptr nusw i8
// CHECK: call void @llvm.assume(i1 true) [ "array.extents"(ptr %[[BOX_ACCESS]], ptr %[[BOX_BASE:.*]], i64 %{{.*}}, i64 %{{.*}}), "array.strides"(ptr %[[BOX_ACCESS]], i64 %{{.*}}, i64 %{{.*}}) ]
// CHECK: ret void
