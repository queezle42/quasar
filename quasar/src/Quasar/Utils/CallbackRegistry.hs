module Quasar.Utils.CallbackRegistry (
  CallbackRegistry,
  newCallbackRegistry,
  newCallbackRegistryIO,
  newCallbackRegistryWithEmptyCallback,
  registerCallback,
  registerCallbackChangeAfterFirstCall,
  callCallbacks,
  callbackRegistryHasCallbacks,
  clearCallbackRegistry,
) where

import Quasar.Resources.Core
