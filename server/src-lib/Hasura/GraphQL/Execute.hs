module Hasura.GraphQL.Execute
  ( GQExecPlan(..)

  , ExecPlanPartial
  , getExecPlanPartial

  , ExecOp(..)
  , ExecPlanResolved
  , getResolvedExecPlan
  , execRemoteGQ

  , EP.PlanCache
  , EP.initPlanCache
  , EP.clearPlanCache
  , EP.dumpPlanCache
  ) where

import           Control.Exception                      (try)
import           Control.Lens
import           Data.Has

import qualified Data.ByteString.Lazy                   as BL
import qualified Data.CaseInsensitive                   as CI
import qualified Data.HashMap.Strict                    as Map
import qualified Data.HashSet                           as Set
import qualified Data.String.Conversions                as CS
import qualified Data.Text                              as T
import qualified Language.GraphQL.Draft.Syntax          as G
import qualified Network.HTTP.Client                    as HTTP
import qualified Network.HTTP.Types                     as N
import qualified Network.Wreq                           as Wreq

import           Hasura.EncJSON
import           Hasura.GraphQL.Context
import           Hasura.GraphQL.Resolve.Context
import           Hasura.GraphQL.Schema
import           Hasura.GraphQL.Transport.HTTP.Protocol
import           Hasura.GraphQL.Validate.Types
import           Hasura.HTTP
import           Hasura.Prelude
import           Hasura.RQL.DDL.Headers
import           Hasura.RQL.Types

import qualified Hasura.GraphQL.Execute.LiveQuery       as EL
import qualified Hasura.GraphQL.Execute.Plan            as EP
import qualified Hasura.GraphQL.Execute.Query           as EQ

import qualified Hasura.GraphQL.Resolve                 as GR
import qualified Hasura.GraphQL.Validate                as VQ
import qualified Hasura.GraphQL.Validate.Types          as VT

-- The current execution plan of a graphql operation, it is
-- currently, either local pg execution or a remote execution
--
-- The 'a' is parameterised so this AST can represent
-- intermediate passes
data GQExecPlan a
  = GExPHasura !a
  | GExPRemote !RemoteSchemaInfo !G.TypedOperationDefinition
  deriving (Functor, Foldable, Traversable)

-- Enforces the current limitation
assertSameLocationNodes
  :: (MonadError QErr m) => [VT.TypeLoc] -> m VT.TypeLoc
assertSameLocationNodes typeLocs =
  case Set.toList (Set.fromList typeLocs) of
    -- this shouldn't happen
    []    -> return VT.HasuraType
    [loc] -> return loc
    _     -> throw400 NotSupported msg
  where
    msg = "cannot mix top level fields from two different graphql servers"

-- TODO: we should fix this function asap
-- as this will fail when there is a fragment at the top level
getTopLevelNodes :: G.TypedOperationDefinition -> [G.Name]
getTopLevelNodes opDef =
  mapMaybe f $ G._todSelectionSet opDef
  where
    f = \case
      G.SelectionField fld        -> Just $ G._fName fld
      G.SelectionFragmentSpread _ -> Nothing
      G.SelectionInlineFragment _ -> Nothing

gatherTypeLocs :: GCtx -> [G.Name] -> [VT.TypeLoc]
gatherTypeLocs gCtx nodes =
  catMaybes $ flip map nodes $ \node ->
    VT._fiLoc <$> Map.lookup node schemaNodes
  where
    schemaNodes =
      let qr = VT._otiFields $ _gQueryRoot gCtx
          mr = VT._otiFields <$> _gMutRoot gCtx
      in maybe qr (Map.union qr) mr

-- This is for when the graphql query is validated
type ExecPlanPartial
  = GQExecPlan (GCtx, VQ.RootSelSet, [G.VariableDefinition])

getExecPlanPartial
  :: (MonadError QErr m)
  => UserInfo
  -> SchemaCache
  -> GQLReqParsed
  -> m ExecPlanPartial
getExecPlanPartial userInfo sc req = do

  (gCtx, _)  <- flip runStateT sc $ getGCtx (userRole userInfo) gCtxRoleMap
  queryParts <- flip runReaderT gCtx $ VQ.getQueryParts req

  let opDef = VQ.qpOpDef queryParts
      topLevelNodes = getTopLevelNodes opDef
      -- gather TypeLoc of topLevelNodes
      typeLocs = gatherTypeLocs gCtx topLevelNodes

  -- see if they are all the same
  typeLoc <- assertSameLocationNodes typeLocs

  case typeLoc of
    VT.HasuraType -> do
      rootSelSet <- runReaderT (VQ.validateGQ queryParts) gCtx
      let varDefs = G._todVariableDefinitions $ VQ.qpOpDef queryParts
      return $ GExPHasura (gCtx, rootSelSet, varDefs)
    VT.RemoteType _ rsi ->
      return $ GExPRemote rsi opDef
  where
    gCtxRoleMap = scGCtxMap sc

