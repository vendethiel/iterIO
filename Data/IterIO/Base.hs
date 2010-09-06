{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}


{- | This module contains the base Enumerator/Iteratee IO
     abstractions.  See the documentation in the "Data.IterIO" module
     for a high-level tutorial on these abstractions.

     An iteratee is a data sink that is fed chunks of data.  It may
     return a useful result, or its utility may lie in monadic
     side-effects, such as storing received data to a file.  Iteratees
     are represented by the type @'Iter' t m a@.  @t@ is the type of
     the data chunks the iteratee receives as input.  (@t@ must be an
     instance of 'ChunkData', such as 'String' or lazy
     'L.ByteString'.)  @m@ is the 'Monad' in which the iteratee
     runs--for instance 'IO' (or an instance of 'MonadIO') for the
     iteratee to perform IO.  @a@ is the result type of the iteratee,
     for when it has consumed enough input to produce a result.

     An enumerator is a data source that feeds data chunks to an
     iteratee.  In this library, all enumerators are also 'Iter's.
     Hence we use the type 'Inum' (/iterator-enumerator/) to represent
     enumerators.  An 'Inum' is an 'Iter' that can sink data of some
     input type usually designated @tIn@.  However, the 'Inum' also
     feeds data of some potentially different output type, @tOut@, to
     an 'Iter'.  Thus, an 'Inum' can be viewed as transcoding data
     from its input type @tIn@ to its output type @tOut@.

     'Inum's are generally constructed using the function 'mkInum',
     which takes a 'Codec' that transcodes from the input to the
     output type.  'mkInum' handles the details of error handling
     while the 'Codec' simply transforms data.

     An important special kind of 'Inum' is an /outer enumerator/,
     which is just an 'Inum' with the void input type @'()'@.  Outer
     enumerators are sources of data.  Rather than transcode input
     data, they produce data from monadic actions (or from pure data
     in the case of 'enumPure').  The type 'Onum' represents outer
     enumerators and is a synonym for 'Inum' with an input type of
     @'()'@.

     To execute iteratee-based IO, you must apply an 'Onum' to an
     'Iter' with the '|$' (\"pipe apply\") binary operator.

     An important property of enumerators and iteratees is that they
     can be /fused/.  The '|..' operator fuses two 'Inum's together
     (provided the output type of the first is the input type of the
     second), yielding a new 'Inum' that transcodes from the input
     type of the first to the output type of the second.  Similarly,
     the '..|' operator fuses an 'Inum' to an 'Iter', yielding a new
     'Iter' with a potentially different input type.

     Enumerators can also be concatenated with the 'cat' function.
     @enum1 ``cat`` enum2@ produces an enumerator whose effect is to
     feed first @enum1@'s data then @enum2@'s data to an 'Iter'.

 -}

module Data.IterIO.Base
    (-- * Base types
     ChunkData(..), Chunk(..)
    , Iter(..), Inum, InumR, Onum, OnumR
    -- * Concatenation and fusing operators
    , (|$), (.|$)
    , cat
    , (|..), (..|)
    -- * Enum construction functions
    , Codec, CodecR(..)
    , iterToCodec
    , mkInumC, mkInum, mkInum'
    , inumCBracket, inumBracket
    -- * Exception and error functions
    , IterNoParse(..), IterEOF(..), IterExpected(..), IterParseErr(..)
    , throwI, throwEOFI
    , tryI, tryBI, catchI, catchBI, handlerI, handlerBI
    , inumCatch, inumHandler
    , resumeI, verboseResumeI, mapExceptionI
    , ifParse, ifNoParse, multiParse
    -- * Some basic Iters
    , nullI, dataI, chunkI, peekI, atEOFI
    -- * Low-level Iter-manipulation functions
    , wrapI, runI, joinI, returnI, resultI
    -- * Some basic Enums
    , enumPure
    , iterLoop
    , inumNop, inumRepeat, inumSplit
    -- * Control functions
    , CtlCmd, CtlReq(..), CtlHandler
    , ctlI, safeCtlI
    , noCtls, ctl, ctl', ctlHandler
    -- * Other functions
    , runIter, run, chunk, chunkEOF
    , isIterError, isEnumError, isIterActive, apNext
    , iterShows, iterShow
    ) where

import Prelude hiding (null)
import qualified Prelude
import Control.Applicative (Applicative(..))
import Control.Concurrent.MVar
import Control.Exception (SomeException(..), ErrorCall(..), Exception(..)
                         , try, throw)
import Control.Monad
import Control.Monad.Fix
import Control.Monad.Trans
import Data.IORef
import Data.List (intercalate)
import Data.Monoid
import Data.Typeable
import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as S8
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Lazy.Char8 as L8
import System.Environment
import System.IO
import System.IO.Error (mkIOError, eofErrorType, isEOFError)
import System.IO.Unsafe

--
-- Iteratee types and instances
--

-- | @ChunkData@ is the class of data types that can be output by an
-- enumerator and iterated on with an iteratee.  A @ChunkData@ type
-- must be a 'Monoid', but must additionally provide a predicate,
-- @null@, for testing whether an object is equal to 'mempty'.
-- Feeding a @null@ chunk to an iteratee followed by any other chunk
-- should have the same effect as just feeding the second chunk.
-- @ChunkData@ must also be convertable to a String with the
-- @chunkShow@ method to simplify debugging.
class (Monoid t) => ChunkData t where
    null :: t -> Bool
    chunkShow :: t -> String
instance (Show a) => ChunkData [a] where
    null = Prelude.null
    chunkShow = show
instance ChunkData L.ByteString where
    null = L.null
    chunkShow = show . L8.unpack
instance ChunkData S.ByteString where
    null = S.null
    chunkShow = show . S8.unpack
instance ChunkData () where
    null _ = True
    chunkShow _ = "()"

-- | @Chunk@ is a wrapper around a 'ChunkData' type that also includes
-- an EOF flag that is 'True' if the data is followed by an
-- end-of-file condition.  An 'Iter' that receives a @Chunk@ with EOF
-- 'True' must return a result (or failure); it is an error to demand
-- more data (return 'IterF') after an EOF.
data Chunk t = Chunk !t !Bool deriving (Eq)

instance (ChunkData t) => Show (Chunk t) where
    showsPrec _ (Chunk t eof) rest =
        chunkShow t ++ if eof then "+EOF" ++ rest else rest

-- | Constructor function that builds a chunk containing data and a
-- 'False' EOF flag.
chunk :: t -> Chunk t
chunk t = Chunk t False

-- | An empty chunk with the EOF flag 'True'.
chunkEOF :: (Monoid t) => Chunk t
chunkEOF = Chunk mempty True

instance (ChunkData t) => Monoid (Chunk t) where
    mempty = Chunk mempty False
    mappend (Chunk a False) (Chunk b eof) = Chunk (mappend a b) eof
    -- We mostly want to avoid appending data to a Chunk that has the
    -- EOF bit set, but make an exception for appending a null chunk,
    -- so that code like the following will work:
    --
    --   (Done (Done "" (Chunk "" True)) (Chunk "" False)) >>= id
    --
    -- While the above code may seem arcane, something similar happens
    -- with, for instance:
    --
    -- do iter <- returnI $ runIter (return "") chunkEOF
    --    iter
    mappend a (Chunk b _) | null b        = a
    mappend _ _                           = error "mappend to EOF"

instance (ChunkData t) => ChunkData (Chunk t) where
    null (Chunk t False) = null t
    null (Chunk _ True)  = False
    chunkShow = show


-- Note that the Ctl types were originally done without
-- MultiParamTypeClasses and FunctionalDependencies, but the result
-- was error prone in that valid control requests would just not be
-- caught if the return type expected didn't match.

-- | Class of control commands for enclosing enumerators.  The class
-- binds each control argument type to a unique result type.
class (Typeable carg, Typeable cres) => CtlCmd carg cres | carg -> cres

-- | A request for a control operation
data CtlReq t m a = forall carg cres. (CtlCmd carg cres) =>
                    CtlReq !carg !(Maybe cres -> Iter t m a)

-- | The basic Iteratee type is @Iter t m a@, where @t@ is the type of
-- input (in class 'ChunkData'), @m@ is a monad in which the iteratee
-- may execute actions (using the 'MonadTrans' 'lift' method), and @a@
-- is the result type of the iteratee.
--
-- An @Iter@ is in one of several states:  it may require more input
-- ('IterF'), it may request some control action other than input data
-- from the enclosing enumerators ('IterC'), it may wish to execute
-- monadic actions in the transformed monad ('IterM'), it may have
-- produced a result ('Done'), or it may have failed.  Failure is
-- indicated by 'IterFail' or 'InumFail', depending on whether the
-- failure occured in an iteratee or enumerator.  In the latter case,
-- when an 'Inum' fails, the 'Iter' it is feeding usually will not
-- have failed.  Thus, the 'InumFail' type includes the state of the
-- 'Iter' that the 'Inum' was feeding.
--
-- Note that @Iter t@ is a 'MonadTrans' and @Iter t m@ is a a 'Monad'
-- (as discussed in the documentation for module "Data.IterIO").
data Iter t m a = IterF !(Chunk t -> Iter t m a)
                -- ^ The iteratee requires more input.
                | IterM !(m (Iter t m a))
                -- ^ The iteratee must execute monadic bind in monad @m@
                | IterC !(CtlReq t m a)
                -- ^ A control request for enclosing enumerators
                | Done a (Chunk t)
                -- ^ Sufficient input was received; the 'Iter' is
                -- returning a result of type @a@.  In adition, the
                -- 'Iter' has a 'Chunk' containing any residual input
                -- that was not consumed in producing the result.
                | IterFail !SomeException
                -- ^ The 'Iter' failed.
                | InumFail !SomeException a
                -- ^ An 'Inum' failed; this result includes status of
                -- the Iteratee.  (The type @a@ will always be @'Iter'
                -- t m a\'@ for some @a'@ in the result of an 'Inum'.)

-- | Show the current state of an 'Iter', prepending it to some
-- remaining input (the standard 'ShowS' optimization), when 'a' is in
-- class 'Show'.  Note that if @a@ is not in 'Show', you can simply
-- use the 'shows' function.
iterShows :: (ChunkData t, Show a) => Iter t m a -> ShowS
iterShows (Done a c) rest = "Done " ++ (shows a $ " " ++ shows c rest)
iterShows (InumFail e a) rest =
    "InumFail " ++ (shows e $ " (" ++ (shows a $ ")" ++ rest))
iterShows iter rest = shows iter rest

-- | Show the current state of an 'Iter' if type @a@ is in the 'Show'
-- class.  (Otherwise, you can simply use the ordinary 'show'
-- function.)
iterShow :: (ChunkData t, Show a) => Iter t m a -> String
iterShow iter = iterShows iter ""

instance (ChunkData t) => Show (Iter t m a) where
    showsPrec _ (IterF _) rest = "IterF _" ++ rest
    showsPrec _ (IterM _) rest = "IterM _" ++ rest
    showsPrec _ (Done _ c) rest = "Done _ " ++ shows c rest
    showsPrec _ (IterC (CtlReq a _)) rest =
        "IterC " ++ show (typeOf a) ++ " _" ++ rest
    showsPrec _ (IterFail e) rest = "IterFail " ++ show e ++ rest
    showsPrec _ (InumFail e _) rest = "InumFail " ++ (shows e $ " _" ++ rest)

instance (ChunkData t, Monad m) => Functor (Iter t m) where
    fmap = liftM

instance (ChunkData t, Monad m) => Applicative (Iter t m) where
    pure   = return
    (<*>)  = ap
    (*>)   = (>>)
    a <* b = do r <- a; b >> return r

instance (ChunkData t, Monad m) => Monad (Iter t m) where
    return a = Done a mempty

    m@(IterF _)           >>= k = IterF $ runIter m >=> k
    (IterM m)             >>= k = IterM $ liftM (>>= k) m
    (Done a c)            >>= k = runIter (k a) c
    (IterC (CtlReq a fr)) >>= k = iterC a $ fr >=> k
    err                   >>= _ = IterFail $ getIterError err

    fail msg = IterFail $ toException $ ErrorCall msg

instance (ChunkData t) => MonadTrans (Iter t) where
    lift m = IterM $ m >>= return . return

-- | The 'Iter' insance of 'MonadIO' handles errors specially.  If the
-- lifted operation throws an exception, 'liftIO' catches the
-- exception and returns it as an 'IterFail' failure.  Moreover, an IO
-- exception satisfying the 'isEOFError' predicate is re-wrapped in an
-- 'IterEOF' type so as to re-parent it below 'IterNoParse' in the
-- exception hierarchy.  ('run' and '|$' un-do the effects of this
-- re-parenting should the exception escape the 'Iter' monad.)  One
-- consequence of this behavior is that with 'Iter', unlike with most
-- monad transformers, 'liftIO' is /not/ equivalent to some number of
-- nested calls to 'lift'.  See the documentation of '.|$' for an
-- example.
instance (ChunkData t, MonadIO m) => MonadIO (Iter t m) where
    liftIO m = do
      result <- lift $ liftIO $ try m
      case result of
        Right ok -> return ok
        Left err -> IterFail $
               case fromException err of
                 Just ioerr | isEOFError ioerr -> toException $ IterEOF ioerr
                 _                             -> err

-- | This is a generalization of 'fixIO' for arbitrary members of the
-- 'MonadIO' class.  
fixMonadIO :: (MonadIO m) =>
              (a -> m a) -> m a
fixMonadIO f = do
  ref <- liftIO $ newIORef $ throw $ toException
         $ ErrorCall "fixMonadIO: non-termination"
  a <- liftIO $ unsafeInterleaveIO $ readIORef ref
  r <- f a
  liftIO $ writeIORef ref r
  return r

instance (ChunkData t, MonadIO m) => MonadFix (Iter t m) where
    mfix f = fixMonadIO f

{- fixIterPure and fixIterIO allow MonadFix instances, which support
   out-of-order name bindings in an "mdo" block, provided your file
   has {-# LANGUAGE RecursiveDo #-} at the top.  A contrived example
   would be:

fixtest :: IO Int
fixtest = enumPure [10] `cat` enumPure [1] |$ fixee
    where
      fixee :: Iter [Int] IO Int
      fixee = mdo
        liftIO $ putStrLn "test #1"
        c <- return $ a + b
        liftIO $ putStrLn "test #2"
        a <- headI
        liftIO $ putStrLn "test #3"
        b <- headI
        liftIO $ putStrLn "test #4"
        return c

-- A very convoluted way of computing factorial
fixtest2 :: Int -> IO Int
fixtest2 i = do
  f <- enumPure [2] `cat` enumPure [1] |$ mfix fact
  run $ f i
    where
      fact :: (Int -> Iter [Int] IO Int)
           -> Iter [Int] IO (Int -> Iter [Int] IO Int)
      fact f = do
               ignore <- headI
               liftIO $ putStrLn $ "ignoring " ++ show ignore
               base <- headI
               liftIO $ putStrLn $ "base is " ++ show base
               return $ \n -> if n <=  0
                              then return base
                              else liftM (n *) (f $ n - 1)
-}

{-
-- | This is a fixed point combinator for iteratees over monads that
-- have no side effects.  If you wish to use @mdo@ with such a monad,
-- you can define an instance of 'MonadFix' in which
-- @'mfix' = fixIterPure@.  However, be warned that this /only/ works
-- when computations in the monad have no side effects, as
-- @fixIterPure@ will repeatedly re-invoke the function passsed in
-- when more input is required (thereby also repeating side-effects).
-- For cases in which the monad may have side effects, if the monad is
-- in the 'MonadIO' class then there is already an 'mfix' instance
-- defined using 'fixMonadIO'.
fixIterPure :: (ChunkData t, MonadFix m) =>
               (a -> Iter t m a) -> Iter t m a
fixIterPure f = IterM $ mfix ff
    where
      ff ~(Done a _)  = check $ f a
      -- Warning: IterF case re-runs function, repeating side effects
      check (IterF i) = return $ IterF $ \c ->
                        fixIterPure $ \a -> runIter (f a) c
      check (IterM m) = m >>= check
      check iter      = return iter
-}


--
-- Internal utility functions
--

-- | @iterC carg fr = 'IterC' ('CtlReq' carg fr)@
iterC :: (CtlCmd carg cres) => carg -> (Maybe cres -> Iter t m a) -> Iter t m a
iterC carg fr = IterC (CtlReq carg fr)

getIterError                 :: Iter t m a -> SomeException
getIterError (IterFail e)   = e
getIterError (InumFail e _) = e
getIterError (IterM _)      = error "getIterError: no error (in IterM state)"
getIterError (IterC _)      = error "getIterError: no error (in IterC state)"
getIterError _              = error "getIterError: no error to extract"

-- | True if an iteratee or an enclosing enumerator has experienced a
-- failure.  (@isIterError@ is always 'True' when 'isEnumError' is
-- 'True', but the converse is not true.)
isIterError :: Iter t m a -> Bool
isIterError (IterFail _)   = True
isIterError (InumFail _ _) = True
isIterError _              = False

-- | True if an enumerator enclosing an iteratee has experienced a
-- failure (but not if the iteratee itself failed).
isEnumError :: Iter t m a -> Bool
isEnumError (InumFail _ _) = True
isEnumError _              = False

-- | True if an 'Iter' is requesting something from an
-- enumerator--i.e., the 'Iter' is not 'Done' and is not in one of the
-- error states.
isIterActive :: Iter t m a -> Bool
isIterActive (IterF _) = True
isIterActive (IterM _) = True
isIterActive (IterC _) = True
isIterActive _         = False

-- | Apply a function to the next state of an 'Iter' if it is still
-- active, or to the current state if it is not.  In other words, when
-- the 'Iter' is in the 'IterF' state, feed it an input chunk, then
-- apply the function to the resulting 'Iter'.  When in the 'IterM'
-- state, execute the monadic action, then apply the function.  In the
-- 'IterC' state, try executing the control request, then apply the
-- function to the result of the (successful or unsuccessful)
-- operation.
apNext :: (Monad m) =>
          (Iter t m a -> Iter t m b)
       -> Iter t m a
       -> Iter t m b
apNext f (IterF iterf)            = IterF $ f . iterf
apNext f (IterM iterm)            = IterM $ iterm >>= return . f
apNext f (IterC (CtlReq carg fr)) = iterC carg $ f . fr
apNext f iter                     = f iter

-- | Like 'apNext', but feed an EOF to the 'Iter' if it is in the
-- 'IterF' state.  Thus it can be used within 'Iter's that have a
-- different input type from the 'Iter' the function is being applied
-- to.
apRun :: (Monad m, ChunkData t1) =>
         (Iter t1 m a -> Iter t2 m b)
      -> Iter t1 m a
      -> Iter t2 m b
apRun f iter@(IterF _)           = f $ unEOF $ runIter iter chunkEOF
apRun f (IterM iterm)            = IterM $ iterm >>= return . f
apRun f (IterC (CtlReq carg fr)) = iterC carg $ f . fr
apRun f iter                     = f iter

-- | Remove EOF bit from an Iter in the 'Done' state.
unEOF :: (Monad m, ChunkData t) => Iter t m a -> Iter t m a
unEOF = wrapI fixeof
    where
      fixeof (Done a (Chunk t _)) = Done a (Chunk t False)
      fixeof iter                 = iter

--
-- Core functions
--

-- | Runs an 'Iter' on a 'Chunk' of data.  When the 'Iter' is already
-- 'Done', or in some error condition, simulates the behavior
-- appropriately.
--
-- Note that this function asserts the following invariants on the
-- behavior of an 'Iter':
--
--     1. An 'Iter' may not return an 'IterF' (asking for more input)
--        if it received a 'Chunk' with the EOF bit 'True'.  (It is
--        okay to return IterF after issuing a successful 'IterC'
--        request.)
--
--     2. An 'Iter' returning 'Done' must not set the EOF bit if it
--        did not receive the EOF bit.
--
-- It /is/, however, okay for an 'Iter' to return 'Done' without the
-- EOF bit even if the EOF bit was set on its input chunk, as
-- @runIter@ will just propagate the EOF bit.  For instance, the
-- following code is valid:
--
-- @
--      runIter (return ()) 'chunkEOF'
-- @
--
-- Even though it is equivalent to:
--
-- @
--      runIter ('Done' () ('Chunk' 'mempty' False)) ('Chunk' 'mempty' True)
-- @
--
-- in which the first argument to @runIter@ appears to be discarding
-- the EOF bit from the input chunk.  @runIter@ will propagate the EOF
-- bit, making the above code equivalent to to @'Done' () 'chunkEOF'@.
--
-- On the other hand, the following code is illegal, as it violates
-- invariant 2 above:
--
-- @
--      runIter ('Done' () 'chunkEOF') $ 'Chunk' \"some data\" False -- Bad
-- @
runIter :: (ChunkData t, Monad m) =>
           Iter t m a
        -> Chunk t
        -> Iter t m a
runIter iter c | null c           = iter
runIter (IterF f) c@(Chunk _ eof) = (if eof then forceEOF else noEOF) $ f c
    where
      noEOF (Done _ (Chunk _ True)) = error "runIter: IterF returned bad EOF"
      noEOF iter                    = iter
      forceEOF (IterF _)             = error "runIter: IterF returned after EOF"
      forceEOF (IterM m)             = IterM $ forceEOF `liftM` m
      forceEOF (IterC (CtlReq a fr)) = iterC a $ \r -> 
                                       case r of Just _  -> fr r
                                                 Nothing -> forceEOF $ fr r
      forceEOF iter                  = iter
runIter (IterM m) c               = IterM $ flip runIter c `liftM` m
runIter (Done a c) c'             = Done a (mappend c c')
runIter (IterC (CtlReq a fr)) c   = iterC a $ flip runIter c . fr
runIter err _                     = err

unIterEOF :: SomeException -> SomeException
unIterEOF e = case fromException e of
                Just (IterEOF e') -> toException e'
                _                 -> e

-- | Return the result of an iteratee.  If it is still in the 'IterF'
-- state, feed it an EOF to extract a result.  Throws an exception if
-- there has been a failure.
run :: (ChunkData t, Monad m) => Iter t m a -> m a
run iter@(IterF _)        = run $ runIter iter chunkEOF
run (IterM m)             = m >>= run
run (Done a _)            = return a
run (IterC (CtlReq _ fr)) = run $ fr Nothing
run (IterFail e)          = throw $ unIterEOF e
run (InumFail e _)        = throw $ unIterEOF e


--
-- Exceptions
--

-- | Generalized class of errors that occur when an Iteratee does not
-- receive expected input.  (Catches 'IterEOF', 'IterExpected', and
-- the miscellaneous 'IterParseErr'.)
data IterNoParse = forall a. (Exception a) => IterNoParse a deriving (Typeable)
instance Show IterNoParse where
    showsPrec _ (IterNoParse e) rest = show e ++ rest
instance Exception IterNoParse

noParseFromException :: (Exception e) => SomeException -> Maybe e
noParseFromException s = do IterNoParse e <- fromException s; cast e

noParseToException :: (Exception e) => e -> SomeException
noParseToException = toException . IterNoParse

-- | End-of-file occured in an Iteratee that required more input.
data IterEOF = IterEOF IOError deriving (Typeable)
instance Show IterEOF where
    showsPrec _ (IterEOF e) rest = show e ++ rest
instance Exception IterEOF where
    toException = noParseToException
    fromException = noParseFromException

-- | True if and only if an exception is of type 'IterEOF'.
isIterEOF :: SomeException -> Bool
isIterEOF err = case fromException err of
                  Just (IterEOF _) -> True
                  Nothing          -> False

-- | Iteratee expected particular input and did not receive it.
data IterExpected = IterExpected {
      iexpReceived :: String    -- ^ Input actually received
    , iexpWanted :: [String]    -- ^ List of inputs expected
    } deriving (Typeable)
instance Show IterExpected where
    showsPrec _ (IterExpected saw [token]) rest =
        "Iter expected " ++ token ++ ", saw " ++ saw ++ rest
    showsPrec _ (IterExpected saw tokens) rest =
        "Iter expected one of ["
        ++ intercalate ", " tokens ++ "]," ++ " saw " ++ saw ++ rest
instance Exception IterExpected where
    toException = noParseToException
    fromException = noParseFromException

-- | Miscellaneous Iteratee parse error.
data IterParseErr = IterParseErr String deriving (Typeable)
instance Show IterParseErr where
    showsPrec _ (IterParseErr err) rest =
        "Iteratee parse error: " ++ err ++ rest
instance Exception IterParseErr where
    toException = noParseToException
    fromException = noParseFromException

-- | Run an Iteratee, and if it throws a parse error by calling
-- 'expectedI', then combine the exptected tokens with those of a
-- previous parse error.
combineExpected :: (ChunkData t, Monad m) =>
                   IterNoParse
                -- ^ Previous parse error
                -> Iter t m a
                -- ^ Iteratee to run and, if it fails, combine with
                -- previous error
                -> Iter t m a
combineExpected (IterNoParse e) iter =
    case cast e of
      Just (IterExpected saw1 e1) -> mapExceptionI (combine saw1 e1) iter
      _                        -> iter
    where
      combine saw1 e1 (IterExpected saw2 e2) =
          IterExpected (if null saw2 then saw1 else saw2) $ e1 ++ e2

-- | Try two Iteratees and return the result of executing the second
-- if the first one throws an 'IterNoParse' exception.  Note that
-- "Data.IterIO.Parse" defines @'<|>'@ as an infix synonym for this
-- function.
--
-- The statement @multiParse a b@ is similar to @'ifParse' a return
-- b@, but the two functions operate differently.  Depending on the
-- situation, only one of the two formulations may be correct.
-- Specifically:
-- 
--  * @'ifParse' a f b@ works by first executing @a@, saving a copy of
--    all input consumed by @a@.  If @a@ throws a parse error, the
--    saved input is used to backtrack and execute @b@ on the same
--    input that @a@ just rejected.  If @a@ suceeds, @b@ is never run;
--    @a@'s result is fed to @f@, and the resulting action is executed
--    without backtracking (so any error thrown within @f@ will not be
--    caught by this 'ifParse' expression).
--
--  * Instead of saving input, @multiParse a b@ executes both @a@ and
--    @b@ concurrently as input chunks arrive.  If @a@ throws a parse
--    error, then the result of executing @b@ is returned.  If @a@
--    either succeeds or throws an exception not of class
--    'IterNoParse', then the result of running @a@ is returned.
--
--  * With @multiParse a b@, if @b@ returns a value, executes a
--    monadic action via 'lift', or issues a control request via
--    'ctlI', then further processing of @b@ will be suspended until
--    @a@ experiences a parse error, and thus the behavior will be
--    equivalent to @'ifParse' a return b@.
--
-- The main restriction on 'ifParse' is that @a@ must not consume
-- unbounded amounts of input, or the program may exhaust memory
-- saving the input for backtracking.  Note that the second argument
-- to 'ifParse' (i.e., 'return' in @ifParse a return b@) is a
-- continuation for @a@ when @a@ succeeds.
--
-- The advantage of @multiParse@ is that it can avoid storing
-- unbounded amounts of input for backtracking purposes if both
-- 'Iter's consume data.  Another advantage is that with an expression
-- such as @'ifParse' a f b@, sometimes it is not convenient to break
-- the parse target into an action to execute with backtracking (@a@)
-- and a continuation to execute without backtracking (@f@).  The
-- equivalent @multiParse (a >>= f) b@ avoids the need to do this,
-- since it does not do backtracking.
--
-- However, it is important to note that it is still possible to end
-- up storing unbounded amounts of input with @multiParse@.  For
-- example, consider the following code:
--
-- > total :: (Monad m) => Iter String m Int
-- > total = multiParse parseAndSumIntegerList (return -1) -- Bad
--
-- Here the intent is for @parseAndSumIntegerList@ to parse a
-- (possibly huge) list of integers and return their sum.  If there is
-- a parse error at any point in the input, then the result is
-- identical to having defined @total = return -1@.  But @return -1@
-- succeeds immediately, consuming no input, which means that @total@
-- must return all left-over input for the next action (i.e., @next@
-- in @total >>= next@).  Since @total@ has to look arbitrarily far
-- into the input to determine that @parseAndSumIntegerList@ fails, in
-- practice @total@ will have to save all input until it knows that
-- @parseAndSumIntegerList@ suceeds.
--
-- A better approach might be:
--
-- @
--   total = multiParse parseAndSumIntegerList ('nullI' >> return -1)
-- @
--
-- Here 'nullI' discards all input until an EOF is encountered, so
-- there is no need to keep a copy of the input around.  This makes
-- sense so long as @total@ is the last or only Iteratee run on the
-- input stream.  (Otherwise, 'nullI' would have to be replaced with
-- an Iteratee that discards input up to some end-of-list marker.)
--
-- Another approach might be to avoid parsing combinators entirely and
-- use:
--
-- @
--   total = parseAndSumIntegerList ``catchI`` handler
--       where handler \('IterNoParse' _) _ = return -1
-- @
--
-- This last definition of @total@ may leave the input in some
-- partially consumed state (including input beyond the parse error
-- that just happened to be in the chunk that caused the parse error).
-- But this is fine so long as @total@ is the last Iteratee executed
-- on the input stream.
multiParse :: (ChunkData t, Monad m) =>
              Iter t m a -> Iter t m a -> Iter t m a
multiParse a@(IterF _) b
    | useIfParse b = ifParse a return b
    | otherwise    = do c <- chunkI
                        multiParse (runIter a c) (runIter b c)
    where
      -- If b is IterM, IterC, or Done, we will just accumulate all
      -- the input anyway inside 'runIter', so we might as well do it
      -- efficiently with 'copyInput' (which is what 'ifParse' uses,
      -- indirectly, via 'tryBI').
      useIfParse (Done _ _) = True
      useIfParse (IterM _)  = True
      useIfParse (IterC _)  = True
      useIfParse _          = False
multiParse a b
    | isIterActive a = apNext (flip multiParse b) a
    | otherwise      = a `catchI` \err _ -> combineExpected err b

-- | @ifParse iter success failure@ runs @iter@, but saves a copy of
-- all input consumed using 'tryBI'.  (This means @iter@ must not
-- consume unbounded amounts of input!  See 'multiParse' for such
-- cases.)  If @iter@ suceeds, its result is passed to the function
-- @success@.  If @iter@ throws an exception of type 'IterNoParse',
-- then @failure@ is executed with the input re-wound (so that
-- @failure@ is fed the same input that @iter@ was).  If @iter@ throws
-- any other type of exception, @ifParse@ passes the exception back
-- and does not execute @failure@.
--
-- See "Data.IterIO.Parse" for a discussion of this function and the
-- related infix operator @\\/@ (which is a synonym for 'ifNoParse').
ifParse :: (ChunkData t, Monad m) =>
           Iter t m a
        -- ^ Iteratee @iter@ to run with backtracking
        -> (a -> Iter t m b)
        -- ^ @success@ function
        -> Iter t m b
        -- ^ @failure@ action
        -> Iter t m b
        -- ^ result
ifParse iter yes no = do
  ea <- tryBI iter
  case ea of
    Right a  -> yes a
    Left err -> combineExpected err no

-- | @ifNoParse@ is just 'ifParse' with the second and third arguments
-- reversed.
ifNoParse :: (ChunkData t, Monad m) =>
             Iter t m a -> Iter t m b -> (a -> Iter t m b) -> Iter t m b
ifNoParse iter no yes = ifParse iter yes no

-- | Throw an exception from an Iteratee.  The exception will be
-- propagated properly through nested Iteratees, which will allow it
-- to be categorized properly and avoid situations in which, for
-- instance, functions holding 'MVar's are prematurely terminated.
-- (Most Iteratee code does not assume the Monad parameter @m@ is in
-- the 'MonadIO' class, and so cannot use 'catch' or @'onException'@
-- to clean up after exceptions.)  Use 'throwI' in preference to
-- 'throw' whenever possible.
throwI :: (Exception e) => e -> Iter t m a
throwI e = IterFail $ toException e

-- | Throw an exception of type 'IterEOF'.  This will be interpreted
-- by 'mkOnum' and 'mkInum' as an end of file chunk when thrown by the
-- generator/codec.  It will also be interpreted by 'ifParse' and
-- 'multiParse' as an exception of type 'IterNoParse'.  If not caught
-- within the 'Iter' monad, the exception will be rethrown by 'run'
-- (and hence '|$') as an 'IOError' of type EOF.
throwEOFI :: String -> Iter t m a
throwEOFI loc = throwI $ IterEOF $ mkIOError eofErrorType loc Nothing Nothing

-- | Internal function used by 'tryI' and 'backtrackI' when re-propagating
-- exceptions that don't match the requested exception type.  (To make
-- the overall types of those two funcitons work out, a 'Right'
-- constructor needs to be wrapped around the returned failing
-- iteratee.)
fixError :: (ChunkData t, Monad m) =>
            Iter t m a -> Iter t m (Either x a)
fixError (InumFail e i) = InumFail e $ Right i
fixError iter           = IterFail $ getIterError iter

-- | If an 'Iter' succeeds and returns @a@, returns @'Right' a@.  If
-- the 'Iter' throws an exception @e@, returns @'Left' (e, i)@ where
-- @i@ is the state of the failing 'Iter'.
tryI :: (ChunkData t, Monad m, Exception e) =>
        Iter t m a
     -> Iter t m (Either (e, Iter t m a) a)
tryI = wrapI errToEither
    where
      errToEither (Done a c) = Done (Right a) c
      errToEither iter       = case fromException $ getIterError iter of
                                 Just e  -> return $ Left (e, iter)
                                 Nothing -> fixError iter

-- | Runs an 'Iter' until it no longer requests input, keeping a copy
-- of all input that was fed to it (which might be longer than the
-- input that the 'Iter' actually consumed, because fed input includes
-- any residual data returned in the 'Done' state).
copyInput :: (ChunkData t, Monad m) =>
          Iter t m a
       -> Iter t m (Iter t m a, Chunk t)
copyInput iter1 = doit id iter1
    where
      -- It is usually faster to use mappend in a right associative
      -- way (i.e, mappend a1 (mappend a2 (mappand a3 a4)) will be
      -- faster than mappend (mappend (mappend a1 a2) a3) a4).  Thus,
      -- acc is a function of the rest of the input, rather than a
      -- simple prefix of ithe input.  This is the same technique used
      -- by 'ShowS' to optimize the use of (++) on srings.
      doit acc iter@(IterF _) =
          IterF $ \c -> doit (acc . mappend c) (runIter iter c)
      doit acc iter | isIterActive iter = apNext (doit acc) iter
      doit acc iter                     = return (iter, acc mempty)

-- | Simlar to 'tryI', but saves all data that has been fed to the
-- 'Iter', and rewinds the input if the 'Iter' fails.  (The @B@ in
-- @tryBI@ stands for \"backtracking\".)  Thus, if @tryBI@ returns
-- @'Left' exception@, the next 'Iter' to be invoked will see the same
-- input that caused the previous 'Iter' to fail.  (For this reason,
-- it makes no sense ever to call 'resumeI' on the 'Iter' you get back
-- from @tryBI@, which is why @tryBI@ does not return the failing
-- Iteratee the way 'tryI' does.)
--
-- Because @tryBI@ saves a copy of all input, it can consume a lot of
-- memory and should only be used when the 'Iter' argument is known to
-- consume a bounded amount of data.
tryBI :: (ChunkData t, Monad m, Exception e) =>
         Iter t m a
      -> Iter t m (Either e a)
tryBI iter1 = copyInput iter1 >>= errToEither
    where
      errToEither (Done a c, _) = Done (Right a) c
      errToEither (iter, c)     = case fromException $ getIterError iter of
                                   Just e  -> Done (Left e) c
                                   Nothing -> fixError iter

-- | Catch an exception thrown by an 'Iter'.  Returns the failed
-- 'Iter' state, which may contain more information than just the
-- exception.  For instance, if the exception occured in an
-- enumerator, the returned 'Iter' will also contain an inner 'Iter'
-- that has not failed.  To avoid discarding this extra information,
-- you should not re-throw exceptions with 'throwI'.  Rather, you
-- should re-throw an exception by re-executing the failed 'Iter'.
-- For example, you could define an @onExceptionI@ function analogous
-- to the standard library @'onException'@ as follows:
--
-- @
--  onExceptionI iter cleanup =
--      iter \`catchI\` \\('SomeException' _) iter' -> cleanup >> iter'
-- @
--
-- If you wish to continue processing the iteratee after a failure in
-- an enumerator, use the 'resumeI' function.  For example:
--
-- @
--  action \`catchI\` \\('SomeException' e) iter ->
--      if 'isEnumError' iter
--        then do liftIO $ putStrLn $ \"ignoring enumerator failure: \" ++ show e
--                'resumeI' iter
--        else iter
-- @
--
-- @catchI@ catches both iteratee and enumerator failures.  However,
-- because enumerators are functions on iteratees, you must apply
-- @catchI@ to the /result/ of executing an enumerator.  For example,
-- the following code modifies 'enumPure' to catch and ignore an
-- exception thrown by a failing 'Iter':
--
-- > catchTest1 :: IO ()
-- > catchTest1 = myEnum |$ fail "bad Iter"
-- >     where
-- >       myEnum :: Onum String IO ()
-- >       myEnum iter = catchI (enumPure "test" iter) handler
-- >       handler (SomeException _) iter = do
-- >         liftIO $ hPutStrLn stderr "ignoring exception"
-- >         return ()
--
-- Note that @myEnum@ is an 'Onum', but it takes an argument, @iter@,
-- reflecting the usually hidden fact that 'Onum's are actually
-- functions.  Thus, @catchI@ is wrapped around the result of applying
-- @'enumPure' \"test\"@ to an 'Iter'.
--
-- Another subtlety to keep in mind is that, when fusing enumerators,
-- the type of the outer enumerator must reflect the fact that it is
-- wrapped around an inner enumerator.  Consider the following test,
-- in which an exception thrown by an inner enumerator is caught:
--
-- > inumBad :: (ChunkData t, Monad m) => Inum t t m a
-- > inumBad = mkInum' $ fail "inumBad"
-- > 
-- > catchTest2 :: IO ()
-- > catchTest2 = myEnum |.. inumBad |$ nullI
-- >     where
-- >       myEnum :: Onum String IO (Iter String IO ())
-- >       myEnum iter = catchI (enumPure "test" iter) handler
-- >       handler (SomeException _) iter = do
-- >         liftIO $ hPutStrLn stderr "ignoring exception"
-- >         return $ return ()
--
-- Note the type of @myEnum :: Onum String IO (Iter String IO ())@
-- reflects that it has been fused to an inner enumerator.  Usually
-- these enumerator result types are computed automatically and you
-- don't have to worry about them as long as your enumreators are
-- polymorphic in the result type.  However, to return a result that
-- suppresses the exception here, we must run @return $ return ()@,
-- invoking @return@ twice, once to create an @Iter String IO ()@, and
-- a second time to create an @Iter String IO (Iter String IO ())@.
-- (To avoid such nesting proliferation in 'Onum' types, it is
-- sometimes easier to fuse multiple 'Inum's together with '..|..',
-- before fusing them to an 'Onum'.)
--
-- If you are only interested in catching enumerator failures, see the
-- functions 'enumCatch' and `inumCatch`, which catch enumerator but
-- not iteratee failures.
--
-- Note that @catchI@ only works for /synchronous/ exceptions, such as
-- IO errors (thrown within 'liftIO' blocks), the monadic 'fail'
-- operation, and exceptions raised by 'throwI'.  It is not possible
-- to catch /asynchronous/ exceptions, such as lazily evaluated
-- divide-by-zero errors, the 'throw' function, or exceptions raised
-- by other threads using @'throwTo'@.
catchI :: (Exception e, ChunkData t, Monad m) =>
          Iter t m a
       -- ^ 'Iter' that might throw an exception
       -> (e -> Iter t m a -> Iter t m a)
       -- ^ Exception handler, which gets as arguments both the
       -- exception and the failing 'Iter' state.
       -> Iter t m a
catchI iter handler = wrapI check iter
    where
      check iter'@(Done _ _) = iter'
      check err              = case fromException $ getIterError err of
                                 Just e  -> handler e err
                                 Nothing -> err

-- | Catch exception with backtracking.  This is a version of 'catchI'
-- that keeps a copy of all data fed to the iteratee.  If an exception
-- is caught, the input is re-wound before running the exception
-- handler.  Because this funciton saves a copy of all input, it
-- should not be used on Iteratees that consume unbounded amounts of
-- input.  Note that unlike 'catchI', this function does not return
-- the failing Iteratee, because it doesn't make sense to call
-- 'resumeI' on an Iteratee after re-winding the input.
catchBI :: (Exception e, ChunkData t, Monad m) =>
           Iter t m a
        -> (e -> Iter t m a)
        -> Iter t m a
catchBI iter handler = copyInput iter >>= uncurry check
    where
      check iter'@(Done _ _) _ = iter'
      check err input          = case fromException $ getIterError err of
                                   Just e  -> runIter (handler e) input
                                   Nothing -> err

-- | A version of 'catchI' with the arguments reversed, analogous to
-- @'handle'@ in the standard library.  (A more logical name for this
-- function might be @handleI@, but that name is used for the file
-- handle iteratee in "Data.IterIO.ListLike".)
handlerI :: (Exception e, ChunkData t, Monad m) =>
          (e -> Iter t m a -> Iter t m a)
         -- ^ Exception handler
         -> Iter t m a
         -- ^ 'Iter' that might throw an exception
         -> Iter t m a
handlerI = flip catchI

-- | 'catchBI' with the arguments reversed.
handlerBI :: (Exception e, ChunkData t, Monad m) =>
             (e -> Iter t m a)
          -- ^ Exception handler
          -> Iter t m a
          -- ^ 'Iter' that might throw an exception
          -> Iter t m a
handlerBI = flip catchBI

-- | Like 'catchI', but applied to 'Onum's and 'Inum's instead of
-- 'Iter's, and does not catch errors thrown by 'Iter's.
--
-- There are three 'catch'-like functions in the iterIO library,
-- catching varying numbers of types of failures.  @inumCatch@ is the
-- middle option.  By comparison:
--
-- * 'catchI' catches the most errors, including those thrown by
--   'Iter's.  'catchI' can be applied to 'Iter's, 'Inum's, or
--   'mkOnum's, and is useful both to the left and to the right of
--   '|$'.
--
-- * @inumCatch@ catches 'Inum' or 'Onum' failures, but not 'Iter'
--   failures.  It can be applied to 'Inum's or 'Onum's, to the left
--   or to the right of '|$'.  When applied to the left of '|$', will
--   not catch any errors thrown by 'Inum's to the right of '|$'.
--
-- * 'enumCatch' only catches 'Onum' failures, and should only be
--   applied to the left of '|$'.  (You /can/ apply 'enumCatch' to
--   'Inum's or to the right of '|$', but this is not useful because
--   it ignores 'Iter' and 'Inum' failures so won't catch anything.)
--
-- One potentially unintuitive apsect of @inumCatch@ is that, when
-- applied to an enumerator, it catches any enumerator failure to the
-- right that is on the same side of '|$'--even enumerators not
-- lexically scoped within the argument of @inumCatch@.  See
-- 'enumCatch' for some examples of this behavior.
inumCatch :: (Exception e, ChunkData tIn, Monad m) =>
              Inum tIn tOut m a
           -- ^ 'Inum' that might throw an exception
           -> (e -> InumR tIn tOut m a -> InumR tIn tOut m a)
           -- ^ Exception handler
           -> Inum tIn tOut m a
inumCatch enum handler iter = wrapI check $ enum iter
    where
      check i@(InumFail e _) = case fromException e of
                                 Just e' -> handler e' i
                                 Nothing -> i
      check i                = i

-- | 'inumCatch' with the argument order switched.
inumHandler :: (Exception e, ChunkData tIn, Monad m) =>
               (e -> InumR tIn tOut m a -> InumR tIn tOut m a)
            -- ^ Exception handler
            -> Inum tIn tOut m a
            -- ^ 'Inum' that might throw an exception
            -> Inum tIn tOut m a
inumHandler = flip inumCatch


--   Like 'catchI', but for 'Onum's instead of 'Iter's.  Catches
-- errors thrown by an 'Onum', but /not/ those thrown by 'Inum's
-- fused to the 'Onum' after @enumCatch@ has been applied, and not
-- exceptions thrown from an 'Iter'.  If you want to catch all
-- enumerator errors, including those from subsequently fused
-- 'Inum's, see the `inumCatch` function.  For example, compare
-- @test1@ (which throws an exception) to @test2@ and @test3@ (which
-- do not):
--
-- >    inumBad :: (ChunkData t, Monad m) => Inum t t m a
-- >    inumBad = mkInum' $ fail "inumBad"
-- >    
-- >    skipError :: (ChunkData t, MonadIO m) =>
-- >                 SomeException -> Iter t m a -> Iter t m a
-- >    skipError e iter = do
-- >      liftIO $ hPutStrLn stderr $ "skipping error: " ++ show e
-- >      resumeI iter
-- >    
-- >    -- Throws an exception
-- >    test1 :: IO ()
-- >    test1 = enumCatch (enumPure "test") skipError |.. inumBad |$ nullI
-- >    
-- >    -- Does not throw an exception, because inumCatch catches all
-- >    -- enumerator errors on the same side of '|$', including from
-- >    -- subsequently fused inumBad.
-- >    test2 :: IO ()
-- >    test2 = inumCatch (enumPure "test") skipError |.. inumBad |$ nullI
-- >    
-- >    -- Does not throw an exception, because enumCatch was applied
-- >    -- after inumBad was fused to enumPure.
-- >    test3 :: IO ()
-- >    test3 = enumCatch (enumPure "test" |.. inumBad) skipError |$ nullI
--
-- Note that both @\`enumCatch\`@ and ``inumCatch`` have the default
-- infix precedence (@infixl 9@), which binds more tightly than any
-- concatenation or fusing operators.


-- | Used in an exception handler, after an enumerator fails, to
-- resume processing of the 'Iter' by the next enumerator in a
-- concatenated series.  See 'catchI' for an example.
resumeI :: (ChunkData tIn, Monad m) =>
           InumR tIn tOut m a -> InumR tIn tOut m a
resumeI (InumFail _ iter) = return iter
resumeI iter              = iter

-- | Like 'resumeI', but if the failure was in an enumerator and the
-- iteratee is resumable, prints an error message to standard error
-- before invoking 'resumeI'.
verboseResumeI :: (ChunkData tIn, MonadIO m) =>
                  InumR tIn tOut m a -> InumR tIn tOut m a
verboseResumeI iter | isEnumError iter = do
  prog <- liftIO $ getProgName
  liftIO $ hPutStrLn stderr $ prog ++ ": " ++ show (getIterError iter)
  resumeI iter
verboseResumeI iter = iter

-- | Similar to the standard @'mapException'@ function in
-- "Control.Exception", but operates on exceptions propagated through
-- the 'Iter' monad, rather than language-level exceptions.
mapExceptionI :: (Exception e1, Exception e2, ChunkData t, Monad m) =>
                 (e1 -> e2) -> Iter t m a -> Iter t m a
mapExceptionI f iter1 = wrapI check iter1
    where
      check (IterFail e)    = IterFail (doMap e)
      check (InumFail e a) = InumFail (doMap e) a
      check iter            = iter
      doMap e = case fromException e of
                  Just e' -> toException (f e')
                  Nothing -> e

--
-- Some super-basic Iteratees
--

-- | Sinks data like @\/dev\/null@, returning @()@ on EOF.
nullI :: (Monad m, Monoid t) => Iter t m ()
nullI = IterF $ check
    where
      check (Chunk _ True) = Done () chunkEOF
      check _              = nullI

-- | Returns any non-empty amount of input data, or throws an
-- exception if EOF is encountered and there is no data.
dataI :: (Monad m, ChunkData t) => Iter t m t
dataI = IterF nextChunk
    where
      nextChunk (Chunk d True) | null d = throwEOFI "dataI"
      nextChunk (Chunk d _)             = return d

-- | Returns a non-empty 'Chunk' or an EOF 'Chunk'.
chunkI :: (Monad m, ChunkData t) => Iter t m (Chunk t)
chunkI = IterF $ \c -> if null c then chunkI else return c

-- | Runs an 'Iter' without consuming any input if the 'Iter'
-- succeeds.  (See 'tryBI' if you want to avoid consuming input when
-- the 'Iter' fails.)
peekI :: (ChunkData t, Monad m) =>
         Iter t m a
      -> Iter t m a
peekI iter0 = copyInput iter0 >>= check
    where
      check (Done a _, c) = Done a c
      check (iter, _)     = iter

-- | Does not actually consume any input, but returns 'True' if there
-- is no more input data to be had.
atEOFI :: (Monad m, ChunkData t) => Iter t m Bool
atEOFI = IterF check
    where
      check c@(Chunk t eof) | not (null t) = Done False c
                            | eof          = Done True c
                            | otherwise    = atEOFI

-- | Wrap a function around an 'Iter' to transform its result.  The
-- 'Iter' will be fed 'Chunk's as usual for as long as it remains in
-- one of the 'IterF', 'IterM', or 'IterC' states.  When the 'Iter'
-- enters a state other than one of these, @wrapI@ passes it through
-- the tranformation function.
wrapI :: (ChunkData t, Monad m) =>
         (Iter t m a -> Iter t m b) -- ^ Transformation function
      -> Iter t m a                 -- ^ Original 'Iter'
      -> Iter t m b                 -- ^ Returns an 'Iter' whose
                                    -- result will be transformed by
                                    -- the transformation function
wrapI f = next
    where next iter | isIterActive iter = apNext next iter
                    | otherwise         = f iter

-- | A function that sort of acts like ('>>='), except that it
-- preserves 'InumFail' failures.  (Ordinary '>>=' will translate an
-- 'InumFail' into an 'IterFail'.)
bindFail :: (ChunkData t, Monad m) =>
            Iter t m a -> (a -> Iter t m a) -> Iter t m a
bindFail iter0 next = do
  iter <- resultI $ runI iter0
  case iter of
    InumFail e i -> InumFail e i
    _            -> iter >>= next

-- | Runs an 'Iter' from within a different 'Iter' monad (feeding it
-- EOF if it is in the 'IterF' state) so as to extract a return value.
-- The return value is lifted into the invoking 'Iter' monad.  If the
-- 'Iter' being run fails, then @runI@ will propagate the failure by
-- also failing in the enclosing monad..
runI :: (ChunkData t1, ChunkData t2, Monad m) =>
        Iter t1 m a
     -> Iter t2 m a
runI (Done a _)            = return a
runI (IterFail e)          = IterFail e
runI (InumFail e i)        = InumFail e i
-- When running, don't propagate control requests back
runI (IterC (CtlReq _ fr)) = runI $ fr Nothing
runI iter                  = apRun runI iter

-- | Join the result of an 'Inum', turning it into an 'Iter'.  The
-- behavior of @joinI@ is similar to what one would obtain by defining
-- @joinI iter = iter >>= 'runI'@, but with more precise error
-- handling.  Specifically, with @iter >>= 'runI'@, the @'>>='@
-- operator for 'Iter' translates enumerator failures ('InumFail')
-- into an iteratee failures ('IterFail'), discarding the state of the
-- 'Iter' even when the failure occured in an 'Inum'.  By contrast,
-- @joinI@ preserves enumerator failures, allowing the state of the
-- non-failed 'Iter' to be resumed by 'resumeI'.  (The fusing
-- operators '|..' and '..|' use @joinI@ internally, and it is this
-- error preserving property that allos 'inumCatch' and 'resumeI' to
-- work properly.)
joinI :: (ChunkData tOut, ChunkData tIn, Monad m) =>
         InumR tIn tOut m a
      -> Iter tIn m a
joinI (Done i c)     = runI i `bindFail` flip Done c
joinI (IterFail e)   = IterFail e
joinI (InumFail e i) = runI i `bindFail` InumFail e
joinI iter           = apRun joinI iter

-- | Allows you to look at the state of an 'Iter' by returning it into
-- an 'Iter' monad.  This is just like the monadic 'return' method,
-- except that so long as the 'Iter' is in the 'IterM' or 'IterC'
-- state, then the monadic action or control request is executed.
-- Thus, 'Iter's that do not require input, such as
-- @returnI $ liftIO $ ...@, can execute and return a result (possibly
-- reflecting exceptions) immediately.  Moreover, code looking at an
-- 'Iter' produced with @iter <- returnI someOtherIter@ does not need
-- to worry about the 'IterM' or 'IterC' cases, since the returned
-- 'Iter' is guaranteed not to be in one of those states.
returnI :: (ChunkData tIn, ChunkData tOut, Monad m) =>
           Iter tOut m a
        -> Iter tIn m (Iter tOut m a)
returnI iter@(IterM _) = apRun returnI iter
returnI iter@(IterC _) = apRun returnI iter
returnI iter           = return iter

-- | @resultI@ is like a version of 'returnI' that additionally
-- ensures the returned 'Iter' is not in the 'IterF' state.  Moreover,
-- if the returned 'Iter' is in the 'Done' state, then the left over
-- data will be pulled up to the enclosing 'Iter', so that the
-- returned 'Iter' always has 'mempty' data.  (The EOF flag in the
-- left-over 'Chunk' is preserved, however.)
resultI :: (ChunkData t, Monad m) =>
           Iter t m a -> Iter t m (Iter t m a)
resultI = wrapI fixdone
    where
      fixdone (Done a c@(Chunk _ eof)) = Done (Done a (Chunk mempty eof)) c
      fixdone iter                     = return iter

--
-- Enumerator types
--

-- | Equivalent to:
--
-- @
--type Inum tIn tOut m a = 'Iter' tOut m a -> 'Iter' tIn m ('Iter' tOut m a)
-- @
--
-- The most general enumerator type, which can transcode from some
-- outer type to some inner type.  Such a function accepts data from
-- an outer enumerator (acting as an 'Iter'), then transcodes the data
-- and feeds it to another Iter (hence also acting like an enumerator
-- towards that inner 'Iter').  Note that data is viewed as flowing
-- inwards from the outermost enumerator to the innermost iteratee.
-- Thus @tIn@, the \"outer type\", is actually the type of input fed
-- to an @Inum@, while @tOut@ is what the @Inum@ feeds to an iteratee.
--
-- @Inum@ is a function from 'Iter's to 'Iter's, where an @Inum@'s
-- input and output types are different.  A simpler alternative to
-- @Inum@ might have been:
--
-- >type Inum' tIn tOut m a = Iter tOut m a -> Iter tIn m a
--
-- In fact, given an @Inum@ object @inum@, it is possible to
-- construct a function of type @Inum'@ with @(inum '..|')@.  But
-- sometimes one might like to concatenate @Inum@s.  For instance,
-- consider a network protocol that changes encryption or compression
-- modes midstream.  Transcoding is done by @Inum@s.  To change
-- transcoding methods after applying an @Inum@ to an iteratee
-- requires the ability to \"pop\" the iteratee back out of the
-- @Inum@ so as to be able to hand it to another @Inum@.
--
-- An @Inum@ must never feed an EOF chunk to its iteratee.  Instead,
-- upon receiving EOF, the @Inum@ should simply return the state of
-- the inner 'Iter' (this is how \"popping\" the iteratee back out
-- works).  An @Inum@ should also return when the iteratee returns a
-- result or fails, or when the @Inum@ fails.  An @Inum@ may return
-- the state of the iteratee earlier, if it has reached some logical
-- message boundary (e.g., many protocols finish processing headers
-- upon reading a blank line).
--
-- @Inum@s are generally constructed with the 'mkInum' function, which
-- hides most of the error handling details.
type Inum tIn tOut m a = Iter tOut m a -> InumR tIn tOut m a

-- | The result of running an 'Inum' is an 'Iter' containing another
-- 'Iter'.
type InumR tIn tOut m a = Iter tIn m (Iter tOut m a)

-- | An @Onum t m a@ is an outer enumerator that gets data of type
-- @t@ by executing actions in monad @m@, then feeds the data in
-- chunks to an iteratee of type @'Iter' t m a@.  Most enumerators are
-- polymorphic in the last type, @a@, so as work with iteratees
-- returning any type.
--
-- An @Onum@ is just a special form of 'Inum' in which the outer type
-- is @()@--so that there is no meaningful input data.
--
-- Under no circumstances should an @Onum@ ever feed a chunk with the
-- EOF bit set to its 'Iter' argument.  When the @Onum@ runs out of
-- data, it must simply return the current state of the 'Iter'.  This
-- way more data from another source can still be fed to the iteratee,
-- as happens when enumerators are concatenated with the 'cat'
-- function.
--
-- @Onum@s should generally be constructed using the 'mkOnum'
-- function, which takes care of most of the error-handling details.
type Onum t m a = Inum () t m a

-- | The result of running an 'Onum'.
type OnumR t m a = InumR () t m a

-- | Run an outer enumerator on an iteratee.  Is equivalent to:
--
-- @
--  inum |$ iter = 'run' ('enum' ..| iter)
--  infixr 2 |$
-- @
(|$) :: (ChunkData t, Monad m) => Onum t m a -> Iter t m a -> m a
(|$) enum iter = run (enum ..| iter)
infixr 2 |$

-- | @.|$@ is a variant of '|$' than allows you to apply an 'Onum'
-- from within an 'Iter' monad.  It has fixity:
--
-- > infixr 2 .|$
--
-- @enum .|$ iter@ is sort of equivalent to @'lift' (enum |$ iter)@,
-- except that the latter will call 'throw' on failures, causing
-- language-level exceptions that cannot be caught within the outer
-- 'Iter'.  Thus, it is better to use @.|$@ than
-- @'lift' (... '|$' ...)@, though in the less general case of the
-- IO monad, @enum .|$ iter@ is equivalent to
-- @'liftIO' (enum '|$' iter)@ as illustrated by the following
-- examples:
--
-- > -- Catches exception, because .|$ propagates failure through the outer
-- > -- Iter Monad, where it can still be caught.
-- > apply1 :: IO String
-- > apply1 = enumPure "test1" |$ iter `catchI` handler
-- >     where
-- >       iter = enumPure "test2" .|$ fail "error"
-- >       handler (SomeException _) _ = return "caught error"
-- > 
-- > -- Does not catch error.  |$ turns the Iter failure into a language-
-- > -- level exception, which can only be caught in the IO Monad.
-- > apply2 :: IO String
-- > apply2 = enumPure "test1" |$ iter `catchI` handler
-- >     where
-- >       iter = lift (enumPure "test2" |$ fail "error")
-- >       handler (SomeException _) _ = return "caught error"
-- > 
-- > -- Catches the exception, because liftIO uses the IO catch function to
-- > -- turn language-level exceptions into Monadic Iter failures.  (By
-- > -- contrast, lift must work for all Monads so cannot this in apply2.)
-- > apply3 :: IO String
-- > apply3 = enumPure "test1" |$ iter `catchI` handler
-- >     where
-- >       iter = liftIO (enumPure "test2" |$ fail "error")
-- >       handler (SomeException _) _ = return "caught error"
(.|$) :: (ChunkData tIn, ChunkData tOut, Monad m) =>
         Onum tOut m a -> Iter tOut m a -> Iter tIn m a
(.|$) enum iter = runI $ enum ..| iter
infixr 2 .|$

-- | Concatenate two enumerators.  Has fixity:
--
-- > infixr 3 `cat`
cat :: (ChunkData tIn, ChunkData tOut, Monad m) =>
        Inum tIn tOut m a      -- ^
     -> Inum tIn tOut m a
     -> Inum tIn tOut m a
cat a b iter0 = do
  iter <- resultI $ a iter0
  if isIterError iter then iter else iter >>= b
infixr 3 `cat`

-- | Fuse two 'Inum's when the inner type of the first 'Inum' is the
-- same as the outer type of the second.  More specifically, if
-- @inum1@ transcodes type @tIn@ to @tMid@ and @inum2@ transcodes
-- @tMid@ to @tOut@, then @inum1 |.. inum2@ produces a new 'Inum' that
-- transcodes @tIn@ to @tOut@.  Has fixity:
--
-- > infixl 4 |..
(|..) :: (ChunkData tIn, ChunkData tMid, ChunkData tOut, Monad m) => 
         Inum tIn tMid m (Iter tOut m a) -- ^
      -> Inum tMid tOut m a
      -> Inum tIn tOut m a
(|..) outer inner iter = wrapI joinI (outer $ inner iter)
infixl 4 |..

-- | Fuse an 'Inum' that transcodes @tIn@ to @tOut@ with an 'Iter'
-- taking type @tOut@ to produce an 'Iter' taking type @tIn@.  Has
-- fixity:
--
-- > infixr 4 ..|
(..|) :: (ChunkData tIn, ChunkData tOut, Monad m) =>
         Inum tIn tOut m a     -- ^
      -> Iter tOut m a
      -> Iter tIn m a
(..|) inner iter = wrapI joinI (inner iter)
infixr 4 ..|

-- | A @Codec@ is an 'Iter' that tranlates data from some input type
-- @tArg@ to an output type @tRes@ and returns the result in a
-- 'CodecR'.  If the @Codec@ is capable of repeatedly being invoked to
-- translate more input, it returns a 'CodecR' in the 'CodecF' state.
-- This convention allows @Codec@s to maintain state from one
-- invocation to the next by currying the state into the codec
-- function for the next time it is invoked.  A @Codec@ that cannot
-- process more input returns a 'CodecR' in the 'CodecE' state,
-- possibly including some final output.
type Codec tArg m tRes = Iter tArg m (CodecR tArg m tRes)

-- | The result type of a 'Codec' that translates from type @tArg@ to
-- @tRes@ in monad @m@.  The result potentially includes a new 'Codec'
-- for translating subsequent input.
data CodecR tArg m tRes = CodecF { unCodecF :: !(Codec tArg m tRes)
                                 , unCodecR :: !tRes }
                          -- ^ This is the normal 'Codec' result,
                          -- which includes another 'Codec' (often the
                          -- same as the one that was just called) for
                          -- processing further input.
                        | CodecE { unCodecR :: !tRes }
                          -- ^ This constructor is used if the 'Codec'
                          -- is ending--i.e., returning for the last
                          -- time--and thus cannot provide another
                          -- 'Codec' to process further input.

-- | Transform an ordinary 'Iter' into a stateless 'Codec'.
iterToCodec :: (ChunkData t, Monad m) => Iter t m a -> Codec t m a
iterToCodec iter = codec
    where codec = CodecF codec `liftM` iter

-- | A variant of 'inumBracket' that also takes a 'CtlHandler' (as a
-- function of the input).
inumCBracket :: (Monad m, ChunkData tIn, ChunkData tOut) =>
                (Iter tIn m b)
             -- ^ Before action
             -> (b -> Iter tIn m c)
             -- ^ After action, as a function of before action result
             -> (b -> CtlHandler tOut m a)
             -- ^ Control request handler, as funciton of before action result
             -> (b -> (Codec tIn m tOut))
             -- ^ Input 'Codec', as a funciton of before aciton result
             -> Inum tIn tOut m a
inumCBracket before after cf codec iter0 = tryI before >>= checkBefore
    where
      checkBefore (Left (e, _)) = InumFail e iter0
      checkBefore (Right b)     = resultI (mkInumC (cf b) (codec b) iter0)
                                  >>= checkMain b
      checkMain b iter = tryI (after b) >>= checkAfter iter
      checkAfter iter (Left (e,_)) = iter `bindFail` InumFail e
      checkAfter iter _            = iter

-- | Build an 'Inum' from a @before@ action, an @after@ function, and
-- an @input@ 'Codec' in a manner analogous to the IO @'bracket'@
-- function.  For instance, you could implement @`enumFile'`@ as
-- follows:
--
-- >   enumFile' :: (MonadIO m) => FilePath -> Onum L.ByteString m a
-- >   enumFile' path = inumBracket (liftIO $ openBinaryFile path ReadMode)
-- >                                (liftIO . hClose) doGet
-- >       where
-- >         doGet h = do
-- >           buf <- liftIO $ hWaitForInput h (-1) >> L.hGetNonBlocking h 8192
-- >           return $ if null buf then CodecE L.empty
-- >                                else CodecF (doGet h) buf
--
-- (As a side note, the simple 'L.hGet' function can block when there
-- is some input data but not as many bytes as requested.  Thus, in
-- order to work with named pipes and process data as it arrives, it
-- is best to call 'hWaitForInput' followed by 'L.hGetNonBlocking'
-- rather than simply 'L.hGet'.  This is a common idiom in enumerators
-- that use 'Handle's.)
inumBracket :: (Monad m, ChunkData tIn, ChunkData tOut) =>
               (Iter tIn m b)
            -- ^ Before action
            -> (b -> Iter tIn m c)
            -- ^ After action, as a function of before action result
            -> (b -> (Codec tIn m tOut))
            -- ^ Input 'Codec', as a funciton of before aciton result
            -> Inum tIn tOut m a
inumBracket before after codec iter0 =
    inumCBracket before after (const noCtls) codec iter0

-- | If an 'Iter' receives EOF, allow it to return 'IterF' and keep
-- feeding it 'chunkEOF'.  If, however, the 'Iter' issues a successful
-- control request, then alow it to ask for more data.
fixEOF :: (ChunkData t, Monad m) => Iter t m a -> Iter t m a
fixEOF iter0 = fok iter0
    where
      fok (IterF f)                = IterF $ \c@(Chunk _ eof) ->
                                     if eof then fNOTok (f c) else fok (f c)
      fok iter | isIterActive iter = apNext fok iter
               | otherwise         = iter
      fNOTok (IterF f)                = fNOTok $ f chunkEOF
      fNOTok (IterC (CtlReq carg fr)) = iterC carg $ \res -> case res of
                                          Nothing -> fNOTok $ fr res
                                          Just _  -> fok $ fr res
      fNOTok iter | isIterActive iter = apNext fNOTok iter
                  | otherwise         = iter

-- | Build an 'Inum' given a 'Codec' that returns chunks of the
-- appropriate type and a 'CtlHandler' to handle control requests.
-- Makes an effort to send an EOF to the codec if the inner 'Iter'
-- fails, so as to facilitate cleanup.  However, if a containing
-- 'Inum' fails, code handling that failure will have to send an EOF
-- or the codec will not be able to clean up.
mkInumC :: (Monad m, ChunkData tIn, ChunkData tOut) =>
           CtlHandler tOut m a
        -- ^ Control request handler
        -> Codec tIn m tOut
        -- ^ Codec to be invoked to produce transcoded chunks.
        -> Inum tIn tOut m a
mkInumC cf codec0 iter0 = fixEOF $ process codec0 iter0
    where
      process codec iter@(IterF _) = tryCodec codec iter process
      process codec (IterC c) = case cf c of
                                  iter@(IterC _) -> apRun (process codec) iter
                                  iter           -> process codec iter
      process codec iter@(IterM _) = apRun (process codec) iter
      process codec@(IterF _) iter = tryCodec (runIter codec chunkEOF) iter $ 
                                     \_ _ -> return iter
      process _ iter               = return iter

      tryCodec codec iter next = do
        ecodecr <- tryI codec
        case ecodecr of
          Right (CodecF c d) -> next c (runIter iter $ chunk d)
          Right (CodecE d) -> next (throwEOFI "CodecE") (runIter iter $ chunk d)
          Left (e, _) | isIterEOF e -> return iter
          Left (e, _)               -> InumFail e iter

-- | A variant of 'mkInumC' that passes all control requests from the
-- innner 'Iter' through to enclosing enumerators.  (If you want to
-- reject all control requests, use @'mkInumC' 'noCtls'@ instead of
-- @mkInum@.)
mkInum :: (Monad m, ChunkData tIn, ChunkData tOut) =>
          Codec tIn m tOut
       -- ^ Codec to be invoked to produce transcoded chunks.
       -> Inum tIn tOut m a
mkInum = mkInumC IterC

-- | A variant of 'mkInum' that transcodes data using a stateless
-- translation 'Iter' instead of a 'Codec'
mkInum' :: (Monad m, ChunkData tIn, ChunkData tOut) =>
           Iter tIn m tOut
        -- ^ This Iteratee will be executed repeatedly to produce
        -- transcoded chunks.
        -> Inum tIn tOut m a
mkInum' fn iter = mkInum (iterToCodec fn) iter

--
-- Support for control operations
--

-- | A control request handler maps control requests to 'Iter's.
type CtlHandler t m a = CtlReq t m a -> Iter t m a

-- | A version of 'ctlI' that uses 'Maybe' instead of throwing an
-- exception to indicate failure.
safeCtlI :: (CtlCmd carg cres, ChunkData t, Monad m) =>
            carg -> Iter t m (Maybe cres)
safeCtlI carg = iterC carg return

-- | Issue a control request, and return the result.  Throws an
-- exception if the operation did not succeed.
ctlI :: (CtlCmd carg cres, ChunkData t, Monad m) =>
        carg -> Iter t m cres
ctlI carg = safeCtlI carg >>= returnit
    where
      returnit (Just res) = return res
      returnit Nothing    = fail $ "Unsupported CtlCmd " ++ show (typeOf carg)

-- | A control request handler that ignores the request argument and
-- always fails immediately (thereby not passing the control request
-- up further to other enclosing enumerators).
--
-- One use of this is for 'Inum's that change the data in such a way
-- that control requests would not makes sense to outer enumerators.
-- Suppose @gunzipCodec@ is a codec that uncompresses a file in gzip
-- format.  The corresponding inner enumerator should probably be
-- defined as:
--
-- > inumGunzip :: (Monad m) => Inum ByteString ByteString m a
-- > inumGunzip = enumCI noCtls gunzipCodec
--
-- The alternate definition @inumGunzip = mkInum gunzipCodec@ would
-- likely wreak havoc in the event of any seek requests, as the outer
-- enumerator might seek around in the file, confusing the
-- decompression codec.
noCtls :: CtlHandler t m a
noCtls (CtlReq _ fr) = fr Nothing

-- | Wrap a control command for requests of type @carg@ into a
-- function of type @'CtlReq' t m a -> Maybe 'Iter' t m a@, which is
-- not parameterized by @carg@ and therefore can be grouped in a list
-- with control functions for other types.  The intent is then to
-- combine a list of such functions into a 'CtlHandler' with
-- 'tryCtls'.
--
-- As an example, the following funciton produces a 'CtlHandler'
-- (suitable to be passed to 'enumCO' or 'enumCObracket') that
-- implements control operations for three types:
--
-- @
--  fileCtl :: ('ChunkData' t, 'MonadIO' m) => 'Handle' -> 'CtlHandler' t m a
--  fileCtl h = 'ctlHandler'
--              [ ctl $ \\('SeekC' mode pos) -> 'liftIO' ('hSeek' h mode pos)
--              , ctl $ \\'TellC' -> 'liftIO' ('hTell' h)
--              , ctl $ \\'SizeC' -> 'liftIO' ('hFileSize' h)
--              ]
-- @
ctl :: (CtlCmd carg cres, ChunkData t, Monad m) =>
       (carg -> Iter t m cres)
    -> CtlReq t m a
    -> Maybe (Iter t m a)
ctl f (CtlReq carg fr) = case cast carg of
                           Nothing    -> Nothing
                           Just carg' -> Just $ f carg' >>= fr . cast

-- | A variant of 'ctl' that, makes the control operation fail if it
-- throws any kind of exception (as opposed to re-propagating the
-- exception as an 'EnumOFail', which is what would end up happening
-- with 'ctl').
ctl' :: (CtlCmd carg cres, ChunkData t, Monad m) =>
        (carg -> Iter t m cres)
     -> CtlReq t m a
     -> Maybe (Iter t m a)
ctl' f (CtlReq carg fr) = case cast carg of
                           Nothing    -> Nothing
                           Just carg' -> Just $ doit carg'
    where
      doit carg' = do
        er <- tryI $ f carg'
        case er of
          Right r                   -> fr $ cast r
          Left (SomeException _, _) -> fr Nothing

-- | Create a 'CtlHandler' from a list of functions created with 'ctl'
-- that try each tries one argument type.  See the example given for
-- 'ctl'.
ctlHandler :: (ChunkData t, Monad m) =>
              [CtlReq t m a -> Maybe (Iter t m a)]
           -> CtlHandler t m a
ctlHandler ctls req = case res of
                     Nothing           -> IterC req
                     Just iter         -> iter
    where
      res = foldr ff Nothing ctls
      ff a b = case a req of
                 Nothing  -> b
                 a'       -> a'

--
-- Basic outer enumerators
--

-- | An 'Onum' that will feed pure data to 'Iter's.
enumPure :: (Monad m, ChunkData t) => t -> Onum t m a
enumPure t = mkInum $ return $ CodecE t

-- | Create a loopback @('Iter', 'Onum')@ pair.  The iteratee and
-- enumerator can be used in different threads.  Any data fed into the
-- 'Iter' will in turn be fed by the 'Onum' into whatever 'Iter' it
-- is given.  This is useful for testing a protocol implementation
-- against itself.
iterLoop :: (MonadIO m, ChunkData t, Show t) =>
            m (Iter t m (), Onum t m a)
iterLoop = do
  -- The loopback is implemented with an MVar (MVar Chunk).  The
  -- enumerator waits on the inner MVar, while the iteratee uses the outer 
  -- MVar to avoid races when appending to the stored chunk.
  pipe <- liftIO $ newEmptyMVar >>= newMVar
  return (IterF $ iterf pipe, enum pipe)
    where
      iterf pipe c@(Chunk _ eof) = do
             liftIO $ withMVar pipe $ \p ->
                 do mp <- tryTakeMVar p
                    putMVar p $ case mp of
                                  Nothing -> c
                                  Just c' -> mappend c' c
             if eof then Done () chunkEOF else IterF $ iterf pipe

      enum pipe = let codec = do
                        p <- liftIO $ readMVar pipe
                        Chunk c eof <- liftIO $ takeMVar p
                        return $ if eof then CodecE c else CodecF codec c
                  in mkInum codec

--
-- Basic inner enumerators
--

-- | The null 'Inum', which passes data through to another iteratee
-- unmodified.
inumNop :: (ChunkData t, Monad m) => Inum t t m a
inumNop = mkInum' dataI

-- | Repeat an 'Inum' until an end of file is received or a failure
-- occurs.
inumRepeat :: (ChunkData tIn, MonadIO m, Show tOut) =>
              (Inum tIn tOut m a) -> (Inum tIn tOut m a)
inumRepeat inum iter0 = do
  eof <- atEOFI
  if eof then return iter0 else resultI (inum iter0) >>= check
    where
      check (Done iter (Chunk _ False)) = inumRepeat inum iter
      check res                         = res

-- | Returns an 'Iter' that always returns itself until a result is
-- produced.  You can fuse @inumSplit@ to an 'Iter' to produce an
-- 'Iter' that can safely be written from multiple threads.
inumSplit :: (MonadIO m, ChunkData t) => Inum t t m a
inumSplit iter1 = do
  mv <- liftIO $ newMVar $ iter1
  IterF $ iterf mv
    where
      iterf mv (Chunk t eof) = do
        rold <- liftIO $ takeMVar mv
        rnew <- returnI $ runIter rold $ chunk t
        liftIO $ putMVar mv rnew
        case rnew of
          IterF _ | not eof -> IterF $ iterf mv
          _                 -> return rnew


