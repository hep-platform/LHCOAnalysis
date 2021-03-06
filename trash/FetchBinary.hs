{-# LANGUAGE ScopedTypeVariables, BangPatterns, GADTs, FlexibleContexts, 
             FlexibleInstances, TypeFamilies #-}


module HEP.Parser.LHCOAnalysis.FetchBinary where

import HEP.Parser.LHCOAnalysis.PhysObj

import qualified Data.ByteString.Lazy.Char8 as B
import qualified Data.Binary as Bi
import System.IO

import Data.Int
import Data.Array.Unboxed

import Control.Monad.Trans.State
import qualified Data.Binary.Get as G

import qualified Data.ListLike as LL 
import qualified Data.Iteratee as Iter 


onefetch :: (Bi.Binary a) => Bi.Get (Bool,a)
onefetch = do  
              boolresult <-G.isEmpty
              case boolresult of
                  True  -> return (False,undefined)
                  False -> do result <- Bi.get
                              result `seq` return (True,result)

onefetchNonIO :: (Bi.Binary a) => State (Int64,B.ByteString) (Bool,a)
onefetchNonIO = do (byte,bytestr) <- get
                   let (result,bytestr',byte') = G.runGetState onefetch bytestr byte
                   put (byte',bytestr')
                   return $! result

readbyte :: Handle -> IO [PhyEventClassified]
readbyte inh = do bytecontent <- B.hGetContents inh
                  let listfetchNonIO = sequence $ repeat onefetchNonIO
                      lst = evalState listfetchNonIO (0,bytecontent)
                  return $ map snd $ takeWhile fst lst 



