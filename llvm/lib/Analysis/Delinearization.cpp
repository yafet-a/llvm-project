//===---- Delinearization.cpp - MultiDimensional Index Delinearization ----===//
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

#include "llvm/Analysis/Delinearization.h"
#include "AnalysisOptions.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/AssumptionCache.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/ScalarEvolution.h"
#include "llvm/Analysis/ScalarEvolutionDivision.h"
#include "llvm/Analysis/ScalarEvolutionExpressions.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/BundleAttributes.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Operator.h"
#include "llvm/IR/PassManager.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/raw_ostream.h"

using namespace llvm;

#define DL_NAME "delinearize"
#define DEBUG_TYPE DL_NAME

// Return true when S contains at least an undef value.
static inline bool containsUndefs(const SCEV *S) {
  return SCEVExprContains(S, [](const SCEV *S) {
    if (const auto *SU = dyn_cast<SCEVUnknown>(S))
      return isa<UndefValue>(SU->getValue());
    return false;
  });
}

namespace {

// Collect all steps of SCEV expressions.
struct SCEVCollectStrides {
  ScalarEvolution &SE;
  SmallVectorImpl<const SCEV *> &Strides;

  SCEVCollectStrides(ScalarEvolution &SE, SmallVectorImpl<const SCEV *> &S)
      : SE(SE), Strides(S) {}

  bool follow(const SCEV *S) {
    const SCEVAddRecExpr *AR = dyn_cast<SCEVAddRecExpr>(S);
    if (!AR || !AR->isAffine())
      return false;

    Strides.push_back(AR->getStepRecurrence(SE));
    return true;
  }

  bool isDone() const { return false; }
};

// Collect all SCEVUnknown and SCEVMulExpr expressions.
struct SCEVCollectTerms {
  SmallVectorImpl<const SCEV *> &Terms;

  SCEVCollectTerms(SmallVectorImpl<const SCEV *> &T) : Terms(T) {}

  bool follow(const SCEV *S) {
    if (isa<SCEVUnknown>(S) || isa<SCEVMulExpr>(S) ||
        isa<SCEVSignExtendExpr>(S))
      if (!containsUndefs(S))
        Terms.push_back(S);

    // Keep looking when S is a specific type expression.
    return isa<SCEVAddExpr, SCEVAddRecExpr>(S);
  }

  bool isDone() const { return false; }
};

// Check if a SCEV contains an AddRecExpr.
struct SCEVHasAddRec {
  bool &ContainsAddRec;

  SCEVHasAddRec(bool &ContainsAddRec) : ContainsAddRec(ContainsAddRec) {
    ContainsAddRec = false;
  }

  bool follow(const SCEV *S) {
    if (isa<SCEVAddRecExpr>(S)) {
      ContainsAddRec = true;

      // Stop recursion: once we collected a term, do not walk its operands.
      return false;
    }

    // Keep looking.
    return true;
  }

  bool isDone() const { return false; }
};

// Find factors that are multiplied with an expression that (possibly as a
// subexpression) contains an AddRecExpr. In the expression:
//
//  8 * (100 +  %p * %q * (%a + {0, +, 1}_loop))
//
// "%p * %q" are factors multiplied by the expression "(%a + {0, +, 1}_loop)"
// that contains the AddRec {0, +, 1}_loop. %p * %q are likely to be array size
// parameters as they form a product with an induction variable.
//
// This collector expects all array size parameters to be in the same MulExpr.
// It might be necessary to later add support for collecting parameters that are
// spread over different nested MulExpr.
struct SCEVCollectAddRecMultiplies {
  SmallVectorImpl<const SCEV *> &Terms;
  ScalarEvolution &SE;

  SCEVCollectAddRecMultiplies(SmallVectorImpl<const SCEV *> &T,
                              ScalarEvolution &SE)
      : Terms(T), SE(SE) {}

  bool follow(const SCEV *S) {
    if (auto *Mul = dyn_cast<SCEVMulExpr>(S)) {
      bool HasAddRec = false;
      SmallVector<SCEVUse, 0> Operands;
      for (const SCEV *Op : Mul->operands()) {
        const SCEVUnknown *Unknown = dyn_cast<SCEVUnknown>(Op);
        if (Unknown && !isa<CallInst>(Unknown->getValue())) {
          Operands.push_back(Op);
        } else if (Unknown) {
          HasAddRec = true;
        } else {
          bool ContainsAddRec = false;
          SCEVHasAddRec ContiansAddRec(ContainsAddRec);
          visitAll(Op, ContiansAddRec);
          HasAddRec |= ContainsAddRec;
        }
      }
      if (Operands.size() == 0)
        return true;

      if (!HasAddRec)
        return false;

      Terms.push_back(SE.getMulExpr(Operands));
    }

    // Keep looking when S is a specific type expression.
    return isa<SCEVAddExpr, SCEVAddRecExpr>(S);
  }

  bool isDone() const { return false; }
};

/// The shape stated by the array.extents and array.strides bundles that
/// describe one access, with extents and strides ordered from the fastest- to
/// the slowest-varying dimension.
struct ArrayAccessContract {
  Value *BaseValue = nullptr;
  const SCEV *Base = nullptr;
  SmallVector<const SCEV *, 4> Extents;
  SmallVector<const SCEV *, 4> Strides;
};

} // end anonymous namespace

