//===- DropAssumeChained.cpp - Drop llvm.assume.chained calls -------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Scalar/DropAssumeChained.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/IntrinsicInst.h"

using namespace llvm;

PreservedAnalyses DropAssumeChainedPass::run(Function &F,
                                             FunctionAnalysisManager &) {
  bool Changed = false;
  for (Instruction &I : make_early_inc_range(instructions(F))) {
    auto *II = dyn_cast<IntrinsicInst>(&I);
    if (!II || II->getIntrinsicID() != Intrinsic::assume_chained)
      continue;
    II->replaceAllUsesWith(II->getArgOperand(0));
    II->eraseFromParent();
    Changed = true;
  }

  if (!Changed)
    return PreservedAnalyses::all();
  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>();
  return PA;
}
