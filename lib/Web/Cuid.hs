{-# LANGUAGE CPP, ForeignFunctionInterface #-}

{-|
Stability: stable
Portability: portable

You can generate a new CUID inside any IO-enabled monad using this module's
one exported function:

>>> cuid <- newCuid
>>> print cuid
"ciaafthr00000qhpm0jp81gry"

This module does not use crypto-strength sources of randomless. Use at your own
peril!
-}
module Web.Cuid (
    Cuid, newCuid
) where

import Control.Monad (liftM)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Char (ord)
import Data.Monoid (mconcat, (<>))
import Data.IORef (IORef, newIORef, atomicModifyIORef')
import Data.String (fromString)
import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Formatting (Format, base, fitRight, sformat, left, (%.))
import Network.HostName (getHostName)
import System.IO.Unsafe (unsafePerformIO)
import System.Random (randomRIO)

#if defined(mingw32_HOST_OS)
import System.Win32 (ProcessId, failIfZero)
#else
import System.Posix.Process (getProcessID)
#endif

-- | Convenience type so that you don't have to import Text downstream. Note that
-- this is strict Text.
type Cuid = Text

-- | Generate a new random CUID.
newCuid :: MonadIO m => m Cuid
newCuid = concatIO [c, time, count, fingerprint, random, random] where
    -- The CUID starts with a letter so it's usable in HTML element IDs.
    c = return (fromString "c")

    -- The second chunk is the timestamp. Note that this means it is possible
    -- to determine the time a particular CUID was created.
    time = liftM (sformat number . millis) getPOSIXTime

    -- To avoid collisions on the same machine, add a global counter to each ID.
    count = liftM (sformat numberPadded) (postIncrement counter)

    -- To avoid collisions between separate machines, generate a 'fingerprint'
    -- from details which are hopefully unique to this machine - PID and hostname.
    fingerprint = do
        pid <- getPid
        hostname <- getHostName
        let hostSum = 36 + length hostname + sum (map ord hostname)
        return (sformat twoOfNum pid <> sformat twoOfNum hostSum)

    -- And some randomness for good measure. Note that System.Random is not a
    -- source of crypto-strength randomness.
    random = liftM (sformat numberPadded) (randomRIO (0, maxCount))

    -- Evaluate IO actions and concatenate their results.
    concatIO actions = liftM mconcat (liftIO $ sequence actions)

    -- POSIX time library gives the result in fractional seconds.
    millis posix = round (posix * 1000)

-- CUID calls for a globally incrementing counter per machine. This is ugly,
-- but it satisfies the requirement.
counter :: IORef Int
counter = unsafePerformIO (newIORef 0)
-- Don't want two different counters being created because of inlining.
-- For more info: https://wiki.haskell.org/Top_level_mutable_state
{-# NOINLINE counter #-}

-- Increment the counter, and return the value before it was incremented.
postIncrement :: MonadIO m => IORef Int -> m Int
postIncrement c = liftIO (atomicModifyIORef' c incrementAndWrap) where
    incrementAndWrap count = (succ count `mod` maxCount, count)

-- These constants are to do with number formatting.
formatBase, blockSize, maxCount :: Int
formatBase = 36
blockSize = 4
maxCount = formatBase ^ blockSize

-- Number formatters for converting to the correct base and padding.
number, numberPadded, twoOfNum :: Format Text (Int -> Text)
number = base formatBase
numberPadded = left blockSize '0' %. number
twoOfNum = fitRight 2 %. number

-- Get the ID of the current process. This function has a platform-specific
-- implementation. Fun times.
getPid :: MonadIO m => m Int

#if defined(mingw32_HOST_OS)

foreign import stdcall unsafe "windows.h GetCurrentProcessId"
    c_GetCurrentProcessId :: IO ProcessId

getCurrentProcessId :: IO ProcessId
getCurrentProcessId = failIfZero "GetCurrentProcessId" c_GetCurrentProcessId

getPid = liftM fromIntegral (liftIO getCurrentProcessId)

#else

getPid = liftM fromIntegral (liftIO getProcessID)

#endif
