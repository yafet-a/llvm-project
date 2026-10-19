//===------------------------------------------------------------*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Removes llvm.assume intrinsics that carry !llvm.array.bounds metadata after
// their final intended consumer and deletes dead instructions feeding them.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_SCALAR_REMOVEREDUNDANTARRAYBOUNDASSUMES_H
#define LLVM_TRANSFORMS_SCALAR_REMOVEREDUNDANTARRAYBOUNDASSUMES_H

#include "llvm/IR/PassManager.h"

namespace llvm {

class RemoveRedundantArrayBoundAssumesPass
    : public OptionalPassInfoMixin<RemoveRedundantArrayBoundAssumesPass> {
public:
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &AM);
};

} // namespace llvm

#endif // LLVM_TRANSFORMS_SCALAR_REMOVEREDUNDANTARRAYBOUNDASSUMES_H
