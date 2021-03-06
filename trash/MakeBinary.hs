module HEP.Parser.LHCOAnalysis.MakeBinary where

import HEP.Parser.LHCOAnalysis.Parse

import qualified Data.ByteString.Lazy.Char8 as B
import qualified Data.Binary as Bi
import System.IO

import Data.IORef

makebinary :: FilePath -> FilePath -> IO ()
makebinary inputfilename outputfilename 
    = do putStrLn inputfilename
         putStrLn $ "output  = " ++ outputfilename
         inh <- openFile inputfilename ReadMode
         outh <- openFile outputfilename  WriteMode

         contents <- B.hGetContents inh
         let parsed = parsestr contents
             encodedbs = (map Bi.encode parsed) :: [B.ByteString]

         count <- newIORef (0::Int )

         let myaction str = do B.hPut outh str 
                               modifyIORef count (+1)
                               countnum <- readIORef count
                               if (countnum `mod` 1000) == 0
                                 then putStrLn (outputfilename ++ ":" ++ (show countnum))
                                 else (return ())

         mapM_ myaction encodedbs

         hClose inh 
         hClose outh

