//===---- Delinearization.h - MultiDimensional Index Delinearization ------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This implements an analysis pass that tries to delinearize all GEP
// instructions in all loops using the SCEV analysis functionality.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_ANALYSIS_DELINEARIZATION_H
#define LLVM_ANALYSIS_DELINEARIZATION_H

#include "llvm/IR/PassManager.h"
#include "llvm/IR/Value.h"

namespace llvm {
class raw_ostream;
template <typename T> class SmallVectorImpl;
class GetElementPtrInst;
class Instruction;
class ScalarEvolution;
class SCEV;

/// Describes whether Sizes includes every declared dimension or omits an
/// unknown outermost dimension inferred from a flattened access.
enum class DelinearizationShapeKind {
  UnknownOuterDimension,
  Complete,
};

/// Compute the array dimensions Sizes from the set of Terms extracted from
/// the memory access function of this SCEVAddRecExpr (second step of
/// delinearization).
LLVM_ABI void findArrayDimensions(ScalarEvolution &SE,
                                  SmallVectorImpl<const SCEV *> &Terms,
                                  SmallVectorImpl<const SCEV *> &Sizes,
                                  const SCEV *ElementSize);

/// Collect parametric terms occurring in step expressions (first step of
/// delinearization).
LLVM_ABI void collectParametricTerms(ScalarEvolution &SE, const SCEV *Expr,
                                     SmallVectorImpl<const SCEV *> &Terms);

/// Return in Subscripts the access functions for each dimension in Sizes
/// (third step of delinearization).
LLVM_ABI void computeAccessFunctions(ScalarEvolution &SE, const SCEV *Expr,
                                     SmallVectorImpl<const SCEV *> &Subscripts,
                                     SmallVectorImpl<const SCEV *> &Sizes);
/// Split this SCEVAddRecExpr into two vectors of SCEVs representing the
/// subscripts and sizes of an array access.
///
/// The delinearization is a 3 step process: the first two steps compute the
/// sizes of each subscript and the third step computes the access functions
/// for the delinearized array:
///
/// 1. Find the terms in the step functions
/// 2. Compute the array size
/// 3. Compute the access function: divide the SCEV by the array size
///    starting with the innermost dimensions found in step 2. The Quotient
///    is the SCEV to be divided in the next step of the recursion. The
///    Remainder is the subscript of the innermost dimension. Loop over all
///    array dimensions computed in step 2.
///
/// To compute a uniform array size for several memory accesses to the same
/// object, one can collect in step 1 all the step terms for all the memory
/// accesses, and compute in step 2 a unique array shape. This guarantees
/// that the array shape will be the same across all memory accesses.
///
/// Example:
///
/// A[][n][m]
///
/// for i
///   for j
///     for k
///       A[j+k][2i][5i] =
///
/// The initial SCEV:
///
/// A[{{{0,+,2*m+5}_i, +, n*m}_j, +, n*m}_k]
///
/// 1. Find the different terms in the step functions:
/// -> [2*m, 5, n*m, n*m]
///
/// 2. Compute the array size: sort and unique them
/// -> [n*m, 2*m, 5]
/// find the GCD of all the terms = 1
/// divide by the GCD and erase constant terms
/// -> [n*m, 2*m]
/// GCD = m
/// divide by GCD -> [n, 2]
/// remove constant terms
/// -> [n]
/// size of the array is A[unknown][n][m]
///
/// 3. Compute the access function
/// a. Divide {{{0,+,2*m+5}_i, +, n*m}_j, +, n*m}_k by the innermost size m
/// Quotient: {{{0,+,2}_i, +, n}_j, +, n}_k
/// Remainder: {{{0,+,5}_i, +, 0}_j, +, 0}_k
/// The remainder is the subscript of the innermost array dimension: [5i].
///
/// b. Divide Quotient: {{{0,+,2}_i, +, n}_j, +, n}_k by next outer size n
/// Quotient: {{{0,+,0}_i, +, 1}_j, +, 1}_k
/// Remainder: {{{0,+,2}_i, +, 0}_j, +, 0}_k
/// The Remainder is the subscript of the next array dimension: [2i].
///
/// The subscript of the outermost dimension is the Quotient: [j+k].
///
/// Overall, we have: A[][n][m], and the access function: A[j+k][2i][5i].
LLVM_ABI void delinearize(ScalarEvolution &SE, const SCEV *Expr,
                          SmallVectorImpl<const SCEV *> &Subscripts,
                          SmallVectorImpl<const SCEV *> &Sizes,
                          const SCEV *ElementSize);

/// Compute the dimensions of fixed size array from \Expr and save the results
/// in \p Sizes.
LLVM_ABI bool findFixedSizeArrayDimensions(ScalarEvolution &SE,
                                           const SCEV *Expr,
                                           SmallVectorImpl<uint64_t> &Sizes,
                                           const SCEV *ElementSize);

/// Split this SCEVAddRecExpr into two vectors of SCEVs representing the
/// subscripts and sizes of an access to a fixed size array. This is a special
/// case of delinearization for fixed size arrays.
///
/// The delinearization is a 2 step process: the first step estimates the sizes
/// of each dimension of the array. The second step computes the access
/// functions for the delinearized array:
///
/// 1. Compute the array size
/// 2. Compute the access function: same as normal delinearization
///
/// When the base object carries a complete array shape, that shape is used
/// directly and symbolic step values are supported. Otherwise, this function
/// falls back to inferring dimensions from constant step values.
///
/// \p ShapeKind reports whether all dimensions came from an explicitly
/// described shape or whether the outermost dimension remains unknown.
///
/// This function is intended to replace getIndexExpressionsFromGEP. They rely
/// on the GEP source element type so that will be removed in the future.
LLVM_ABI bool
delinearizeFixedSizeArray(ScalarEvolution &SE, const SCEV *Expr,
                          SmallVectorImpl<const SCEV *> &Subscripts,
                          SmallVectorImpl<const SCEV *> &Sizes,
                          const SCEV *ElementSize,
                          DelinearizationShapeKind &ShapeKind);

/// Check that each subscript in \p Subscripts is within the corresponding size
/// in \p Sizes. For the outermost dimension, the subscript being negative is
/// allowed when \p ShapeKind says its size is unknown. If \p CtxI is provided,
/// facts that dominate that instruction may be used to validate the
/// subscripts.
LLVM_ABI bool validateDelinearizationResult(ScalarEvolution &SE,
                                            ArrayRef<const SCEV *> Sizes,
                                            ArrayRef<const SCEV *> Subscripts,
                                            DelinearizationShapeKind ShapeKind,
                                            const Instruction *CtxI = nullptr);

/// Gathers the individual index expressions from a GEP instruction.
///
/// This function optimistically assumes the GEP references into a fixed size
/// array. If this is actually true, this function returns a list of array
/// subscript expressions in \p Subscripts and a list of SCEV expressions
/// describing the size of the individual array dimensions in \p Sizes. Both
/// lists have either equal length or the size list is one element shorter in
/// case there is no known size available for the outermost array dimension.
/// Returns true if successful and false otherwise.
LLVM_ABI bool
getIndexExpressionsFromGEP(ScalarEvolution &SE, const GetElementPtrInst *GEP,
                           SmallVectorImpl<const SCEV *> &Subscripts,
                           SmallVectorImpl<const SCEV *> &Sizes);

struct DelinearizationPrinterPass
    : public RequiredPassInfoMixin<DelinearizationPrinterPass> {
  LLVM_ABI explicit DelinearizationPrinterPass(raw_ostream &OS);
  LLVM_ABI PreservedAnalyses run(Function &F, FunctionAnalysisManager &AM);

private:
  raw_ostream &OS;
};
} // namespace llvm

#endif // LLVM_ANALYSIS_DELINEARIZATION_H
