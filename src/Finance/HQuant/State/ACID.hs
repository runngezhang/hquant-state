{-# LANGUAGE TemplateHaskell, DeriveDataTypeable, TypeFamilies, RankNTypes, OverloadedStrings, NamedFieldPuns, TupleSections, DoAndIfThenElse #-}
-- | This module provides the base ACID state storage layer.
--
module Finance.HQuant.State.ACID where

import Prelude hiding (minimum, maximum, foldr, foldl, all)

import Finance.HQuant.State.Types
import Finance.HQuant.State.Config
import Finance.HQuant.State.Aggregations

import qualified Control.Exception as E
import Control.Applicative
import Control.Comonad
import Control.Lens hiding ((|>))
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Identity
import Control.Monad.Error

import qualified Data.Sequence as Seq
import qualified Data.Array as A
import qualified Data.Map as M
import qualified Data.Text as T
import Data.Acid
import Data.Acid.Memory
import Data.Acid.Remote
import Data.List (intercalate)
import Data.Sequence (Seq, (|>), viewl, viewr, ViewL(..), ViewR(..))
import Data.Map (Map)
import Data.Array (Array, listArray, (!))
import Data.ByteString (ByteString)
import Data.Int
import Data.Typeable
import Data.Either
import Data.Time.Clock
import Data.SafeCopy
import Data.Maybe
import Data.Foldable

import Debug.Trace

import Network

data Series      = Series
                   { _declaration    :: [FieldDeclaration] -- ^ Descriptions of the columns
                   , _times          :: Seq UTCTime
                   , _seriesData     :: Array Int (SeriesSeq Seq) }

data HQuantState = HQuantState
                   { _declarations   :: [SeriesDeclaration]
                   , _series         :: Map SeriesName Series
                   , _actionsLastRun :: Map (SchedulableAction SeriesName) UTCTime }
                   deriving (Typeable)

makeLenses ''HQuantState
makeLenses ''Series

deriveSafeCopy 0 'base ''HQuantState
deriveSafeCopy 0 'base ''Series

runError = runIdentity . runErrorT

findAgg :: AggregationName -> [SeriesDeclaration] -> Maybe SeriesDeclaration
findAgg name declarations = findAgg' declarations
    where findAgg' [] = Nothing
          findAgg' (a@AggregationDecl {_aggName}:_)
              | _aggName == name = Just a
          findAgg' (_:xs) = findAgg' xs

findDecl :: SeriesName -> [SeriesDeclaration] -> Maybe SeriesDeclaration
findDecl _ []                                = Nothing
findDecl name (t@(TimeSeriesDecl {}):series)
    | name `matchesPattern` (_tsdNamePattern t) = Just t
findDecl name (_:series)                        = findDecl name series

timeSeriesDeclarations :: Query HQuantState [SeriesDeclaration]
timeSeriesDeclarations = _declarations <$> ask

-- | Given a series name and the declarations. Computes the names of all aggregations that apply.
--
--   For example, if there are aggregations "stockInfo1Day" and "stockInfo15Min" that apply to all
--   "/trades/" series, then if we pass in "/trades/MSFT", we get "stockInfo1Day:/trades/MSFT" and
--   "stockInfo15Min:/trades/MSFT".
computeAggs :: SeriesName -> [SeriesDeclaration] -> [SeriesName]
computeAggs _    []     = []
computeAggs name (d:ds) = case d of
                            TimeSeriesDecl {} -> computeAggs name ds
                            AggregationDecl {}
                                | name `matchesPattern` (_aggTarget d) ->
                                    aggSeriesName (_aggName d) name : computeAggs name ds
                                | otherwise                            ->
                                    computeAggs name ds

-- | Create the time series with the given name, including possibly creating any aggregations that
--   apply to the series.
newTimeSeries :: SeriesName -> Update HQuantState (Either String ())
newTimeSeries seriesName
    | not (validSeriesName . unSeriesName $  seriesName) = return (Left "Series names must start with '/' or be of the form '<aggregation>:<series>'")
    | otherwise = do
        decl <- case aggregationAndTargetOf seriesName of
                  Nothing                -> maybe (Left "Series not configured") (Right . _schemaDFields . _tsdSchema) <$>
                                            uses declarations (findDecl seriesName)
                  Just (aggName, target) -> do
                    aggDecl <- uses declarations (findAgg aggName)
                    case aggDecl of
                      Nothing  -> return (Left "Aggregation not found")
                      Just agg -> if aggregationApplies (_aggTarget agg) target
                                  then do
                                    -- If this aggregation works, then we need to find it's target and attempt
                                    st <- get
                                    let tsdDecl = maybe (Left "Aggregation target series not found") Right $
                                                  (st ^. series ^. at target)
                                    case tsdDecl of
                                      Left e -> return (Left e)
                                      Right tsdDecl ->
                                          -- This will derive the types of the aggregation schema fields based on those of
                                          -- the time series.
                                          case deriveAggSchema (_aggSchema agg) (_declaration tsdDecl) of
                                            Left  err       -> return (Left err)
                                            Right aggSchema -> return (Right aggSchema)
                                  else return (Left $ "Aggregation '" ++ (T.unpack . unSeriesName $ aggName) ++ "' does not apply to series '" ++ (T.unpack . unSeriesName $ target) ++ "'")
        case decl of
          Left e -> return (Left e)
          Right decl -> do
              existingDecl <- M.lookup seriesName <$> gets _series
              case existingDecl of
                Just _  -> return (Left "Series already exists")
                Nothing -> do
                    let newSeries = Series
                                    { _declaration = decl
                                    , _times       = Seq.empty
                                    , _seriesData  = listArray (0, length decl - 1) $
                                                     map mkSeq decl }
                        mkSeq (FieldDeclaration _ (Fixed _ decimals)) = FixedSeq   (10 ^ decimals) Seq.empty
                        mkSeq (FieldDeclaration _ Integer)            = IntegerSeq                 Seq.empty
                        mkSeq (FieldDeclaration _ String)             = StringSeq                  Seq.empty

                    series.at seriesName .= Just newSeries -- Add the series in so that newTimeSeries can find the target
                    return (Right ())
    where validSeriesName seriesName = case T.split (== ':') seriesName of
                                         [aggregation, seriesName] -> validSeriesNameNoAgg seriesName
                                         [seriesName]              -> validSeriesNameNoAgg seriesName
                                         _                         -> False
          validSeriesNameNoAgg seriesName = "/" `T.isPrefixOf` seriesName

          aggregationAndTargetOf seriesName = case T.split (== ':') (unSeriesName seriesName) of
                                                [aggNameT, seriesNameT] -> Just (SeriesName aggNameT, SeriesName seriesNameT)
                                                _                       -> Nothing

deleteTimeSeries :: SeriesName -> Update HQuantState ()
deleteTimeSeries seriesName = do
  series.at seriesName .= Nothing

listTimeSeries :: Query HQuantState [SeriesName]
listTimeSeries = do
  st <- ask
  return (M.keys (_series st))

timeSeriesDatum :: SeriesName -> UTCTime -> [Datum] -> Update HQuantState (Either String ())
timeSeriesDatum seriesName time dat = do
  st <- get
  case st ^. series ^. at seriesName of
    Nothing -> case aggAndSeriesFromName seriesName of
                 Nothing            -> return (Left $ "Unknown series: " ++ (T.unpack . unSeriesName $ seriesName))
                 Just (agg, series) -> do
                   -- This is an aggregation, so we may want to try creating the aggregation
                   result <- newTimeSeries seriesName
                   case result of
                     Left err -> return (Left $ "Couldn't create aggregation: " ++ err)
                     Right () -> timeSeriesDatum seriesName time dat -- Now that we've created the aggregation, we can continue
    Just newSeries
        | length (_declaration newSeries) /= length dat ->
            return (Left "Bad data length")
        | otherwise -> do
           let updateSeq (FixedD i) (FixedSeq e s) = return $ FixedSeq e (s |> i)
               updateSeq (StringD t) (StringSeq s) = return $ StringSeq (s |> t)
               updateSeq (IntegerD i) (IntegerSeq s) = return $ IntegerSeq (s |> i)
               updateSeq _ _ = throwError "Type mismatch"

               seriesData' = runError $ mapM (uncurry updateSeq) (zip dat (A.elems . _seriesData $ newSeries))
           case seriesData' of
             Left s            -> return (Left s)
             Right seriesData' -> do
                         let newSeries' = newSeries
                                          { _times      = (newSeries ^. times) |> time
                                          , _seriesData = _seriesData newSeries A.// zip [0..] seriesData' }
                         series.at seriesName .= Just newSeries'
                         return (Right ())

timeSeriesQuery :: SeriesName -> UTCTime -> UTCTime -> Query HQuantState (Either String (Seq UTCTime, [SeriesSeqWrapper]))
timeSeriesQuery seriesName from to = do
  st <- ask
  case st ^. series ^. at seriesName of
    Nothing -> return (Left "Couldn't find series by that name")
    Just series -> do
      let (indices, times) = unzip $
                             filter (\(_, t) -> t >= from && t < to) (zip [0..] (toList . _times $ series))
          (startI, endI) = (minimum indices, maximum indices)
          transformSeq :: Seq a -> Seq a
          transformSeq = Seq.take (endI - startI + 1) . Seq.drop startI
      case indices of
        [] -> return (Right (Seq.empty, map (WrapSeries . adjustSeq (const Seq.empty)) (A.elems . _seriesData $ series)))
        _ -> return (Right (Seq.fromList times, map (WrapSeries . adjustSeq transformSeq) (A.elems . _seriesData $ series)))

deleteData :: SeriesName -> UTCTime -> UTCTime -> Update HQuantState (Either String ())
deleteData seriesName from to = do
  st <- get
  case st ^. series ^. at seriesName of
    Nothing     -> return (Left $ "Unknown series: " ++ (T.unpack . unSeriesName $ seriesName))
    Just series_ -> do
      let timesList   = toList (series_ ^. times)
          toBeRemoved = map fst $ filter (\(_, t) -> t >= from && t < to) (zip [0..] timesList)
          (startI, endI) = (minimum toBeRemoved, maximum toBeRemoved)

          spliceSeq :: Seq a -> Seq a
          spliceSeq s = let (start, rest) = Seq.splitAt startI s
                            (_, end)      = Seq.splitAt (endI - startI) rest
                        in start Seq.>< end

          newSeries = map (adjustSeq spliceSeq) (A.elems (_seriesData series_))
          newSeriesData = (_seriesData series_) A.// zip [0..] newSeries
      case toBeRemoved of
        [] -> return (Right ())
        _ -> do
          series . at seriesName .= Just (series_ { _seriesData = newSeriesData, _times = spliceSeq (_times series_) })
          return (Right ())

aggregate :: AggregationName -> SeriesName -> UTCTime -> UTCTime -> Query HQuantState (Either String (Seq UTCTime, [SeriesSeqWrapper]))
aggregate aggName seriesName startingAt endingAt = do
    st <- ask
    case findAgg aggName (_declarations st) of
      Nothing  -> return (Left "No aggregation found with that name")
      Just agg -> do
        case st ^. series ^. at seriesName of
          Nothing -> return (Left "Target series with that name not found")
          Just series -> do
              let periodStartingTimes = takeWhile (< endingAt) (iterate (addDuration (_aggPeriod agg)) startingAt)

                  -- This is now a list of [(UTCTime, UTCTime)] representing the intervals which will be grouped together
                  periods = zip periodStartingTimes (tail periodStartingTimes ++ [endingAt])

                  timesSeq = Seq.fromList periodStartingTimes

                  -- This groups our column data into groups representing each period
                  groupIntoPeriods :: [(UTCTime, UTCTime)] -> Seq (UTCTime, a) -> Seq (Seq a)
                  groupIntoPeriods [] _ = Seq.empty
                  groupIntoPeriods ((start, end):times) sq = let sq' = Seq.dropWhileL ((< start) . fst) sq
                                                                 (group, rest) = Seq.spanl ((< end) . fst) sq'
                                                             in fmap snd group <|
                                                                groupIntoPeriods times rest

                  fieldNames         = map _fieldDName (_declaration series)
                  groupedIntoPeriods = zip fieldNames $
                                       map (adjustSeq (DoubleSeq . groupIntoPeriods periods . Seq.zip (_times series))) (A.elems (_seriesData series))

                  -- This runs the aggregation
                  aggregated = mapM (runAggregation timesSeq groupedIntoPeriods) (_aggSchemaFields . _aggSchema $ agg)

                  aggSchemaFields = _aggSchemaFields . _aggSchema $ agg
                  aggFieldNames = map _aggFieldName aggSchemaFields

                  missingMethodIndices = case sequence (map (flip missingMethodFieldsToIndex aggFieldNames . _aggFieldMissingMethod) aggSchemaFields) of
                                           Just x  -> Right x
                                           Nothing -> Left "Could not find field references in missing method"

                  filledIn :: Either String [SeriesSeq MaybeSeq]
                  filledIn = do
                              emptySeqs <- map (adjustSeq (MaybeSeq . const Seq.empty)) <$> aggregated
                              transposedSeries <- unfoldSeries <$> aggregated
                              doAppend <- appendCalculatingMissing <$> missingMethodIndices
                              foldlM doAppend emptySeqs transposedSeries

                  timeSeqs   = map (adjustSeq' validTimes) <$> filledIn
                  filledIn' :: Either String [SeriesSeq Seq]
                  filledIn'  = map (adjustSeq (fmap fromJust . Seq.filter isJust . unMaybeSeq)) <$> filledIn

                  validTimes :: MaybeSeq a -> Seq UTCTime
                  validTimes x = fmap fst $ Seq.filter (isJust . snd ) $ Seq.zip timesSeq (unMaybeSeq x)

                  removeJusts = adjustSeq (fmap fromJust . unMaybeSeq)

                  timesSeq'  = foldr combineTimes timesSeq <$> timeSeqs
                  selected = do
                              doSelectTimes <- selectTimes <$> timesSeq'
                              timesAndColumns <- zip <$> timeSeqs <*> filledIn'
                              return (map (uncurry doSelectTimes) timesAndColumns)
                  aggregated' = map WrapSeries <$> selected
              return ((,) <$> timesSeq' <*> aggregated')

whenLastRun :: SchedulableAction SeriesName -> Query HQuantState (Either String UTCTime)
whenLastRun act = do
  st <- ask
  case M.lookup act (_actionsLastRun st) of
    Nothing -> return (Left $ "Action " ++ show act ++ " never ran")
    Just at -> return (Right at)

updateLastRunTime :: SchedulableAction SeriesName -> UTCTime -> Update HQuantState ()
updateLastRunTime act lastRunTime = do
  actionsLastRun.at act .= Just lastRunTime

makeAcidic ''HQuantState [ 'newTimeSeries, 'deleteTimeSeries, 'timeSeriesDatum, 'timeSeriesQuery
                         , 'deleteData
                         , 'aggregate, 'listTimeSeries, 'whenLastRun, 'updateLastRunTime
                         , 'timeSeriesDeclarations ]

-- * Load functions

loadHQuantState :: FilePath -> FilePath -> IO (AcidState HQuantState)
loadHQuantState configFile statePath = do
  r <- readConfigFile configFile
  case r of
    Left e -> fail ("Error parsing config file: " ++ show e)
    Right r -> openLocalStateFrom statePath (HQuantState { _declarations   = r
                                                         , _series         = M.empty
                                                         , _actionsLastRun = M.empty})

openRemoteHQuantState :: Maybe ByteString -> HostName -> PortID -> IO (AcidState HQuantState)
openRemoteHQuantState secret host port =
    let checkSecret = case secret of
                        Nothing -> skipAuthenticationPerform
                        Just s  -> sharedSecretPerform s
    in openRemoteState checkSecret host port

loadHQuantStateMem :: FilePath -> IO (AcidState HQuantState)
loadHQuantStateMem configFile = do
  r <- readConfigFile configFile
  case r of
    Left e -> fail ("Error parsing config file: " ++ show e)
    Right r -> openMemoryState (HQuantState { _declarations   = r
                                            , _series         = M.empty
                                            , _actionsLastRun = M.empty})

test = loadHQuantStateMem "config.example" >>= \st ->
       (flip E.finally) (closeAcidState st) $
       do
         let th3n  = read "2014-02-13 00:00:00"
             th3n1 = read "2014-02-13 00:01:00"
             th3n2 = read "2014-02-13 00:01:30"
             th3n3 = read "2014-02-13 00:04:00"
         now <- getCurrentTime
         update st (NewTimeSeries "/trades/MSFT")
         update st (TimeSeriesDatum "/trades/MSFT" th3n   [FixedD 4500000, IntegerD 55])
         update st (TimeSeriesDatum "/trades/MSFT" th3n1  [FixedD 4200000, IntegerD 54])
         update st (TimeSeriesDatum "/trades/MSFT" th3n2  [FixedD 4900000, IntegerD 20])
         update st (TimeSeriesDatum "/trades/MSFT" th3n3  [FixedD 4890000, IntegerD 10])
         r <- query st (TimeSeriesQuery "/trades/MSFT" th3n now)
         (putStrLn . show $ r )
         r <- query st (Aggregate "stockInfo" "/trades/MSFT" th3n now)
         (putStrLn . show $ r )