/// Return whether \p SrcContract and \p DstContract prove that \p Src and
/// \p Dst address disjoint constant-offset subobjects of one allocation.
static bool areDisjointSubobjects(ScalarEvolution &SE, Instruction *Src,
                                  Instruction *Dst,
                                  const ArrayAccessContract &SrcContract,
                                  const ArrayAccessContract &DstContract) {
  if (!SrcContract.BaseValue || !DstContract.BaseValue ||
      SrcContract.BaseValue == DstContract.BaseValue ||
      !SrcContract.Strides.empty() || !DstContract.Strides.empty())
    return false;

  const SCEV *SrcElementSize = SE.getElementSize(Src);
  const SCEV *DstElementSize = SE.getElementSize(Dst);
  if (SrcElementSize != DstElementSize)
    return false;

  auto GetByteSize = [](const ArrayAccessContract &Contract,
                        const SCEV *ElementSize) -> std::optional<APInt> {
    const auto *ElementSizeC = dyn_cast<SCEVConstant>(ElementSize);
    if (!ElementSizeC || ElementSizeC->getAPInt().isZero() ||
        ElementSizeC->getAPInt().isNegative())
      return std::nullopt;
    APInt Size = ElementSizeC->getAPInt();
    for (const SCEV *Extent : Contract.Extents) {
      const auto *ExtentC = dyn_cast<SCEVConstant>(Extent);
      if (!ExtentC || ExtentC->getAPInt().isZero() ||
          ExtentC->getAPInt().isNegative())
        return std::nullopt;
      bool Overflow;
      Size = Size.umul_ov(ExtentC->getAPInt(), Overflow);
      if (Overflow || Size.isNegative())
        return std::nullopt;
    }
    return Size;
  };

  std::optional<APInt> SrcSize = GetByteSize(SrcContract, SrcElementSize);
  std::optional<APInt> DstSize = GetByteSize(DstContract, DstElementSize);
  if (!SrcSize || !DstSize)
    return false;

  const DataLayout &DL = Src->getModule()->getDataLayout();
  unsigned OffsetBitWidth =
      DL.getIndexTypeSizeInBits(SrcContract.BaseValue->getType());
  APInt SrcOffset(OffsetBitWidth, 0);
  APInt DstOffset(OffsetBitWidth, 0);
  const Value *SrcRoot =
      SrcContract.BaseValue->stripAndAccumulateConstantOffsets(
          DL, SrcOffset, /*AllowNonInbounds=*/false);
  const Value *DstRoot =
      DstContract.BaseValue->stripAndAccumulateConstantOffsets(
          DL, DstOffset, /*AllowNonInbounds=*/false);
  if (SrcRoot != DstRoot || SrcSize->getActiveBits() >= OffsetBitWidth ||
      DstSize->getActiveBits() >= OffsetBitWidth)
    return false;

  bool SrcOverflow;
  bool DstOverflow;
  APInt SrcEnd =
      SrcOffset.sadd_ov(SrcSize->zextOrTrunc(OffsetBitWidth), SrcOverflow);
  APInt DstEnd =
      DstOffset.sadd_ov(DstSize->zextOrTrunc(OffsetBitWidth), DstOverflow);
  return !SrcOverflow && !DstOverflow &&
         (SrcEnd.sle(DstOffset) || DstEnd.sle(SrcOffset));
}

/// Find parametric terms in this SCEVAddRecExpr. We first for parameters in
/// two places:
///   1) The strides of AddRec expressions.
///   2) Unknowns that are multiplied with AddRec expressions.
void llvm::collectParametricTerms(ScalarEvolution &SE, const SCEV *Expr,
                                  SmallVectorImpl<const SCEV *> &Terms) {
  SmallVector<const SCEV *, 4> Strides;
  SCEVCollectStrides StrideCollector(SE, Strides);
  visitAll(Expr, StrideCollector);

  LLVM_DEBUG({
    dbgs() << "Strides:\n";
    for (const SCEV *S : Strides)
      dbgs().indent(2) << *S << "\n";
  });

  for (const SCEV *S : Strides) {
    SCEVCollectTerms TermCollector(Terms);
    visitAll(S, TermCollector);
  }

  LLVM_DEBUG({
    dbgs() << "Terms:\n";
    for (const SCEV *T : Terms)
      dbgs().indent(2) << *T << "\n";
  });

  SCEVCollectAddRecMultiplies MulCollector(Terms, SE);
  visitAll(Expr, MulCollector);
}

static bool findArrayDimensionsRec(ScalarEvolution &SE,
                                   SmallVectorImpl<const SCEV *> &Terms,
                                   SmallVectorImpl<const SCEV *> &Sizes) {
  int Last = Terms.size() - 1;
  const SCEV *Step = Terms[Last];

  // End of recursion.
  if (Last == 0) {
    if (const SCEVMulExpr *M = dyn_cast<SCEVMulExpr>(Step)) {
      SmallVector<SCEVUse, 2> Qs;
      for (const SCEV *Op : M->operands())
        if (!isa<SCEVConstant>(Op))
          Qs.push_back(Op);

      Step = SE.getMulExpr(Qs);
    }

    Sizes.push_back(Step);
    return true;
  }

  for (const SCEV *&Term : Terms) {
    // Normalize the terms before the next call to findArrayDimensionsRec.
    const SCEV *Q, *R;
    SCEVDivision::divide(SE, Term, Step, &Q, &R);

    // Bail out when GCD does not evenly divide one of the terms.
    if (!R->isZero())
      return false;

    Term = Q;
  }

  // Remove all SCEVConstants.
  erase_if(Terms, [](const SCEV *E) { return isa<SCEVConstant>(E); });

  if (Terms.size() > 0)
    if (!findArrayDimensionsRec(SE, Terms, Sizes))
      return false;

  Sizes.push_back(Step);
  return true;
}

// Returns true when one of the SCEVs of Terms contains a SCEVUnknown parameter.
static inline bool containsParameters(SmallVectorImpl<const SCEV *> &Terms) {
  for (const SCEV *T : Terms)
    if (SCEVExprContains(T, [](const SCEV *S) { return isa<SCEVUnknown>(S); }))
      return true;

  return false;
}

// Return the number of product terms in S.
static inline int numberOfTerms(const SCEV *S) {
  if (const SCEVMulExpr *Expr = dyn_cast<SCEVMulExpr>(S))
    return Expr->getNumOperands();
  return 1;
}

static const SCEV *removeConstantFactors(ScalarEvolution &SE, const SCEV *T) {
  if (isa<SCEVConstant>(T))
    return nullptr;

  if (isa<SCEVUnknown>(T))
    return T;

  if (const SCEVMulExpr *M = dyn_cast<SCEVMulExpr>(T)) {
    SmallVector<SCEVUse, 2> Factors;
    for (const SCEV *Op : M->operands())
      if (!isa<SCEVConstant>(Op))
        Factors.push_back(Op);

    return SE.getMulExpr(Factors);
  }

  return T;
}

