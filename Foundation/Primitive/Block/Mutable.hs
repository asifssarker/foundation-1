-- |
-- Module      : Foundation.Primitive.Block.Mutable
-- License     : BSD-style
-- Maintainer  : Haskell Foundation
--
-- A block of memory that contains elements of a type,
-- very similar to an unboxed array but with the key difference:
--
-- * It doesn't have slicing capability (no cheap take or drop)
-- * It consume less memory: 1 Offset, 1 Size, 1 Pinning status trimmed
-- * It's unpackable in any constructor
-- * It uses unpinned memory by default
--
-- It should be rarely needed in high level API, but
-- in lowlevel API or some data structure containing lots
-- of unboxed array that will benefit from optimisation.
--
-- Because it's unpinned, the blocks are compactable / movable,
-- at the expense of making them less friendly to C layer / address.
--
-- Note that sadly the bytearray primitive type automatically create
-- a pinned bytearray if the size is bigger than a certain threshold
--
-- GHC Documentation associated:
--
-- includes/rts/storage/Block.h
--   * LARGE_OBJECT_THRESHOLD ((uint32_t)(BLOCK_SIZE * 8 / 10))
--   * BLOCK_SIZE   (1<<BLOCK_SHIFT)
--
-- includes/rts/Constant.h
--   * BLOCK_SHIFT  12
--
{-# LANGUAGE MagicHash           #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UnboxedTuples       #-}
module Foundation.Primitive.Block.Mutable
    ( Block(..)
    , MutableBlock(..)
    , mutableLengthSize
    , mutableLengthBytes
    , new
    , isPinned
    , iterSet
    , read
    , write
    , unsafeNew
    , unsafeWrite
    , unsafeRead
    , unsafeFreeze
    , unsafeThaw
    , unsafeCopyElements
    , unsafeCopyElementsRO
    , unsafeCopyBytes
    , unsafeCopyBytesRO
    ) where

import           GHC.Prim
import           GHC.Types
import           Foundation.Internal.Base
import           Foundation.Internal.Proxy
import           Foundation.Primitive.Exception
import           Foundation.Primitive.Types.OffsetSize
import           Foundation.Primitive.Monad
import           Foundation.Numerical
import           Foundation.Primitive.Types
import           Foundation.Primitive.Block.Base

-- | Return the length of a Mutable Block
--
-- note: we don't allow resizing yet, so this can remain a pure function
mutableLengthSize :: forall ty st . PrimType ty => MutableBlock ty st -> Size ty
mutableLengthSize (MutableBlock mba) =
    let !(Size (I# szBits)) = primSizeInBytes (Proxy :: Proxy ty)
        !elems              = quotInt# (sizeofMutableByteArray# mba) szBits
     in Size (I# elems)
{-# INLINE[1] mutableLengthSize #-}

mutableLengthBytes :: MutableBlock ty st -> Size Word8
mutableLengthBytes (MutableBlock mba) = Size (I# (sizeofMutableByteArray# mba))
{-# INLINE[1] mutableLengthBytes #-}

-- | Return if a Mutable Block is pinned or not
isPinned :: MutableBlock ty st -> Bool
isPinned (MutableBlock mba) =
    -- TODO use the exact value where the array become pinned (LARGE_OBJECT_THRESHOLD)
    -- in 8.2, there's a primitive to know if an array in pinned
    I# (sizeofMutableByteArray# mba) > 3000


-- | Set all mutable block element to a value
iterSet :: (PrimType ty, PrimMonad prim)
        => (Offset ty -> ty)
        -> MutableBlock ty (PrimState prim)
        -> prim ()
iterSet f ma = loop 0
  where
    !sz = mutableLengthSize ma
    loop i
        | i .==# sz = pure ()
        | otherwise = unsafeWrite ma i (f i) >> loop (i+1)
    {-# INLINE loop #-}

-- | read a cell in a mutable array.
--
-- If the index is out of bounds, an error is raised.
read :: (PrimMonad prim, PrimType ty) => MutableBlock ty (PrimState prim) -> Offset ty -> prim ty
read array n
    | isOutOfBound n len = primOutOfBound OOB_Read n len
    | otherwise          = unsafeRead array n
  where len = mutableLengthSize array
{-# INLINE read #-}

-- | Write to a cell in a mutable array.
--
-- If the index is out of bounds, an error is raised.
write :: (PrimMonad prim, PrimType ty) => MutableBlock ty (PrimState prim) -> Offset ty -> ty -> prim ()
write array n val
    | isOutOfBound n len = primOutOfBound OOB_Write n len
    | otherwise          = unsafeWrite array n val
  where
    len = mutableLengthSize array
{-# INLINE write #-}
