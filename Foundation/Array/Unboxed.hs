-- |
-- Module      : Foundation.Array.Unboxed
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : portable
--
-- A simple array abstraction that allow to use typed
-- array of bytes where the array is pinned in memory
-- to allow easy use with Foreign interfaces, ByteString
-- and always aligned to 64 bytes.
--
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE Rank2Types #-}
module Foundation.Array.Unboxed
    ( UArray(..)
    , PrimType(..)
    -- * methods
    , copy
    , unsafeCopyAtRO
    -- * internal methods
    -- , copyAddr
    , recast
    , unsafeRecast
    , length
    , lengthSize
    , freeze
    , unsafeFreeze
    , thaw
    , unsafeThaw
    -- * Creation
    , new
    , empty
    , create
    , createFromIO
    , sub
    , copyToPtr
    , withPtr
    , withMutablePtr
    , unsafeFreezeShrink
    , freezeShrink
    , unsafeSlide
    -- * accessors
    , update
    , unsafeUpdate
    , unsafeIndex
    , unsafeIndexer
    , unsafeDewrap
    , unsafeRead
    , unsafeWrite
    -- * Functions
    , singleton
    , replicate
    , map
    , mapIndex
    , findIndex
    , index
    , null
    , take
    , drop
    , splitAt
    , revDrop
    , revTake
    , revSplitAt
    , splitOn
    , splitElem
    , break
    , breakElem
    , elem
    , intersperse
    , span
    , cons
    , snoc
    , uncons
    , unsnoc
    , find
    , sortBy
    , filter
    , reverse
    , foldl
    , foldr
    , foldl'
    , foreignMem
    , fromForeignPtr
    , builderAppend
    , builderBuild
    , toHexadecimal
    ) where

import           GHC.Prim
import           GHC.Types
import           GHC.Word
import           GHC.ST
import           GHC.Ptr
import           GHC.ForeignPtr (ForeignPtr)
import           Foreign.Marshal.Utils (copyBytes)
import qualified Prelude
import           Foundation.Internal.Base
import           Foundation.Internal.Primitive
import           Foundation.Internal.Proxy
import           Foundation.Primitive.Types.OffsetSize
import           Foundation.Internal.MonadTrans
import qualified Foundation.Primitive.Base16 as Base16
import           Foundation.Primitive.Monad
import           Foundation.Primitive.Types
import           Foundation.Primitive.NormalForm
import           Foundation.Primitive.IntegralConv
import           Foundation.Primitive.FinalPtr
import           Foundation.Primitive.Utils
import           Foundation.Primitive.Exception
import           Foundation.Array.Unboxed.Mutable hiding (sub)
import           Foundation.Numerical
import           Foundation.Boot.Builder
import qualified Data.List

