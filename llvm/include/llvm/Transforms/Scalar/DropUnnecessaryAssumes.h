//===------------------------------------------------------------*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Pass that drops assumes that are unlikely to be useful.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_SCALAR_DROPUNNECESSARYASSUMES_H
#define LLVM_TRANSFORMS_SCALAR_DROPUNNECESSARYASSUMES_H

#include "llvm/IR/PassManager.h"

namespace llvm {

struct DropUnnecessaryAssumesPass
    : public OptionalPassInfoMixin<DropUnnecessaryAssumesPass> {
  /// With \p OnlyArrayExtents, drop the array contract bundles and leave
  /// every other assume alone.
  DropUnnecessaryAssumesPass(bool DropDereferenceable = false,
                             bool OnlyArrayExtents = false)
      : DropDereferenceable(DropDereferenceable),
        OnlyArrayExtents(OnlyArrayExtents) {}

  LLVM_ABI PreservedAnalyses run(Function &F, FunctionAnalysisManager &AM);
  LLVM_ABI void
  printPipeline(raw_ostream &OS,
                function_ref<StringRef(StringRef)> MapClassName2PassName);

private:
  bool DropDereferenceable;
  bool OnlyArrayExtents;
};

} // end namespace llvm

#endif // LLVM_TRANSFORMS_SCALAR_DROPUNNECESSARYASSUMES_H
