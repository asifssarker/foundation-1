module Foundation.IO.Handle.Common
    ( HandleIOError(..)
    ) where

import           Foundation.Internal.Base
import           Foreign.C.Types
import           Foundation.String

data HandleIOError = HandleIOError String CInt
    deriving (Show,Eq,Typeable)

instance Exception HandleIOError
