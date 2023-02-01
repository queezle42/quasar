module Quasar.Utils.CallbackRegistry (
  CallbackRegistry,
  newCallbackRegistry,
  newCallbackRegistryIO,
  newCallbackRegistryWithEmptyCallback,
  registerCallback,
  callCallbacks,
  callbackRegistryHasCallbacks,
) where

import Quasar.Resources.Core