void llvm::findArrayDimensions(ScalarEvolution &SE,
                               SmallVectorImpl<const SCEV *> &Terms,
                               SmallVectorImpl<const SCEV *> &Sizes,
                               const SCEV *ElementSize) {
  if (Terms.size() < 1 || !ElementSize)
    return;

  // Early return when Terms do not contain parameters: we do not delinearize
  // non parametric SCEVs.
  if (!containsParameters(Terms))
    return;

  LLVM_DEBUG({
    dbgs() << "Terms:\n";
    for (const SCEV *T : Terms)
      dbgs().indent(2) << *T << "\n";
  });

  // Remove duplicates.
  array_pod_sort(Terms.begin(), Terms.end());
  Terms.erase(llvm::unique(Terms), Terms.end());

  // Put larger terms first.
  llvm::sort(Terms, [](const SCEV *LHS, const SCEV *RHS) {
    return numberOfTerms(LHS) > numberOfTerms(RHS);
  });

  // Try to divide all terms by the element size. If term is not divisible by
  // element size, proceed with the original term.
  for (const SCEV *&Term : Terms) {
    const SCEV *Q, *R;
    SCEVDivision::divide(SE, Term, ElementSize, &Q, &R);
    if (!Q->isZero())
      Term = Q;
  }

  SmallVector<const SCEV *, 4> NewTerms;

  // Remove constant factors.
  for (const SCEV *T : Terms)
    if (const SCEV *NewT = removeConstantFactors(SE, T))
      NewTerms.push_back(NewT);

  LLVM_DEBUG({
    dbgs() << "Terms after sorting:\n";
    for (const SCEV *T : NewTerms)
      dbgs().indent(2) << *T << "\n";
  });

  if (NewTerms.empty() || !findArrayDimensionsRec(SE, NewTerms, Sizes)) {
    Sizes.clear();
    return;
  }

  // The last element to be pushed into Sizes is the size of an element.
  Sizes.push_back(ElementSize);

  LLVM_DEBUG({
    dbgs() << "Sizes:\n";
    for (const SCEV *S : Sizes)
      dbgs().indent(2) << *S << "\n";
  });
}

void llvm::computeAccessFunctions(ScalarEvolution &SE, const SCEV *Expr,
                                  SmallVectorImpl<const SCEV *> &Subscripts,
                                  SmallVectorImpl<const SCEV *> &Sizes) {
  // Early exit in case this SCEV is not an affine multivariate function.
  if (Sizes.empty())
    return;

  if (auto *AR = dyn_cast<SCEVAddRecExpr>(Expr))
    if (!AR->isAffine())
      return;

  // Clear output vector.
  Subscripts.clear();

  LLVM_DEBUG(dbgs() << "\ncomputeAccessFunctions\n"
                    << "Memory Access Function: " << *Expr << "\n");

  const SCEV *Res = Expr;
  int Last = Sizes.size() - 1;

  for (int i = Last; i >= 0; i--) {
    const SCEV *Size = Sizes[i];
    const SCEV *Q, *R;

    SCEVDivision::divide(SE, Res, Size, &Q, &R);

    LLVM_DEBUG({
      dbgs() << "Computing 'MemAccFn / Sizes[" << i << "]':\n";
      dbgs() << "  MemAccFn: " << *Res << "\n";
      dbgs() << "  Sizes[" << i << "]: " << *Size << "\n";
      dbgs() << "  Quotient (Leftover): " << *Q << "\n";
      dbgs() << "  Remainder (Subscript Access Function): " << *R << "\n";
    });

    Res = Q;

    // Do not record the last subscript corresponding to the size of elements in
    // the array.
    if (i == Last) {

      // Bail out if the byte offset is non-zero.
      if (!R->isZero()) {
        Subscripts.clear();
        Sizes.clear();
        return;
      }

      continue;
    }

    // Record the access function for the current subscript.
    Subscripts.push_back(R);
  }

  if (!Res->isZero()) {
    // This is only needed when the outermost array size is not known.  Res = 0
    // when the outermost array dimension is known, as for example when reading
    // array sizes from a local or global declaration.
    Subscripts.push_back(Res);
    LLVM_DEBUG(dbgs() << "Subscripts push_back Res: " << *Res << "\n");
  }

  std::reverse(Subscripts.begin(), Subscripts.end());

  LLVM_DEBUG({
    dbgs() << "Subscripts:\n";
    for (const SCEV *S : Subscripts)
      dbgs().indent(2) << *S << "\n";
    dbgs() << "\n";
  });
}

/// Splits the SCEV into two vectors of SCEVs representing the subscripts and
/// sizes of an array access. Returns the remainder of the delinearization that
/// is the offset start of the array.  The SCEV->delinearize algorithm computes
/// the multiples of SCEV coefficients: that is a pattern matching of sub
/// expressions in the stride and base of a SCEV corresponding to the
/// computation of a GCD (greatest common divisor) of base and stride.  When
/// SCEV->delinearize fails, it returns the SCEV unchanged.
///
/// For example: when analyzing the memory access A[i][j][k] in this loop nest
///
///  void foo(long n, long m, long o, double A[n][m][o]) {
///
///    for (long i = 0; i < n; i++)
///      for (long j = 0; j < m; j++)
///        for (long k = 0; k < o; k++)
///          A[i][j][k] = 1.0;
///  }
///
/// the delinearization input is the following AddRec SCEV:
///
///  AddRec: {{{%A,+,(8 * %m * %o)}<%for.i>,+,(8 * %o)}<%for.j>,+,8}<%for.k>
///
/// From this SCEV, we are able to say that the base offset of the access is %A
/// because it appears as an offset that does not divide any of the strides in
/// the loops:
///
///  CHECK: Base offset: %A
///
/// and then SCEV->delinearize determines the size of some of the dimensions of
/// the array as these are the multiples by which the strides are happening:
///
///  CHECK: ArrayDecl[UnknownSize][%m][%o] with elements of sizeof(double)
///  bytes.
///
/// Note that the outermost dimension remains of UnknownSize because there are
/// no strides that would help identifying the size of the last dimension: when
/// the array has been statically allocated, one could compute the size of that
/// dimension by dividing the overall size of the array by the size of the known
/// dimensions: %m * %o * 8.
///
/// Finally delinearize provides the access functions for the array reference
/// that does correspond to A[i][j][k] of the above C testcase:
///
///  CHECK: ArrayRef[{0,+,1}<%for.i>][{0,+,1}<%for.j>][{0,+,1}<%for.k>]
///
/// The testcases are checking the output of a function pass:
/// DelinearizationPass that walks through all loads and stores of a function
/// asking for the SCEV of the memory access with respect to all enclosing
/// loops, calling SCEV->delinearize on that and printing the results.
void llvm::delinearize(ScalarEvolution &SE, const SCEV *Expr,
                       SmallVectorImpl<const SCEV *> &Subscripts,
                       SmallVectorImpl<const SCEV *> &Sizes,
                       const SCEV *ElementSize) {
  // Clear output vectors.
  Subscripts.clear();
  Sizes.clear();

  // First step: collect parametric terms.
  SmallVector<const SCEV *, 4> Terms;
  collectParametricTerms(SE, Expr, Terms);

  if (Terms.empty())
    return;

  // Second step: find subscript sizes.
  findArrayDimensions(SE, Terms, Sizes, ElementSize);

  if (Sizes.empty())
    return;

  // Third step: compute the access functions for each subscript.
  computeAccessFunctions(SE, Expr, Subscripts, Sizes);
}