-- An execution operation, in case of
-- queries and mutations it is just a transaction
-- to be executed
data ExecOp
  = ExOpQuery !LazyRespTx
  | ExOpMutation !LazyRespTx
  | ExOpSubs !EL.LiveQueryOp

-- The graphql query is resolved into an execution operation
type ExecPlanResolved
  = GQExecPlan ExecOp

getResolvedExecPlan
  :: (MonadError QErr m, MonadIO m)
  => PGExecCtx
  -> EP.PlanCache
  -> UserInfo
  -> SQLGenCtx
  -> SchemaCache
  -> SchemaCacheVer
  -> GQLReqUnparsed
  -> m ExecPlanResolved
getResolvedExecPlan pgExecCtx planCache userInfo sqlGenCtx
  sc scVer reqUnparsed = do
  planM <- liftIO $ EP.getPlan scVer (userRole userInfo)
           opNameM queryStr planCache
  let usrVars = userVars userInfo
  case planM of
    -- plans are only for queries and subscriptions
    Just plan -> GExPHasura <$> case plan of
      EP.RPQuery queryPlan ->
        ExOpQuery <$> EQ.queryOpFromPlan usrVars queryVars queryPlan
      EP.RPSubs subsPlan ->
        ExOpSubs <$> EL.subsOpFromPlan pgExecCtx queryVars subsPlan
    Nothing -> noExistingPlan
  where
    GQLReq opNameM queryStr queryVars = reqUnparsed
    addPlanToCache plan =
      liftIO $ EP.addPlan scVer (userRole userInfo)
      opNameM queryStr plan planCache
    noExistingPlan = do
      req      <- toParsed reqUnparsed
      partialExecPlan <- getExecPlanPartial userInfo sc req
      forM partialExecPlan $ \(gCtx, rootSelSet, varDefs) ->
        case rootSelSet of
          VQ.RMutation selSet ->
            ExOpMutation <$> getMutOp gCtx sqlGenCtx userInfo selSet
          VQ.RQuery selSet -> do
            (queryTx, planM) <- getQueryOp gCtx sqlGenCtx
                                userInfo selSet varDefs
            mapM_ (addPlanToCache . EP.RPQuery) planM
            return $ ExOpQuery queryTx
          VQ.RSubscription fld -> do
            (lqOp, planM) <- getSubsOp pgExecCtx gCtx sqlGenCtx
                             userInfo reqUnparsed varDefs fld
            mapM_ (addPlanToCache . EP.RPSubs) planM
            return $ ExOpSubs lqOp

-- Monad for resolving a hasura query/mutation
type E m =
  ReaderT ( UserInfo
          , OpCtxMap
          , TypeMap
          , FieldMap
          , OrdByCtx
          , InsCtxMap
          , SQLGenCtx
          ) (ExceptT QErr m)

runE
  :: (MonadError QErr m)
  => GCtx
  -> SQLGenCtx
  -> UserInfo
  -> E m a
  -> m a
runE ctx sqlGenCtx userInfo action = do
  res <- runExceptT $ runReaderT action
    (userInfo, opCtxMap, typeMap, fldMap, ordByCtx, insCtxMap, sqlGenCtx)
  either throwError return res
  where
    opCtxMap = _gOpCtxMap ctx
    typeMap = _gTypes ctx
    fldMap = _gFields ctx
    ordByCtx = _gOrdByCtx ctx
    insCtxMap = _gInsCtxMap ctx

getQueryOp
  :: (MonadError QErr m)
  => GCtx
  -> SQLGenCtx
  -> UserInfo
  -> VQ.SelSet
  -> [G.VariableDefinition]
  -> m (LazyRespTx, Maybe EQ.ReusableQueryPlan)
getQueryOp gCtx sqlGenCtx userInfo fields varDefs =
  runE gCtx sqlGenCtx userInfo $ EQ.convertQuerySelSet varDefs fields

mutationRootName :: Text
mutationRootName = "mutation_root"

resolveMutSelSet
  :: ( MonadError QErr m
     , MonadReader r m
     , Has UserInfo r
     , Has OpCtxMap r
     , Has FieldMap r
     , Has OrdByCtx r
     , Has SQLGenCtx r
     , Has InsCtxMap r
     )
  => VQ.SelSet
  -> m LazyRespTx
