{-# LANGUAGE GADTs, RecordWildCards, NamedFieldPuns, TemplateHaskell #-}

module NoExit where

import Data.List
import Data.Maybe

import Test.QuickCheck
import Debug.Trace

------------------
-- Introduction --
------------------

-- GADTs

data Pair a where
  Pair :: a -> a -> Pair a

-- But what if I make a typo?

data Pear a where
  Pear :: a -> b -> Pear a

-- Huh! That type-checked...?

-- Uncomment me and find out what happens!
-- pare (Pear a b) = (a, b)  -- doesn't compile

halfPare :: Pear a -> a
halfPare (Pear a _) = a  -- works just fine

-- The forall-exists duality!

-------------------------------
-- Some syntactic extensions --
-------------------------------

data ThreeInts where
  ThreeInts :: { first  :: Integer
               , second :: Integer
               , third  :: Integer } -> ThreeInts

makeThirdSum, makeThirdSum',
  makeThirdSum'', makeThirdSum'''
  :: ThreeInts -> ThreeInts

-- No special syntax sugar: very verbose!
makeThirdSum ThreeInts{first = first, second = second, third = third} =
  ThreeInts { first  = first
            , second = second
            , third  = first + second + third }

-- With NamedFieldPuns:
makeThirdSum' ThreeInts{first, second, third} =
  ThreeInts { first
            , second
            , third = first + second + third }

-- With NamedFieldPuns and RecordWildCards:
makeThirdSum'' ThreeInts{..} =
  ThreeInts { first
            , second
            , third = first + second + third }

-- We can even use a record wildcard when *constructing* a record:
makeThirdSum''' ThreeInts{..} =
  ThreeInts { third = first + second + third, .. }

------------------------------------------
-- Existential types are abstract types --
------------------------------------------

-- An existential type for a queue "object"
data Queue a where
  Queue :: { _enqueue :: a -> q -> q
           , _dequeue :: q -> Maybe (a, q)
           , _insides :: q
           } -> Queue a

-- A very simple queue with O(n) enqueue and O(1) dequeue
-- This is useful as a reference implementation
slowQueue :: Queue a
slowQueue = Queue tack uncons []
  where
    tack x xs = xs ++ [x]

enqueue :: a -> Queue a -> Queue a
enqueue a Queue{..} =
  Queue { _insides = _enqueue a _insides, .. }

dequeue :: Queue a -> Maybe (a, Queue a)
dequeue Queue{..} =
  case _dequeue _insides of
    Nothing -> Nothing
    Just (a, rest) ->
      Just (a, Queue { _insides = rest, .. })

queueToList :: Queue a -> [a]
queueToList = unfoldr dequeue

enqueueAll :: Queue a -> [a] -> Queue a
enqueueAll = foldl (flip enqueue)

prop_queueToList_enqueueAll_id :: [Integer] -> Bool
prop_queueToList_enqueueAll_id xs =
  xs == queueToList (enqueueAll slowQueue xs)

-- But before we go on to make faster queues...

---------------------------------------------------
-- Testing queue implementations for correctness --
---------------------------------------------------

-- An operation on a queue
data QueueOp a where
  Enqueue :: a -> QueueOp a
  Dequeue :: QueueOp a
  deriving (Eq, Ord, Show)

-- How to make arbitrary operations
instance Arbitrary a => Arbitrary (QueueOp a) where
  arbitrary = do
    coin <- arbitrary
    if coin
      then return Dequeue
      else Enqueue <$> arbitrary

  -- When we *shrink* a value, we produce a list ofconceptually /smaller/
  -- versions of that value that we hope still falsify a given test.
  shrink (Enqueue a) = [Enqueue a' | a' <- shrink a]
  shrink Dequeue     = []

-- Run a bunch of queue operations on a queue; hand back the results & the queue
runQueueOps :: Queue a -> [QueueOp a] -> (Queue a, [Maybe a])
runQueueOps queue0 =
  fmap catMaybes . mapAccumL runOp queue0
  where
    runOp queue op =
      case op of
        Dequeue -> case dequeue queue of
          Nothing          -> (queue,  Just Nothing)
          Just (a, queue') -> (queue', Just (Just a))
        Enqueue a -> (enqueue a queue, Nothing)

-- A higher order property stating *observational equivalence* for two queues
-- That is, for all sequences of operations, they return the same results
compareQueues :: Eq a => Queue a -> Queue a -> [QueueOp a] -> Property
compareQueues q1 q2 ops =
  queueToList q1 == queueToList q2
                 ==>
        results1 == results2
  where
    (_, results1) = runQueueOps q1 ops
    (_, results2) = runQueueOps q2 ops

-- Making sure our tests mean something: compare a bad queue to our spec
badQueue :: Queue a
badQueue = Queue (:) uncons []

-- This property fails: can you guess why?
-- This is also a good example of the utility of QuickCheck's *shrinking*:
-- we see in the results a minimal distinguishing sequence of operations.
prop_slowQueue_vs_badQueue :: [QueueOp Integer] -> Property
prop_slowQueue_vs_badQueue =
  expectFailure . compareQueues slowQueue badQueue

---------------------------
-- Other implementations --
---------------------------

-- A queue with non-persistent amortized O(1) performance

-- We enqueue into the "back" list and dequeue from the "front" list
-- When we run out of elements in the "front" list, we reverse the "back"
-- list and set it to be the "front" list. But this only happens once
-- every O(n) operations, and since it only takes O(n) time, the amortized
-- performance of the queue is O(1).
twoListQueue :: Queue a
twoListQueue =
  Queue { _insides = ([], [])
        , _enqueue = \a (front, back) -> (front, a : back)  -- enqueue into back
        , _dequeue = \(front, back) ->
                       case (front, back) of
                         ([], []) -> Nothing    -- queue empty if both lists are
                         (a : front', _) ->
                           Just (a, (front', back))  -- dequeue from front,
                         ([], _)  ->                 -- or if front is empty,
                           let (a : front') = reverse back in  -- reverse back
                           Just (a, (front', [])) }            -- & set as front

prop_twoListQueue_spec :: [QueueOp Integer] -> Property
prop_twoListQueue_spec = compareQueues slowQueue twoListQueue

-- A queue with persistent worst-case O(1) performance
-- Chris Okasaki: "Simple and Efficient Purely Functional Queues and Deques"
-- J. Functional Programming 5(4): 583–592, October 1995

-- The trick: instead of reversing the "back" list all at once, we reverse it
-- one step every operation, so that when we need it reversed, we've already
-- done it!
okasakiQueue :: Queue a
okasakiQueue =
  Queue { _insides = ([], [], [])
        , _enqueue = \e (fs, bs, as) ->
                       makeEq (fs, e : bs, as)
        , _dequeue = \(fs, bs, as) ->
                       case fs of
                         [] -> Nothing
                         (e : es) ->
                           Just (e, makeEq (es, bs, as)) }
  where
    -- makeEq (fs bs as) preserves invariant: |fs| - |bs| = |as|
    -- ... since it's called exactly when |fs| decreases or |bs| increases
    makeEq (fs, bs, _ : as') = (fs, bs, as')
    makeEq (fs, bs, []) =
      let fs' = appendReverse fs bs
      in (fs', [], fs')

-- Maximally lazy computation of: xs ++ reverse ys
appendReverse :: [a] -> [a] -> [a]
appendReverse xs ys =
  rot xs ys []
  where
    rot :: [a] -> [a] -> [a] -> [a]
    rot      []       []  as =                    as
    rot      []  (b : bs) as =     rot [] bs (b : as)
    rot (f : fs)      []  as = f : rot fs []      as
    rot (f : fs) (b : bs) as = f : rot fs bs (b : as)

prop_appendReverse_correct :: [Integer] -> [Integer] -> Bool
prop_appendReverse_correct fs bs =
  appendReverse fs bs == fs ++ reverse bs

prop_okasakiQueue_spec :: [QueueOp Integer] -> Property
prop_okasakiQueue_spec = compareQueues slowQueue okasakiQueue

------------------------------------------------------
-- An aside: observing the lazy evaluation of lists --
------------------------------------------------------

-- So why does this work? How is it that using appendReverse like this
-- gives us an O(1) persistent worst-case guarantee?

-- trace :: String -> [a] -> [a]

-- Instrument a list to see how it gets evaluated
instrument :: String -> [a] -> [a]
instrument s =
  foldr cons nil
  where
    cons a as = trace (s ++ " :")  (a : as)
    nil       = trace (s ++ " []") []

-- Force the first n cons-cells in a list
observe :: Int -> [a] -> IO ()
observe 0      _   = return ()
observe _      []  = return ()
observe n (_ : as) = observe (n - 1) as

-- Below are two different ways of computing [1,2,3] ++ reverse [4,5,6]
-- Try playing around with 'observe' to see what's happening.

listA, listB :: [Integer]
listA = [1,2,3]
listB = [4,5,6]

lazyEnough :: () -> [Integer]
lazyEnough () =
  appendReverse (instrument "A" listA) (instrument "B" listB)

tooStrict :: () -> [Integer]
tooStrict () =
  instrument "A" listA ++ reverse (instrument "B" listB)

-- Another thought exercise: why do we make 'lazyEnough' and 'tooStrict'
-- functions from () -> Integer? What would happen if we didn't have that
-- argument of ()?

--------------------------------------------------------------------
-- Modifying the implementation of an existing object, abstractly --
--------------------------------------------------------------------

-- Drops every other enqueue operation
everyOther :: Queue a -> Queue a
everyOther Queue{..} =
  Queue { _insides = (True,     -- flag to tell us whether to accept an enqueue
                      _insides) -- insides of the queue we're wrapping (opaque)
        , _enqueue = \a (b, q) ->
                       if b then (not b, _enqueue a q)  -- enqueue iff flag True
                            else (not b, q)             -- flip flag regardless
        , _dequeue = \(b, q) ->
                       case _dequeue q of
                         Just (a, rest) ->
                           Just (a, (not b, rest))  -- flip the flag on dequeue
                         Nothing -> Nothing }

-- Enqueues twice anything you tell it to enqueue
-- That is to say, we call the enqueue "method" of the wrapped queue twice
doubleEnqueue :: Queue a -> Queue a
doubleEnqueue Queue{..} =
  Queue { _enqueue = \a -> _enqueue a . _enqueue a, .. }

-- Claim: doublePush . everyOther === id
prop_doubleEnqueue_everyOther_id :: [QueueOp Integer] -> Property
prop_doubleEnqueue_everyOther_id =
  compareQueues okasakiQueue (doubleEnqueue (everyOther okasakiQueue))

--------------------------
-- Miscellaneous things --
--------------------------

-- A silly show instance for queues, just so we can peek at them in the REPL
instance (Show a) => Show (Queue a) where
  show queue =
    "<<< " ++ text ++ " <<<"
    where
      contents = queueToList queue
      text =
        case contents of
          [] -> "empty"
          _  -> intercalate "," (map show contents)


-- Use Template Haskell to make a function to run all tests
-- (a test is anything with a name starting with "prop_")
return []
runTests :: IO Bool
runTests = $quickCheckAll