-- | An array of type built on top of GHC primitive.
--
-- The elements need to have fixed sized and the representation is a
-- packed contiguous array in memory that can easily be passed
-- to foreign interface
data UArray ty =
      UVecBA {-# UNPACK #-} !(Offset ty)
             {-# UNPACK #-} !(Size ty)
             {-# UNPACK #-} !PinnedStatus {- unpinned / pinned flag -}
                            ByteArray#
    | UVecAddr {-# UNPACK #-} !(Offset ty)
               {-# UNPACK #-} !(Size ty)
                              !(FinalPtr ty)
    deriving (Typeable)

instance Data ty => Data (UArray ty) where
    dataTypeOf _ = arrayType
    toConstr _   = error "toConstr"
    gunfold _ _  = error "gunfold"

arrayType :: DataType
arrayType = mkNoRepType "Foundation.UArray"

instance NormalForm (UArray ty) where
    toNormalForm (UVecBA _ _ _ !_) = ()
    toNormalForm (UVecAddr _ _ _) = ()
instance (PrimType ty, Show ty) => Show (UArray ty) where
    show v = show (toList v)
instance (PrimType ty, Eq ty) => Eq (UArray ty) where
    (==) = equal
instance (PrimType ty, Ord ty) => Ord (UArray ty) where
    compare = vCompare

instance PrimType ty => Monoid (UArray ty) where
    mempty  = empty
    mappend = append
    mconcat = concat

instance PrimType ty => IsList (UArray ty) where
    type Item (UArray ty) = ty
    fromList = vFromList
    toList = vToList

vectorProxyTy :: UArray ty -> Proxy ty
vectorProxyTy _ = Proxy

-- | Copy every cells of an existing array to a new array
copy :: PrimType ty => UArray ty -> UArray ty
copy array = runST (thaw array >>= unsafeFreeze)

-- | Thaw an array to a mutable array.
--
-- the array is not modified, instead a new mutable array is created
-- and every values is copied, before returning the mutable array.
thaw :: (PrimMonad prim, PrimType ty) => UArray ty -> prim (MUArray ty (PrimState prim))
thaw array = do
    ma <- new (lengthSize array)
    unsafeCopyAtRO ma azero array (Offset 0) (lengthSize array)
    return ma
{-# INLINE thaw #-}

-- | Return the element at a specific index from an array.
--
-- If the index @n is out of bounds, an error is raised.
index :: PrimType ty => UArray ty -> Offset ty -> ty
index array n
    | isOutOfBound n len = outOfBound OOB_Index n len
    | otherwise          = unsafeIndex array n
  where
    !len = lengthSize array
{-# INLINE index #-}

-- | Return the element at a specific index from an array without bounds checking.
--
-- Reading from invalid memory can return unpredictable and invalid values.
-- use 'index' if unsure.
unsafeIndex :: forall ty . PrimType ty => UArray ty -> Offset ty -> ty
unsafeIndex (UVecBA start _ _ ba) n = primBaIndex ba (start + n)
unsafeIndex (UVecAddr start _ fptr) n = withUnsafeFinalPtr fptr (\(Ptr addr) -> return (primAddrIndex addr (start+n)) :: IO ty)
{-# INLINE unsafeIndex #-}

unsafeIndexer :: (PrimMonad prim, PrimType ty) => UArray ty -> ((Offset ty -> ty) -> prim a) -> prim a
unsafeIndexer (UVecBA start _ _ ba) f = f (\n -> primBaIndex ba (start + n))
unsafeIndexer (UVecAddr start _ fptr) f = withFinalPtr fptr $ \(Ptr addr) -> f (\n -> primAddrIndex addr (start + n))
{-# INLINE unsafeIndexer #-}

unsafeDewrap :: PrimType ty
             => (ByteArray# -> Offset ty -> a)
             -> (Ptr ty -> Offset ty -> ST s a)
             -> UArray ty
             -> a
unsafeDewrap _ g (UVecAddr start _ fptr) = withUnsafeFinalPtr fptr $ \ptr -> g ptr start
unsafeDewrap f _ (UVecBA start _ _ ba)   = f ba start
{-# INLINE unsafeDewrap #-}

foreignMem :: PrimType ty
           => FinalPtr ty -- ^ the start pointer with a finalizer
           -> Int         -- ^ the number of elements (in elements, not bytes)
           -> UArray ty
foreignMem fptr nb = UVecAddr (Offset 0) (Size nb) fptr

fromForeignPtr :: PrimType ty
               => (ForeignPtr ty, Int, Int) -- ForeignPtr, an offset in prim elements, a size in prim elements
               -> UArray ty
fromForeignPtr (fptr, ofs, len)   = UVecAddr (Offset ofs) (Size len) (toFinalPtrForeign fptr)

-- | return the number of elements of the array.
length :: PrimType ty => UArray ty -> Int
length a = let (Size len) = lengthSize a in len
{-# INLINE[1] length #-}

lengthSize :: PrimType ty => UArray ty -> Size ty
lengthSize (UVecAddr _ len _) = len
lengthSize (UVecBA _ len _ _) = len
{-# INLINE[1] lengthSize #-}

-- TODO Optimise with copyByteArray#
-- | Copy @n@ sequential elements from the specified offset in a source array
--   to the specified position in a destination array.
--
--   This function does not check bounds. Accessing invalid memory can return
--   unpredictable and invalid values.
unsafeCopyAtRO :: (PrimMonad prim, PrimType ty)
               => MUArray ty (PrimState prim) -- ^ destination array
               -> Offset ty                   -- ^ offset at destination
               -> UArray ty                   -- ^ source array
               -> Offset ty                   -- ^ offset at source
               -> Size ty                     -- ^ number of elements to copy
               -> prim ()
unsafeCopyAtRO (MUVecMA dstStart _ _ dstMba) ed uvec@(UVecBA srcStart _ _ srcBa) es n =
    primitive $ \st -> (# copyByteArray# srcBa os dstMba od nBytes st, () #)
  where
    sz = primSizeInBytes (vectorProxyTy uvec)
    !(Offset (I# os))   = offsetOfE sz (srcStart+es)
    !(Offset (I# od))   = offsetOfE sz (dstStart+ed)
    !(Size (I# nBytes)) = sizeOfE sz n
unsafeCopyAtRO (MUVecMA dstStart _ _ dstMba) ed uvec@(UVecAddr srcStart _ srcFptr) es n =
    withFinalPtr srcFptr $ \srcPtr ->
        let !(Ptr srcAddr) = srcPtr `plusPtr` os
         in primitive $ \s -> (# compatCopyAddrToByteArray# srcAddr dstMba od nBytes s, () #)
  where
    sz  = primSizeInBytes (vectorProxyTy uvec)
    !(Offset os)        = offsetOfE sz (srcStart+es)
    !(Offset (I# od))   = offsetOfE sz (dstStart+ed)
    !(Size (I# nBytes)) = sizeOfE sz n
unsafeCopyAtRO dst od src os n = loop od os
  where
    !endIndex = os `offsetPlusE` n
    loop d i
        | i == endIndex = return ()
        | otherwise     = unsafeWrite dst d (unsafeIndex src i) >> loop (d+1) (i+1)

-- | Allocate a new array with a fill function that has access to the elements of
--   the source array.
unsafeCopyFrom :: (PrimType a, PrimType b)
               => UArray a -- ^ Source array
               -> Size b -- ^ Length of the destination array
               -> (UArray a -> Offset a -> MUArray b s -> ST s ())
               -- ^ Function called for each element in the source array
               -> ST s (UArray b) -- ^ Returns the filled new array
unsafeCopyFrom v' newLen f = new newLen >>= fill 0 >>= unsafeFreeze
  where len = lengthSize v'
        fill i r'
            | i .==# len = return r'
            | otherwise  = do f v' i r'
                              fill (i + 1) r'

-- | Freeze a mutable array into an array.
--
-- the MUArray must not be changed after freezing.
unsafeFreeze :: PrimMonad prim => MUArray ty (PrimState prim) -> prim (UArray ty)
unsafeFreeze (MUVecMA start len pinnedState mba) = primitive $ \s1 ->
    case unsafeFreezeByteArray# mba s1 of
        (# s2, ba #) -> (# s2, UVecBA start len pinnedState ba #)
unsafeFreeze (MUVecAddr start len fptr) = return $ UVecAddr start len fptr
{-# INLINE unsafeFreeze #-}

unsafeFreezeShrink :: (PrimType ty, PrimMonad prim) => MUArray ty (PrimState prim) -> Size ty -> prim (UArray ty)
unsafeFreezeShrink (MUVecMA start _ pinnedState mba) n = unsafeFreeze (MUVecMA start n pinnedState mba)
unsafeFreezeShrink (MUVecAddr start _ fptr) n = unsafeFreeze (MUVecAddr start n fptr)
{-# INLINE unsafeFreezeShrink #-}

freeze :: (PrimType ty, PrimMonad prim) => MUArray ty (PrimState prim) -> prim (UArray ty)
freeze ma = do
    ma' <- new len
    copyAt ma' (Offset 0) ma (Offset 0) len
    unsafeFreeze ma'
  where len = Size $ mutableLength ma

freezeShrink :: (PrimType ty, PrimMonad prim) => MUArray ty (PrimState prim) -> Size ty -> prim (UArray ty)
freezeShrink ma n = do
    ma' <- new n
    copyAt ma' (Offset 0) ma (Offset 0) n
    unsafeFreeze ma'

unsafeSlide :: (PrimType ty, PrimMonad prim) => MUArray ty (PrimState prim) -> Offset ty -> Offset ty -> prim ()
unsafeSlide mua s e = doSlide mua s e
  where
    doSlide :: (PrimType ty, PrimMonad prim) => MUArray ty (PrimState prim) -> Offset ty -> Offset ty -> prim ()
    doSlide (MUVecMA mbStart _ _ mba) start end  =
        primMutableByteArraySlideToStart mba (primOffsetOfE $ mbStart+start) (primOffsetOfE end)
    doSlide (MUVecAddr mbStart _ fptr) start end = withFinalPtr fptr $ \(Ptr addr) ->
        primMutableAddrSlideToStart addr (primOffsetOfE $ mbStart+start) (primOffsetOfE end)

-- | Thaw an immutable array.
--
-- The UArray must not be used after thawing.
unsafeThaw :: (PrimType ty, PrimMonad prim) => UArray ty -> prim (MUArray ty (PrimState prim))
unsafeThaw (UVecBA start len pinnedState ba) = primitive $ \st -> (# st, MUVecMA start len pinnedState (unsafeCoerce# ba) #)
unsafeThaw (UVecAddr start len fptr) = return $ MUVecAddr start len fptr
{-# INLINE unsafeThaw #-}

-- | Create a new array of size @n by settings each cells through the
-- function @f.
create :: forall ty . PrimType ty
       => Size ty           -- ^ the size of the array
       -> (Offset ty -> ty) -- ^ the function that set the value at the index
       -> UArray ty         -- ^ the array created
create n initializer
    | n == 0    = empty
    | otherwise = runST (new n >>= iter initializer)
  where
    iter :: (PrimType ty, PrimMonad prim) => (Offset ty -> ty) -> MUArray ty (PrimState prim) -> prim (UArray ty)
    iter f ma = loop 0
      where
        loop i
            | i .==# n  = unsafeFreeze ma
            | otherwise = unsafeWrite ma i (f i) >> loop (i+1)
        {-# INLINE loop #-}
    {-# INLINE iter #-}

-- | Create a pinned array that is filled by a 'filler' function (typically an IO call like hGetBuf)
createFromIO :: PrimType ty
             => Size ty                  -- ^ the size of the array
             -> (Ptr ty -> IO (Size ty)) -- ^ filling function that
             -> IO (UArray ty)
createFromIO size filler
    | size == 0 = return empty
    | otherwise = do
        mba <- newPinned size
        r   <- withMutablePtr mba $ \p -> filler p
        case r of
            0             -> return empty -- make sure we don't keep our array referenced by using empty
            _ | r < 0     -> error "filler returned negative number"
              | otherwise -> unsafeFreezeShrink mba r

-----------------------------------------------------------------------
-- higher level collection implementation
-----------------------------------------------------------------------
data BA0 = BA0 !ByteArray# -- zero ba

empty_ :: BA0
empty_ = runST $ primitive $ \s1 ->
    case newByteArray# 0# s1           of { (# s2, mba #) ->
    case unsafeFreezeByteArray# mba s2 of { (# s3, ba  #) ->
        (# s3, BA0 ba #) }}

empty :: UArray ty
empty = UVecBA 0 0 unpinned ba where !(BA0 ba) = empty_

singleton :: PrimType ty => ty -> UArray ty
singleton ty = create 1 (const ty)

replicate :: PrimType ty => Word -> ty -> UArray ty
replicate sz ty = create (Size (integralCast sz)) (const ty)

-- | make an array from a list of elements.
vFromList :: PrimType ty => [ty] -> UArray ty
vFromList l = runST $ do
    ma <- new (Size len)
    iter 0 l $ \i x -> unsafeWrite ma i x
    unsafeFreeze ma
  where len = Data.List.length l
        iter _  []     _ = return ()
        iter !i (x:xs) z = z i x >> iter (i+1) xs z

-- | transform an array to a list.
vToList :: forall ty . PrimType ty => UArray ty -> [ty]
vToList a
    | len == 0  = []
    | otherwise = unsafeDewrap goBa goPtr a
  where
    !len = lengthSize a
    goBa ba start = loop start
      where
        !end = start `offsetPlusE` len
        loop !i | i == end  = []
                | otherwise = primBaIndex ba i : loop (i+1)
    goPtr (Ptr addr) start = pureST (loop start)
      where
        !end = start `offsetPlusE` len
        loop !i | i == end  = []
                | otherwise = primAddrIndex addr i : loop (i+1)

-- | Check if two vectors are identical
equal :: (PrimType ty, Eq ty) => UArray ty -> UArray ty -> Bool
equal a b
    | la /= lb  = False
    | otherwise = loop 0
  where
    !la = lengthSize a
    !lb = lengthSize b
    loop n | n .==# la = True
           | otherwise = (unsafeIndex a n == unsafeIndex b n) && loop (n+1)

{-
sizeEqual :: PrimType ty => UArray ty -> UArray ty -> Bool
sizeEqual a b = length a == length b -- TODO optimise with direct comparaison of bytes or elements when possible
-}

-- | Compare 2 vectors
vCompare :: (Ord ty, PrimType ty) => UArray ty -> UArray ty -> Ordering
vCompare a b = loop 0
  where
    !la = lengthSize a
    !lb = lengthSize b
    loop n
        | n .==# la = if la == lb then EQ else LT
        | n .==# lb = GT
        | otherwise =
            case unsafeIndex a n `compare` unsafeIndex b n of
                EQ -> loop (n+1)
                r  -> r

-- | Append 2 arrays together by creating a new bigger array
append :: PrimType ty => UArray ty -> UArray ty -> UArray ty
append a b
    | la == azero = b
    | lb == azero = a
    | otherwise = runST $ do
        r  <- new (la+lb)
        ma <- unsafeThaw a
        mb <- unsafeThaw b
        copyAt r (Offset 0) ma (Offset 0) la
        copyAt r (sizeAsOffset la) mb (Offset 0) lb
        unsafeFreeze r
  where
    !la = lengthSize a
    !lb = lengthSize b

concat :: PrimType ty => [UArray ty] -> UArray ty
concat [] = empty
concat l  =
    case filterAndSum (Size 0) [] l of
        (_,[])            -> empty
        (_,[x])           -> x
        (totalLen,chunks) -> runST $ do
            r <- new totalLen
            doCopy r (Offset 0) chunks
            unsafeFreeze r
  where
    -- TODO would go faster not to reverse but pack from the end instead
    filterAndSum !totalLen acc []     = (totalLen, Prelude.reverse acc)
    filterAndSum !totalLen acc (x:xs)
        | len == Size 0 = filterAndSum totalLen acc xs
        | otherwise      = filterAndSum (len+totalLen) (x:acc) xs
      where len = lengthSize x

    doCopy _ _ []     = return ()
    doCopy r i (x:xs) = do
        unsafeCopyAtRO r i x (Offset 0) lx
        doCopy r (i `offsetPlusE` lx) xs
      where lx = lengthSize x

-- | update an array by creating a new array with the updates.
--
-- the operation copy the previous array, modify it in place, then freeze it.
update :: PrimType ty
       => UArray ty
       -> [(Offset ty, ty)]
       -> UArray ty
update array modifiers = runST (thaw array >>= doUpdate modifiers)
  where doUpdate l ma = loop l
          where loop []         = unsafeFreeze ma
                loop ((i,v):xs) = write ma i v >> loop xs
                {-# INLINE loop #-}
        {-# INLINE doUpdate #-}

unsafeUpdate :: PrimType ty
             => UArray ty
             -> [(Offset ty, ty)]
             -> UArray ty
unsafeUpdate array modifiers = runST (thaw array >>= doUpdate modifiers)
  where doUpdate l ma = loop l
          where loop []         = unsafeFreeze ma
                loop ((i,v):xs) = unsafeWrite ma i v >> loop xs
                {-# INLINE loop #-}
        {-# INLINE doUpdate #-}

-- | Copy all the block content to the memory starting at the destination address
copyToPtr :: forall ty prim . (PrimType ty, PrimMonad prim)
          => UArray ty -- ^ the source array to copy
          -> Ptr ty    -- ^ The destination address where the copy is going to start
          -> prim ()
copyToPtr (UVecBA start sz _ ba) (Ptr p) = primitive $ \s1 ->
    (# compatCopyByteArrayToAddr# ba offset p szBytes s1, () #)
  where
    !(Offset (I# offset)) = primOffsetOfE start
    !(Size (I# szBytes)) = sizeInBytes sz
copyToPtr (UVecAddr start sz fptr) dst =
    unsafePrimFromIO $ withFinalPtr fptr $ \ptr -> copyBytes dst (ptr `plusPtr` os) szBytes
  where
    !(Offset os)    = primOffsetOfE start
    !(Size szBytes) = sizeInBytes sz

data TmpBA = TmpBA ByteArray#

withPtr :: (PrimMonad prim, PrimType ty)
        => UArray ty
        -> (Ptr ty -> prim a)
        -> prim a
withPtr vec@(UVecAddr start _ fptr)  f =
    withFinalPtr fptr (\ptr -> f (ptr `plusPtr` os))
  where
    sz           = primSizeInBytes (vectorProxyTy vec)
    !(Offset os) = offsetOfE sz start
withPtr vec@(UVecBA start _ pstatus a) f
    | isPinned pstatus = f (Ptr (byteArrayContents# a) `plusPtr` os)
    | otherwise        = do
        -- TODO don't copy the whole vector, and just allocate+copy the slice.
        let !sz# = sizeofByteArray# a
        (TmpBA ba) <- primitive $ \s -> do
            case newAlignedPinnedByteArray# sz# 8# s of { (# s2, mba #) ->
            case copyByteArray# a 0# mba 0# sz# s2 of { s3 ->
            case unsafeFreezeByteArray# mba s3 of { (# s4, ba #) -> (# s4, TmpBA ba #) }}}
        r <- f (Ptr (byteArrayContents# ba))
        unsafePrimFromIO $ primitive $ \s -> case touch# ba s of { s2 -> (# s2, () #) }
        pure r
  where
    sz           = primSizeInBytes (vectorProxyTy vec)
    !(Offset os) = offsetOfE sz start
{-# INLINE withPtr #-}

recast :: (PrimType a, PrimType b) => UArray a -> UArray b
recast = recast_ Proxy Proxy
  where
    recast_ :: (PrimType a, PrimType b)
            => Proxy a -> Proxy b -> UArray a -> UArray b
    recast_ pa pb array
        | aTypeSize == bTypeSize = unsafeRecast array
        | missing   == 0         = unsafeRecast array
        | otherwise = throw $ InvalidRecast
                          (RecastSourceSize      alen)
                          (RecastDestinationSize $ alen + missing)
      where
        aTypeSize@(Size as) = primSizeInBytes pa
        bTypeSize@(Size bs) = primSizeInBytes pb
        alen = length array * as
        missing = alen `mod` bs

unsafeRecast :: (PrimType a, PrimType b) => UArray a -> UArray b
unsafeRecast (UVecBA start len pinStatus b) = UVecBA (primOffsetRecast start) (sizeRecast len) pinStatus b
unsafeRecast (UVecAddr start len a) = UVecAddr (primOffsetRecast start) (sizeRecast len) (castFinalPtr a)

null :: UArray ty -> Bool
null (UVecBA _ sz _ _) = sz == Size 0
null (UVecAddr _ l _)  = l == Size 0

take :: PrimType ty => Int -> UArray ty -> UArray ty
take nbElems v
    | nbElems <= 0 = empty
    | n >= vlen    = v
    | otherwise    =
        case v of
            UVecBA start _ pinst ba -> UVecBA start n pinst ba
            UVecAddr start _ fptr   -> UVecAddr start n fptr
  where
    n    = Size nbElems
    vlen = lengthSize v

drop :: PrimType ty => Int -> UArray ty -> UArray ty
drop nbElems v
    | nbElems <= 0 = v
    | n >= vlen    = empty
    | otherwise    =
        case v of
            UVecBA start len pinst ba -> UVecBA (start `offsetPlusE` n) (len - n) pinst ba
            UVecAddr start len fptr   -> UVecAddr (start `offsetPlusE` n) (len - n) fptr
  where
    n    = Size nbElems
    vlen = lengthSize v

splitAt :: PrimType ty => Int -> UArray ty -> (UArray ty, UArray ty)
splitAt nbElems v
    | nbElems <= 0   = (empty, v)
    | n == Size vlen = (v, empty)
    | otherwise      =
        case v of
            UVecBA start len pinst ba -> ( UVecBA start                   n         pinst ba
                                         , UVecBA (start `offsetPlusE` n) (len - n) pinst ba)
            UVecAddr start len fptr    -> ( UVecAddr start                   n         fptr
                                          , UVecAddr (start `offsetPlusE` n) (len - n) fptr)
  where
    n    = Size $ min nbElems vlen
    vlen = length v

splitElem :: PrimType ty => ty -> UArray ty -> (# UArray ty, UArray ty #)
splitElem !ty r@(UVecBA start len pinst ba)
    | k == end   = (# r, empty #)
    | k == start = (# empty, r #)
    | otherwise  =
        (# UVecBA start (offsetAsSize k - offsetAsSize start) pinst ba
        ,  UVecBA k     (len - (offsetAsSize k - offsetAsSize start)) pinst ba
        #)
  where
    !end = start `offsetPlusE` len
    !k = loop start
    loop !i | i < end && t /= ty = loop (i+Offset 1)
            | otherwise          = i
        where t                  = primBaIndex ba i
splitElem !ty r@(UVecAddr start len fptr)
    | k == end  = (# r, empty #)
    | otherwise =
        (# UVecAddr start (offsetAsSize k - offsetAsSize start) fptr
        ,  UVecAddr k     (len - (offsetAsSize k - offsetAsSize start)) fptr
        #)
  where
    !(Ptr addr) = withFinalPtrNoTouch fptr id
    !end = start `offsetPlusE` len
    !k = loop start
    loop !i | i < end && t /= ty = loop (i+Offset 1)
            | otherwise          = i
        where t                  = primAddrIndex addr i
{-# SPECIALIZE [3] splitElem :: Word8 -> UArray Word8 -> (# UArray Word8, UArray Word8 #) #-}
{-# SPECIALIZE [3] splitElem :: Word32 -> UArray Word32 -> (# UArray Word32, UArray Word32 #) #-}

revTake :: PrimType ty => Int -> UArray ty -> UArray ty
revTake nbElems v = drop (length v - nbElems) v

revDrop :: PrimType ty => Int -> UArray ty -> UArray ty
revDrop nbElems v = take (length v - nbElems) v

revSplitAt :: PrimType ty => Int -> UArray ty -> (UArray ty, UArray ty)
revSplitAt n v = (drop idx v, take idx v)
  where idx = length v - n

splitOn :: PrimType ty => (ty -> Bool) -> UArray ty -> [UArray ty]
splitOn xpredicate ivec
    | len == 0  = [mempty]
    | otherwise = runST $ unsafeIndexer ivec (pureST . go ivec xpredicate)
  where
    !len = lengthSize ivec
    --go :: PrimType ty => UArray ty -> (ty -> Bool) -> (Offset ty -> ty) -> ST s [UArray ty]
    go v predicate getIdx = loop 0 0
      where
        loop !prevIdx !idx
            | idx .==# len = [sub v prevIdx idx]
            | otherwise    =
                let e = getIdx idx
                    idx' = idx + 1
                 in if predicate e
                        then sub v prevIdx idx : loop idx' idx'
                        else loop prevIdx idx'
    {-# INLINE go #-}

pureST :: a -> ST s a
pureST = pure

sub :: PrimType ty => UArray ty -> Offset ty -> Offset ty -> UArray ty
sub vec startIdx expectedEndIdx
    | startIdx >= endIdx = empty
    | otherwise          =
        case vec of
            UVecBA start _ pinst ba -> UVecBA (start + startIdx) newLen pinst ba
            UVecAddr start _ fptr   -> UVecAddr (start + startIdx) newLen fptr
  where
    newLen = endIdx - startIdx
    endIdx = min expectedEndIdx (0 `offsetPlusE` len)
    len = lengthSize vec

findIndex :: PrimType ty => ty -> UArray ty -> Maybe Int
findIndex tyOuter ba = runST $ unsafeIndexer ba (go tyOuter)
  where
    !len = length ba

    go :: PrimType ty => ty -> (Offset ty -> ty) -> ST s (Maybe Int)
    go ty getIdx = loop (Offset 0)
      where
        loop ofs@(Offset i)
            | ofs == Offset len = return Nothing
            | getIdx ofs == ty  = return $ Just i
            | otherwise         = loop (ofs + Offset 1)
{-# SPECIALIZE [3] findIndex :: Word8 -> UArray Word8 -> Maybe Int #-}

break :: PrimType ty => (ty -> Bool) -> UArray ty -> (UArray ty, UArray ty)
break xpredicate xv
    | len == 0  = (empty, empty)
    | otherwise = runST $ unsafeIndexer xv (go xv xpredicate)
  where
    !len = length xv
    go :: PrimType ty => UArray ty -> (ty -> Bool) -> (Offset ty -> ty) -> ST s (UArray ty, UArray ty)
    go v predicate getIdx = return (findBreak $ Offset 0)
      where
        findBreak !i@(Offset io)
            | i == Offset len     = (v, empty)
            | predicate (getIdx i) = splitAt io v
            | otherwise            = findBreak (i + Offset 1)
        {-# INLINE findBreak #-}
    {-# INLINE go #-}
{-# NOINLINE [2] break #-}
{-# SPECIALIZE [2] break :: (Word8 -> Bool) -> UArray Word8 -> (UArray Word8, UArray Word8) #-}

{-
{-# RULES "break (== ty)" [3] forall (x :: forall ty . PrimType ty => ty) . break (== x) = breakElem x #-}
{-# RULES "break (ty ==)" [3] forall (x :: forall ty . PrimType ty => ty) . break (x ==) = breakElem x #-}
{-# RULES "break (== ty)" [3] forall (x :: Word8) . break (== x) = breakElem x #-}
-}

breakElem :: PrimType ty => ty -> UArray ty -> (UArray ty, UArray ty)
breakElem xelem xv = let (# v1, v2 #) = splitElem xelem xv in (v1, v2)
{-# SPECIALIZE [2] breakElem :: Word8 -> UArray Word8 -> (UArray Word8, UArray Word8) #-}
{-# SPECIALIZE [2] breakElem :: Word32 -> UArray Word32 -> (UArray Word32, UArray Word32) #-}

elem :: PrimType ty => ty -> UArray ty -> Bool
elem !ty (UVecBA start len _ ba)
    | k == end   = False
    | otherwise  = True
  where
    !end = start `offsetPlusE` len
    !k = loop start
    loop !i | i < end && t /= ty = loop (i+Offset 1)
            | otherwise          = i
        where t                  = primBaIndex ba i
elem ty (UVecAddr start len fptr)
    | k == end  = False
    | otherwise = True
  where
    !(Ptr addr) = withFinalPtrNoTouch fptr id
    !end = start `offsetPlusE` len
    !k = loop start
    loop !i | i < end && t /= ty = loop (i+Offset 1)
            | otherwise          = i
        where t                  = primAddrIndex addr i
{-# SPECIALIZE [2] elem :: Word8 -> UArray Word8 -> Bool #-}

intersperse :: forall ty . PrimType ty => ty -> UArray ty -> UArray ty
intersperse sep v
    | len <= 1  = v
    | otherwise = runST $ unsafeCopyFrom v newSize (go sep)
  where
    len = lengthSize v
    newSize = (scale (2:: Word) len) - 1

    go :: PrimType ty => ty -> UArray ty -> Offset ty -> MUArray ty s -> ST s ()
    go sep' oldV oldI newV
        | oldI .==# (len - 1) = unsafeWrite newV newI e
        | otherwise           = do
            unsafeWrite newV newI e
            unsafeWrite newV (newI + 1) sep'
      where
        e = unsafeIndex oldV oldI
        newI = scale (2 :: Word) oldI

span :: PrimType ty => (ty -> Bool) -> UArray ty -> (UArray ty, UArray ty)
span p = break (not . p)

map :: (PrimType a, PrimType b) => (a -> b) -> UArray a -> UArray b
map f a = create lenB (\i -> f $ unsafeIndex a (offsetCast Proxy i))
  where !lenB = sizeCast (Proxy :: Proxy (a -> b)) (lengthSize a)

mapIndex :: (PrimType a, PrimType b) => (Offset b -> a -> b) -> UArray a -> UArray b
mapIndex f a = create (sizeCast Proxy $ lengthSize a) (\i -> f i $ unsafeIndex a (offsetCast Proxy i))

cons :: PrimType ty => ty -> UArray ty -> UArray ty
cons e vec
    | len == Size 0 = singleton e
    | otherwise     = runST $ do
        muv <- new (len + 1)
        unsafeCopyAtRO muv 1 vec 0 len
        unsafeWrite muv 0 e
        unsafeFreeze muv
  where
    !len = lengthSize vec

snoc :: PrimType ty => UArray ty -> ty -> UArray ty
snoc vec e
    | len == Size 0 = singleton e
    | otherwise     = runST $ do
        muv <- new (len + Size 1)
        unsafeCopyAtRO muv (Offset 0) vec (Offset 0) len
        unsafeWrite muv (0 `offsetPlusE` lengthSize vec) e
        unsafeFreeze muv
  where
     !len = lengthSize vec

uncons :: PrimType ty => UArray ty -> Maybe (ty, UArray ty)
uncons vec
    | nbElems == 0 = Nothing
    | otherwise    = Just (unsafeIndex vec 0, sub vec 1 (0 `offsetPlusE` nbElems))
  where
    !nbElems = lengthSize vec

unsnoc :: PrimType ty => UArray ty -> Maybe (UArray ty, ty)
unsnoc vec
    | nbElems == 0 = Nothing
    | otherwise    = Just (sub vec 0 lastElem, unsafeIndex vec lastElem)
  where
    !lastElem = 0 `offsetPlusE` (nbElems - 1)
    !nbElems = lengthSize vec

find :: PrimType ty => (ty -> Bool) -> UArray ty -> Maybe ty
find predicate vec = loop 0
  where
    !len = lengthSize vec
    loop i
        | i .==# len = Nothing
        | otherwise  =
            let e = unsafeIndex vec i
             in if predicate e then Just e else loop (i+1)

sortBy :: forall ty . PrimType ty => (ty -> ty -> Ordering) -> UArray ty -> UArray ty
sortBy xford vec
    | len == 0  = empty
    | otherwise = runST (thaw vec >>= doSort xford)
  where
    len = lengthSize vec
    doSort :: (PrimType ty, PrimMonad prim) => (ty -> ty -> Ordering) -> MUArray ty (PrimState prim) -> prim (UArray ty)
    doSort ford ma = qsort 0 (sizeLastOffset len) >> unsafeFreeze ma
      where
        qsort lo hi
            | lo >= hi  = return ()
            | otherwise = do
                p <- partition lo hi
                qsort lo (pred p)
                qsort (p+1) hi
        partition lo hi = do
            pivot <- unsafeRead ma hi
            let loop i j
                    | j == hi   = return i
                    | otherwise = do
                        aj <- unsafeRead ma j
                        i' <- if ford aj pivot == GT
                                then return i
                                else do
                                    ai <- unsafeRead ma i
                                    unsafeWrite ma j ai
                                    unsafeWrite ma i aj
                                    return $ i + 1
                        loop i' (j+1)

            i <- loop lo lo
            ai  <- unsafeRead ma i
            ahi <- unsafeRead ma hi
            unsafeWrite ma hi ai
            unsafeWrite ma i ahi
            return i

filter :: PrimType ty => (ty -> Bool) -> UArray ty -> UArray ty
filter predicate vec = vFromList $ Data.List.filter predicate $ vToList vec

reverse :: PrimType ty => UArray ty -> UArray ty
reverse a
    | len == Size 0 = empty
    | otherwise     = runST $ do
        ma <- newNative len $ \mba ->
                case a of
                    (UVecBA start _ _ ba)   -> goNative endOfs mba ba start
                    (UVecAddr start _ fptr) -> withFinalPtr fptr $ \ptr -> goAddr endOfs mba ptr start
        unsafeFreeze ma
  where
    !len = lengthSize a
    !endOfs = Offset 0 `offsetPlusE` len

    goNative :: PrimType ty => Offset ty -> MutableByteArray# s -> ByteArray# -> Offset ty -> ST s ()
    goNative !end !ma !ba !srcStart = loop (Offset 0)
      where
        !endI = sizeAsOffset ((srcStart + end) - Offset 1)
        loop !i
            | i == end  = return ()
            | otherwise = primMbaWrite ma i (primBaIndex ba (sizeAsOffset (endI - i))) >> loop (i+Offset 1)
    goAddr !end !ma !(Ptr ba) !srcStart = loop (Offset 0)
      where
        !endI = sizeAsOffset ((srcStart + end) - Offset 1)
        loop !i
            | i == end  = return ()
            | otherwise = primMbaWrite ma i (primAddrIndex ba (sizeAsOffset (endI - i))) >> loop (i+Offset 1)
{-# SPECIALIZE [3] reverse :: UArray Word8 -> UArray Word8 #-}

foldl :: PrimType ty => (a -> ty -> a) -> a -> UArray ty -> a
foldl f initialAcc vec = loop 0 initialAcc
  where
    len = lengthSize vec
    loop i acc
        | i .==# len = acc
        | otherwise  = loop (i+1) (f acc (unsafeIndex vec i))

foldr :: PrimType ty => (ty -> a -> a) -> a -> UArray ty -> a
foldr f initialAcc vec = loop 0
  where
    !len = lengthSize vec
    loop i
        | i .==# len = initialAcc
        | otherwise  = unsafeIndex vec i `f` loop (i+1)

foldl' :: PrimType ty => (a -> ty -> a) -> a -> UArray ty -> a
foldl' f initialAcc vec = loop 0 initialAcc
  where
    !len = lengthSize vec
    loop i !acc
        | i .==# len = acc
        | otherwise  = loop (i+1) (f acc (unsafeIndex vec i))

builderAppend :: (PrimType ty, PrimMonad state) => ty -> Builder (UArray ty) (MUArray ty) ty state ()
builderAppend v = Builder $ State $ \(i, st) ->
    if offsetAsSize i == chunkSize st
        then do
            cur      <- unsafeFreeze (curChunk st)
            newChunk <- new (chunkSize st)
            unsafeWrite newChunk 0 v
            return ((), (Offset 1, st { prevChunks     = cur : prevChunks st
                                      , prevChunksSize = chunkSize st + prevChunksSize st
                                      , curChunk       = newChunk
                                      }))
        else do
            unsafeWrite (curChunk st) i v
            return ((), (i + 1, st))

builderBuild :: (PrimType ty, PrimMonad m) => Int -> Builder (UArray ty) (MUArray ty) ty m () -> m (UArray ty)
builderBuild sizeChunksI ab
    | sizeChunksI <= 0 = builderBuild 64 ab
    | otherwise        = do
        first         <- new sizeChunks
        ((), (i, st)) <- runState (runBuilder ab) (Offset 0, BuildingState [] (Size 0) first sizeChunks)
        cur           <- unsafeFreezeShrink (curChunk st) (offsetAsSize i)
        -- Build final array
        let totalSize = prevChunksSize st + offsetAsSize i
        new totalSize >>= fillFromEnd totalSize (cur : prevChunks st) >>= unsafeFreeze
  where
      sizeChunks = Size sizeChunksI

      fillFromEnd _   []     mua = return mua
      fillFromEnd !end (x:xs) mua = do
          let sz = lengthSize x
          unsafeCopyAtRO mua (sizeAsOffset (end - sz)) x (Offset 0) sz
          fillFromEnd (end - sz) xs mua

toHexadecimal :: PrimType ty => UArray ty -> UArray Word8
toHexadecimal ba
    | len == Size 0 = empty
    | otherwise     = runST $ do
        ma <- new (len `scale` 2)
        unsafeIndexer b8 (go ma)
        unsafeFreeze ma
  where
    b8 = unsafeRecast ba
    !len = lengthSize b8
    !endOfs = Offset 0 `offsetPlusE` len

    go :: MUArray Word8 s -> (Offset Word8 -> Word8) -> ST s ()
    go !ma !getAt = loop 0 0
      where
        loop !dIdx !sIdx
            | sIdx == endOfs = return ()
            | otherwise      = do
                let !(W8# !w)      = getAt sIdx
                    (# wHi, wLo #) = Base16.unsafeConvertByte w
                unsafeWrite ma dIdx     (W8# wHi)
                unsafeWrite ma (dIdx+1) (W8# wLo)
                loop (dIdx + 2) (sIdx+1)