resolveMutSelSet fields = do
  aliasedTxs <- forM (toList fields) $ \fld -> do
    fldRespTx <- case VQ._fName fld of
      "__typename" -> return $ return $ encJFromJValue mutationRootName
      _            -> liftTx <$> GR.mutFldToTx fld
    return (G.unName $ G.unAlias $ VQ._fAlias fld, fldRespTx)

  -- combines all transactions into a single transaction
  return $ toSingleTx aliasedTxs
  where
    -- A list of aliased transactions for eg
    -- [("f1", Tx r1), ("f2", Tx r2)]
    -- are converted into a single transaction as follows
    -- Tx {"f1": r1, "f2": r2}
    toSingleTx :: [(Text, LazyRespTx)] -> LazyRespTx
    toSingleTx aliasedTxs =
      fmap encJFromAssocList $
      forM aliasedTxs $ \(al, tx) -> (,) al <$> tx

getMutOp
  :: (MonadError QErr m)
  => GCtx
  -> SQLGenCtx
  -> UserInfo
  -> VQ.SelSet
  -> m LazyRespTx
getMutOp ctx sqlGenCtx userInfo selSet =
  runE ctx sqlGenCtx userInfo $ resolveMutSelSet selSet

getSubsOpM
  :: ( MonadError QErr m
     , MonadReader r m
     , Has OpCtxMap r
     , Has FieldMap r
     , Has OrdByCtx r
     , Has SQLGenCtx r
     , Has UserInfo r
     , MonadIO m
     )
  => PGExecCtx
  -> GQLReqUnparsed
  -> [G.VariableDefinition]
  -> VQ.Field
  -> m (EL.LiveQueryOp, Maybe EL.SubsPlan)
getSubsOpM pgExecCtx req varDefs fld =
  case VQ._fName fld of
    "__typename" ->
      throwVE "you cannot create a subscription on '__typename' field"
    _            -> do
      astUnresolved <- GR.queryFldToPGAST fld
      EL.subsOpFromPGAST pgExecCtx req varDefs (VQ._fAlias fld, astUnresolved)

getSubsOp
  :: ( MonadError QErr m
     , MonadIO m
     )
  => PGExecCtx
  -> GCtx
  -> SQLGenCtx
  -> UserInfo
  -> GQLReqUnparsed
  -> [G.VariableDefinition]
  -> VQ.Field
  -> m (EL.LiveQueryOp, Maybe EL.SubsPlan)
getSubsOp pgExecCtx gCtx sqlGenCtx userInfo req varDefs fld =
  runE gCtx sqlGenCtx userInfo $ getSubsOpM pgExecCtx req varDefs fld

execRemoteGQ
  :: (MonadIO m, MonadError QErr m)
  => HTTP.Manager
  -> UserInfo
  -> [N.Header]
  -> BL.ByteString
  -- ^ the raw request string
  -> RemoteSchemaInfo
  -> G.TypedOperationDefinition
  -> m EncJSON
execRemoteGQ manager userInfo reqHdrs q rsi opDef = do
  let opTy = G._todType opDef
  when (opTy == G.OperationTypeSubscription) $
    throw400 NotSupported "subscription to remote server is not supported"
  hdrs <- getHeadersFromConf hdrConf
  let confHdrs   = map (\(k, v) -> (CI.mk $ CS.cs k, CS.cs v)) hdrs
      clientHdrs = bool [] filteredHeaders fwdClientHdrs
      options    = wreqOptions manager (userInfoToHdrs ++ clientHdrs ++ confHdrs)

  res  <- liftIO $ try $ Wreq.postWith options (show url) q
  resp <- either httpThrow return res
  return $ encJFromLBS $ resp ^. Wreq.responseBody

  where
    RemoteSchemaInfo url hdrConf fwdClientHdrs = rsi
    httpThrow :: (MonadError QErr m) => HTTP.HttpException -> m a
    httpThrow err = throw500 $ T.pack . show $ err

    userInfoToHdrs = map (\(k, v) -> (CI.mk $ CS.cs k, CS.cs v)) $
                 userInfoToList userInfo
    filteredHeaders = flip filter reqHdrs $ \(n, _) ->
      n `notElem` [ "Content-Length", "Content-MD5", "User-Agent", "Host"
                  , "Origin", "Referer" , "Accept", "Accept-Encoding"
                  , "Accept-Language", "Accept-Datetime"
                  , "Cache-Control", "Connection", "DNT"
                  ]
