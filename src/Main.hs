--------------------------------------------------------------------------------
--
-- | Gomoku is a simple board game using haskell gloss library.
-- @
-- Release Notes:
-- For 0.1.0.0
--     Initial checkin, human to human.
--
--------------------------------------------------------------------------------
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}

import Prelude()
import ClassyPrelude
import Graphics.Gloss hiding (Vector)
import Graphics.Gloss.Interface.IO.Game hiding (Vector)
import qualified Data.Set
import Data.Tuple
import Data.Ratio
import Data.Maybe
import Data.List ((!!))
import Data.Set (fromList, delete)
import Control.Concurrent
import System.Random

type Dimension = (Int, Int)
type Pos = (Int, Int)

data Player = Human | AI deriving (Eq, Show)

data Message = Move Pos | Bug | Win | Lose | Tie | Start deriving (Eq, Show)

data Opponent = Opponent
    {
        stoneSet   :: Set Pos
    ,   stoneColor :: Color
    ,   players    :: Player
    } deriving (Show)

data Board = Board
    {
        opponent    :: (Opponent, Opponent)
    ,   totalMoves  :: Int
    ,   win         :: Set Pos
    ,   ch          :: (Maybe ([TChan Message]), Maybe ([TChan Message]))
    }

data Config = Config
    {
        gridSize     :: Int
    ,   dimension    :: Dimension
    ,   background   :: Color
    ,   stoneSize    :: Float
    ,   markSize     :: Float
    ,   pollInterval :: Int
    ,   winCondition :: Int
    ,   margin       :: Int
    ,   textScale    :: Float
    ,   delay        :: Int
    }

-- check x, y is within the board boundary.
withinBoard (dx, dy) (x, y) = x >= 0 && y >= 0 && x < dx && y < dy

-- maps f to a tuple.
mapTuple f = f *** f

walkDirection :: Set Pos -> Dimension -> Pos -> Pos -> Set Pos
walkDirection set dimension position (deltax, deltay) =
    let oneDirection position'@(x, y) inc =
         if withinBoard dimension position'
           && position' `member` set
            then position' `Data.Set.insert` oneDirection
                    (x + inc * deltax, y + inc * deltay) inc
            else mempty
    in (oneDirection position 1) <> (oneDirection position (-1))

isTie board =
    let d = dimension gameConfig in (fst d) * (snd d) <= totalMoves board

isWin board = not . null . win $ board

getGameEndMsg board | isWin board = (Lose, Win)
                    | isTie board = (Tie, Tie)
                    | otherwise   = (Bug, Bug)

--
-- checkWinCondition locations dimension move set-connected-to-the-move
-- A stone is connected to another if it's adjacent
-- either horizontally, vertially or diagnoally.
--
checkWinCondition :: Set Pos -> Dimension -> Pos -> Set Pos
checkWinCondition set dimension position =
    let dir :: [Pos]
        dir = [(1, 0), (0, 1), (1, 1), ((-1), 1)]
        walk = walkDirection set dimension position
    in  unions . filter ((==winCondition gameConfig) . length) . map walk $ dir

-- Declare picture as semigroup in order to use <>
instance Semigroup Picture

-- convinent function to applies offset and locate the board to the
-- center of screen
(shiftx, shifty) = mapTuple shiftFun $ dimension gameConfig where
    shiftFun = negate . fromIntegral . (* (gridSize gameConfig `div` 2))

-- Draw board and stones. First draws grid, then stones of white and black,
-- finally a small square for the group stones that are connected (winner
-- side).
draw :: Board -> IO Picture
draw board = return $ translate shiftx shifty pic where
    Config gs (boundaryX, boundaryY) _ ss mark _ _ margin ts _ = gameConfig

    pic = grid <> plays <> wins <> context <> gameInfo

    stone = thickCircle 1 ((fromIntegral gs) * ss)
    scaleGrid = map $ map $ mapTuple $ fromIntegral . (* gs)

    gx = scaleGrid [[(x, 0), (x, boundaryY)] | x <- [0 .. boundaryX]]
    gy = scaleGrid [[(0, y), (boundaryX, y)] | y <- [0 .. boundaryY]]
    gridfunc = mconcat . map (color black . line)
    grid = gridfunc gx <> gridfunc gy

    center = fromIntegral . (+ (gs `div` 2)) . (* gs)
    playsfunc location = mconcat
        [   translate (center mx) (center my) $
            color (stoneColor party) stone
        |   (mx, my) <- toList $ stoneSet party] where
        party = location $ opponent board
    plays = playsfunc fst <> playsfunc snd

    wins  = mconcat [   translate (center mx) (center my) $
                        color red
                        (rectangleSolid ((fromIntegral gs) * mark)
                                        ((fromIntegral gs) * mark))
                    |   (mx, my) <- toList $ win board ]

    d = dimension gameConfig
    contextX = fromIntegral $ gs * (fst d + 1) + margin
    contextY = fromIntegral $ gs * (snd d `div` 2)
    context = translate contextX contextY $
        color (stoneColor $ fst $ opponent board) stone

    m = show (totalMoves board) ++ "  " ++
        if isTie board || isWin board
            then show $ fst $ getGameEndMsg board
            else ""
    gameInfo = translate (contextX + fromIntegral gs) contextY $
                scale ts ts $ text m

