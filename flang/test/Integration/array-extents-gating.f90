!===----------------------------------------------------------------------===!
! This directory can be used to add Integration tests involving multiple
! stages of the compiler (for eg. from Fortran to LLVM IR). It should not
! contain executable tests. We should only add tests here sparingly and only
! if there is no other way to test. Repeat this message in each test that is
! added to this directory and sub-directories.
!===----------------------------------------------------------------------===!

! Array extents are only stated when requested, at -O2 and above. Check the IR
! that enters the LLVM pipeline.
! RUN: %flang_fc1 -emit-llvm -O2 -mllvm -enable-array-extents-assumption -mllvm -print-before=annotation2metadata -o /dev/null %s 2>&1 | FileCheck %s --check-prefix=EXTENTS
! RUN: %flang_fc1 -emit-llvm -O1 -mllvm -enable-array-extents-assumption -mllvm -print-before=annotation2metadata -o /dev/null %s 2>&1 | FileCheck %s --check-prefix=NOEXTENTS
! RUN: %flang_fc1 -emit-llvm -O3 -mllvm -print-before=annotation2metadata -o /dev/null %s 2>&1 | FileCheck %s --check-prefix=NOEXTENTS

! EXTENTS: IR Dump Before
! EXTENTS: "array.extents"
! NOEXTENTS: IR Dump Before
! NOEXTENTS-NOT: "array.extents"

subroutine s(a, n)
  integer :: n, i, j
  real :: a(n, n)
  do j = 1, n
    do i = 1, n
      a(i, j) = 0.0
    end do
  end do
end subroutine
