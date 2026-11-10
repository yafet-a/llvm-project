//===- DropAssumeChained.h - Drop llvm.assume.chained calls -----*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Pass that forwards the operand of every llvm.assume.chained call to its
// users and erases the call, once no later pass consumes its facts.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_SCALAR_DROPASSUMECHAINED_H
#define LLVM_TRANSFORMS_SCALAR_DROPASSUMECHAINED_H

#include "llvm/IR/PassManager.h"

namespace llvm {

struct DropAssumeChainedPass
    : public OptionalPassInfoMixin<DropAssumeChainedPass> {
  LLVM_ABI PreservedAnalyses run(Function &F, FunctionAnalysisManager &AM);
};

} // end namespace llvm

#endif // LLVM_TRANSFORMS_SCALAR_DROPASSUMECHAINED_H
