// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "internal/platform/cancellation_flag.h"

#include <memory>
#include <thread>

#include "gtest/gtest.h"
#include "internal/platform/feature_flags.h"

namespace nearby {
namespace {

class CancellationScopeTest : public testing::Test {
 protected:
  void SetUp() override {
    original_flags_ = FeatureFlags::GetInstance().GetFlags();
    auto flags = original_flags_;
    flags.enable_cancellation_flag = true;
    FeatureFlags::GetMutableInstanceForTesting().SetFlags(flags);
  }
  void TearDown() override {
    FeatureFlags::GetMutableInstanceForTesting().SetFlags(original_flags_);
  }

  FeatureFlags::Flags original_flags_;
};

TEST_F(CancellationScopeTest, CancelAndResetBetweenPollsStaysCancelled) {
  auto parent = std::make_shared<CancellationFlag>();
  auto attempt = parent->CreateScopedFlag();
  EXPECT_FALSE(attempt->Cancelled());
  parent->Cancel();
  parent->Uncancel();
  EXPECT_FALSE(parent->Cancelled());
  EXPECT_TRUE(attempt->Cancelled());
}

TEST_F(CancellationScopeTest, AlreadyCancelledParentCancelsNewScope) {
  auto parent = std::make_shared<CancellationFlag>(true);
  auto attempt = parent->CreateScopedFlag();
  EXPECT_TRUE(attempt->Cancelled());
  parent->Uncancel();
  EXPECT_TRUE(attempt->Cancelled());
}

TEST_F(CancellationScopeTest, RetryAfterResetGetsIndependentCancellation) {
  auto parent = std::make_shared<CancellationFlag>();
  auto previous = parent->CreateScopedFlag();
  parent->Cancel();
  parent->Uncancel();
  auto retry = parent->CreateScopedFlag();
  EXPECT_TRUE(previous->Cancelled());
  EXPECT_FALSE(retry->Cancelled());
  parent->Cancel();
  EXPECT_TRUE(retry->Cancelled());
}

TEST_F(CancellationScopeTest, ScopedFlagCanBeDestroyedDuringParentCancel) {
  for (int i = 0; i < 1000; ++i) {
    auto parent = std::make_shared<CancellationFlag>();
    auto expired = parent->CreateScopedFlag();
    expired.reset();
    auto attempt = parent->CreateScopedFlag();
    std::thread cancel([&] { parent->Cancel(); });
    attempt.reset();
    cancel.join();
    EXPECT_TRUE(parent->Cancelled());
  }
}

TEST_F(CancellationScopeTest, ScopeDoesNotKeepParentAlive) {
  auto parent = std::make_shared<CancellationFlag>();
  std::weak_ptr<CancellationFlag> weak_parent = parent;
  auto attempt = parent->CreateScopedFlag();
  parent.reset();
  EXPECT_TRUE(weak_parent.expired());
  EXPECT_FALSE(attempt->Cancelled());
  attempt->Cancel();
  EXPECT_TRUE(attempt->Cancelled());
}

TEST_F(CancellationScopeTest, DisabledCancellationRemainsNoOp) {
  auto flags = original_flags_;
  flags.enable_cancellation_flag = false;
  FeatureFlags::GetMutableInstanceForTesting().SetFlags(flags);
  auto parent = std::make_shared<CancellationFlag>();
  auto attempt = parent->CreateScopedFlag();
  parent->Cancel();
  EXPECT_FALSE(parent->Cancelled());
  EXPECT_FALSE(attempt->Cancelled());
  attempt->Cancel();
  EXPECT_FALSE(attempt->Cancelled());
  auto already_cancelled = std::make_shared<CancellationFlag>(true);
  EXPECT_FALSE(already_cancelled->CreateScopedFlag()->Cancelled());
}

}  // namespace
}  // namespace nearby
