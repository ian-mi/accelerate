{-# LANGUAGE CPP, GADTs, TypeFamilies, ScopedTypeVariables, FlexibleContexts, RankNTypes #-}
{-# LANGUAGE FlexibleInstances, MultiParamTypeClasses, TypeSynonymInstances #-}
{-# LANGUAGE DeriveDataTypeable, StandaloneDeriving, PatternGuards #-}

-- Module      : Data.Array.Accelerate.Smart
-- Copyright   : [2008..2010] Manuel M T Chakravarty, Gabriele Keller, Sean Lee
-- License     : BSD3
--
-- Maintainer  : Manuel M T Chakravarty <chak@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--
-- This modules defines the AST of the user-visible embedded language using
-- more convenient higher-order abstract syntax (instead of de Bruijn
-- indices). Moreover, it defines smart constructors to construct programs.

module Data.Array.Accelerate.Smart (

  -- * HOAS AST
  Acc(..), PreAcc(..), Exp(..), Boundary(..), Stencil(..),
  
  -- * HOAS -> de Bruijn conversion
  convertAcc,
  convertExp, convertFun1, convertFun2,

  -- * Smart constructors for unpairing
  unpair,

  -- * Smart constructors for literals
  constant,
  
  -- * Smart constructors and destructors for tuples
  tup2, tup3, tup4, tup5, tup6, tup7, tup8, tup9,
  untup2, untup3, untup4, untup5, untup6, untup7, untup8, untup9,

  -- * Smart constructors for constants
  mkMinBound, mkMaxBound, mkPi, 
  mkSin, mkCos, mkTan,
  mkAsin, mkAcos, mkAtan,
  mkAsinh, mkAcosh, mkAtanh,
  mkExpFloating, mkSqrt, mkLog,
  mkFPow, mkLogBase,
  mkAtan2,

  -- * Smart constructors for primitive functions
  mkAdd, mkSub, mkMul, mkNeg, mkAbs, mkSig, mkQuot, mkRem, mkIDiv, mkMod,
  mkBAnd, mkBOr, mkBXor, mkBNot, mkBShiftL, mkBShiftR, mkBRotateL, mkBRotateR,
  mkFDiv, mkRecip, mkLt, mkGt, mkLtEq, mkGtEq,
  mkEq, mkNEq, mkMax, mkMin, mkLAnd, mkLOr, mkLNot, mkBoolToInt, mkIntFloat,
  mkRoundFloatInt, mkTruncFloatInt,
  
  -- * Auxilliary functions
  ($$), ($$$), ($$$$), ($$$$$)

) where
  
import Debug.Trace

-- standard library
import Control.Monad
import Data.List
import Data.HashTable as Hash
import System.Mem.StableName
import System.IO.Unsafe         (unsafePerformIO)
import Data.Typeable

-- friends
import Data.Array.Accelerate.Type
import Data.Array.Accelerate.Array.Sugar
import Data.Array.Accelerate.Tuple hiding    (Tuple)
import qualified Data.Array.Accelerate.Tuple as Tuple
import Data.Array.Accelerate.AST hiding (OpenAcc(..), Acc, Stencil, OpenExp(..), Exp)
import qualified Data.Array.Accelerate.AST                  as AST
import Data.Array.Accelerate.Pretty ()

#include "accelerate.h"


-- Array computations
-- ------------------

-- |Array-valued collective computations without a recursive knot
--
data PreAcc acc a where
  
  FstArray    :: (Ix dim1, Ix dim2, Elem e1, Elem e2)
              => acc (Array dim1 e1, Array dim2 e2)
              -> PreAcc acc (Array dim1 e1)
  SndArray    :: (Ix dim1, Ix dim2, Elem e1, Elem e2)
              => acc (Array dim1 e1, Array dim2 e2)
              -> PreAcc acc (Array dim2 e2)

  Use         :: (Ix dim, Elem e)
              => Array dim e -> PreAcc acc (Array dim e)
  Unit        :: Elem e
              => Exp e 
              -> PreAcc acc (Scalar e)
  Reshape     :: (Ix dim, Ix dim', Elem e)
              => Exp dim
              -> acc (Array dim' e)
              -> PreAcc acc (Array dim e)
  Replicate   :: (SliceIx slix, Elem e,
                  Typeable (Slice slix), Typeable (SliceDim slix))
                  -- the Typeable constraints shouldn't be necessary as they are implied by 
                  -- 'SliceIx slix' — unfortunately, the (old) type checker doesn't grok that
              => Exp slix
              -> acc (Array (Slice slix)    e)
              -> PreAcc acc (Array (SliceDim slix) e)
  Index       :: (SliceIx slix, Elem e, 
                  Typeable (Slice slix), Typeable (SliceDim slix))
                  -- the Typeable constraints shouldn't be necessary as they are implied by 
                  -- 'SliceIx slix' — unfortunately, the (old) type checker doesn't grok that
              => acc (Array (SliceDim slix) e)
              -> Exp slix
              -> PreAcc acc (Array (Slice slix) e)
  Map         :: (Ix dim, Elem e, Elem e')
              => (Exp e -> Exp e') 
              -> acc (Array dim e)
              -> PreAcc acc (Array dim e')
  ZipWith     :: (Ix dim, Elem e1, Elem e2, Elem e3)
              => (Exp e1 -> Exp e2 -> Exp e3) 
              -> acc (Array dim e1)
              -> acc (Array dim e2)
              -> PreAcc acc (Array dim e3)
  Fold        :: (Ix dim, Elem e)
              => (Exp e -> Exp e -> Exp e)
              -> Exp e
              -> acc (Array dim e)
              -> PreAcc acc (Scalar e)
  FoldSeg     :: Elem e
              => (Exp e -> Exp e -> Exp e)
              -> Exp e
              -> acc (Vector e)
              -> acc Segments
              -> PreAcc acc (Vector e)
  Scanl       :: Elem e
              => (Exp e -> Exp e -> Exp e)
              -> Exp e
              -> acc (Vector e)
              -> PreAcc acc (Vector e, Scalar e)
  Scanr       :: Elem e
              => (Exp e -> Exp e -> Exp e)
              -> Exp e
              -> acc (Vector e)
              -> PreAcc acc (Vector e, Scalar e)
  Permute     :: (Ix dim, Ix dim', Elem e)
              => (Exp e -> Exp e -> Exp e)
              -> acc (Array dim' e)
              -> (Exp dim -> Exp dim')
              -> acc (Array dim e)
              -> PreAcc acc (Array dim' e)
  Backpermute :: (Ix dim, Ix dim', Elem e)
              => Exp dim'
              -> (Exp dim' -> Exp dim)
              -> acc (Array dim e)
              -> PreAcc acc (Array dim' e)
  Stencil     :: (Ix dim, Elem a, Elem b, Stencil dim a stencil)
              => (stencil -> Exp b)
              -> Boundary a
              -> acc (Array dim a)
              -> PreAcc acc (Array dim b)
  Stencil2    :: (Ix dim, Elem a, Elem b, Elem c,
                 Stencil dim a stencil1, Stencil dim b stencil2)
              => (stencil1 -> stencil2 -> Exp c)
              -> Boundary a
              -> acc (Array dim a)
              -> Boundary b
              -> acc (Array dim b)
              -> PreAcc acc (Array dim c)

-- |Array-valued collective computations
--
newtype Acc a = Acc (PreAcc Acc a)

deriving instance Typeable1 Acc

-- |Conversion from HOAS to de Bruijn computation AST
-- -

-- |Convert a closed array expression to de Bruijn form while also incorporating sharing information.
--
convertAcc :: Arrays arrs => Acc arrs -> AST.Acc arrs
convertAcc = convertOpenAcc EmptyLayout

-- |Convert a closed array expression to de Bruijn form while also incorporating sharing information.
--
convertOpenAcc :: Arrays arrs => Layout aenv aenv -> Acc arrs -> AST.OpenAcc aenv arrs
convertOpenAcc alyt = convertSharingAcc alyt . recoverSharing

-- |Convert an array expression with given array environment layout and sharing information into
-- de Bruijn form while recovering sharing at the same time (by introducing appropriate let
-- bindings).  The latter implements the third phase of sharing recovery.
--
convertSharingAcc :: Layout aenv aenv 
                  -> SharingAcc a 
                  -> AST.OpenAcc aenv a
convertSharingAcc alyt = convert alyt []
  where
    -- The sharing environment 'env' keeps track of all currently bound sharing variables,
    -- keeping them in reverse chronological order (outermost variable is at the end of the list)
    --
    convert :: Layout aenv aenv -> [StableSharingAcc] -> SharingAcc a -> AST.OpenAcc aenv a
    convert alyt env (VarSharing sa)
      | Just i <- findIndex (matchStableAcc sa) env 
      = AST.Avar (prjIdx i alyt)
      | otherwise                                   
      = INTERNAL_ERROR(error) "prjIdx" "inconsistent valuation"
    convert alyt env (LetSharing sa@(StableSharingAcc _ boundAcc) bodyAcc)
      = let alyt' = incLayout alyt `PushLayout` ZeroIdx
        in
        AST.Let (convert alyt env boundAcc) (convert alyt' (sa:env) bodyAcc)
    convert alyt env (AccSharing _ preAcc)
      = case preAcc of
          FstArray acc
            -> AST.Let2 (convert alyt env acc) (AST.Avar (AST.SuccIdx AST.ZeroIdx))
          SndArray acc
            -> AST.Let2 (convert alyt env acc) (AST.Avar AST.ZeroIdx)
          Use array
            -> AST.Use array
          Unit e
            -> AST.Unit (convertExp alyt e)
          Reshape e acc
            -> AST.Reshape (convertExp alyt e) (convert alyt env acc)
          Replicate ix acc
            -> mkReplicate (convertExp alyt ix) (convert alyt env acc)
          Index acc ix
            -> mkIndex (convert alyt env acc) (convertExp alyt ix)
          Map f acc 
            -> AST.Map (convertFun1 alyt f) (convert alyt env acc)
          ZipWith f acc1 acc2
            -> AST.ZipWith (convertFun2 alyt f) (convert alyt env acc1) (convert alyt env acc2)
          Fold f e acc
            -> AST.Fold (convertFun2 alyt f) (convertExp alyt e) (convert alyt env acc)
          FoldSeg f e acc1 acc2
            -> AST.FoldSeg (convertFun2 alyt f) (convertExp alyt e) 
                           (convert alyt env acc1) (convert alyt env acc2)
          Scanl f e acc
            -> AST.Scanl (convertFun2 alyt f) (convertExp alyt e) (convert alyt env acc)
          Scanr f e acc
            -> AST.Scanr (convertFun2 alyt f) (convertExp alyt e) (convert alyt env acc)
          Permute f dftAcc perm acc
            -> AST.Permute (convertFun2 alyt f) 
                           (convert alyt env dftAcc)
                           (convertFun1 alyt perm) 
                           (convert alyt env acc)
          Backpermute newDim perm acc
            -> AST.Backpermute (convertExp alyt newDim)
                               (convertFun1 alyt perm) 
                               (convert alyt env acc)
          Stencil stencil boundary acc
            -> AST.Stencil (convertStencilFun acc alyt stencil) 
                           (convertBoundary boundary) 
                           (convert alyt env acc)
          Stencil2 stencil bndy1 acc1 bndy2 acc2
            -> AST.Stencil2 (convertStencilFun2 acc1 acc2 alyt stencil) 
                            (convertBoundary bndy1) 
                            (convert alyt env acc1)
                            (convertBoundary bndy2) 
                            (convert alyt env acc2)

-- |Convert a boundary condition
--
convertBoundary :: Elem e => Boundary e -> Boundary (ElemRepr e)
convertBoundary Clamp        = Clamp
convertBoundary Mirror       = Mirror
convertBoundary Wrap         = Wrap
convertBoundary (Constant e) = Constant (fromElem e)


-- Sharing recovery
-- ----------------

-- Sharing recovery proceeds in two phases:
--
-- /Phase One: build the occurence map/
--
-- This is a top-down traversal of the AST that computes a map from AST nodes to the number of
-- occurences of that AST node in the overall Accelerate program.  An occurrences count of two or
-- more indicates sharing.  (Implemented by 'makeOccMap'.)
--
-- /Phase Two: determine scopes and inject sharing information/
--
-- This is a bottom-up traversal that determines the scope for every binding to be introduced
-- to share a subterm.  It uses the occurence map to determine, for every shared subtree, the
-- lowest AST node at which the binding for that shared subtree can be placed — it's the meet of
-- all the shared subtree occurences.  (Implemented by 'determineScopes'.)
--
-- The second phase is also injecting the sharing information into the HOAS AST using sharing let and 
-- variable annotations (see 'SharingAcc' below).
--
-- We use hash tables (instead of Data.Map) as computing stable names forces us to live in IO anyway.

-- Opaque stable name for an array computation — used to key the occurence map.
--
data StableAccName where
  StableAccName :: Typeable arrs => StableName (Acc arrs) -> StableAccName

instance Eq StableAccName where
  StableAccName sn1 == StableAccName sn2
    | Just sn1' <- gcast sn1 = sn1' == sn2
    | otherwise              = False

makeStableAcc :: Acc arrs -> IO (StableName (Acc arrs))
makeStableAcc acc = acc `seq` makeStableName acc

-- Interleave sharing annotations into an array computation AST.  Subtrees can be marked as being
-- represented by variable (binding a shared subtree) using 'VarSharing' and as being prefixed by
-- a let binding (for a shared subtree) using 'LetSharing'.
--
data SharingAcc arrs where
  VarSharing :: Arrays arrs => StableName (Acc arrs)                           -> SharingAcc arrs
  LetSharing ::                StableSharingAcc -> SharingAcc arrs             -> SharingAcc arrs
  AccSharing :: Arrays arrs => StableName (Acc arrs) -> PreAcc SharingAcc arrs -> SharingAcc arrs

-- Stable name for an array computation associated with its sharing-annotated version.
--
data StableSharingAcc where
  StableSharingAcc :: (Typeable arrs, Arrays arrs) 
                   => StableName (Acc arrs) -> SharingAcc arrs -> StableSharingAcc

instance Show StableSharingAcc where
  show (StableSharingAcc sn _) = show $ hashStableName sn

instance Eq StableSharingAcc where
  StableSharingAcc sn1 _ == StableSharingAcc sn2 _
    | Just sn1' <- gcast sn1 = sn1' == sn2
    | otherwise              = False

-- Test whether the given stable names matches an array computation with sharing.
--
matchStableAcc :: Typeable arrs => StableName (Acc arrs) -> StableSharingAcc -> Bool
matchStableAcc sn1 (StableSharingAcc sn2 _)
  | Just sn1' <- gcast sn1 = sn1' == sn2
  | otherwise              = False

-- Hash table keyed on the stable names of array computations.
--    
type AccHashTable v = Hash.HashTable StableAccName v

-- The occurrence map associates each AST node with an occurence count.
--
type OccMap = AccHashTable Int

-- Create a new hash table keyed by array computations.
--
newAccHashTable :: IO (AccHashTable v)
newAccHashTable = Hash.new (==) hashStableAcc
  where
    hashStableAcc (StableAccName sn) = fromIntegral (hashStableName sn)
    
-- Look up a hash table keyed by array computations using a sharing array computation.
--
lookupWithSharingAcc :: AccHashTable v -> StableSharingAcc -> IO (Maybe v)
lookupWithSharingAcc oc (StableSharingAcc sn _) = Hash.lookup oc (StableAccName sn)

-- Higher-order combinators to traverse array computations.
--
traverseAcc :: forall a res. Typeable a 
            => (StableAccName -> IO res)           -- process current node (before subtree traversal)
            -> (StableAccName -> [res] -> IO res)  -- combine results
            -> Acc a
            -> IO res
traverseAcc process combine acc@(Acc pacc)
  = do
      sa <- liftM StableAccName $ makeStableAcc acc
      case pacc of
        FstArray acc             -> trav sa acc
        SndArray acc             -> trav sa acc
        Use _                    -> process sa
        Unit _                   -> process sa
        Reshape _ acc            -> trav sa acc
        Replicate _ acc          -> trav sa acc
        Index acc _              -> trav sa acc
        Map _ acc                -> trav sa acc
        ZipWith _ acc1 acc2      -> trav2 sa acc1 acc2
        Fold _ _ acc             -> trav sa acc
        FoldSeg _ _ acc1 acc2    -> trav2 sa acc1 acc2
        Scanl _ _ acc            -> trav sa acc
        Scanr _ _ acc            -> trav sa acc
        Permute _ acc1 _ acc2    -> trav2 sa acc1 acc2
        Backpermute _ _ acc      -> trav sa acc
        Stencil _ _ acc          -> trav sa acc
        Stencil2 _ _ acc1 _ acc2 -> trav2 sa acc1 acc2
  where
    trav :: Typeable b => StableAccName -> Acc b -> IO res
    trav sa acc
      = do
          thisRes <- process sa
          subRes  <- traverseAcc process combine acc
          combine sa [subRes, thisRes]                  -- local result must be last

    trav2 :: (Typeable b, Typeable c) => StableAccName -> Acc b -> Acc c -> IO res
    trav2 sa acc1 acc2
      = do
          thisRes <- process sa
          subRes1 <- traverseAcc process combine acc1
          subRes2 <- traverseAcc process combine acc2
          combine sa [subRes1, subRes2, thisRes]        -- local result must be last

-- Compute the occurence map (Phase One).
--
makeOccMap :: Typeable arrs => Acc arrs -> IO OccMap
makeOccMap acc
  = do
      occMap <- newAccHashTable
      traverseAcc (enterOcc occMap) (\_ _ -> return ()) acc
      return occMap
  where
    -- Enter one AST node occurences into an occurence map.
    --
    enterOcc :: OccMap -> StableAccName -> IO ()
    enterOcc occMap sa 
      = do
          entry <- Hash.lookup occMap sa
          case entry of
            Nothing -> Hash.insert occMap sa 1
            Just n  -> Hash.update occMap sa (n + 1) >> return ()

type NodeCounts = [(StableSharingAcc, Int)]

-- Determine the scopes of all variables representing shared subterms (Phase Two).
--
determineScopes :: Typeable a => OccMap -> Acc a -> IO (SharingAcc a)
determineScopes occMap acc
  = do
      accWithLets <- liftM fst $ injectBindings acc
      liftM fst $ pruneSharedSubtrees occMap Nothing accWithLets
  where
    injectBindings :: forall arrs. Acc arrs -> IO (SharingAcc arrs, NodeCounts)
    injectBindings acc@(Acc pacc)
      = case pacc of
          FstArray acc                    -> trav FstArray acc
          SndArray acc                    -> trav SndArray acc
          Use arr                         -> reconstruct (Use arr) []
          Unit e                          -> reconstruct (Unit e) []
          Reshape sh acc                  -> trav (Reshape sh) acc
          Replicate n acc                 -> trav (Replicate n) acc
          Index acc i                     -> trav (\a -> Index a i) acc
          Map f acc                       -> trav (Map f) acc
          ZipWith f acc1 acc2             -> trav2 (ZipWith f) acc1 acc2
          Fold f z acc                    -> trav (Fold f z) acc
          FoldSeg f z acc1 acc2           -> trav2 (FoldSeg f z) acc1 acc2
          Scanl f z acc                   -> trav (Scanl f z) acc
          Scanr f z acc                   -> trav (Scanr f z) acc
          Permute fc acc1 fp acc2         -> trav2 (\a1 a2 -> Permute fc a1 fp a2) acc1 acc2
          Backpermute sh fp acc           -> trav (Backpermute sh fp) acc
          Stencil st bnd acc              -> trav (Stencil st bnd) acc
          Stencil2 st bnd1 acc1 bnd2 acc2 -> trav2 (\a1 a2 -> Stencil2 st bnd1 a1 bnd2 a2) acc1 acc2
      where
        trav :: Arrays arrs 
             => (SharingAcc arrs' -> PreAcc SharingAcc arrs) 
             -> Acc arrs' 
             -> IO (SharingAcc arrs, NodeCounts)
        trav c acc
          = do
              (acc', accCount) <- injectBindings acc
              reconstruct (c acc') accCount

        trav2 :: Arrays arrs 
              => (SharingAcc arrs1 -> SharingAcc arrs2 -> PreAcc SharingAcc arrs) 
              -> Acc arrs1 
              -> Acc arrs2 
              -> IO (SharingAcc arrs, NodeCounts)
        trav2 c acc1 acc2
          = do
              (acc1', accCount1) <- injectBindings acc1
              (acc2', accCount2) <- injectBindings acc2
              reconstruct (c acc1' acc2') (accCount1 ++ accCount2)
        
        reconstruct :: Arrays arrs 
                    => PreAcc SharingAcc arrs -> NodeCounts -> IO (SharingAcc arrs, NodeCounts)
        reconstruct newAcc subCount
          = do
              sn <- makeStableAcc acc
              Just occCount <- Hash.lookup occMap (StableAccName sn)
              let sharingAcc = AccSharing sn newAcc
                  --
                  thisCount | occCount > 1 = [(StableSharingAcc sn sharingAcc, 1)] 
                            | otherwise    = []

              (newCount, bindHere) <- filterCompleted . merge $ thisCount ++ subCount
              let lets = foldl (flip (.)) id . map LetSharing $ bindHere
                           -- bind the innermost subterm with the outermost let
              return (lets sharingAcc, newCount)

    -- Combine node counts that belong to the same node.
    -- * We must preserve the ordering (as nested subterms must come after their parents).
    -- * We achieve that by using a 'foldl', while 'insert' extends the list at its end.
    merge :: NodeCounts -> NodeCounts
    merge = foldl insert []
      where
        insert []                       sub'               = [sub']
        insert (sub@(sa, count) : subs) sub'@(sa', count')
          | sa == sa' = (sa, count + count') : subs
          | otherwise = sub : insert subs sub'

    -- Extract nodes that have a complete node count (i.e., there node count is equal to the number
    -- of occurences of that node in the overall expression) => the node should be let bound at the
    -- present node.
    filterCompleted :: NodeCounts -> IO (NodeCounts, [StableSharingAcc])
    filterCompleted []                 = return ([], [])
    filterCompleted (sub@(sa, n):subs)
      = do
          (subs', bindHere) <- filterCompleted subs
          Just occCount <- lookupWithSharingAcc occMap sa
          if occCount > 1 && occCount == n
            then -- current node is the binding point for the shared node 'sa'
              return (subs', sa:bindHere)
            else -- not a binding point
              return (sub:subs, bindHere)

    -- Top-down traversal:
    -- (1) Replace every subtree that has an occurence count greater than one (which implies that
    --     the subtree is shared) by a sharing variable.
    -- (2) Drop all let bindings that are unused.
    -- The conversion of shared subtrees is performed at their abstraction point (i.e., as part of
    -- processing the let-binding where they are bound).
    --
    -- During the traversal we maintain the /sharing factor/ of the currently processed subtree;
    -- that is the number of times the currently processed subtree is used.  The occurence count of
    -- a let-bound subtree determines the sharing factor when processing that subtree.
    --
    -- To drop all unused let bindings, we collect all subtrees that we do replace by a sharing
    -- variable.
    --
    pruneSharedSubtrees :: OccMap -> Maybe Int -> SharingAcc arrs 
                        -> IO (SharingAcc arrs, [StableAccName])
    pruneSharedSubtrees _ _ (VarSharing _)
      -- before pruning, a tree may not have sharing variables
      = INTERNAL_ERROR(error) "replaceSharedByVariables" "unexpected sharing variable"
    pruneSharedSubtrees occMap sharingFactor (LetSharing (StableSharingAcc sn boundAcc) bodyAcc)
      -- prune a let binding (both it's body and binding); might drop the binding altogether
      = do
          let sa = StableAccName sn
          result@(bodyAcc', bodyUsed) <- pruneSharedSubtrees occMap sharingFactor bodyAcc
          -- Drop current binding if it is not used
          if sa `elem` bodyUsed
            then do
              -- prune the bound computation, reseting the sharing factor
              (boundAcc', boundUsed) <- pruneSharedSubtrees occMap Nothing boundAcc
              return (LetSharing (StableSharingAcc sn boundAcc') bodyAcc', 
                      filter (/= sa) bodyUsed ++ boundUsed)
            else
              return result
    pruneSharedSubtrees occMap Nothing acc@(AccSharing sn _)
      -- new root: establish the current sharing factor
      = do
        trace "-=ROOT" $ return ()
        Just occCount <- Hash.lookup occMap (StableAccName sn)
        pruneSharedSubtrees occMap (Just occCount) acc
    pruneSharedSubtrees occMap sf@(Just sharingFactor) (AccSharing sn pacc)
      -- prune tree node
      = do
          let sa = StableAccName sn
          Just occCount <- Hash.lookup occMap sa
          trace ("SF=" ++ show sharingFactor ++ "; oC=" ++ show occCount) $ return ()
          if occCount > sharingFactor
            then
              return (VarSharing sn, [sa])
            else
              case pacc of
                FstArray acc                    -> trav FstArray acc
                SndArray acc                    -> trav SndArray acc
                Use arr                         -> return (AccSharing sn $ Use arr, [])
                Unit e                          -> return (AccSharing sn $ Unit e, [])
                Reshape sh acc                  -> trav (Reshape sh) acc
                Replicate n acc                 -> trav (Replicate n) acc
                Index acc i                     -> trav (\a -> Index a i) acc
                Map f acc                       -> trav (Map f) acc
                ZipWith f acc1 acc2             -> trav2 (ZipWith f) acc1 acc2
                Fold f z acc                    -> trav (Fold f z) acc
                FoldSeg f z acc1 acc2           -> trav2 (FoldSeg f z) acc1 acc2
                Scanl f z acc                   -> trav (Scanl f z) acc
                Scanr f z acc                   -> trav (Scanr f z) acc
                Permute fc acc1 fp acc2         -> trav2 (\a1 a2 -> Permute fc a1 fp a2) acc1 acc2
                Backpermute sh fp acc           -> trav (Backpermute sh fp) acc
                Stencil st bnd acc              -> trav (Stencil st bnd) acc
                Stencil2 st bnd1 acc1 bnd2 acc2 -> trav2 (\a1 a2 -> Stencil2 st bnd1 a1 bnd2 a2) 
                                                     acc1 acc2
      where
        trav c acc
          = do
              (acc', used) <- pruneSharedSubtrees occMap sf acc
              return (AccSharing sn $ c acc', used)
    
        trav2 c acc1 acc2
          = do
              (acc1', used1) <- pruneSharedSubtrees occMap sf acc1
              (acc2', used2) <- pruneSharedSubtrees occMap sf acc2
              return (AccSharing sn $ c acc1' acc2', used1 ++ used2)

-- |Recover sharing information and annotate the HOAS AST with variable and let binding annotations.
--
-- NB: Strictly speaking, this function is not deterministic, as it uses stable pointers to determine
-- the sharing of subterms.  The stable pointer API does not guarantee its completeness; i.e., it may
-- miss some equalities, which implies that we may fail to discover some sharing.  However, sharing
-- does not affect the denotational meaning of the array computation; hence, we will never compromise
-- denotational correctness.
--
recoverSharing :: Typeable a => Acc a -> SharingAcc a
{-# NOINLINE recoverSharing #-}
recoverSharing acc 
  = unsafePerformIO $ do          -- as we need to use stable pointers; it's safe as explained above
      occMap <- makeOccMap acc
      determineScopes occMap acc


-- Embedded expressions of the surface language
-- --------------------------------------------

-- HOAS expressions mirror the constructors of `AST.OpenExp', but with the
-- `Tag' constructor instead of variables in the form of de Bruijn indices.
-- Moreover, HOAS expression use n-tuples and the type class 'Elem' to
-- constrain element types, whereas `AST.OpenExp' uses nested pairs and the 
-- GADT 'TupleType'.
--

-- |Scalar expressions used to parametrise collective array operations
--
data Exp t where
    -- Needed for conversion to de Bruijn form
  Tag         :: Elem t
              => Int                          -> Exp t
                 -- environment size at defining occurrence

    -- All the same constructors as 'AST.Exp'
  Const       :: Elem t 
              => t                             -> Exp t

  Tuple       :: (Elem t, IsTuple t)
              => Tuple.Tuple Exp (TupleRepr t) -> Exp t
  Prj         :: (Elem t, IsTuple t)
              => TupleIdx (TupleRepr t) e     
              -> Exp t                         -> Exp e              
  Cond        :: Exp Bool -> Exp t -> Exp t    -> Exp t
  PrimConst   :: Elem t                       
              => PrimConst t                   -> Exp t
  PrimApp     :: (Elem a, Elem r)             
              => PrimFun (a -> r) -> Exp a     -> Exp r
  IndexScalar :: (Ix dim, Elem t)
              => Acc (Array dim t) -> Exp dim  -> Exp t
  Shape       :: (Ix dim, Elem e)
              => Acc (Array dim e)             -> Exp dim


-- |Conversion from HOAS to de Bruijn expression AST
-- -

-- A layout of an environment has an entry for each entry of the environment.
-- Each entry in the layout holds the deBruijn index that refers to the
-- corresponding entry in the environment.
--
data Layout env env' where
  EmptyLayout :: Layout env ()
  PushLayout  :: Typeable t 
              => Layout env env' -> Idx env t -> Layout env (env', t)

-- Project the nth index out of an environment layout.
--
prjIdx :: Typeable t => Int -> Layout env env' -> Idx env t
prjIdx 0 (PushLayout _ ix) = case gcast ix of
                               Just ix' -> ix'
                               Nothing  -> INTERNAL_ERROR(error) "prjIdx" "type mismatch"
prjIdx n (PushLayout l _)  = prjIdx (n - 1) l
prjIdx _ EmptyLayout       = INTERNAL_ERROR(error) "prjIdx" "inconsistent valuation"

-- Add an entry to a layout, incrementing all indices
--
incLayout :: Layout env env' -> Layout (env, t) env'
incLayout EmptyLayout         = EmptyLayout
incLayout (PushLayout lyt ix) = PushLayout (incLayout lyt) (SuccIdx ix)

-- |Convert an open expression with given environment layouts.
--
convertOpenExp :: forall t env aenv. 
                  Layout env  env       -- scalar environment
               -> Layout aenv aenv      -- array environment
               -> Exp t                 -- expression to be converted
               -> AST.OpenExp env aenv t
convertOpenExp lyt alyt = cvt
  where
    cvt :: Exp t' -> AST.OpenExp env aenv t'
    cvt (Tag i)             = AST.Var (prjIdx i lyt)
    cvt (Const v)           = AST.Const (fromElem v)
    cvt (Tuple tup)         = AST.Tuple (convertTuple lyt alyt tup)
    cvt (Prj idx e)         = AST.Prj idx (cvt e)
    cvt (Cond e1 e2 e3)     = AST.Cond (cvt e1) (cvt e2) (cvt e3)
    cvt (PrimConst c)       = AST.PrimConst c
    cvt (PrimApp p e)       = AST.PrimApp p (cvt e)
    cvt (IndexScalar a e)   = AST.IndexScalar (convertOpenAcc alyt a) (cvt e)
    cvt (Shape a)           = AST.Shape (convertOpenAcc alyt a)

-- |Convert a tuple expression
--
convertTuple :: Layout env env 
             -> Layout aenv aenv 
             -> Tuple.Tuple Exp t 
             -> Tuple.Tuple (AST.OpenExp env aenv) t
convertTuple _lyt _alyt NilTup           = NilTup
convertTuple lyt  alyt  (es `SnocTup` e) 
  = convertTuple lyt alyt es `SnocTup` convertOpenExp lyt alyt e

-- |Convert an expression closed wrt to scalar variables
--
convertExp :: Layout aenv aenv      -- array environment
           -> Exp t                 -- expression to be converted
           -> AST.Exp aenv t
convertExp alyt = convertOpenExp EmptyLayout alyt

-- |Convert a closed expression
--
convertClosedExp :: Exp t -> AST.Exp () t
convertClosedExp = convertExp EmptyLayout

-- |Convert a unary functions
--
convertFun1 :: forall a b aenv. Elem a
            => Layout aenv aenv 
            -> (Exp a -> Exp b) 
            -> AST.Fun aenv (a -> b)
convertFun1 alyt f = Lam (Body openF)
  where
    a     = Tag 0
    lyt   = EmptyLayout 
            `PushLayout` 
            (ZeroIdx :: Idx ((), ElemRepr a) (ElemRepr a))
    openF = convertOpenExp lyt alyt (f a)

-- |Convert a binary functions
--
convertFun2 :: forall a b c aenv. (Elem a, Elem b) 
            => Layout aenv aenv 
            -> (Exp a -> Exp b -> Exp c) 
            -> AST.Fun aenv (a -> b -> c)
convertFun2 alyt f = Lam (Lam (Body openF))
  where
    a     = Tag 1
    b     = Tag 0
    lyt   = EmptyLayout 
            `PushLayout`
            (SuccIdx ZeroIdx :: Idx (((), ElemRepr a), ElemRepr b) (ElemRepr a))
            `PushLayout`
            (ZeroIdx         :: Idx (((), ElemRepr a), ElemRepr b) (ElemRepr b))
    openF = convertOpenExp lyt alyt (f a b)

-- Convert a unary stencil function
--
convertStencilFun :: forall dim a stencil b aenv. (Elem a, Stencil dim a stencil)
                  => SharingAcc (Array dim a)            -- just passed to fix the type variables
                  -> Layout aenv aenv 
                  -> (stencil -> Exp b)
                  -> AST.Fun aenv (StencilRepr dim stencil -> b)
convertStencilFun _ alyt stencilFun = Lam (Body openStencilFun)
  where
    stencil = Tag 0 :: Exp (StencilRepr dim stencil)
    lyt     = EmptyLayout 
              `PushLayout` 
              (ZeroIdx :: Idx ((), ElemRepr (StencilRepr dim stencil)) 
                              (ElemRepr (StencilRepr dim stencil)))
    openStencilFun = convertOpenExp lyt alyt $
                       stencilFun (stencilPrj (undefined::dim) (undefined::a) stencil)

-- Convert a binary stencil function
--
convertStencilFun2 :: forall dim a b stencil1 stencil2 c aenv. 
                      (Elem a, Stencil dim a stencil1,
                       Elem b, Stencil dim b stencil2)
                   => SharingAcc (Array dim a)           -- just passed to fix the type variables
                   -> SharingAcc (Array dim b)           -- just passed to fix the type variables
                   -> Layout aenv aenv 
                   -> (stencil1 -> stencil2 -> Exp c)
                   -> AST.Fun aenv (StencilRepr dim stencil1 ->
                                    StencilRepr dim stencil2 -> c)
convertStencilFun2 _ _ alyt stencilFun = Lam (Lam (Body openStencilFun))
  where
    stencil1 = Tag 1 :: Exp (StencilRepr dim stencil1)
    stencil2 = Tag 0 :: Exp (StencilRepr dim stencil2)
    lyt     = EmptyLayout 
              `PushLayout` 
              (SuccIdx ZeroIdx :: Idx (((), ElemRepr (StencilRepr dim stencil1)),
                                            ElemRepr (StencilRepr dim stencil2)) 
                                       (ElemRepr (StencilRepr dim stencil1)))
              `PushLayout` 
              (ZeroIdx         :: Idx (((), ElemRepr (StencilRepr dim stencil1)),
                                            ElemRepr (StencilRepr dim stencil2)) 
                                       (ElemRepr (StencilRepr dim stencil2)))
    openStencilFun = convertOpenExp lyt alyt $
                       stencilFun (stencilPrj (undefined::dim) (undefined::a) stencil1)
                                  (stencilPrj (undefined::dim) (undefined::b) stencil2)


-- Pretty printing
--

instance Arrays arrs => Show (Acc arrs) where
  show = show . convertAcc
  
instance Show (Exp a) where
  show = show . convertClosedExp


-- |Smart constructors to construct representation AST forms
-- ---------------------------------------------------------

mkIndex :: forall slix e aenv. (SliceIx slix, Elem e) 
        => AST.OpenAcc aenv (Array (SliceDim slix) e)
        -> AST.Exp     aenv slix
        -> AST.OpenAcc aenv (Array (Slice slix) e)
mkIndex arr e 
  = AST.Index (convertSliceIndex slix (sliceIndex slix)) arr e
  where
    slix = undefined :: slix

mkReplicate :: forall slix e aenv. (SliceIx slix, Elem e) 
        => AST.Exp     aenv slix
        -> AST.OpenAcc aenv (Array (Slice slix) e)
        -> AST.OpenAcc aenv (Array (SliceDim slix) e)
mkReplicate e arr
  = AST.Replicate (convertSliceIndex slix (sliceIndex slix)) e arr
  where
    slix = undefined :: slix


-- |Smart constructors for stencil reification
-- -------------------------------------------

-- Stencil reification
--
-- In the AST representation, we turn the stencil type from nested tuples of Accelerate expressions
-- into an Accelerate expression whose type is a tuple nested in the same manner.  This enables us
-- to represent the stencil function as a unary function (which also only needs one de Bruijn
-- index). The various positions in the stencil are accessed via tuple indices (i.e., projections).

class (Elem (StencilRepr dim stencil), AST.Stencil dim a (StencilRepr dim stencil)) 
  => Stencil dim a stencil where
  type StencilRepr dim stencil :: *
  stencilPrj :: dim{-dummy-} -> a{-dummy-} -> Exp (StencilRepr dim stencil) -> stencil
  
-- DIM1
instance Elem a => Stencil DIM1 a (Exp a, Exp a, Exp a) where
  type StencilRepr DIM1 (Exp a, Exp a, Exp a) = (a, a, a)
  stencilPrj _ _ s = (Prj tix2 s, Prj tix1 s, Prj tix0 s)
instance Elem a => Stencil DIM1 a (Exp a, Exp a, Exp a, Exp a, Exp a) where
  type StencilRepr DIM1 (Exp a, Exp a, Exp a, Exp a, Exp a) = (a, a, a, a, a)
  stencilPrj _ _ s = (Prj tix4 s, Prj tix3 s, Prj tix2 s, Prj tix1 s, Prj tix0 s)
instance Elem a => Stencil DIM1 a (Exp a, Exp a, Exp a, Exp a, Exp a, Exp a, Exp a) where
  type StencilRepr DIM1 (Exp a, Exp a, Exp a, Exp a, Exp a, Exp a, Exp a) = (a, a, a, a, a, a, a)
  stencilPrj _ _ s = (Prj tix6 s, Prj tix5 s, Prj tix4 s, Prj tix3 s, Prj tix2 s, Prj tix1 s, 
                      Prj tix0 s)
instance Elem a 
  => Stencil DIM1 a (Exp a, Exp a, Exp a, Exp a, Exp a, Exp a, Exp a, Exp a, Exp a) where
  type StencilRepr DIM1 (Exp a, Exp a, Exp a, Exp a, Exp a, Exp a, Exp a, Exp a, Exp a) 
    = (a, a, a, a, a, a, a, a, a)
  stencilPrj _ _ s = (Prj tix8 s, Prj tix7 s, Prj tix6 s, Prj tix5 s, Prj tix4 s, Prj tix3 s,
                      Prj tix2 s, Prj tix1 s, Prj tix0 s)

-- DIM2
instance (Stencil DIM1 a row2, 
          Stencil DIM1 a row1,
          Stencil DIM1 a row0) => Stencil DIM2 a (row2, row1, row0) where
  type StencilRepr DIM2 (row2, row1, row0) 
    = (StencilRepr DIM1 row2, StencilRepr DIM1 row1, StencilRepr DIM1 row0)
  stencilPrj _ a s = (stencilPrj (undefined::DIM1) a (Prj tix2 s), 
                      stencilPrj (undefined::DIM1) a (Prj tix1 s), 
                      stencilPrj (undefined::DIM1) a (Prj tix0 s))
instance (Stencil DIM1 a row1,
          Stencil DIM1 a row2,
          Stencil DIM1 a row3,
          Stencil DIM1 a row4,
          Stencil DIM1 a row5) => Stencil DIM2 a (row1, row2, row3, row4, row5) where
  type StencilRepr DIM2 (row1, row2, row3, row4, row5) 
    = (StencilRepr DIM1 row1, StencilRepr DIM1 row2, StencilRepr DIM1 row3, StencilRepr DIM1 row4,
       StencilRepr DIM1 row5)
  stencilPrj _ a s = (stencilPrj (undefined::DIM1) a (Prj tix4 s), 
                      stencilPrj (undefined::DIM1) a (Prj tix3 s), 
                      stencilPrj (undefined::DIM1) a (Prj tix2 s), 
                      stencilPrj (undefined::DIM1) a (Prj tix1 s), 
                      stencilPrj (undefined::DIM1) a (Prj tix0 s))
instance (Stencil DIM1 a row1,
          Stencil DIM1 a row2,
          Stencil DIM1 a row3,
          Stencil DIM1 a row4,
          Stencil DIM1 a row5,
          Stencil DIM1 a row6,
          Stencil DIM1 a row7) => Stencil DIM2 a (row1, row2, row3, row4, row5, row6, row7) where
  type StencilRepr DIM2 (row1, row2, row3, row4, row5, row6, row7) 
    = (StencilRepr DIM1 row1, StencilRepr DIM1 row2, StencilRepr DIM1 row3, StencilRepr DIM1 row4,
       StencilRepr DIM1 row5, StencilRepr DIM1 row6, StencilRepr DIM1 row7)
  stencilPrj _ a s = (stencilPrj (undefined::DIM1) a (Prj tix6 s), 
                      stencilPrj (undefined::DIM1) a (Prj tix5 s), 
                      stencilPrj (undefined::DIM1) a (Prj tix4 s), 
                      stencilPrj (undefined::DIM1) a (Prj tix3 s), 
                      stencilPrj (undefined::DIM1) a (Prj tix2 s), 
                      stencilPrj (undefined::DIM1) a (Prj tix1 s), 
                      stencilPrj (undefined::DIM1) a (Prj tix0 s))
instance (Stencil DIM1 a row1,
          Stencil DIM1 a row2,
          Stencil DIM1 a row3,
          Stencil DIM1 a row4,
          Stencil DIM1 a row5,
          Stencil DIM1 a row6,
          Stencil DIM1 a row7,
          Stencil DIM1 a row8,
          Stencil DIM1 a row9) 
  => Stencil DIM2 a (row1, row2, row3, row4, row5, row6, row7, row8, row9) where
  type StencilRepr DIM2 (row1, row2, row3, row4, row5, row6, row7, row8, row9) 
    = (StencilRepr DIM1 row1, StencilRepr DIM1 row2, StencilRepr DIM1 row3, StencilRepr DIM1 row4,
       StencilRepr DIM1 row5, StencilRepr DIM1 row6, StencilRepr DIM1 row7, StencilRepr DIM1 row8,
       StencilRepr DIM1 row9)
  stencilPrj _ a s = (stencilPrj (undefined::DIM1) a (Prj tix8 s), 
                      stencilPrj (undefined::DIM1) a (Prj tix7 s), 
                      stencilPrj (undefined::DIM1) a (Prj tix6 s), 
                      stencilPrj (undefined::DIM1) a (Prj tix5 s), 
                      stencilPrj (undefined::DIM1) a (Prj tix4 s), 
                      stencilPrj (undefined::DIM1) a (Prj tix3 s), 
                      stencilPrj (undefined::DIM1) a (Prj tix2 s), 
                      stencilPrj (undefined::DIM1) a (Prj tix1 s), 
                      stencilPrj (undefined::DIM1) a (Prj tix0 s))

-- DIM3
instance (Stencil DIM2 a row1, 
          Stencil DIM2 a row2,
          Stencil DIM2 a row3) => Stencil DIM3 a (row1, row2, row3) where
  type StencilRepr DIM3 (row1, row2, row3) 
    = (StencilRepr DIM2 row1, StencilRepr DIM2 row2, StencilRepr DIM2 row3)
  stencilPrj _ a s = (stencilPrj (undefined::DIM2) a (Prj tix2 s), 
                      stencilPrj (undefined::DIM2) a (Prj tix1 s), 
                      stencilPrj (undefined::DIM2) a (Prj tix0 s))
instance (Stencil DIM2 a row1,
          Stencil DIM2 a row2,
          Stencil DIM2 a row3,
          Stencil DIM2 a row4,
          Stencil DIM2 a row5) => Stencil DIM3 a (row1, row2, row3, row4, row5) where
  type StencilRepr DIM3 (row1, row2, row3, row4, row5) 
    = (StencilRepr DIM2 row1, StencilRepr DIM2 row2, StencilRepr DIM2 row3, StencilRepr DIM2 row4,
       StencilRepr DIM2 row5)
  stencilPrj _ a s = (stencilPrj (undefined::DIM2) a (Prj tix4 s), 
                      stencilPrj (undefined::DIM2) a (Prj tix3 s), 
                      stencilPrj (undefined::DIM2) a (Prj tix2 s), 
                      stencilPrj (undefined::DIM2) a (Prj tix1 s), 
                      stencilPrj (undefined::DIM2) a (Prj tix0 s))
instance (Stencil DIM2 a row1,
          Stencil DIM2 a row2,
          Stencil DIM2 a row3,
          Stencil DIM2 a row4,
          Stencil DIM2 a row5,
          Stencil DIM2 a row6,
          Stencil DIM2 a row7) => Stencil DIM3 a (row1, row2, row3, row4, row5, row6, row7) where
  type StencilRepr DIM3 (row1, row2, row3, row4, row5, row6, row7) 
    = (StencilRepr DIM2 row1, StencilRepr DIM2 row2, StencilRepr DIM2 row3, StencilRepr DIM2 row4,
       StencilRepr DIM2 row5, StencilRepr DIM2 row6, StencilRepr DIM2 row7)
  stencilPrj _ a s = (stencilPrj (undefined::DIM2) a (Prj tix6 s), 
                      stencilPrj (undefined::DIM2) a (Prj tix5 s), 
                      stencilPrj (undefined::DIM2) a (Prj tix4 s), 
                      stencilPrj (undefined::DIM2) a (Prj tix3 s), 
                      stencilPrj (undefined::DIM2) a (Prj tix2 s), 
                      stencilPrj (undefined::DIM2) a (Prj tix1 s), 
                      stencilPrj (undefined::DIM2) a (Prj tix0 s))
instance (Stencil DIM2 a row1,
          Stencil DIM2 a row2,
          Stencil DIM2 a row3,
          Stencil DIM2 a row4,
          Stencil DIM2 a row5,
          Stencil DIM2 a row6,
          Stencil DIM2 a row7,
          Stencil DIM2 a row8,
          Stencil DIM2 a row9) 
  => Stencil DIM3 a (row1, row2, row3, row4, row5, row6, row7, row8, row9) where
  type StencilRepr DIM3 (row1, row2, row3, row4, row5, row6, row7, row8, row9) 
    = (StencilRepr DIM2 row1, StencilRepr DIM2 row2, StencilRepr DIM2 row3, StencilRepr DIM2 row4,
       StencilRepr DIM2 row5, StencilRepr DIM2 row6, StencilRepr DIM2 row7, StencilRepr DIM2 row8,
       StencilRepr DIM2 row9)
  stencilPrj _ a s = (stencilPrj (undefined::DIM2) a (Prj tix8 s), 
                      stencilPrj (undefined::DIM2) a (Prj tix7 s), 
                      stencilPrj (undefined::DIM2) a (Prj tix6 s), 
                      stencilPrj (undefined::DIM2) a (Prj tix5 s), 
                      stencilPrj (undefined::DIM2) a (Prj tix4 s), 
                      stencilPrj (undefined::DIM2) a (Prj tix3 s), 
                      stencilPrj (undefined::DIM2) a (Prj tix2 s), 
                      stencilPrj (undefined::DIM2) a (Prj tix1 s), 
                      stencilPrj (undefined::DIM2) a (Prj tix0 s))

-- Auxilliary tuple index constants
--
tix0 :: Elem s => TupleIdx (t, s) s
tix0 = ZeroTupIdx
tix1 :: Elem s => TupleIdx ((t, s), s1) s
tix1 = SuccTupIdx tix0
tix2 :: Elem s => TupleIdx (((t, s), s1), s2) s
tix2 = SuccTupIdx tix1
tix3 :: Elem s => TupleIdx ((((t, s), s1), s2), s3) s
tix3 = SuccTupIdx tix2
tix4 :: Elem s => TupleIdx (((((t, s), s1), s2), s3), s4) s
tix4 = SuccTupIdx tix3
tix5 :: Elem s => TupleIdx ((((((t, s), s1), s2), s3), s4), s5) s
tix5 = SuccTupIdx tix4
tix6 :: Elem s => TupleIdx (((((((t, s), s1), s2), s3), s4), s5), s6) s
tix6 = SuccTupIdx tix5
tix7 :: Elem s => TupleIdx ((((((((t, s), s1), s2), s3), s4), s5), s6), s7) s
tix7 = SuccTupIdx tix6
tix8 :: Elem s => TupleIdx (((((((((t, s), s1), s2), s3), s4), s5), s6), s7), s8) s
tix8 = SuccTupIdx tix7

-- Pushes the 'Acc' constructor through a pair
--
unpair :: (Ix dim1, Ix dim2, Elem e1, Elem e2)
       => Acc (Array dim1 e1, Array dim2 e2) 
       -> (Acc (Array dim1 e1), Acc (Array dim2 e2))
unpair acc = (Acc $ FstArray acc, Acc $ SndArray acc)


-- Smart constructor for literals
-- 

-- |Constant scalar expression
--
constant :: Elem t => t -> Exp t
constant = Const

-- Smart constructor and destructors for tuples
--

tup2 :: (Elem a, Elem b) => (Exp a, Exp b) -> Exp (a, b)
tup2 (x1, x2) = Tuple (NilTup `SnocTup` x1 `SnocTup` x2)

tup3 :: (Elem a, Elem b, Elem c) => (Exp a, Exp b, Exp c) -> Exp (a, b, c)
tup3 (x1, x2, x3) = Tuple (NilTup `SnocTup` x1 `SnocTup` x2 `SnocTup` x3)

tup4 :: (Elem a, Elem b, Elem c, Elem d) 
     => (Exp a, Exp b, Exp c, Exp d) -> Exp (a, b, c, d)
tup4 (x1, x2, x3, x4) 
  = Tuple (NilTup `SnocTup` x1 `SnocTup` x2 `SnocTup` x3 `SnocTup` x4)

tup5 :: (Elem a, Elem b, Elem c, Elem d, Elem e) 
     => (Exp a, Exp b, Exp c, Exp d, Exp e) -> Exp (a, b, c, d, e)
tup5 (x1, x2, x3, x4, x5)
  = Tuple $
      NilTup `SnocTup` x1 `SnocTup` x2 `SnocTup` x3 `SnocTup` x4 `SnocTup` x5

tup6 :: (Elem a, Elem b, Elem c, Elem d, Elem e, Elem f)
     => (Exp a, Exp b, Exp c, Exp d, Exp e, Exp f) -> Exp (a, b, c, d, e, f)
tup6 (x1, x2, x3, x4, x5, x6)
  = Tuple $
      NilTup `SnocTup` x1 `SnocTup` x2 `SnocTup` x3 `SnocTup` x4 `SnocTup` x5 `SnocTup` x6

tup7 :: (Elem a, Elem b, Elem c, Elem d, Elem e, Elem f, Elem g)
     => (Exp a, Exp b, Exp c, Exp d, Exp e, Exp f, Exp g)
     -> Exp (a, b, c, d, e, f, g)
tup7 (x1, x2, x3, x4, x5, x6, x7)
  = Tuple $
      NilTup `SnocTup` x1 `SnocTup` x2 `SnocTup` x3
	     `SnocTup` x4 `SnocTup` x5 `SnocTup` x6 `SnocTup` x7

tup8 :: (Elem a, Elem b, Elem c, Elem d, Elem e, Elem f, Elem g, Elem h)
     => (Exp a, Exp b, Exp c, Exp d, Exp e, Exp f, Exp g, Exp h)
     -> Exp (a, b, c, d, e, f, g, h)
tup8 (x1, x2, x3, x4, x5, x6, x7, x8)
  = Tuple $
      NilTup `SnocTup` x1 `SnocTup` x2 `SnocTup` x3 `SnocTup` x4
	     `SnocTup` x5 `SnocTup` x6 `SnocTup` x7 `SnocTup` x8

tup9 :: (Elem a, Elem b, Elem c, Elem d, Elem e, Elem f, Elem g, Elem h, Elem i)
     => (Exp a, Exp b, Exp c, Exp d, Exp e, Exp f, Exp g, Exp h, Exp i)
     -> Exp (a, b, c, d, e, f, g, h, i)
tup9 (x1, x2, x3, x4, x5, x6, x7, x8, x9)
  = Tuple $
      NilTup `SnocTup` x1 `SnocTup` x2 `SnocTup` x3 `SnocTup` x4
	     `SnocTup` x5 `SnocTup` x6 `SnocTup` x7 `SnocTup` x8 `SnocTup` x9

untup2 :: (Elem a, Elem b) => Exp (a, b) -> (Exp a, Exp b)
untup2 e = ((SuccTupIdx ZeroTupIdx) `Prj` e, ZeroTupIdx `Prj` e)

untup3 :: (Elem a, Elem b, Elem c) => Exp (a, b, c) -> (Exp a, Exp b, Exp c)
untup3 e = (SuccTupIdx (SuccTupIdx ZeroTupIdx) `Prj` e, 
            SuccTupIdx ZeroTupIdx `Prj` e, 
            ZeroTupIdx `Prj` e)

untup4 :: (Elem a, Elem b, Elem c, Elem d) 
       => Exp (a, b, c, d) -> (Exp a, Exp b, Exp c, Exp d)
untup4 e = (SuccTupIdx (SuccTupIdx (SuccTupIdx ZeroTupIdx)) `Prj` e, 
            SuccTupIdx (SuccTupIdx ZeroTupIdx) `Prj` e, 
            SuccTupIdx ZeroTupIdx `Prj` e, 
            ZeroTupIdx `Prj` e)

untup5 :: (Elem a, Elem b, Elem c, Elem d, Elem e) 
       => Exp (a, b, c, d, e) -> (Exp a, Exp b, Exp c, Exp d, Exp e)
untup5 e = (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx ZeroTupIdx))) 
            `Prj` e, 
            SuccTupIdx (SuccTupIdx (SuccTupIdx ZeroTupIdx)) `Prj` e, 
            SuccTupIdx (SuccTupIdx ZeroTupIdx) `Prj` e, 
            SuccTupIdx ZeroTupIdx `Prj` e, 
            ZeroTupIdx `Prj` e)

untup6 :: (Elem a, Elem b, Elem c, Elem d, Elem e, Elem f)
       => Exp (a, b, c, d, e, f) -> (Exp a, Exp b, Exp c, Exp d, Exp e, Exp f)
untup6 e = (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx ZeroTupIdx)))) `Prj` e,
            SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx ZeroTupIdx))) `Prj` e,
            SuccTupIdx (SuccTupIdx (SuccTupIdx ZeroTupIdx)) `Prj` e,
            SuccTupIdx (SuccTupIdx ZeroTupIdx) `Prj` e,
            SuccTupIdx ZeroTupIdx `Prj` e,
            ZeroTupIdx `Prj` e)

untup7 :: (Elem a, Elem b, Elem c, Elem d, Elem e, Elem f, Elem g)
       => Exp (a, b, c, d, e, f, g) -> (Exp a, Exp b, Exp c, Exp d, Exp e, Exp f, Exp g)
untup7 e = (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx ZeroTupIdx))))) `Prj` e,
            SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx ZeroTupIdx)))) `Prj` e,
            SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx ZeroTupIdx))) `Prj` e,
            SuccTupIdx (SuccTupIdx (SuccTupIdx ZeroTupIdx)) `Prj` e,
            SuccTupIdx (SuccTupIdx ZeroTupIdx) `Prj` e,
            SuccTupIdx ZeroTupIdx `Prj` e,
            ZeroTupIdx `Prj` e)

untup8 :: (Elem a, Elem b, Elem c, Elem d, Elem e, Elem f, Elem g, Elem h)
       => Exp (a, b, c, d, e, f, g, h) -> (Exp a, Exp b, Exp c, Exp d, Exp e, Exp f, Exp g, Exp h)
untup8 e = (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx ZeroTupIdx)))))) `Prj` e,
            SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx ZeroTupIdx))))) `Prj` e,
            SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx ZeroTupIdx)))) `Prj` e,
            SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx ZeroTupIdx))) `Prj` e,
            SuccTupIdx (SuccTupIdx (SuccTupIdx ZeroTupIdx)) `Prj` e,
            SuccTupIdx (SuccTupIdx ZeroTupIdx) `Prj` e,
            SuccTupIdx ZeroTupIdx `Prj` e,
            ZeroTupIdx `Prj` e)

untup9 :: (Elem a, Elem b, Elem c, Elem d, Elem e, Elem f, Elem g, Elem h, Elem i)
       => Exp (a, b, c, d, e, f, g, h, i) -> (Exp a, Exp b, Exp c, Exp d, Exp e, Exp f, Exp g, Exp h, Exp i)
untup9 e = (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx ZeroTupIdx))))))) `Prj` e,
            SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx ZeroTupIdx)))))) `Prj` e,
            SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx ZeroTupIdx))))) `Prj` e,
            SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx ZeroTupIdx)))) `Prj` e,
            SuccTupIdx (SuccTupIdx (SuccTupIdx (SuccTupIdx ZeroTupIdx))) `Prj` e,
            SuccTupIdx (SuccTupIdx (SuccTupIdx ZeroTupIdx)) `Prj` e,
            SuccTupIdx (SuccTupIdx ZeroTupIdx) `Prj` e,
            SuccTupIdx ZeroTupIdx `Prj` e,
            ZeroTupIdx `Prj` e)

-- Smart constructor for constants
-- 

mkMinBound :: (Elem t, IsBounded t) => Exp t
mkMinBound = PrimConst (PrimMinBound boundedType)

mkMaxBound :: (Elem t, IsBounded t) => Exp t
mkMaxBound = PrimConst (PrimMaxBound boundedType)

mkPi :: (Elem r, IsFloating r) => Exp r
mkPi = PrimConst (PrimPi floatingType)

-- Operators from Floating
--

mkSin :: (Elem t, IsFloating t) => Exp t -> Exp t
mkSin x = PrimSin floatingType `PrimApp` x

mkCos :: (Elem t, IsFloating t) => Exp t -> Exp t
mkCos x = PrimCos floatingType `PrimApp` x

mkTan :: (Elem t, IsFloating t) => Exp t -> Exp t
mkTan x = PrimTan floatingType `PrimApp` x

mkAsin :: (Elem t, IsFloating t) => Exp t -> Exp t
mkAsin x = PrimAsin floatingType `PrimApp` x

mkAcos :: (Elem t, IsFloating t) => Exp t -> Exp t
mkAcos x = PrimAcos floatingType `PrimApp` x

mkAtan :: (Elem t, IsFloating t) => Exp t -> Exp t
mkAtan x = PrimAtan floatingType `PrimApp` x

mkAsinh :: (Elem t, IsFloating t) => Exp t -> Exp t
mkAsinh x = PrimAsinh floatingType `PrimApp` x

mkAcosh :: (Elem t, IsFloating t) => Exp t -> Exp t
mkAcosh x = PrimAcosh floatingType `PrimApp` x

mkAtanh :: (Elem t, IsFloating t) => Exp t -> Exp t
mkAtanh x = PrimAtanh floatingType `PrimApp` x

mkExpFloating :: (Elem t, IsFloating t) => Exp t -> Exp t
mkExpFloating x = PrimExpFloating floatingType `PrimApp` x

mkSqrt :: (Elem t, IsFloating t) => Exp t -> Exp t
mkSqrt x = PrimSqrt floatingType `PrimApp` x

mkLog :: (Elem t, IsFloating t) => Exp t -> Exp t
mkLog x = PrimLog floatingType `PrimApp` x

mkFPow :: (Elem t, IsFloating t) => Exp t -> Exp t -> Exp t
mkFPow x y = PrimFPow floatingType `PrimApp` tup2 (x, y)

mkLogBase :: (Elem t, IsFloating t) => Exp t -> Exp t -> Exp t
mkLogBase x y = PrimLogBase floatingType `PrimApp` tup2 (x, y)

-- Smart constructors for primitive applications
-- 

-- Operators from Num

mkAdd :: (Elem t, IsNum t) => Exp t -> Exp t -> Exp t
mkAdd x y = PrimAdd numType `PrimApp` tup2 (x, y)

mkSub :: (Elem t, IsNum t) => Exp t -> Exp t -> Exp t
mkSub x y = PrimSub numType `PrimApp` tup2 (x, y)

mkMul :: (Elem t, IsNum t) => Exp t -> Exp t -> Exp t
mkMul x y = PrimMul numType `PrimApp` tup2 (x, y)

mkNeg :: (Elem t, IsNum t) => Exp t -> Exp t
mkNeg x = PrimNeg numType `PrimApp` x

mkAbs :: (Elem t, IsNum t) => Exp t -> Exp t
mkAbs x = PrimAbs numType `PrimApp` x

mkSig :: (Elem t, IsNum t) => Exp t -> Exp t
mkSig x = PrimSig numType `PrimApp` x

-- Operators from Integral & Bits

mkQuot :: (Elem t, IsIntegral t) => Exp t -> Exp t -> Exp t
mkQuot x y = PrimQuot integralType `PrimApp` tup2 (x, y)

mkRem :: (Elem t, IsIntegral t) => Exp t -> Exp t -> Exp t
mkRem x y = PrimRem integralType `PrimApp` tup2 (x, y)

mkIDiv :: (Elem t, IsIntegral t) => Exp t -> Exp t -> Exp t
mkIDiv x y = PrimIDiv integralType `PrimApp` tup2 (x, y)

mkMod :: (Elem t, IsIntegral t) => Exp t -> Exp t -> Exp t
mkMod x y = PrimMod integralType `PrimApp` tup2 (x, y)

mkBAnd :: (Elem t, IsIntegral t) => Exp t -> Exp t -> Exp t
mkBAnd x y = PrimBAnd integralType `PrimApp` tup2 (x, y)

mkBOr :: (Elem t, IsIntegral t) => Exp t -> Exp t -> Exp t
mkBOr x y = PrimBOr integralType `PrimApp` tup2 (x, y)

mkBXor :: (Elem t, IsIntegral t) => Exp t -> Exp t -> Exp t
mkBXor x y = PrimBXor integralType `PrimApp` tup2 (x, y)

mkBNot :: (Elem t, IsIntegral t) => Exp t -> Exp t
mkBNot x = PrimBNot integralType `PrimApp` x

mkBShiftL :: (Elem t, IsIntegral t) => Exp t -> Exp Int -> Exp t
mkBShiftL x i = PrimBShiftL integralType `PrimApp` tup2 (x, i)

mkBShiftR :: (Elem t, IsIntegral t) => Exp t -> Exp Int -> Exp t
mkBShiftR x i = PrimBShiftR integralType `PrimApp` tup2 (x, i)

mkBRotateL :: (Elem t, IsIntegral t) => Exp t -> Exp Int -> Exp t
mkBRotateL x i = PrimBRotateL integralType `PrimApp` tup2 (x, i)

mkBRotateR :: (Elem t, IsIntegral t) => Exp t -> Exp Int -> Exp t
mkBRotateR x i = PrimBRotateR integralType `PrimApp` tup2 (x, i)

-- Operators from Fractional, Floating, RealFrac & RealFloat

mkFDiv :: (Elem t, IsFloating t) => Exp t -> Exp t -> Exp t
mkFDiv x y = PrimFDiv floatingType `PrimApp` tup2 (x, y)

mkRecip :: (Elem t, IsFloating t) => Exp t -> Exp t
mkRecip x = PrimRecip floatingType `PrimApp` x

mkAtan2 :: (Elem t, IsFloating t) => Exp t -> Exp t -> Exp t
mkAtan2 x y = PrimAtan2 floatingType `PrimApp` tup2 (x, y)

-- FIXME: add operations from Floating, RealFrac & RealFloat

-- Relational and equality operators

mkLt :: (Elem t, IsScalar t) => Exp t -> Exp t -> Exp Bool
mkLt x y = PrimLt scalarType `PrimApp` tup2 (x, y)

mkGt :: (Elem t, IsScalar t) => Exp t -> Exp t -> Exp Bool
mkGt x y = PrimGt scalarType `PrimApp` tup2 (x, y)

mkLtEq :: (Elem t, IsScalar t) => Exp t -> Exp t -> Exp Bool
mkLtEq x y = PrimLtEq scalarType `PrimApp` tup2 (x, y)

mkGtEq :: (Elem t, IsScalar t) => Exp t -> Exp t -> Exp Bool
mkGtEq x y = PrimGtEq scalarType `PrimApp` tup2 (x, y)

mkEq :: (Elem t, IsScalar t) => Exp t -> Exp t -> Exp Bool
mkEq x y = PrimEq scalarType `PrimApp` tup2 (x, y)

mkNEq :: (Elem t, IsScalar t) => Exp t -> Exp t -> Exp Bool
mkNEq x y = PrimNEq scalarType `PrimApp` tup2 (x, y)

mkMax :: (Elem t, IsScalar t) => Exp t -> Exp t -> Exp t
mkMax x y = PrimMax scalarType `PrimApp` tup2 (x, y)

mkMin :: (Elem t, IsScalar t) => Exp t -> Exp t -> Exp t
mkMin x y = PrimMin scalarType `PrimApp` tup2 (x, y)

-- Logical operators

mkLAnd :: Exp Bool -> Exp Bool -> Exp Bool
mkLAnd x y = PrimLAnd `PrimApp` tup2 (x, y)

mkLOr :: Exp Bool -> Exp Bool -> Exp Bool
mkLOr x y = PrimLOr `PrimApp` tup2 (x, y)

mkLNot :: Exp Bool -> Exp Bool
mkLNot x = PrimLNot `PrimApp` x

-- FIXME: Character conversions

-- FIXME: Numeric conversions

-- FIXME: Other conversions

mkBoolToInt :: Exp Bool -> Exp Int
mkBoolToInt b = PrimBoolToInt `PrimApp` b

mkIntFloat :: Exp Int -> Exp Float
mkIntFloat x = PrimIntFloat `PrimApp` x

mkRoundFloatInt :: Exp Float -> Exp Int
mkRoundFloatInt x = PrimRoundFloatInt `PrimApp` x

mkTruncFloatInt :: Exp Float -> Exp Int
mkTruncFloatInt x = PrimTruncFloatInt `PrimApp` x


-- Auxilliary functions
-- --------------------

infixr 0 $$
($$) :: (b -> a) -> (c -> d -> b) -> c -> d -> a
(f $$ g) x y = f $ (g x y)

infixr 0 $$$
($$$) :: (b -> a) -> (c -> d -> e -> b) -> c -> d -> e -> a
(f $$$ g) x y z = f $ (g x y z)

infixr 0 $$$$
($$$$) :: (b -> a) -> (c -> d -> e -> f -> b) -> c -> d -> e -> f -> a
(f $$$$ g) x y z u = f $ (g x y z u)

infixr 0 $$$$$
($$$$$) :: (b -> a) -> (c -> d -> e -> f -> g -> b) -> c -> d -> e -> f -> g-> a
(f $$$$$ g) x y z u v = f $ (g x y z u v)

