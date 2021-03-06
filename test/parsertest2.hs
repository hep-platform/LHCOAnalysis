{-# LANGUAGE RecordWildCards, GADTs #-}

import Codec.Compression.GZip
import Control.Applicative
import Control.Monad
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Function (on)
import Data.List hiding (delete)
import Data.Maybe
import System.Environment
import System.FilePath
-- 
import HEP.Parser.LHCOAnalysis.PhysObj
import HEP.Parser.LHCOAnalysis.Parse
import HEP.Util.Functions (invmass)
import HROOT.Core
import HROOT.Hist 
import HROOT.Graf
import HROOT.IO
-- 
import Debug.Trace

data LeptonType = HardLepton | SoftLepton 
                deriving Show 


tau2Jet :: PhyObj Tau -> PhyObj Jet
tau2Jet (ObjTau x _ _) = ObjJet x 1.77 1

bJet2Jet :: PhyObj BJet -> PhyObj Jet
bJet2Jet (ObjBJet x m n) = ObjJet x m n

taubjetMerge :: PhyEventClassified -> PhyEventClassified
taubjetMerge PhyEventClassified {..} = 
  PhyEventClassified { eventid = eventid 
                     , photonlst = photonlst
                     , electronlst = electronlst
                     , muonlst = muonlst
                     , taulst = [] 
                     , jetlst = -- sortBy (compare `on`  trd3 . etaphiptjet . snd)
                                ptordering
                                ( jetlst 
                                  ++ map ((,) <$> fst <*> tau2Jet.snd) taulst 
                                  ++ map ((,) <$> fst <*> bJet2Jet.snd) bjetlst )
                     , bjetlst = []
                     , met = met }

canBePreselected :: LeptonType -> PhyObj a -> Bool 
canBePreselected _ (ObjPhoton _) = False
canBePreselected typ (ObjElectron (eta,phi,pt) _) = abs eta < 2.47 && pt > pt0 
  where pt0 = case typ of 
                HardLepton -> 10 
                SoftLepton -> 7 
canBePreselected typ (ObjMuon (eta,phi,pt) _ ) = abs eta < 2.4 && pt > pt0 
  where pt0 = case typ of 
                HardLepton -> 10 
                SoftLepton -> 6 
canBePreselected _ (ObjTau _ _ _) = False 
canBePreselected _ (ObjJet (eta,phi,pt) _ _) = abs eta < 4.5 && pt > 20 
canBePreselected _ (ObjBJet (eta,phi,pt) _ _) = abs eta < 4.5 && pt > 20 
canBePreselected _ (ObjMET (phi,pt)) = True 

preselect :: LeptonType -> PhyEventClassified -> PhyEventClassified 
preselect typ PhyEventClassified {..} = 
  PhyEventClassified { eventid = eventid 
                     , photonlst = filter (canBePreselected typ.snd) photonlst
                     , electronlst = filter (canBePreselected typ.snd) electronlst
                     , muonlst = filter (canBePreselected typ.snd) muonlst
                     , taulst = filter (canBePreselected typ.snd) taulst
                     , jetlst = filter (canBePreselected typ.snd) jetlst
                     , bjetlst = filter (canBePreselected typ.snd) bjetlst
                     , met = met }
 


mt :: (Double,Double) -> (Double,Double) -> Double
mt (pt1x,pt1y) (pt2x,pt2y) = sqrt (2.0*pt1*pt2-2.0*pt1x*pt2x-2.0*pt1y*pt2y) 
  where pt1 = sqrt (pt1x*pt1x+pt1y*pt1y)
        pt2 = sqrt (pt2x*pt2x+pt2y*pt2y)
        -- cosph = (pt1x*pt2x + pt1y*pt2y)/

meffinc :: PhyEventClassified -> Double 
meffinc PhyEventClassified {..} = 
  (sum . map (trd3.etaphiptelectron.snd)) electronlst 
  + (sum . map (trd3.etaphiptmuon.snd)) muonlst
  + (sum . map (trd3.etaphipt.snd)) jetlst 
  + (snd.phiptmet) met

meff :: PhyEventClassified -> Double
meff PhyEventClassified {..} = 
  (sum . map (trd3.etaphiptelectron.snd)) electronlst 
  + (sum . map (trd3.etaphiptmuon.snd)) muonlst
  + (sum . map (trd3.etaphipt.snd)) (take 4 jetlst) 
  + (snd.phiptmet) met


data JetType = ThreeJets | FourJets
             deriving (Show)

data JetType2 = M2Jet | M4Jet
                deriving (Show)

data SingleLeptonEventType = HardLeptonEvent JetType | SoftLeptonEvent
                           deriving (Show)

data EventType = SingleLeptonEvent SingleLeptonEventType | MultiLeptonEvent JetType2 
               deriving (Show)


-- data SingleLeptonType = Electron | Muon 
classifyEvent :: PhyEventClassified -> Maybe EventType
classifyEvent ev@PhyEventClassified {..} = do 
  let llst = leptonlst ev
  guard ((not.null) llst) 
  (etyp,l) <- do 
      guard (length llst >= 1)
      let (_,l) = head llst 
      etyp <- case l of 
        LO_Elec e -> do
          guard (pt e > 7) 
          if pt e < 25 
            then do guard (all (not.pass2nd SoftLepton) (tail llst))
                    return (Left SoftLepton)
            else if (all (not.pass2nd HardLepton) (tail llst)) 
                   then return (Left HardLepton)
                   else return (Right ())
        LO_Muon m -> do 
          guard (pt m > 6) 
          if pt m < 20 
            then do guard (all (not.pass2nd SoftLepton) (tail llst))
                    return (Left SoftLepton)
            else if (all (not.pass2nd HardLepton) (tail llst))
                   then return (Left HardLepton) 
                   else return (Right ())
      return (etyp,l)
  case etyp of 
    Left HardLepton -> do
      jtyp <- classifyJetsInSingleLepton ev 
      metcheck (SingleLeptonEvent (HardLeptonEvent jtyp)) l ev
      return (SingleLeptonEvent (HardLeptonEvent jtyp))
    Left SoftLepton -> do
      metcheck (SingleLeptonEvent SoftLeptonEvent) l ev
      return (SingleLeptonEvent SoftLeptonEvent)
    Right () -> do 
      jtyp <- classifyJetsInMultiLepton ev 
      metcheck (MultiLeptonEvent jtyp) l ev
      return (MultiLeptonEvent jtyp)

 where pass2nd HardLepton x = ((>10) . pt . snd) x
       pass2nd SoftLepton x = let y = snd x 
                              in case y of 
                                   LO_Elec e -> (pt e > 7) 
                                   LO_Muon m -> (pt m > 6)


metcheck :: EventType -> Lepton12Obj -> PhyEventClassified -> Maybe () 
metcheck (SingleLeptonEvent (HardLeptonEvent ThreeJets)) l ev
    = do let missing = met ev
             etmiss = (snd.phiptmet) missing
         let lpxpy = (pxpyFromPhiPT  . ((,)<$>phi<*>pt)) l
             mpxpy = (pxpyFromPhiPT . phiptmet)  missing
             mtvalue = mt lpxpy mpxpy 
             meffvalue = meff ev
             meffincvalue = meffinc ev
         -- trace (show (eventid ev) ++ ":  " ++ show etmiss ++ "    " ++ show mtvalue ++ "    " ++ show meffvalue) $
         guard (etmiss > 250) 
         guard (mtvalue > 100 ) 
         guard (etmiss / meffvalue > 0.3 )
         guard (meffincvalue > 1200 ) 
metcheck (SingleLeptonEvent (HardLeptonEvent FourJets)) l ev
    = do let missing = met ev
             etmiss = (snd.phiptmet) missing
         guard (etmiss > 250) 
         let lpxpy = (pxpyFromPhiPT  . ((,)<$>phi<*>pt)) l
             mpxpy = (pxpyFromPhiPT . phiptmet)  missing
             mtvalue = mt lpxpy mpxpy 
             meffvalue = meff ev
             meffincvalue = meffinc ev
         guard (mtvalue > 100 ) 
         guard (etmiss / meffvalue > 0.2 )
         guard (meffincvalue > 800 ) 
metcheck (SingleLeptonEvent SoftLeptonEvent) l ev 
    = do let nj = numofobj Jet ev
         guard (nj >= 2)
         guard ((pt.snd) (jetlst ev !! 0) > 130)
         guard ((pt.snd) (jetlst ev !! 1) > 25) 
         -- 
         let missing = met ev
             etmiss = (snd.phiptmet) missing
         guard (etmiss > 250) 
         let lpxpy = (pxpyFromPhiPT  . ((,)<$>phi<*>pt)) l
             mpxpy = (pxpyFromPhiPT . phiptmet)  missing
             mtvalue = mt lpxpy mpxpy 
             meffvalue = meff ev
         guard (mtvalue > 100 ) 
         guard (etmiss / meffvalue > 0.3 )
metcheck (MultiLeptonEvent M2Jet) l ev 
    = do let missing = met ev
             etmiss = (snd.phiptmet) missing
         guard (etmiss > 300)
metcheck (MultiLeptonEvent M4Jet) l ev 
    = do let missing = met ev
             etmiss = (snd.phiptmet) missing
             meffvalue = meff ev
             meffincvalue = meffinc ev
         guard (etmiss > 100)
         guard (etmiss / meffvalue > 0.2 )
         guard (meffincvalue > 650 )   

classifyJetsInSingleLepton :: PhyEventClassified -> Maybe JetType
classifyJetsInSingleLepton p@PhyEventClassified {..} = do 
    let nj = numofobj Jet p
    guard (nj >= 3)
    if nj == 3 
      then check3jet
      else if (pt.snd) (jetlst !! 3) > 80 then check4jet else check3jet 
  where check3jet = do 
          guard ((pt.snd) (jetlst !! 0) > 100)
          guard ((pt.snd) (jetlst !! 1) > 25) 
          guard ((pt.snd) (jetlst !! 2) > 25)
          return ThreeJets
        check4jet = do 
          guard ((pt.snd) (jetlst !! 0) > 80)
          guard ((pt.snd) (jetlst !! 1) > 80)
          guard ((pt.snd) (jetlst !! 2) > 80)
          guard ((pt.snd) (jetlst !! 3) > 80)
          return FourJets

classifyJetsInMultiLepton :: PhyEventClassified -> Maybe JetType2
classifyJetsInMultiLepton p@PhyEventClassified {..} = do 
    let nj = numofobj Jet p
    guard (nj >= 2)
    if nj < 4 
      then check2jet
      else if (pt.snd) (jetlst !! 2) > 50 then check4jet else check2jet 
  where check2jet = do 
          guard ((pt.snd) (jetlst !! 0) > 200)
          guard ((pt.snd) (jetlst !! 1) > 200) 
          return M2Jet
        check4jet = do 
          guard ((pt.snd) (jetlst !! 0) > 50)
          guard ((pt.snd) (jetlst !! 1) > 50)
          guard ((pt.snd) (jetlst !! 2) > 50)
          guard ((pt.snd) (jetlst !! 3) > 50)
          return M4Jet



isSingleLep3 :: EventType -> Bool 
isSingleLep3 (SingleLeptonEvent (HardLeptonEvent ThreeJets)) = True 
isSingleLep3 _ = False 

isSingleLep4 :: EventType -> Bool 
isSingleLep4 (SingleLeptonEvent (HardLeptonEvent FourJets)) = True
isSingleLep4 _ = False 

isSingleLepSoft :: EventType -> Bool 
isSingleLepSoft (SingleLeptonEvent SoftLeptonEvent) = True
isSingleLepSoft _ = False 

isMultiLep2 :: EventType -> Bool 
isMultiLep2 (MultiLeptonEvent M2Jet) = True 
isMultiLep2 _ = False 

isMultiLep4 :: EventType -> Bool 
isMultiLep4 (MultiLeptonEvent M4Jet) = True 
isMultiLep4 _ = False 
  
  

hardestJetNLep :: PhyEventClassified -> Maybe (PhyObj Jet, Lepton12Obj) 
hardestJetNLep ev@(PhyEventClassified {..}) = do
  guard ((not.null) jetlst) 
  let leplst = leptonlst ev
  guard ((not.null) leplst) 
  return ((snd.head) jetlst,(snd.head) leplst)
 

main = do 
  putStrLn "invariantmass"
  args <- getArgs
  when (length args /= 1) $ error "./parsertest2 filename"
  let fn = args !! 0 
      basename = takeBaseName fn 
  -- "ADMXQLD311MST400.0MG900.0MSQ50000.0_gluinopair_stopdecayfull_LHC7ATLAS_NoMatch_NoCut_Cone0.4_Set1_pgs_events.lhco.gz" -- "ADMXQLD311MST1500.0_stoppair_full_LHC7ATLAS_NoMatch_NoCut_Cone0.4_Set1_pgs_events.lhco.gz"
 
  bstr <- LB.readFile fn 
  let unzipped = decompress bstr 

      evts = parsestr unzipped
      signalevts = map (preselect HardLepton . taubjetMerge) evts 

      jl = map hardestJetNLep signalevts

  tcanvas <- newTCanvas  "Test" "Test" 640 480 
  h1 <- newTH1D "test" "test" 100 0 2000 
  
  let deposit = fill1 h1 . (invmass <$> fourmom.fst <*> fourmom.snd)
  mapM_ deposit (catMaybes jl)
  draw h1 "" 
  
  -- tfile <- newTFile "test.root" "NEW" "" 1   
  -- write h1 "" 0 0 
  -- close tfile ""
  saveAs tcanvas (basename <.> "pdf") "" 
  saveAs tcanvas (basename <.> "png") ""

  delete h1
  delete tcanvas



  -- print $ (take 3 . map (invmass <$> fourmom.fst <*> fourmom.snd)) $ catMaybes jl
  -- print $ map meff signalevts
  
{-      classified = mapMaybe classifyEvent signalevts 
  -- print (length evts) 
  putStrLn fn 
  putStrLn $ "total number = " ++ show (length evts)
  putStrLn $ "single lep 3 = " ++ (show . length . filter isSingleLep3) classified 
  putStrLn $ "single lep 4 = " ++ (show . length . filter isSingleLep4) classified 
  putStrLn $ "single lep soft = " ++ (show . length . filter isSingleLepSoft) classified 
  putStrLn $ "multi lep 2 = " ++ (show . length . filter isMultiLep2) classified 
  putStrLn $ "multi lep 4 = " ++ (show . length . filter isMultiLep4) classified 

    
  -- LB.putStrLn (LB.take 100 unzipped) 

-}
