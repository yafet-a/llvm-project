; RUN: llvm-as < %s | llvm-dis | FileCheck %s
; RUN: verify-uselistorder < %s

; Test that array.dims metadata can be attached to alloca and global variables.
; Format: size per dimension.

; CHECK: @global_array = global [10 x [20 x i32]] zeroinitializer, !array.dims ![[GLOBAL_DIMS:[0-9]+]]
@global_array = global [10 x [20 x i32]] zeroinitializer, !array.dims !0

define void @test_alloca() {
; CHECK-LABEL: @test_alloca()
entry:
  ; CHECK: %local_array = alloca [5 x [10 x double]], align 8, !array.dims ![[LOCAL_DIMS:[0-9]+]]
  %local_array = alloca [5 x [10 x double]], align 8, !array.dims !1
  ret void
}

define void @test_alloca_1d() {
; CHECK-LABEL: @test_alloca_1d()
entry:
  ; CHECK: %arr = alloca [100 x i32], align 4, !array.dims ![[DIMS_1D:[0-9]+]]
  %arr = alloca [100 x i32], align 4, !array.dims !2
  ret void
}

define void @test_alloca_3d() {
; CHECK-LABEL: @test_alloca_3d()
entry:
  ; CHECK: %arr3d = alloca [2 x [3 x [4 x float]]], align 4, !array.dims ![[DIMS_3D:[0-9]+]]
  %arr3d = alloca [2 x [3 x [4 x float]]], align 4, !array.dims !3
  ret void
}

; CHECK: ![[GLOBAL_DIMS]] = !{i64 10, i64 20}
!0 = !{i64 10, i64 20}

; CHECK: ![[LOCAL_DIMS]] = !{i64 5, i64 10}
!1 = !{i64 5, i64 10}

; CHECK: ![[DIMS_1D]] = !{i64 100}
!2 = !{i64 100}

; CHECK: ![[DIMS_3D]] = !{i64 2, i64 3, i64 4}
!3 = !{i64 2, i64 3, i64 4}