static std::optional<APInt> tryIntoAPInt(const SCEV *S) {
  if (const auto *Const = dyn_cast<SCEVConstant>(S))
    return Const->getAPInt();
  return std::nullopt;
}

/// Collects the absolute values of constant steps for all induction variables.
/// Returns true if we can prove that all step recurrences are constants and \p
/// Expr is divisible by \p ElementSize. Each step recurrence is stored in \p
/// Steps after divided by \p ElementSize.
static bool collectConstantAbsSteps(ScalarEvolution &SE, const SCEV *Expr,
                                    SmallVectorImpl<uint64_t> &Steps,
                                    uint64_t ElementSize) {
  // End of recursion. The value must be aligned to ElementSize. Permit a
  // dynamic start only after recovering at least two dimensions; this avoids
  // treating an arbitrary one-dimensional expression as an array shape.
  if (const auto *Const = dyn_cast<SCEVConstant>(Expr))
    return Const->getAPInt().urem(ElementSize) == 0;

  const SCEVAddRecExpr *AR = dyn_cast<SCEVAddRecExpr>(Expr);
  if (!AR)
    return Steps.size() >= 2 && SE.isKnownMultipleOf(Expr, ElementSize);
  if (!AR->isAffine())
    return false;

  const SCEV *Step = AR->getStepRecurrence(SE);
  std::optional<APInt> StepAPInt = tryIntoAPInt(Step);
  if (!StepAPInt)
    return false;

  APInt Q;
  uint64_t R;
  APInt::udivrem(StepAPInt->abs(), ElementSize, Q, R);
  if (R != 0)
    return false;

  // Bail out when the step is too large.
  std::optional<uint64_t> StepVal = Q.tryZExtValue();
  if (!StepVal)
    return false;

  Steps.push_back(*StepVal);
  return collectConstantAbsSteps(SE, AR->getStart(), Steps, ElementSize);
}

bool llvm::findFixedSizeArrayDimensions(ScalarEvolution &SE, const SCEV *Expr,
                                        SmallVectorImpl<uint64_t> &Sizes,
                                        const SCEV *ElementSize) {
  if (!ElementSize)
    return false;

  std::optional<APInt> ElementSizeAPInt = tryIntoAPInt(ElementSize);
  if (!ElementSizeAPInt || *ElementSizeAPInt == 0)
    return false;

  std::optional<uint64_t> ElementSizeConst = ElementSizeAPInt->tryZExtValue();

  // Early exit when ElementSize is not a positive constant.
  if (!ElementSizeConst)
    return false;

  if (!collectConstantAbsSteps(SE, Expr, Sizes, *ElementSizeConst) ||
      Sizes.empty()) {
    Sizes.clear();
    return false;
  }

  // At this point, Sizes contains the absolute step recurrences for all
  // induction variables. Each step recurrence must be a multiple of the size of
  // the array element. Assuming that the each value represents the size of an
  // array for each dimension, attempts to restore the length of each dimension
  // by dividing the step recurrence by the next smaller value. For example, if
  // we have the following AddRec SCEV:
  //
  //   AddRec: {{{0,+,2048}<%for.i>,+,256}<%for.j>,+,8}<%for.k> (ElementSize=8)
  //
  // Then Sizes will become [256, 32, 1] after sorted. We don't know the size of
  // the outermost dimension, the next dimension will be computed as 256 / 32 =
  // 8, and the last dimension will be computed as 32 / 1 = 32. Thus it results
  // in like Arr[UnknownSize][8][32] with elements of size 8 bytes, where Arr is
  // a base pointer.
  //
  // TODO: Catch more cases, e.g., when a step recurrence is not divisible by
  // the next smaller one, like A[i][3*j].
  llvm::sort(Sizes.rbegin(), Sizes.rend());
  Sizes.erase(llvm::unique(Sizes), Sizes.end());

  // The last element in Sizes should be ElementSize. At this point, all values
  // in Sizes are assumed to be divided by ElementSize, so replace it with 1.
  assert(Sizes.back() != 0 && "Unexpected zero size in Sizes.");
  Sizes.back() = 1;

  for (unsigned I = 0; I + 1 < Sizes.size(); I++) {
    uint64_t PrevSize = Sizes[I + 1];
    if (Sizes[I] % PrevSize) {
      Sizes.clear();
      return false;
    }
    Sizes[I] /= PrevSize;
  }

  // Finally, the last element in Sizes should be ElementSize.
  Sizes.back() = *ElementSizeConst;
  return true;
}

