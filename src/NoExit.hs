{-# LANGUAGE GADTs, TemplateHaskell #-}

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

------------------------------------------
-- Existential types are abstract types --
------------------------------------------

-- An existential type for a queue "object"
data Queue a where
  Queue :: (a -> q -> q)
        -> (q -> Maybe (a, q))
        -> q
        -> Queue a

-- A very simple queue with O(n) enqueue and O(1) dequeue
-- This is useful as a reference implementation
slowQueue :: Queue a
slowQueue = Queue tack uncons []
  where
    tack :: a -> [a] -> [a]
    tack x xs = xs ++ [x]

enqueue :: a -> Queue a -> Queue a
enqueue a (Queue enQ deQ q) =
  Queue enQ deQ (enQ a q)

dequeue :: Queue a -> Maybe (a, Queue a)
dequeue (Queue enQ deQ q) =
  (fmap . fmap) (Queue enQ deQ) (deQ q)
  -- case deQ q of
  --   Nothing -> Nothing
  --   Just (a, rest) ->
  --     Just (a, Queue enQ deQ rest)

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

  -- When we *shrink* a value, we produce a list of conceptually /smaller/
  -- versions of that value that we hope still falsify a given test.
  shrink (Enqueue a) = Enqueue <$> shrink a
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
twoListQueue = Queue enQ deQ q
  where
    q = ([], [])  -- a queue consists of a "front" and a "back"

    enQ a (front, back) =
          (front, a : back)  -- enqueue into back

    deQ ([], [])           = Nothing     -- queue empty if both lists are empty
    deQ (a : front', back) = Just (a, (front', back))  -- we dequeue from front,
    deQ ([], back) =                                   -- or if front is empty,
      let (a : front') = reverse back                  -- reverse back
      in Just (a, (front', []))                        -- & set as front

prop_twoListQueue_spec :: [QueueOp Integer] -> Property
prop_twoListQueue_spec = compareQueues slowQueue twoListQueue

-- A queue with persistent worst-case O(1) performance
-- Chris Okasaki: "Simple and Efficient Purely Functional Queues and Deques"
-- J. Functional Programming 5(4): 583–592, October 1995

-- The trick: instead of reversing the "back" list all at once, we reverse it
-- one step every operation, so that when we need it reversed, we've already
-- done it!
okasakiQueue :: Queue a
okasakiQueue = Queue enQ deQ q
  where
    q = ([], [], [])  -- (front, back, some tail of front)

    enQ e (fs, bs, as) =
      makeEq (fs, e : bs, as)  -- enqueue into back

    deQ ([],      _, _)  = Nothing
    deQ (f : fs, bs, as) = Just (f, makeEq (fs, bs, as))

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

-- trace :: String -> a -> a

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
everyOther (Queue enQ deQ q0) = Queue enQ' deQ' q'
  where
    q' = (True,  -- flag to tell us whether to accept an enqueue
          q0)    -- insides of the queue we're wrapping (opaque)

    enQ' a (True,  q) = (False, enQ a q)  -- enqueue iff flag True
    enQ' _ (False, q) = (True, q)         -- flip flag regardless

    deQ' (b, q) =
      case deQ q of
        Just (a, rest) ->
          Just (a, (not b, rest))  -- flip the flag on dequeue
        Nothing -> Nothing

-- Enqueues twice anything you tell it to enqueue
-- That is to say, we call the enqueue "method" of the wrapped queue twice
doubleEnqueue :: Queue a -> Queue a
doubleEnqueue (Queue enQ deQ q) =
  Queue (\a -> enQ a . enQ a) deQ q

prop_doubleEnqueue_everyOther_id :: [QueueOp Integer] -> Property
prop_doubleEnqueue_everyOther_id =
  compareQueues okasakiQueue (everyOther (doubleEnqueue okasakiQueue))

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
