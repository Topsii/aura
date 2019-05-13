{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE ScopedTypeVariables         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE MonoLocalBinds    #-}
{-# LANGUAGE MultiWayIf        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications  #-}

-- |
-- Module    : Aura.Core
-- Copyright : (c) Colin Woodbury, 2012 - 2019
-- License   : GPL3
-- Maintainer: Colin Woodbury <colin@fosskers.ca>
--
-- Core types and functions which belong nowhere else.

module Aura.Core
  ( -- * Types
    Repository(..)
  , liftEither, liftEitherM
  , liftMaybe, liftMaybeM
    -- * User Privileges
  , sudo, trueRoot
    -- * Querying the Package Database
  , foreignPackages, orphans, develPkgs
  , isSatisfied, isInstalled
  , checkDBLock
    -- * Misc. Package Handling
  , removePkgs, partitionPkgs, packageBuildable
    -- * IO
  , notify, warn, scold, report
  ) where

import           Aura.Colour
import           Aura.Languages
import           Aura.Pacman
import           Aura.Pkgbuild.Editing (hotEdit)
import           Aura.Settings
import           Aura.Types
import           Aura.Utils
import           BasePrelude hiding ((<>))
import           Control.Compactable (fmapEither)
import           Control.Effect (Carrier, Member)
import           Control.Effect.Error (Error, throwError)
import           Control.Effect.Lift (Lift, sendM)
import           Control.Effect.Reader (Reader, ask, asks)
import           Control.Monad.Trans.Maybe
import qualified Data.ByteString.Lazy.Char8 as BL
import           Data.Generics.Product (field)
import qualified Data.List.NonEmpty as NEL
import           Data.Semigroup
import qualified Data.Set as S
import           Data.Set.NonEmpty (NonEmptySet)
import qualified Data.Set.NonEmpty as NES
import qualified Data.Text as T
import qualified Data.Text.IO as T
import           Data.Text.Prettyprint.Doc
import           Data.Text.Prettyprint.Doc.Render.Terminal
import           Data.Versions (prettyV)
import           Lens.Micro ((^.))
import           Lens.Micro.Extras (view)
import           System.Path.IO (doesFileExist)

---

--------
-- TYPES
--------

-- | A `Repository` is a place where packages may be fetched from. Multiple
-- repositories can be combined with the `Semigroup` instance.
-- Checks packages in batches for efficiency.
newtype Repository = Repository { repoLookup :: Settings -> NonEmptySet PkgName -> IO (Maybe (S.Set PkgName, S.Set Package)) }

instance Semigroup Repository where
  a <> b = Repository $ \ss ps -> runMaybeT $
    MaybeT (repoLookup a ss ps) >>= \(bads, goods) -> case NES.fromSet bads of
      Nothing    -> pure (bads, goods)
      Just bads' -> second (goods <>) <$> MaybeT (repoLookup b ss bads')

---------------------------------
-- Functions common to `Package`s
---------------------------------
-- | Partition a list of packages into pacman and buildable groups.
-- Yes, this is the correct signature. As far as this function (in isolation)
-- is concerned, there is no way to guarantee that the list of `NonEmptySet`s
-- will itself be non-empty.
partitionPkgs :: NonEmpty (NonEmptySet Package) -> ([Prebuilt], [NonEmptySet Buildable])
partitionPkgs = bimap fold f . unzip . map g . toList
  where g = fmapEither toEither . toList
        f = mapMaybe (fmap NES.fromNonEmpty . NEL.nonEmpty)
        toEither (FromAUR b)  = Right b
        toEither (FromRepo b) = Left b

-- | Package a Buildable, running the customization handler first.
packageBuildable :: Settings -> Buildable -> IO Package
packageBuildable ss b = FromAUR <$> hotEdit ss b

-----------
-- THE WORK
-----------
-- | Lift a common return type into the `Eff` world. Usually used after a `pacman` call.
liftEither :: (Carrier sig m, Member (Error a) sig) => Either a b -> m b
liftEither = either throwError pure

-- | Like `liftEither`, but the `Either` can be embedded in something else,
-- usually a `Monad`.
liftEitherM :: (Carrier sig m, Member (Error a) sig) => m (Either a b) -> m b
liftEitherM m = m >>= liftEither

-- | Like `liftEither`, but for `Maybe`.
liftMaybe :: (Carrier sig m, Member (Error a) sig) => a -> Maybe b -> m b
liftMaybe a = maybe (throwError a) pure

-- | Like `liftEitherM`, but for `Maybe`.
liftMaybeM :: (Carrier sig m, Member (Error a) sig) => a -> m (Maybe b) -> m b
liftMaybeM a m = m >>= liftMaybe a

-- | Action won't be allowed unless user is root, or using sudo.
sudo :: ( Carrier sig m
        , Member (Reader Settings) sig
        , Member (Error Failure) sig
        )
     => m a -> m a
sudo action = asks (hasRootPriv . envOf) >>= bool (throwError $ Failure mustBeRoot_1) action

-- | Stop the user if they are the true root. Building as root isn't allowed
-- since makepkg v4.2.
trueRoot :: ( Carrier sig m
            , Member (Reader Settings) sig
            , Member (Error Failure) sig
            )
         => m a -> m a
trueRoot action = ask >>= \ss ->
  if not (isTrueRoot $ envOf ss) && buildUserOf (buildConfigOf ss) /= Just (User "root")
    then action else throwError $ Failure trueRoot_3

-- | A list of non-prebuilt packages installed on the system.
-- `-Qm` yields a list of sorted values.
foreignPackages :: IO (S.Set SimplePkg)
foreignPackages = S.fromList . mapMaybe (simplepkg' . strictText) . BL.lines <$> pacmanOutput ["-Qm"]

-- | Packages marked as a dependency, yet are required by no other package.
orphans :: IO (S.Set PkgName)
orphans = S.fromList . map (PkgName . strictText) . BL.lines <$> pacmanOutput ["-Qqdt"]

-- | Any package whose name is suffixed by git, hg, svn, darcs, cvs, or bzr.
develPkgs :: IO (S.Set PkgName)
develPkgs = S.filter isDevelPkg . S.map (^. field @"name") <$> foreignPackages
  where isDevelPkg (PkgName pkg) = any (`T.isSuffixOf` pkg) suffixes
        suffixes = ["-git", "-hg", "-svn", "-darcs", "-cvs", "-bzr"]

-- | Returns what it was given if the package is already installed.
-- Reasoning: Using raw bools can be less expressive.
isInstalled :: PkgName -> IO (Maybe PkgName)
isInstalled pkg = bool Nothing (Just pkg) <$> pacmanSuccess ["-Qq", T.unpack (pkg ^. field @"name")]

-- | An @-Rsu@ call.
removePkgs :: ( Carrier sig m
              , Member (Reader Settings) sig
              , Member (Error Failure) sig
              , Member (Lift IO) sig
              ) => NonEmptySet PkgName -> m ()
removePkgs pkgs = do
  pacOpts <- asks commonConfigOf
  liftEitherM . sendM . pacman $ ["-Rsu"] <> asFlag pkgs <> asFlag pacOpts

-- | True if a dependency is satisfied by an installed package.
-- `asT` renders the `VersionDemand` into the specific form that `pacman -T`
-- understands. See `man pacman` for more info.
isSatisfied :: Dep -> IO Bool
isSatisfied (Dep n ver) = pacmanSuccess $ map T.unpack ["-T", (n ^. field @"name") <> asT ver]
  where asT (LessThan v) = "<"  <> prettyV v
        asT (AtLeast  v) = ">=" <> prettyV v
        asT (MoreThan v) = ">"  <> prettyV v
        asT (MustBe   v) = "="  <> prettyV v
        asT Anything     = ""

-- | Block further action until the database is free.
checkDBLock :: Settings -> IO ()
checkDBLock ss = do
  locked <- doesFileExist lockFile
  when locked $ (warn ss . checkDBLock_1 $ langOf ss) *> getLine *> checkDBLock ss

-------
-- MISC  -- Too specific for `Utilities.hs` or `Aura.Utils`
-------

-- | Print some message in green with Aura flair.
notify :: Settings -> Doc AnsiStyle -> IO ()
notify ss = putStrLnA ss . green

-- | Print some message in yellow with Aura flair.
warn :: Settings -> Doc AnsiStyle -> IO ()
warn ss = putStrLnA ss . yellow

-- | Print some message in red with Aura flair.
scold :: Settings -> Doc AnsiStyle -> IO ()
scold ss = putStrLnA ss . red

-- | Report a message with multiple associated items. Usually a list of
-- naughty packages.
report :: ( Carrier sig m
          , Member (Reader Settings) sig
          , Member (Lift IO) sig
          )
       => (Doc AnsiStyle -> Doc AnsiStyle)
       -> (Language -> Doc AnsiStyle)
       -> NonEmpty PkgName
       -> m ()
report c msg pkgs = do
  ss <- ask
  sendM . putStrLnA ss . c . msg $ langOf ss
  sendM . T.putStrLn . dtot . colourCheck ss . vsep . map (cyan . pretty . view (field @"name")) $ toList pkgs