/// Decode the side-band array contract that is valid at \p CtxI. Descriptor
/// strides are in bytes, fastest-varying dimension first. Delinearization's
/// mixed-radix representation is applicable only when those strides describe
/// a contiguous array; reject other descriptors instead of treating extents
/// as implicit strides.
static bool extractArrayAccessContract(ScalarEvolution &SE, Value *BasePtr,
                                       ArrayAccessContract &Contract,
                                       const SCEV *ElementSize,
                                       const Instruction *CtxI) {
  if (!CtxI)
    return false;

  const Value *AccessPtr = getLoadStorePointerOperand(CtxI);
  if (!AccessPtr)
    return false;
  const Value *CanonicalAccess = AccessPtr->stripPointerCasts();
  SmallVector<const Value *, 2> AccessKeys{AccessPtr};
  if (CanonicalAccess != AccessPtr)
    AccessKeys.push_back(CanonicalAccess);

  ArrayAccessContract Selected;
  bool Found = false;
  for (const Value *AccessKey : AccessKeys) {
    for (AssumptionCache::ResultElem Elem :
         SE.getAssumptionCache().assumptionsFor(AccessKey)) {
      auto *Assume = dyn_cast_or_null<AssumeInst>(Elem.Assume);
      if (!Assume || Elem.Index == AssumptionCache::ExprResultIdx ||
          Elem.Index >= Assume->getNumOperandBundles() ||
          getBundleAttrFromOBU(Assume->getOperandBundleAt(Elem.Index)) !=
              BundleAttr::ArrayExtents ||
          !SE.getDominatorTree().dominates(Assume, CtxI))
        continue;

      auto [DeclaredAccess, Base, Extents] =
          getAssumeArrayExtentsInfo(Assume->getOperandBundleAt(Elem.Index));
      if (DeclaredAccess.get() != AccessPtr &&
          DeclaredAccess->stripPointerCasts() != CanonicalAccess)
        continue;

      // SCEV reduces a COMMON-block subobject to the enclosing global. Select
      // the contract by its scoped access first, then ensure its declared base
      // still belongs to the same allocation.
      if (getUnderlyingObject(Base.get()) != getUnderlyingObject(BasePtr))
        continue;

      ArrayAccessContract Candidate;
      Candidate.BaseValue = Base.get();
      Candidate.Base = SE.getSCEV(Base.get());
      Candidate.Extents.reserve(Extents.size());
      for (const Use &Extent : Extents)
        Candidate.Extents.push_back(SE.getTruncateOrZeroExtend(
            SE.getSCEV(Extent.get()), ElementSize->getType()));

      for (OperandBundleUse Bundle : Assume->operand_bundles()) {
        if (getBundleAttrFromOBU(Bundle) != BundleAttr::ArrayStrides ||
            Bundle.Inputs[0].get() != DeclaredAccess.get())
          continue;
        ArrayRef<Use> Strides = getAssumeArrayStridesInfo(Bundle).Strides;
        Candidate.Strides.reserve(Strides.size());
        for (const Use &Stride : Strides)
          Candidate.Strides.push_back(SE.getTruncateOrZeroExtend(
              SE.getSCEV(Stride.get()), ElementSize->getType()));
        break;
      }
      if (!Candidate.Strides.empty() &&
          Candidate.Strides.size() != Candidate.Extents.size())
        continue;

      if (!Found) {
        Selected = std::move(Candidate);
        Found = true;
      } else if (Selected.Base != Candidate.Base ||
                 Selected.Extents != Candidate.Extents ||
                 Selected.Strides != Candidate.Strides) {
        LLVM_DEBUG(
            dbgs() << "Conflicting dominating array.extents carriers for "
                   << *AccessPtr << "\n");
        return false;
      }
    }
  }

  if (!Found)
    return false;

  if (!Selected.Strides.empty()) {
    const SCEV *ExpectedStride = ElementSize;
    for (auto [Extent, Stride] :
         llvm::zip_equal(Selected.Extents, Selected.Strides)) {
      if (Stride != ExpectedStride &&
          !SE.isKnownPredicateAt(ICmpInst::ICMP_EQ, Stride, ExpectedStride,
                                 CtxI)) {
        LLVM_DEBUG(dbgs() << "array.strides does not describe a contiguous "
                             "mixed-radix array for "
                          << *BasePtr << "\n");
        return false;
      }
      ExpectedStride = SE.getMulExpr(ExpectedStride, Extent);
    }
  }

  Contract = std::move(Selected);
  return true;
}

bool llvm::arrayExtentsProveDisjoint(ScalarEvolution &SE, Instruction *Src,
                                     Instruction *Dst) {
  const Value *SrcPtr = getLoadStorePointerOperand(Src);
  const Value *DstPtr = getLoadStorePointerOperand(Dst);
  if (!SrcPtr || !DstPtr)
    return false;

  const auto *SrcAllocation = dyn_cast<SCEVUnknown>(
      SE.getPointerBase(SE.getSCEV(const_cast<Value *>(SrcPtr))));
  const auto *DstAllocation = dyn_cast<SCEVUnknown>(
      SE.getPointerBase(SE.getSCEV(const_cast<Value *>(DstPtr))));
  const SCEV *SrcElementSize = SE.getElementSize(Src);
  const SCEV *DstElementSize = SE.getElementSize(Dst);
  if (!SrcAllocation || !DstAllocation ||
      SrcAllocation->getValue() != DstAllocation->getValue() ||
      SrcElementSize != DstElementSize)
    return false;

  ArrayAccessContract SrcContract;
  ArrayAccessContract DstContract;
  if (!extractArrayAccessContract(SE, SrcAllocation->getValue(), SrcContract,
                                  SrcElementSize, Src) ||
      !extractArrayAccessContract(SE, DstAllocation->getValue(), DstContract,
                                  DstElementSize, Dst))
    return false;

  return areDisjointSubobjects(SE, Src, Dst, SrcContract, DstContract);
}

