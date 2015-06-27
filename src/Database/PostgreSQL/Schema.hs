module Database.PostgreSQL.Schema
  ( add
  , bootstrap
  , converge
  ) where

import BasePrelude hiding ( FilePath, (%), intercalate, lines )
import Data.Text          ( Text, intercalate, lines, strip )
import Formatting         ( (%), sformat, stext )
import Shelly

psqlCommand :: Text -> Text -> Sh Text
psqlCommand c url =
  run "psql" [ "--no-align"
             , "--tuples-only"
             , "--command"
             , c
             , url ]

psqlFile :: FilePath -> Text -> Sh ()
psqlFile f url =
  run_ "psql" [ "--no-align"
              , "--tuples-only"
              , "--quiet"
              , "--file"
              , toTextIgnore f
              , url ]

countSchema :: Text -> Text
countSchema =
  sformat ( " SELECT count(*) " %
            " FROM pg_namespace " %
            " WHERE nspname = '" % stext % "' " )

countMigration :: FilePath -> Text -> Text -> Text
countMigration migration table schema =
  sformat ( " SELECT count(*) " %
            " FROM " % stext % "." % stext %
            " WHERE filename = '" % stext % "' " )
    schema table (toTextIgnore migration)

insertMigration :: FilePath -> Text -> Text -> Text
insertMigration migration table schema =
  sformat ( " INSERT INTO " % stext % "." % stext % " (filename) " %
            " SELECT '" % stext % "' " %
            " WHERE NOT EXISTS " %
            " ( SELECT TRUE FROM " % stext % "." % stext %
            "   WHERE filename = '" % stext % "') " )
    schema table (toTextIgnore migration) schema table (toTextIgnore migration)

selectMigrations :: [FilePath] -> Text -> Text -> Text
selectMigrations migrations table schema =
  sformat ( " SELECT filename " %
            " FROM " % stext % "." % stext %
            " WHERE filename IN ( " % stext % " ) " )
    schema table $
      intercalate ", " $ flip map migrations $ \migration ->
        sformat ("'" % stext % "'") (toTextIgnore migration)

checkSchema :: Text -> Text -> Sh Bool
checkSchema schema url = do
  r <- psqlCommand (countSchema schema) url
  return $ strip r == "0"

checkMigration :: FilePath -> Text -> Text -> Text -> Sh Bool
checkMigration migration table schema url = do
  r <- psqlCommand (countMigration migration table schema) url
  return $ strip r == "0"

filterMigrations :: [FilePath] -> Text -> Text -> Text -> Sh [FilePath]
filterMigrations migrations table schema url = do
  r <- psqlCommand (selectMigrations migrations table schema) url
  return $ migrations \\ map fromText (lines r)

findMigrations :: FilePath -> Sh [FilePath]
findMigrations dir = do
  migrations <- findWhen test_f dir
  forM migrations $ relativeTo dir

migrate :: FilePath -> FilePath -> Text -> Text -> Text -> Sh ()
migrate migration dir table schema url = do
  echo out
  contents <- readfile migration
  appendfile (dir </> migration) "\\set ON_ERROR_STOP true\n\n"
  appendfile (dir </> migration) contents
  appendfile (dir </> migration) $ insertMigration migration table schema
  psqlFile (dir </> migration) url where
    out =
      sformat ( "M " % stext % " -> " % stext )
        (toTextIgnore migration) table

migrateWithCheck :: [FilePath] -> Text -> Text -> Text -> Sh ()
migrateWithCheck migrations table schema url =
  withTmpDir $ \dir ->
    forM_ migrations $ \migration -> do
      check <- checkMigration migration table schema url
      when check $
        migrate migration dir table schema url

migrateWithoutCheck :: [FilePath] -> Text -> Text -> Text -> Sh ()
migrateWithoutCheck migrations table schema url =
  withTmpDir $ \dir ->
    forM_ migrations $ \migration ->
      migrate migration dir table schema url

bootstrap :: FilePath -> Text -> Text -> Text -> Sh ()
bootstrap dir table schema url = do
  migrations <- findMigrations dir
  chdir dir $ do
    check <- checkSchema schema url
    when check $ do
      echo "Bootstrapping..."
      migrateWithoutCheck migrations table schema url
    migrations' <- filterMigrations migrations table schema url
    unless (null migrations') $ do
      echo "Bootstrap migrating..."
      migrateWithCheck migrations' table schema url

converge :: FilePath -> Text -> Text -> Text -> Sh ()
converge dir table schema url = do
  migrations <- findMigrations dir
  chdir dir $ do
    migrations' <- filterMigrations migrations table schema url
    unless (null migrations') $ do
      echo "Migrating..."
      migrateWithCheck migrations' table schema url

add :: FilePath -> FilePath -> FilePath -> Sh ()
add migration file dir = do
  echo out
  mv file (dir </> migration) where
    out =
      sformat ( "A " % stext % " -> " % stext )
        (toTextIgnore file)
        (toTextIgnore (dir </> migration))
