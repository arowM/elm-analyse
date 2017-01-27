module Analyser exposing (..)

import Analyser.InterfaceLoadingStage as InterfaceLoadingStage
import Analyser.LoadedDependencies as LoadedDependencies exposing (LoadedDependencies)
import Analyser.Messages exposing (Message)
import Analyser.SourceLoadingStage as SourceLoadingStage
import Analyser.Types exposing (FileLoad(Failed), LoadedSourceFiles)
import AnalyserPorts
import Platform exposing (program, programWithFlags)
import Task
import Time exposing (Time)
import Analyser.FileContext as FileContext


type alias Flags =
    { interfaceFiles : InputInterfaces
    , sourceFiles : InputFiles
    }


type alias InputFiles =
    List String


type alias InputInterfaces =
    List ( String, InputFiles )


type Msg
    = InterfaceLoadingStageMsg InterfaceLoadingStage.Msg
    | SourceLoadingStageMsg SourceLoadingStage.Msg
    | Now Time


type alias Model =
    { interfaceFiles : InputInterfaces
    , sourceFiles : InputFiles
    , messages : List Message
    , stage : Stage
    }


type Stage
    = InterfaceLoadingStage InterfaceLoadingStage.Model
    | SourceLoadingStage SourceLoadingStage.Model LoadedDependencies
    | Finished LoadedSourceFiles LoadedDependencies


main : Program Flags Model Msg
main =
    programWithFlags { init = init, update = update, subscriptions = subscriptions }


init : Flags -> ( Model, Cmd Msg )
init { interfaceFiles, sourceFiles } =
    let
        ( stage, cmds ) =
            InterfaceLoadingStage.init interfaceFiles
    in
        ( { interfaceFiles = interfaceFiles
          , sourceFiles = sourceFiles
          , stage = InterfaceLoadingStage stage
          , messages = []
          }
        , Cmd.map InterfaceLoadingStageMsg cmds
        )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case ( msg, model.stage ) of
        ( InterfaceLoadingStageMsg x, InterfaceLoadingStage stage ) ->
            let
                ( newStage, cmds ) =
                    InterfaceLoadingStage.update x stage
            in
                if InterfaceLoadingStage.isDone newStage then
                    let
                        ( nextStage, cmds ) =
                            (SourceLoadingStage.init model.sourceFiles)

                        loadedDependencies =
                            InterfaceLoadingStage.parsedInterfaces newStage
                    in
                        ( { model
                            | messages = model.messages ++ LoadedDependencies.messages loadedDependencies
                            , stage = SourceLoadingStage nextStage loadedDependencies
                          }
                        , Cmd.map SourceLoadingStageMsg cmds
                        )
                else
                    ( { model | stage = InterfaceLoadingStage newStage }
                    , Cmd.map InterfaceLoadingStageMsg cmds
                    )

        ( SourceLoadingStageMsg x, SourceLoadingStage stage loadedDependencies ) ->
            let
                ( newStage, cmds ) =
                    SourceLoadingStage.update x stage
            in
                if SourceLoadingStage.isDone newStage then
                    let
                        files =
                            SourceLoadingStage.parsedFiles newStage

                        contexts =
                            List.map (FileContext.create files loadedDependencies) files
                    in
                        { model | stage = Finished (SourceLoadingStage.parsedFiles newStage) loadedDependencies } ! [ Time.now |> Task.perform Now ]
                else
                    ( { model | stage = SourceLoadingStage newStage loadedDependencies }
                    , Cmd.map SourceLoadingStageMsg cmds
                    )

        ( _, Finished x y ) ->
            let
                _ =
                    x
                        |> List.map (FileContext.create x y)
            in
                model ! [ AnalyserPorts.sendMessagesAsStrings model.messages ]

        ( b, a ) ->
            let
                _ =
                    Debug.log "Unknown" b
            in
                model ! []


subscriptions : Model -> Sub Msg
subscriptions model =
    case model.stage of
        InterfaceLoadingStage stage ->
            InterfaceLoadingStage.subscriptions stage |> Sub.map InterfaceLoadingStageMsg

        SourceLoadingStage stage _ ->
            SourceLoadingStage.subscriptions stage |> Sub.map SourceLoadingStageMsg

        Finished _ _ ->
            Sub.none