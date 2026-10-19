//===- RemoveRedundantArrayBoundAssumes.cpp ----------------------*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Remove marked Fortran array-bound assumes after LoopInterchange has consumed
// them and before vectorization can duplicate them or include them in its cost
// model.
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Scalar/RemoveRedundantArrayBoundAssumes.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/Transforms/Utils/Local.h"

using namespace llvm;

PreservedAnalyses
RemoveRedundantArrayBoundAssumesPass::run(Function &F,
                                          FunctionAnalysisManager &AM) {
  SmallVector<Instruction *, 16> ToDelete;
  for (BasicBlock &BB : F)
    for (Instruction &I : BB)
      if (auto *Assume = dyn_cast<AssumeInst>(&I);
          Assume && Assume->getMetadata("llvm.array.bounds"))
        ToDelete.push_back(Assume);

  if (ToDelete.empty())
    return PreservedAnalyses::all();

  SmallVector<WeakTrackingVH, 16> DeadOps;
  for (Instruction *I : ToDelete) {
    Value *Cond = cast<AssumeInst>(I)->getArgOperand(0);
    I->eraseFromParent();
    if (Cond->use_empty())
      DeadOps.push_back(Cond);
  }
  RecursivelyDeleteTriviallyDeadInstructionsPermissive(DeadOps);

  return PreservedAnalyses::none();
}