bool llvm::arrayExtentsDescribeDelinearization(ScalarEvolution &SE,
                                               const SCEV *Expr,
                                               ArrayRef<const SCEV *> Sizes,
                                               const SCEV *ElementSize,
                                               const Instruction *CtxI) {
  if (Sizes.empty() || Sizes.back() != ElementSize)
    return false;

  const auto *BasePointer = dyn_cast<SCEVUnknown>(SE.getPointerBase(Expr));
  if (!BasePointer)
    return false;

  ArrayAccessContract Contract;
  if (!extractArrayAccessContract(SE, BasePointer->getValue(), Contract,
                                  ElementSize, CtxI) ||
      Sizes.size() != Contract.Extents.size())
    return false;

  // Delinearization orders dimensions in the opposite direction, omits the
  // slowest-varying extent and appends the element size.
  size_t ComparedExtents = Contract.Extents.size() - 1;
  for (size_t I = 0; I != ComparedExtents; ++I) {
    const SCEV *Declared = Contract.Extents[ComparedExtents - 1 - I];
    if (Sizes[I] != Declared &&
        !SE.isKnownPredicateAt(ICmpInst::ICMP_EQ, Sizes[I], Declared, CtxI))
      return false;
  }
  return true;
}

/// Splits the SCEV into two vectors of SCEVs representing the subscripts and
/// sizes of an array access, assuming that the array is a fixed size array.
///
/// E.g., if we have the code like as follows:
///
///  double A[42][8][32];
///  for i
///    for j
///      for k
///        use A[i][j][k]
///
/// The access function will be represented as an AddRec SCEV like:
///
///  AddRec: {{{0,+,2048}<%for.i>,+,256}<%for.j>,+,8}<%for.k> (ElementSize=8)
///
/// Then findFixedSizeArrayDimensions infers the size of each dimension of the
/// array based on the fact that the value of the step recurrence is a multiple
/// of the size of the corresponding array element. In the above example, it
/// results in the following:
///
///  CHECK: ArrayDecl[UnknownSize][8][32] with elements of 8 bytes.
///
/// Finally each subscript will be computed as follows:
///
///  CHECK: ArrayRef[{0,+,1}<%for.i>][{0,+,1}<%for.j>][{0,+,1}<%for.k>]
///
/// Note that this function doesn't check the range of possible values for each
/// subscript, so the caller should perform additional boundary checks if
/// necessary.
///
/// Also note that this function doesn't guarantee that the original array size
/// is restored "correctly". For example, in the following case:
///
///  double A[42][4][64];
///  double B[42][8][32];
///  for i
///    for j
///      for k
///        use A[i][j][k]
///        use B[i][2*j][k]
///
/// The access function for both accesses will be the same:
///
///  AddRec: {{{0,+,2048}<%for.i>,+,512}<%for.j>,+,8}<%for.k> (ElementSize=8)
///
/// The array sizes for both A and B will be computed as
/// ArrayDecl[UnknownSize][4][64], which matches for A, but not for B.
///
/// TODO: At the moment, this function can handle only simple cases. For
/// example, we cannot handle a case where a step recurrence is not divisible
/// by the next smaller step recurrence, e.g., A[i][3*j].
bool llvm::delinearizeFixedSizeArray(ScalarEvolution &SE, const SCEV *Expr,
                                     SmallVectorImpl<const SCEV *> &Subscripts,
                                     SmallVectorImpl<const SCEV *> &Sizes,
                                     const SCEV *ElementSize,
                                     DelinearizationShapeKind &ShapeKind,
                                     const Instruction *CtxI,
                                     bool *UsesArrayExtents) {
  // Clear output vectors.
  Subscripts.clear();
  Sizes.clear();
  ShapeKind = DelinearizationShapeKind::UnknownOuterDimension;
  if (UsesArrayExtents)
    *UsesArrayExtents = false;

  const SCEVUnknown *BasePointer =
      dyn_cast<SCEVUnknown>(SE.getPointerBase(Expr));
  const SCEV *Offset = BasePointer ? SE.getMinusSCEV(Expr, BasePointer) : Expr;

  // SCEV canonicalizes a COMMON-block subobject pointer to the enclosing
  // allocation. Recover the offset from the access-scoped array base so the
  // constant subobject displacement does not obscure the mixed-radix shape.
  ArrayAccessContract ScopedContract;
  bool HasScopedContract =
      BasePointer &&
      extractArrayAccessContract(SE, BasePointer->getValue(), ScopedContract,
                                 ElementSize, CtxI);
  if (HasScopedContract)
    Offset = SE.getMinusSCEV(Expr, ScopedContract.Base);

  // An exact access-scoped contract supplies the declared physical shape.
  // Prefer that shape when the source subscript is itself linearized, for
  // example A(N * I + J, N * K + L). Inferring dimensions from recurrence
  // strides would recover the logical radix N instead of A's physical
  // dimensions. This only establishes a faithful delinearization; dependence
  // analysis must still prove that each recovered subscript is injective in
  // the loops it uses.
  if (HasScopedContract) {
    SmallVector<const SCEV *, 4> ContractSizes;
    ContractSizes.append(ScopedContract.Extents.rbegin(),
                         ScopedContract.Extents.rend());
    ContractSizes.push_back(ElementSize);

    SmallVector<const SCEV *, 4> ContractSubscripts;
    computeAccessFunctions(SE, Offset, ContractSubscripts, ContractSizes);
    if (ContractSubscripts.size() == ScopedContract.Extents.size()) {
      Sizes.assign(ContractSizes.begin(), ContractSizes.end());
      Subscripts.assign(ContractSubscripts.begin(), ContractSubscripts.end());
      ShapeKind = DelinearizationShapeKind::Complete;
      if (UsesArrayExtents)
        *UsesArrayExtents = true;
      return true;
    }
  }

  LLVM_DEBUG(dbgs() << "delinearizeFixedSizeArray, analysing expr: ";
             Expr->dump(););

  // Infer the mixed-radix shape from the access expression. A carrier may
  // validate this recovered shape, but must not define it: doing so would
  // infer injectivity merely from an in-range assertion.
  SmallVector<uint64_t, 4> ConstSizes;
  if (!findFixedSizeArrayDimensions(SE, Offset, ConstSizes, ElementSize)) {
    Sizes.clear();
    return false;
  }

  // Convert the constant size to SCEV.
  for (uint64_t Size : ConstSizes)
    Sizes.push_back(SE.getConstant(Offset->getType(), Size));

  // Second step: compute the access functions for each subscript.
  computeAccessFunctions(SE, Offset, Subscripts, Sizes);

  bool HasMatchingArrayExtents =
      arrayExtentsDescribeDelinearization(SE, Expr, Sizes, ElementSize, CtxI);
  if (HasMatchingArrayExtents) {
    if (UsesArrayExtents)
      *UsesArrayExtents = true;
  }

  return !Subscripts.empty();
}