nextState :: Board -> Pos -> IO (Board, Bool)
nextState board pos = do
    let Config gs' dimBoard _ ss mark _ _ _ _ _ = gameConfig
        stones   = stoneSet $ fst $ opponent board
        update = pos `Data.Set.insert` stones
        allstones = uncurry union $ mapTuple stoneSet $ opponent board
    if withinBoard dimBoard pos &&
       pos `Data.Set.notMember` allstones
        then return (board {
                totalMoves = totalMoves board + 1,
                opponent = swap ((fst $ opponent board)
                                    { stoneSet = update },
                                 (snd $ opponent board)),
                win  = checkWinCondition update dimBoard pos,
                ch   = swap $ ch board }, True)
        else return (board, False)

-- Capture left mouse button release event.
input :: Event -> Board -> IO Board
input _ board | not . null . win $ board = return board
input _ board | isTie board  = return board
input _ board | (players . fst . opponent $ board) == AI = return board
input (EventKey (MouseButton LeftButton) Up _ (mousex, mousey)) board = do
    let sc = fromIntegral $ gridSize gameConfig
        snap     = floor . (/ sc)
        -- pos@(x, y) is normalized position of the move.
        pos@(x, y) = (snap (mousex - shiftx), snap (mousey - shifty))
    (newBoard, legal) <- nextState board pos
    when legal $ do
        let msgch = snd $ ch board
        when (isJust msgch) $
            atomically $ writeTChan (headEx $ fromJust msgch) $ Move pos
    return newBoard
input _ board = return board

nextAIMove pos board = fst <$> nextState board pos

step :: Float -> Board -> IO Board
step _ board | (players . fst . opponent $ board) == Human = return board
step _ board = do
    let [chTx, chRx] = fromJust . fst . ch $ board
    maybeMsg <- atomically $ tryReadTChan chRx
    if not $ isJust maybeMsg
        then return board
        else stepUnblocked board (fromJust maybeMsg)

stepUnblocked :: Board -> Message -> IO Board
stepUnblocked board msg =
    let
        [chTx, chRx] = fromJust . fst . ch $ board
    in if isTie board || isWin board
        then
            do  (p', p'') <- return $ getGameEndMsg board
                atomically $ writeTChan chTx p'
                peer <- return $ snd $ ch board
                when (isJust peer) $
                    atomically $ writeTChan (headEx $ fromJust peer) p'' 
                return board
        else
            (threadDelay $ delay gameConfig) >>
            case msg of
            Move pos ->
                do  newBoard <- nextAIMove pos board
                    peer <- return $ fst $ ch newBoard
                    when (isWin newBoard || isTie newBoard) $
                        atomically $
                            writeTChan chTx (snd $ getGameEndMsg newBoard)
                    when (isJust peer) $
                        atomically $ writeTChan
                        (headEx . fromJust $ peer) msg
                    return newBoard
            _       -> return board

nextMove :: Set (Int, Int) -> IO (Int, Int)
nextMove legalMoves = do
    let l   = toList legalMoves
        len = length legalMoves
    idx <- randomRIO (0, len - 1) :: IO Int
    e   <- return $ l !!idx
    return e

runAI :: [TChan Message] -> Set (Int, Int) -> IO ()
runAI channels legalMoves = do
    let [chRx, chTx] = channels
        doMove ch moves = do
            p <- nextMove moves
            atomically $ writeTChan chTx $ Move p
            runAI ch $ delete p moves
    msg <- atomically $ readTChan chRx
    case msg of
        Start -> doMove channels legalMoves
        Move pos -> do
            lm <- return $ delete pos legalMoves
            doMove channels lm
        m -> do
            -- echo finishing condition back
            atomically $ writeTChan chTx m
            return ()

newTChanIOpair :: IO [TChan a]
newTChanIOpair = newTChanIO >>= \a -> newTChanIO >>= \b -> return [a, b]

makeChTbl :: [(Player, IO (Maybe [TChan a]))]
makeChTbl = [(Human, return Nothing), (AI, Just <$> newTChanIOpair)]

main :: IO ()
main = do
    let playmode = mapTuple players . opponent $ initialBoard
        ch =  mapTuple (fromJust . flip lookup makeChTbl) playmode

    -- create channels for AIs
    channels <- (uncurry $ liftM2 (,)) ch

    -- fork tasks for AIs
    let legalMoves = Data.Set.fromList [ (x, y) |
                                x <- [0 .. fst (dimension gameConfig) - 1],
                                y <- [0 .. snd (dimension gameConfig) - 1]]
        startIO :: Maybe [TChan Message] -> IO ()
        startIO maybech = case maybech of
                            Nothing-> return ()
                            Just c -> forkIO (runAI c legalMoves) >> return ()
    (startIO $ fst channels) >> (startIO $ snd channels)
    board <- return $ initialBoard {ch = channels }

    -- Sending message to jumpstart the first AI
    atomically $ mapM_ (\x -> writeTChan (headEx x) Start) $ fst channels
    
    let scaling = (* gridSize gameConfig)
    playIO (InWindow "GOMOKU" (1, 1) $
                mapTuple scaling $ dimension gameConfig)
           (background gameConfig)
           (pollInterval gameConfig)
           board draw input step

-- Initial configurations
initialBoard = Board
    {
        opponent  = (Opponent mempty black AI, Opponent mempty white AI)
    ,   totalMoves= 0
    ,   win       = mempty
    ,   ch        = (Nothing, Nothing)
    }

gameConfig = Config
    {
        dimension  = (15, 15)
    ,   gridSize   = 50
    ,   background = makeColor 0.86 0.71 0.52 0.50
    ,   stoneSize  = fromRational $ 4 % 5
    ,   markSize   = fromRational $ 1 % 6
    ,   pollInterval = 200
    ,   winCondition = 5 -- Win condition: 5 stones connected
    ,   margin     = 20
    ,   textScale  = 0.2
    ,   delay      = 500000
    }

