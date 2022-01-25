{-# LANGUAGE OverloadedStrings #-}

import Control.Monad.State (State, evalState, get, modify, put)
import Data.Text (Text, lines, pack, strip, takeWhile, unlines, unpack, words)
import qualified Data.Text.IO as IO
import Data.Text.Read (decimal)
import Fmt ( (+|), (|+) )
import System.Environment (getArgs)
import System.FilePath (replaceExtension, takeBaseName)

parseFile :: Text -> [Text]
parseFile = filter (/= "") . map (strip . Data.Text.takeWhile (/= '/')) . Data.Text.lines

parseTemp :: Text -> Text 
parseTemp "0" = "R5"
parseTemp "1" = "R6"
parseTemp "2" = "R7"
parseTemp "3" = "R8"
parseTemp "4" = "R9"
parseTemp "5" = "R10"
parseTemp "6" = "R11"
parseTemp "7" = "R12"
parseTemp offset = error "Uknown temp location"

arithmetic :: Text -> Text
arithmetic str = "@SP\nAM=M-1\nD=M\nA=A-1\nM=M" +| str |+ "D"

bit :: Text -> Text
bit str = "@SP\nA=M-1\nM=" +| str |+ "M"

logic :: Text -> Int -> Text -> Text
logic fileName counter str = "@SP\nAM=M-1\nD=M\nA=A-1\nD=M-D\nM=0\n\
\@TRUTHY." +| fileName |+ "." +| counter |+ "\n\
\D;" +| str |+ "\n\
\@DONE." +| fileName |+ "." +| counter |+ "\n\
\0;JMP\n\
\(TRUTHY." +| fileName |+ "." +| counter |+ ")\n\
\@SP\nA=M-1\nM=-1\n\
\(DONE." +| fileName |+ "." +| counter |+ ")"

pushBody = "@SP\nM=M+1\nA=M-1\nM=D"

push :: Text -> Text -> Text -> Text
push _ "constant" offset = "@" +| offset |+ "\nD=A\n" +| pushBody
push _ "pointer" "0" = "@THIS\nD=M\n" +| pushBody
push _ "pointer" "1" = "@THAT\nD=M\n" +| pushBody
push _ "temp" offset = "@" +| parseTemp offset |+ "\nD=M\n" +| pushBody
push fileName "static" offset = "@" +| fileName |+ "." +| offset |+ "\nD=M\n" +| pushBody
push fileName "local" offset = "@LCL\nD=M\n@" +| offset |+ "\nA=D+A\nD=M\n" +| pushBody
push fileName "argument" offset = "@ARG\nD=M\n@" +| offset |+ "\nA=D+A\nD=M\n" +| pushBody
push fileName "this" offset = "@THIS\nD=M\n@" +| offset |+ "\nA=D+A\nD=M\n" +| pushBody
push fileName "that" offset = "@THAT\nD=M\n@" +| offset |+ "\nA=D+A\nD=M\n" +| pushBody
push _ t offset = error $ "push " +| t |+ " " +| offset |+ " not implemented"

popBody = "D=A+D\n@R13\nM=D\n@SP\nAM=M-1\nD=M\n@R13\nA=M\nM=D"

pop :: Text -> Text -> Text -> Text
pop _ "pointer" "0" = "@SP\nAM=M-1\nD=M\n@THIS\nM=D"
pop _ "pointer" "1" = "@SP\nAM=M-1\nD=M\n@THAT\nM=D"
pop _ "temp" offset = "@SP\nAM=M-1\nD=M\n@" +| parseTemp offset |+ "\nM=D"
pop _ "local" offset = "@LCL\nD=M\n@"+|offset|+"\n" +| popBody
pop _ "argument" offset = "@ARG\nD=M\n@"+|offset|+"\n" +| popBody
pop _ "this" offset = "@THIS\nD=M\n@"+|offset|+"\n" +| popBody
pop _ "that" offset = "@THAT\nD=M\n@"+|offset|+"\n" +| popBody
pop fileName "static" offset = "@SP\nAM=M-1\nD=M\n@" +| fileName |+ "." +| offset |+ "\nM=D"
pop _ t offset = error $ "pop " +| t |+ " " +| offset |+ " not implemented"

processItem :: Text -> Int -> [Text] -> Text
processItem fileName _ ["push", location, dest] = push fileName location dest
processItem fileName _ ["pop", location, dest] = pop fileName location dest
processItem _ _ ["add"] = arithmetic "+"
processItem _ _ ["sub"] = arithmetic "-"
processItem _ _ ["and"] = arithmetic "&"
processItem _ _ ["or"] = arithmetic "|"
processItem _ _ ["neg"] = bit "-"
processItem _ _ ["not"] = bit "!"
processItem fileName count ["eq"] = logic fileName count "JEQ"
processItem fileName count ["lt"] = logic fileName count "JLT"
processItem fileName count ["gt"] = logic fileName count "JGT"
processItem _ _ a = error $ "processItem " +| show a |+ " not implemented"

statefulCalculation :: Text -> Text -> State Int Text
statefulCalculation filename str = do
  x <- get
  let asdf = Data.Text.words str
  let processed = processItem filename x asdf
  if head asdf `elem` ["eq", "lt", "gt"] then put $ x + 1 else pure ()
  return processed

main :: IO ()
main = do
  args <- getArgs
  let fileName = head args
  file <- IO.readFile fileName

  let fileLines = parseFile file

  let x = evalState (mapM (statefulCalculation $ pack $ takeBaseName fileName) fileLines) 0

  IO.writeFile (replaceExtension fileName "asm") $ Data.Text.unlines x