static bool isKnownInRange(ScalarEvolution &SE, const SCEV *Subscript,
                           const SCEV *Size, const Instruction *CtxI) {
  Type *WiderTy = SE.getWiderType(Subscript->getType(), Size->getType());
  Subscript = SE.getNoopOrSignExtend(Subscript, WiderTy);
  Size = SE.getNoopOrSignExtend(Size, WiderTy);

  auto IsKnownPredicate = [&](CmpPredicate Pred, const SCEV *LHS,
                              const SCEV *RHS) {
    return CtxI ? SE.isKnownPredicateAt(Pred, LHS, RHS, CtxI)
                : SE.isKnownPredicate(Pred, LHS, RHS);
  };

  const SCEV *Zero = SE.getZero(WiderTy);
  if (IsKnownPredicate(ICmpInst::ICMP_SGE, Subscript, Zero) &&
      IsKnownPredicate(ICmpInst::ICMP_SLT, Subscript, Size))
    return true;
  return IsKnownPredicate(ICmpInst::ICMP_SGT, Size, Zero) &&
         IsKnownPredicate(ICmpInst::ICMP_ULT, Subscript, Size);
}

bool llvm::validateDelinearizationResult(ScalarEvolution &SE,
                                         ArrayRef<const SCEV *> Sizes,
                                         ArrayRef<const SCEV *> Subscripts,
                                         DelinearizationShapeKind ShapeKind,
                                         const Instruction *CtxI,
                                         bool SubscriptsInRange) {
  // With an unknown outer dimension there is one size per subscript. When an
  // array.extents contract states the complete array shape, Sizes
  // additionally contains the known outer dimension.
  bool HasKnownOuterDimension = ShapeKind == DelinearizationShapeKind::Complete;
  size_t ExpectedSizeCount =
      Subscripts.size() + (HasKnownOuterDimension ? 1 : 0);
  if (Sizes.size() != ExpectedSizeCount || Subscripts.empty()) {
    LLVM_DEBUG(dbgs() << "Delinearization validation failed: incompatible "
                         "size and subscript counts\n");
    return false;
  }

  // Sizes and Subscripts are as follows:
  //
  //   Sizes:      [UNK][S_2]...[S_n]
  //   Subscripts: [I_1][I_2]...[I_n]
  //
  // where the size of the outermost dimension is unknown (UNK).

  auto AddOverflow = [&](const SCEV *A, const SCEV *B) -> const SCEV * {
    if (!SE.willNotOverflow(Instruction::Add, /*IsSigned=*/true, A, B, CtxI))
      return nullptr;
    return SE.getAddExpr(A, B);
  };

  auto MulOverflow = [&](const SCEV *A, const SCEV *B) -> const SCEV * {
    if (!SE.willNotOverflow(Instruction::Mul, /*IsSigned=*/true, A, B, CtxI))
      return nullptr;
    return SE.getMulExpr(A, B);
  };

  auto IsKnownPredicate = [&](CmpPredicate Pred, const SCEV *LHS,
                              const SCEV *RHS) {
    return CtxI ? SE.isKnownPredicateAt(Pred, LHS, RHS, CtxI)
                : SE.isKnownPredicate(Pred, LHS, RHS);
  };

  // Range check all dimensions whose sizes are known. Skip I_1 when the
  // outermost dimension is unknown.
  size_t FirstSubscript = HasKnownOuterDimension ? 0 : 1;
  for (size_t I = FirstSubscript; I < Subscripts.size(); ++I) {
    const SCEV *Size = Sizes[HasKnownOuterDimension ? I : I - 1];
    const SCEV *Subscript = Subscripts[I];

    if (!SubscriptsInRange && !isKnownInRange(SE, Subscript, Size, CtxI)) {
      LLVM_DEBUG(dbgs() << "Range check failed: could not prove 0 <= "
                        << *Subscript << " < " << *Size << "\n");
      return false;
    }
  }

  // A matching array.extents bundle establishes every source subscript range of
  // a validly allocated array. The byte offset of an in-range access then lies
  // inside the object, so the linearization is injective by construction and
  // there is no overflow left to rule out. Rebuilding that argument from the
  // IR fails for runtime extents, and the GEP no-wrap flags it could rely on
  // are routinely dropped by earlier passes.
  if (SubscriptsInRange)
    return true;

  // A complete shape is only trusted together with the contract that states
  // it; the reasoning below assumes an unknown outermost dimension.
  if (HasKnownOuterDimension)
    return false;

  // The offset computation is as follows:
  //
  //   Offset = I_n +
  //            S_n * I_{n-1} +
  //            ... +
  //            (S_2 * ... * S_n) * I_1
  //
  // Regarding this as a function from (I_1, I_2, ..., I_n) to integers, it
  // must be injective. To guarantee it, the above calculation must not
  // overflow. Since we have already checked that 0 <= I_k < S_k for k = 2..n,
  // the minimum and maximum values occur in the following cases:
  //
  //   Min = [I_1][0]...[0] = S_2 * ... * S_n * I_1
  //   Max = [I_1][S_2-1]...[S_n-1]
  //       = (S_2 * ... * S_n) * I_1 +
  //         (S_2 * ... * S_{n-1}) * (S_2 - 1) +
  //         ... +
  //         (S_n - 1)
  //       = (S_2 * ... * S_n) * I_1 +
  //         (S_2 * ... * S_n) - 1  (can be proven by induction)
  //       = Min + (S_2 * ... * S_n) - 1
  //
  // NOTE: I_1 can be negative, so Min is not just 0.
  const SCEV *Prod = SE.getOne(Sizes[0]->getType());
  for (const SCEV *Size : Sizes) {
    Prod = MulOverflow(Prod, Size);
    if (!Prod) {
      LLVM_DEBUG(dbgs() << "Delinearization validation failed: dimension "
                           "product may overflow\n");
      return false;
    }
  }
  const SCEV *Min = MulOverflow(Prod, Subscripts[0]);
  if (!Min) {
    LLVM_DEBUG(dbgs() << "Delinearization validation failed: minimum offset "
                         "may overflow\n");
    return false;
  }

  // We have already checked that Min and Prod don't overflow, so it's enough
  // to check whether Min + Prod - 1 doesn't overflow.
  const SCEV *MaxPlusOne = AddOverflow(Min, Prod);
  if (!MaxPlusOne) {
    LLVM_DEBUG(dbgs() << "Delinearization validation failed: maximum offset "
                         "may overflow\n");
    return false;
  }
  if (!SE.willNotOverflow(Instruction::Sub, /*IsSigned=*/true, MaxPlusOne,
                          SE.getOne(MaxPlusOne->getType()), CtxI)) {
    LLVM_DEBUG(dbgs() << "Delinearization validation failed: final offset "
                         "subtraction may overflow\n");
    return false;
  }

  return true;
}

