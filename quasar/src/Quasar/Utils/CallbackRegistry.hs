module Quasar.Utils.CallbackRegistry (
  CallbackRegistry,
  newCallbackRegistry,
  newCallbackRegistryIO,
  newCallbackRegistryWithEmptyCallback,
  registerCallback,
  callCallbacks,
  callbackRegistryHasCallbacks,
  clearCallbackRegistry,
) where

import Quasar.Resources.Core
