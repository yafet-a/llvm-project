! RUN: %flang_fc1 -emit-llvm %s -o - | FileCheck %s

! Test that array.dims metadata is emitted for fixed-size Fortran arrays.
! Global arrays should get metadata.
!
! CHECK: @{{.*}}module_array{{.*}} = global [20 x float] zeroinitializer, align 64, !array.dims ![[DIMS_GLOBAL:[0-9]+]]

module test_module
  real :: module_array(20)
end module