bool llvm::getIndexExpressionsFromGEP(ScalarEvolution &SE,
                                      const GetElementPtrInst *GEP,
                                      SmallVectorImpl<const SCEV *> &Subscripts,
                                      SmallVectorImpl<const SCEV *> &Sizes) {
  assert(Subscripts.empty() && Sizes.empty() &&
         "Expected output lists to be empty on entry to this function.");
  assert(GEP && "getIndexExpressionsFromGEP called with a null GEP");
  LLVM_DEBUG(dbgs() << "\nGEP to delinearize: " << *GEP << "\n");
  Type *Ty = nullptr;
  Type *IndexTy = SE.getEffectiveSCEVType(GEP->getPointerOperandType());
  bool DroppedFirstDim = false;
  for (unsigned i = 1; i < GEP->getNumOperands(); i++) {
    const SCEV *Expr = SE.getSCEV(GEP->getOperand(i));
    if (i == 1) {
      Ty = GEP->getSourceElementType();
      if (auto *Const = dyn_cast<SCEVConstant>(Expr))
        if (Const->getValue()->isZero()) {
          DroppedFirstDim = true;
          continue;
        }
      Subscripts.push_back(Expr);
      continue;
    }

    auto *ArrayTy = dyn_cast<ArrayType>(Ty);
    if (!ArrayTy) {
      LLVM_DEBUG(dbgs() << "GEP delinearize failed: " << *Ty
                        << " is not an array type.\n");
      Subscripts.clear();
      Sizes.clear();
      return false;
    }

    Subscripts.push_back(Expr);
    if (!(DroppedFirstDim && i == 2))
      Sizes.push_back(SE.getConstant(IndexTy, ArrayTy->getNumElements()));

    Ty = ArrayTy->getElementType();
  }
  LLVM_DEBUG({
    dbgs() << "Subscripts:\n";
    for (const SCEV *S : Subscripts)
      dbgs() << *S << "\n";
    dbgs() << "\n";
  });

  return !Subscripts.empty();
}

namespace {

void printDelinearization(raw_ostream &O, Function *F, LoopInfo *LI,
                          ScalarEvolution *SE) {
  O << "Printing analysis 'Delinearization' for function '" << F->getName()
    << "':";
  const AnalysisOptions &Opts = getAnalysisOptions(*F);
  for (Instruction &Inst : instructions(F)) {
    // Only analyze loads and stores.
    if (!isa<StoreInst>(&Inst) && !isa<LoadInst>(&Inst))
      continue;

    const BasicBlock *BB = Inst.getParent();
    Loop *L = LI->getLoopFor(BB);
    // Only delinearize the memory access in the innermost loop.
    // Do not analyze memory accesses outside loops.
    if (!L)
      continue;

    const SCEV *AccessFn = SE->getSCEVAtScope(getPointerOperand(&Inst), L);

    const SCEVUnknown *BasePointer =
        dyn_cast<SCEVUnknown>(SE->getPointerBase(AccessFn));
    // Do not delinearize if we cannot find the base pointer.
    if (!BasePointer)
      break;
    AccessFn = SE->getMinusSCEV(AccessFn, BasePointer);

    O << "\n";
    O << "Inst:" << Inst << "\n";
    O << "AccessFunction: " << *AccessFn << "\n";

    SmallVector<const SCEV *, 3> Subscripts, Sizes;

    auto IsDelinearizationFailed = [&]() {
      return Subscripts.size() == 0 || Sizes.size() == 0 ||
             Subscripts.size() != Sizes.size();
    };

    delinearize(*SE, AccessFn, Subscripts, Sizes, SE->getElementSize(&Inst));
    DelinearizationShapeKind ShapeKind =
        DelinearizationShapeKind::UnknownOuterDimension;
    if (Opts.delinearize_use_fixed_size_array_heuristic &&
        IsDelinearizationFailed()) {
      Subscripts.clear();
      Sizes.clear();
      delinearizeFixedSizeArray(*SE, AccessFn, Subscripts, Sizes,
                                SE->getElementSize(&Inst), ShapeKind);
    }

    if (IsDelinearizationFailed()) {
      O << "failed to delinearize\n";
      continue;
    }

    O << "Base offset: " << *BasePointer << "\n";
    O << "ArrayDecl[UnknownSize]";
    int Size = Subscripts.size();
    for (int i = 0; i < Size - 1; i++)
      O << "[" << *Sizes[i] << "]";
    O << " with elements of " << *Sizes[Size - 1] << " bytes.\n";

    O << "ArrayRef";
    for (int i = 0; i < Size; i++)
      O << "[" << *Subscripts[i] << "]";
    O << "\n";

    bool IsValid =
        validateDelinearizationResult(*SE, Sizes, Subscripts, ShapeKind, &Inst);
    O << "Delinearization validation: " << (IsValid ? "Succeeded" : "Failed")
      << "\n";
  }
}

} // end anonymous namespace

DelinearizationPrinterPass::DelinearizationPrinterPass(raw_ostream &OS)
    : OS(OS) {}
PreservedAnalyses DelinearizationPrinterPass::run(Function &F,
                                                  FunctionAnalysisManager &AM) {
  printDelinearization(OS, &F, &AM.getResult<LoopAnalysis>(F),
                       &AM.getResult<ScalarEvolutionAnalysis>(F));
  return PreservedAnalyses::all();
}
