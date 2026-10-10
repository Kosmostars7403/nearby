// Copyright 2020 Google LLC
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
#include <utility>

#include "absl/container/flat_hash_set.h"
#include "absl/synchronization/mutex.h"
#include "internal/platform/feature_flags.h"

namespace nearby {

CancellationFlag::CancellationFlag() {
  mutex_ = std::make_unique<absl::Mutex>();
}

CancellationFlag::CancellationFlag(bool cancelled) {
  mutex_ = std::make_unique<absl::Mutex>();
  cancelled_ = cancelled;
}

CancellationFlag::~CancellationFlag() {
  absl::MutexLock lock(*mutex_);
  listeners_.clear();
}

void CancellationFlag::Cancel() {
  // Return immediately as no-op if feature flag is not enabled.
  if (!FeatureFlags::GetInstance().GetFlags().enable_cancellation_flag) {
    return;
  }

  absl::flat_hash_set<CancelListener *> listeners;
  std::vector<std::shared_ptr<CancellationFlag>> scoped_flags;
  {
    absl::MutexLock lock(*mutex_);
    if (cancelled_) {
      // Someone already cancelled. Return immediately.
      return;
    }
    cancelled_ = true;

    listeners = listeners_;
    for (const auto& weak_flag : scoped_flags_) {
      if (auto scoped_flag = weak_flag.lock()) {
        scoped_flags.push_back(std::move(scoped_flag));
      }
    }
    scoped_flags_.clear();
  }

  // Keep the scoped flags alive through notification without holding our mutex.
  for (const auto& scoped_flag : scoped_flags) {
    scoped_flag->Cancel();
  }
  for (auto *listener : listeners) {
    (*listener)();
  }
}

std::shared_ptr<CancellationFlag> CancellationFlag::CreateScopedFlag() {
  absl::MutexLock lock(*mutex_);
  auto scoped_flag = std::make_shared<CancellationFlag>(cancelled_);
  if (!cancelled_) {
    for (auto it = scoped_flags_.begin(); it != scoped_flags_.end();) {
      if (it->expired()) {
        it = scoped_flags_.erase(it);
      } else {
        ++it;
      }
    }
    scoped_flags_.push_back(scoped_flag);
  }
  return scoped_flag;
}

void CancellationFlag::Uncancel() {
  // Return immediately as no-op if feature flag is not enabled.
  if (!FeatureFlags::GetInstance().GetFlags().enable_cancellation_flag) {
    return;
  }

  {
    absl::MutexLock lock(*mutex_);
    assert(cancelled_);
    cancelled_ = false;
  }
}

bool CancellationFlag::Cancelled() const {
  absl::MutexLock lock(*mutex_);

  // Return false as no-op if feature flag is not enabled.
  if (!FeatureFlags::GetInstance().GetFlags().enable_cancellation_flag) {
    return false;
  }

  return cancelled_;
}

void CancellationFlag::RegisterOnCancelListener(CancelListener *listener) {
  absl::MutexLock lock(*mutex_);

  listeners_.emplace(listener);
}

void CancellationFlag::UnregisterOnCancelListener(CancelListener *listener) {
  absl::MutexLock lock(*mutex_);

  listeners_.erase(listener);
}

}  // namespace nearby
