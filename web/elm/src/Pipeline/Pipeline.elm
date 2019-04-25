module Pipeline.Pipeline exposing
    ( Flags
    , Model
    , changeToPipelineAndGroups
    , documentTitle
    , getUpdateMessage
    , handleCallback
    , handleDelivery
    , init
    , subscriptions
    , update
    , view
    )

import Colors
import Concourse
import Concourse.Cli as Cli
import Dict
import EffectTransformer exposing (ET)
import Html exposing (Html)
import Html.Attributes
    exposing
        ( class
        , download
        , href
        , id
        , src
        , style
        )
import Html.Attributes.Aria exposing (ariaLabel)
import Html.Events exposing (onClick, onMouseEnter, onMouseLeave)
import Http
import Json.Decode
import Json.Encode
import Keyboard
import Login.Login as Login
import Message.Callback exposing (Callback(..))
import Message.Effects exposing (Effect(..))
import Message.Message exposing (DomID(..), Message(..))
import Message.Subscription
    exposing
        ( Delivery(..)
        , Interval(..)
        , Subscription(..)
        )
import Message.TopLevelMessage exposing (TopLevelMessage(..))
import Pipeline.Styles as Styles
import RemoteData exposing (WebData)
import Routes
import Set
import StrictEvents exposing (onLeftClickOrShiftLeftClick)
import Svg
import Svg.Attributes as SvgAttributes
import UpdateMsg exposing (UpdateMsg)
import UserState exposing (UserState)
import Views.Icon as Icon
import Views.PauseToggle as PauseToggle
import Views.Styles
import Views.TopBar as TopBar


type alias Model =
    Login.Model
        { pipelineLocator : Concourse.PipelineIdentifier
        , pipeline : WebData Concourse.Pipeline
        , fetchedJobs : Maybe Json.Encode.Value
        , fetchedResources : Maybe Json.Encode.Value
        , renderedJobs : Maybe Json.Encode.Value
        , renderedResources : Maybe Json.Encode.Value
        , concourseVersion : String
        , turbulenceImgSrc : String
        , experiencingTurbulence : Bool
        , selectedGroups : List String
        , hideLegend : Bool
        , hideLegendCounter : Float
        , isToggleLoading : Bool
        , hovered : Maybe DomID
        , isPhoneScreen : Bool
        , isSideBarOpen : Bool
        , teams : List String
        , teamExpanded : Bool
        }


type alias Flags =
    { pipelineLocator : Concourse.PipelineIdentifier
    , turbulenceImgSrc : String
    , selectedGroups : List String
    }


init : Flags -> ( Model, List Effect )
init flags =
    let
        model =
            { concourseVersion = ""
            , turbulenceImgSrc = flags.turbulenceImgSrc
            , pipelineLocator = flags.pipelineLocator
            , pipeline = RemoteData.NotAsked
            , fetchedJobs = Nothing
            , fetchedResources = Nothing
            , renderedJobs = Nothing
            , renderedResources = Nothing
            , experiencingTurbulence = False
            , hideLegend = False
            , hideLegendCounter = 0
            , isToggleLoading = False
            , selectedGroups = flags.selectedGroups
            , isUserMenuExpanded = False
            , hovered = Nothing
            , isPhoneScreen = False
            , isSideBarOpen = False
            , teams = []
            , teamExpanded = False
            }
    in
    ( model
    , [ FetchPipeline flags.pipelineLocator
      , FetchVersion
      , ResetPipelineFocus
      , GetScreenSize
      , FetchPipelines
      ]
    )


changeToPipelineAndGroups :
    { pipelineLocator : Concourse.PipelineIdentifier
    , selectedGroups : List String
    }
    -> ET Model
changeToPipelineAndGroups { pipelineLocator, selectedGroups } ( model, effects ) =
    if model.pipelineLocator == pipelineLocator then
        let
            ( newModel, newEffects ) =
                renderIfNeeded ( { model | selectedGroups = selectedGroups }, [] )
        in
        ( newModel, effects ++ newEffects ++ [ ResetPipelineFocus ] )

    else
        let
            ( newModel, newEffects ) =
                init
                    { pipelineLocator = pipelineLocator
                    , selectedGroups = selectedGroups
                    , turbulenceImgSrc = model.turbulenceImgSrc
                    }
        in
        ( newModel, effects ++ newEffects )


timeUntilHidden : Float
timeUntilHidden =
    10 * 1000


timeUntilHiddenCheckInterval : Float
timeUntilHiddenCheckInterval =
    1 * 1000


getUpdateMessage : Model -> UpdateMsg
getUpdateMessage model =
    case model.pipeline of
        RemoteData.Failure _ ->
            UpdateMsg.NotFound

        _ ->
            UpdateMsg.AOK


handleCallback : Callback -> ET Model
handleCallback callback ( model, effects ) =
    let
        redirectToLoginIfUnauthenticated status =
            if status.code == 401 then
                [ RedirectToLogin ]

            else
                []
    in
    case callback of
        PipelineFetched (Ok pipeline) ->
            ( { model | pipeline = RemoteData.Success pipeline }
            , effects
                ++ [ FetchJobs model.pipelineLocator
                   , FetchResources model.pipelineLocator
                   ]
            )

        PipelineFetched (Err err) ->
            case err of
                Http.BadStatus { status } ->
                    if status.code == 404 then
                        ( { model | pipeline = RemoteData.Failure err }
                        , effects
                        )

                    else
                        ( model
                        , effects ++ redirectToLoginIfUnauthenticated status
                        )

                _ ->
                    renderIfNeeded
                        ( { model | experiencingTurbulence = True }
                        , effects
                        )

        PipelineToggled _ (Ok ()) ->
            ( { model
                | pipeline =
                    RemoteData.map
                        (\p -> { p | paused = not p.paused })
                        model.pipeline
                , isToggleLoading = False
              }
            , effects
            )

        PipelineToggled _ (Err _) ->
            ( { model | isToggleLoading = False }, effects )

        JobsFetched (Ok fetchedJobs) ->
            renderIfNeeded
                ( { model
                    | fetchedJobs = Just fetchedJobs
                    , experiencingTurbulence = False
                  }
                , effects
                )

        JobsFetched (Err err) ->
            case err of
                Http.BadStatus { status } ->
                    ( model, effects ++ redirectToLoginIfUnauthenticated status )

                _ ->
                    renderIfNeeded
                        ( { model
                            | fetchedJobs = Nothing
                            , experiencingTurbulence = True
                          }
                        , effects
                        )

        ResourcesFetched (Ok fetchedResources) ->
            renderIfNeeded
                ( { model
                    | fetchedResources = Just fetchedResources
                    , experiencingTurbulence = False
                  }
                , effects
                )

        ResourcesFetched (Err err) ->
            case err of
                Http.BadStatus { status } ->
                    ( model, effects ++ redirectToLoginIfUnauthenticated status )

                _ ->
                    renderIfNeeded
                        ( { model
                            | fetchedResources = Nothing
                            , experiencingTurbulence = True
                          }
                        , effects
                        )

        VersionFetched (Ok version) ->
            ( { model
                | concourseVersion = version
                , experiencingTurbulence = False
              }
            , effects
            )

        VersionFetched (Err _) ->
            ( { model | experiencingTurbulence = True }, effects )

        ScreenResized viewport ->
            ( { model | isPhoneScreen = viewport.viewport.width < 812 }, effects )

        PipelinesFetched (Ok pipelines) ->
            ( { model
                | teams =
                    pipelines
                        |> List.map .teamName
                        |> Set.fromList
                        |> Set.union (Set.fromList model.teams)
                        |> Set.toList
              }
            , effects
            )

        PipelinesFetched (Err _) ->
            ( { model | experiencingTurbulence = True }, effects )

        _ ->
            ( model, effects )


handleDelivery : Delivery -> ET Model
handleDelivery delivery ( model, effects ) =
    case delivery of
        KeyDown keyEvent ->
            ( { model | hideLegend = False, hideLegendCounter = 0 }
            , if keyEvent.code == Keyboard.F then
                effects ++ [ ResetPipelineFocus ]

              else
                effects
            )

        Moused ->
            ( { model | hideLegend = False, hideLegendCounter = 0 }, effects )

        ClockTicked OneSecond _ ->
            if model.hideLegendCounter + timeUntilHiddenCheckInterval > timeUntilHidden then
                ( { model | hideLegend = True }, effects )

            else
                ( { model | hideLegendCounter = model.hideLegendCounter + timeUntilHiddenCheckInterval }
                , effects
                )

        ClockTicked FiveSeconds _ ->
            ( model, effects ++ [ FetchPipeline model.pipelineLocator ] )

        ClockTicked OneMinute _ ->
            ( model, effects ++ [ FetchVersion ] )

        WindowResized width height ->
            ( { model | isPhoneScreen = width < 812 }, effects )

        _ ->
            ( model, effects )


update : Message -> ET Model
update msg ( model, effects ) =
    case msg of
        ToggleGroup group ->
            ( model
            , effects
                ++ [ NavigateTo <|
                        getNextUrl
                            (toggleGroup group model.selectedGroups model.pipeline)
                            model
                   ]
            )

        SetGroups groups ->
            ( model, effects ++ [ NavigateTo <| getNextUrl groups model ] )

        Click (PipelineButton pipelineIdentifier) ->
            let
                paused =
                    model.pipeline |> RemoteData.map .paused
            in
            case paused of
                RemoteData.Success p ->
                    ( { model | isToggleLoading = True }
                    , effects
                        ++ [ SendTogglePipelineRequest
                                pipelineIdentifier
                                p
                           ]
                    )

                _ ->
                    ( model, effects )

        Click HamburgerMenu ->
            ( { model | isSideBarOpen = not model.isSideBarOpen }, effects )

        Click (SideBarTeam _) ->
            ( { model | teamExpanded = True }, effects )

        Hover hoverable ->
            ( { model | hovered = hoverable }, effects )

        _ ->
            ( model, effects )


getPinnedResources : Model -> List ( String, Concourse.Version )
getPinnedResources model =
    case model.fetchedResources of
        Nothing ->
            []

        Just res ->
            Json.Decode.decodeValue (Json.Decode.list Concourse.decodeResource) res
                |> Result.withDefault []
                |> List.filterMap (\r -> Maybe.map (\v -> ( r.name, v )) r.pinnedVersion)


subscriptions : List Subscription
subscriptions =
    [ OnClockTick OneMinute
    , OnClockTick FiveSeconds
    , OnClockTick OneSecond
    , OnMouse
    , OnKeyDown
    , OnWindowResize
    ]


documentTitle : Model -> String
documentTitle model =
    model.pipelineLocator.pipelineName


view : UserState -> Model -> Html Message
view userState model =
    let
        route =
            Routes.Pipeline
                { id = model.pipelineLocator
                , groups = model.selectedGroups
                }
    in
    Html.div [ Html.Attributes.style "height" "100%" ] <|
        let
            isHamburgerClickable =
                not <| List.isEmpty model.teams
        in
        [ Html.div
            (id "page-including-top-bar" :: Views.Styles.pageIncludingTopBar)
            [ Html.div
                (id "top-bar-app"
                    :: (Views.Styles.topBar <|
                            isPaused model.pipeline
                       )
                )
                [ if model.isPhoneScreen then
                    Html.text ""

                  else
                    Html.div
                        [ style "border-right" <|
                            "1px solid "
                                ++ separatorColor model.pipeline
                        , style "opacity" "1"
                        , style "background-color" <|
                            if isPaused model.pipeline then
                                Colors.paused

                            else if model.isSideBarOpen then
                                "#333333"

                            else
                                Colors.frame
                        ]
                        [ Icon.icon
                            { sizePx = 54
                            , image = "baseline-menu-24px.svg"
                            }
                            ([ style "cursor" <|
                                if isHamburgerClickable then
                                    "pointer"

                                else
                                    "default"
                             , onMouseEnter <| Hover <| Just HamburgerMenu
                             , onMouseLeave <| Hover Nothing
                             , style "opacity" <|
                                if (model.hovered == Just HamburgerMenu) && isHamburgerClickable then
                                    "1"

                                else
                                    "0.5"
                             ]
                                ++ (if isHamburgerClickable then
                                        [ onClick <| Click HamburgerMenu ]

                                    else
                                        []
                                   )
                            )
                        ]
                , TopBar.concourseLogo
                , TopBar.breadcrumbs route
                , viewPinMenu
                    { pinnedResources = getPinnedResources model
                    , pipeline = model.pipelineLocator
                    , isPinMenuExpanded =
                        model.hovered == Just PinIcon
                    }
                , Html.div
                    (id "top-bar-pause-toggle"
                        :: (Styles.pauseToggle <| isPaused model.pipeline)
                    )
                    [ PauseToggle.view "17px"
                        userState
                        { pipeline = model.pipelineLocator
                        , isPaused = isPaused model.pipeline
                        , isToggleHovered =
                            model.hovered
                                == (Just <|
                                        PipelineButton model.pipelineLocator
                                   )
                        , isToggleLoading = model.isToggleLoading
                        }
                    ]
                , Login.view userState model <| isPaused model.pipeline
                ]
            , Html.div
                (id "page-below-top-bar" :: Views.Styles.pageBelowTopBar route)
              <|
                [ case ( model.teams, model.isSideBarOpen ) of
                    ( _, False ) ->
                        Html.text ""

                    ( [], _ ) ->
                        Html.text ""

                    ( teams, True ) ->
                        Html.div
                            [ id "side-bar"
                            , style "background-color" Colors.frame
                            , style "border-top" <|
                                "1px solid "
                                    ++ Colors.background
                            , style "padding-right" "10px"
                            , style "overflow-y" "auto"
                            , style "max-width" "38%"
                            ]
                        <|
                            List.map (sideBarPipelineGroup model) teams
                , viewSubPage model
                ]
            ]
        ]


sideBarPipelineGroup :
    { a | hovered : Maybe DomID, teamExpanded : Bool }
    -> String
    -> Html Message
sideBarPipelineGroup { hovered, teamExpanded } teamName =
    Html.div
        [ style "display" "flex"
        , style "cursor" "pointer"
        , onClick <| Click <| SideBarTeam teamName
        , onMouseEnter <| Hover <| Just <| SideBarTeam teamName
        , onMouseLeave <| Hover Nothing
        ]
        [ Html.div
            [ style "box-sizing" "border-box"
            , style "width" "54px"
            , style "display" "flex"
            , style "align-items" "center"
            , style "justify-content" "space-between"
            , style "padding" "5px"
            , style "flex-shrink" "0"
            ]
            [ Icon.icon
                { image = "baseline-people-24px.svg"
                , sizePx = 20
                }
                [ style "opacity" <|
                    if hovered == Just (SideBarTeam teamName) then
                        "1"

                    else
                        "0.5"
                ]
            , Icon.icon
                { image =
                    "baseline-keyboard-arrow-"
                        ++ (if teamExpanded then
                                "down"

                            else
                                "right"
                           )
                        ++ "-24px.svg"
                , sizePx = 20
                }
                [ style "opacity" "1" ]
            ]
        , Html.div
            [ style "font-size" "18px"
            , style "padding" "5px"
            , style "white-space" "nowrap"
            , style "overflow" "hidden"
            , style "text-overflow" "ellipsis"
            , style "opacity" <|
                if hovered == Just (SideBarTeam teamName) then
                    "1"

                else
                    "0.5"
            ]
            [ Html.text teamName ]
        ]


separatorColor : WebData Concourse.Pipeline -> String
separatorColor pipeline =
    if isPaused pipeline then
        Colors.pausedTopbarSeparator

    else
        Colors.background


viewPinMenu :
    { pinnedResources : List ( String, Concourse.Version )
    , pipeline : Concourse.PipelineIdentifier
    , isPinMenuExpanded : Bool
    }
    -> Html Message
viewPinMenu ({ pinnedResources, isPinMenuExpanded } as params) =
    Html.div
        (id "pin-icon" :: Styles.pinIconContainer isPinMenuExpanded)
        [ if List.length pinnedResources > 0 then
            Html.div
                ([ onMouseEnter <| Hover <| Just PinIcon
                 , onMouseLeave <| Hover Nothing
                 ]
                    ++ Styles.pinIcon
                )
                (Html.div
                    (id "pin-badge" :: Styles.pinBadge)
                    [ Html.div []
                        [ Html.text <|
                            String.fromInt <|
                                List.length pinnedResources
                        ]
                    ]
                    :: viewPinMenuDropdown params
                )

          else
            Html.div Styles.pinIcon []
        ]


viewPinMenuDropdown :
    { pinnedResources : List ( String, Concourse.Version )
    , pipeline : Concourse.PipelineIdentifier
    , isPinMenuExpanded : Bool
    }
    -> List (Html Message)
viewPinMenuDropdown { pinnedResources, pipeline, isPinMenuExpanded } =
    if isPinMenuExpanded then
        [ Html.ul
            Styles.pinIconDropdown
            (pinnedResources
                |> List.map
                    (\( resourceName, pinnedVersion ) ->
                        Html.li
                            (onClick
                                (GoToRoute <|
                                    Routes.Resource
                                        { id =
                                            { teamName = pipeline.teamName
                                            , pipelineName = pipeline.pipelineName
                                            , resourceName = resourceName
                                            }
                                        , page = Nothing
                                        }
                                )
                                :: Styles.pinDropdownCursor
                            )
                            [ Html.div
                                Styles.pinText
                                [ Html.text resourceName ]
                            , Html.table []
                                (pinnedVersion
                                    |> Dict.toList
                                    |> List.map
                                        (\( k, v ) ->
                                            Html.tr []
                                                [ Html.td [] [ Html.text k ]
                                                , Html.td [] [ Html.text v ]
                                                ]
                                        )
                                )
                            ]
                    )
            )
        , Html.div Styles.pinHoverHighlight []
        ]

    else
        []


isPaused : WebData Concourse.Pipeline -> Bool
isPaused p =
    RemoteData.withDefault False (RemoteData.map .paused p)


viewSubPage : Model -> Html Message
viewSubPage model =
    Html.div
        [ class "pipeline-view"
        , id "pipeline-container"
        , style "display" "flex"
        , style "flex-direction" "column"
        , style "flex-grow" "1"
        ]
        [ viewGroupsBar model
        , Html.div [ class "pipeline-content" ]
            [ Svg.svg
                [ SvgAttributes.class "pipeline-graph test" ]
                []
            , Html.div
                [ if model.experiencingTurbulence then
                    class "error-message"

                  else
                    class "error-message hidden"
                ]
                [ Html.div [ class "message" ]
                    [ Html.img [ src model.turbulenceImgSrc, class "seatbelt" ] []
                    , Html.p [] [ Html.text "experiencing turbulence" ]
                    , Html.p [ class "explanation" ] []
                    ]
                ]
            , if model.hideLegend then
                Html.text ""

              else
                Html.dl
                    [ id "legend", class "legend" ]
                    [ Html.dt [ class "succeeded" ] []
                    , Html.dd [] [ Html.text "succeeded" ]
                    , Html.dt [ class "errored" ] []
                    , Html.dd [] [ Html.text "errored" ]
                    , Html.dt [ class "aborted" ] []
                    , Html.dd [] [ Html.text "aborted" ]
                    , Html.dt [ class "paused" ] []
                    , Html.dd [] [ Html.text "paused" ]
                    , Html.dt
                        [ Html.Attributes.style "background-color" Colors.pinned
                        ]
                        []
                    , Html.dd [] [ Html.text "pinned" ]
                    , Html.dt [ class "failed" ] []
                    , Html.dd [] [ Html.text "failed" ]
                    , Html.dt [ class "pending" ] []
                    , Html.dd [] [ Html.text "pending" ]
                    , Html.dt [ class "started" ] []
                    , Html.dd [] [ Html.text "started" ]
                    , Html.dt [ class "dotted" ] [ Html.text "." ]
                    , Html.dd [] [ Html.text "dependency" ]
                    , Html.dt [ class "solid" ] [ Html.text "-" ]
                    , Html.dd [] [ Html.text "dependency (trigger)" ]
                    ]
            , Html.table [ class "lower-right-info" ]
                [ Html.tr []
                    [ Html.td [ class "label" ] [ Html.text "cli:" ]
                    , Html.td []
                        [ Html.ul [ class "cli-downloads" ] <|
                            List.map
                                (\cli ->
                                    Html.li []
                                        [ Html.a
                                            ([ href <| Cli.downloadUrl cli
                                             , ariaLabel <| Cli.label cli
                                             , download ""
                                             ]
                                                ++ Styles.cliIcon cli
                                            )
                                            []
                                        ]
                                )
                                Cli.clis
                        ]
                    ]
                , Html.tr []
                    [ Html.td [ class "label" ] [ Html.text "version:" ]
                    , Html.td []
                        [ Html.div [ id "concourse-version" ]
                            [ Html.text "v"
                            , Html.span
                                [ class "number" ]
                                [ Html.text model.concourseVersion ]
                            ]
                        ]
                    ]
                ]
            ]
        ]


viewGroupsBar : Model -> Html Message
viewGroupsBar model =
    let
        groupList =
            case model.pipeline of
                RemoteData.Success pipeline ->
                    List.indexedMap
                        (viewGroup
                            { selectedGroups = selectedGroupsOrDefault model
                            , pipelineLocator = model.pipelineLocator
                            , hovered = model.hovered
                            }
                        )
                        pipeline.groups

                _ ->
                    []
    in
    if List.isEmpty groupList then
        Html.text ""

    else
        Html.div
            (id "groups-bar" :: Styles.groupsBar)
            groupList


viewGroup :
    { a
        | selectedGroups : List String
        , pipelineLocator : Concourse.PipelineIdentifier
        , hovered : Maybe DomID
    }
    -> Int
    -> Concourse.PipelineGroup
    -> Html Message
viewGroup { selectedGroups, pipelineLocator, hovered } idx grp =
    let
        url =
            Routes.toString <|
                Routes.Pipeline { id = pipelineLocator, groups = [ grp.name ] }
    in
    Html.a
        ([ Html.Attributes.href <| url
         , onLeftClickOrShiftLeftClick
            (SetGroups [ grp.name ])
            (ToggleGroup grp)
         , onMouseEnter <| Hover <| Just <| JobGroup idx
         , onMouseLeave <| Hover Nothing
         ]
            ++ Styles.groupItem
                { selected = List.member grp.name selectedGroups
                , hovered = hovered == (Just <| JobGroup idx)
                }
        )
        [ Html.text grp.name ]


jobAppearsInGroups : List String -> Concourse.PipelineIdentifier -> Json.Encode.Value -> Bool
jobAppearsInGroups groupNames pi jobJson =
    let
        concourseJob =
            Json.Decode.decodeValue (Concourse.decodeJob pi) jobJson
    in
    case concourseJob of
        Ok cj ->
            anyIntersect cj.groups groupNames

        Err _ ->
            -- failed to check if job is in group
            False


expandJsonList : Json.Encode.Value -> List Json.Decode.Value
expandJsonList flatList =
    let
        result =
            Json.Decode.decodeValue (Json.Decode.list Json.Decode.value) flatList
    in
    case result of
        Ok res ->
            res

        Err _ ->
            []


filterJobs : Model -> Json.Encode.Value -> Json.Encode.Value
filterJobs model value =
    Json.Encode.list identity <|
        List.filter
            (jobAppearsInGroups (activeGroups model) model.pipelineLocator)
            (expandJsonList value)


activeGroups : Model -> List String
activeGroups model =
    case ( model.selectedGroups, model.pipeline |> RemoteData.toMaybe |> Maybe.andThen (List.head << .groups) ) of
        ( [], Just firstGroup ) ->
            [ firstGroup.name ]

        ( groups, _ ) ->
            groups


renderIfNeeded : ET Model
renderIfNeeded ( model, effects ) =
    case ( model.fetchedResources, model.fetchedJobs ) of
        ( Just fetchedResources, Just fetchedJobs ) ->
            let
                filteredFetchedJobs =
                    if List.isEmpty (activeGroups model) then
                        fetchedJobs

                    else
                        filterJobs model fetchedJobs
            in
            case ( model.renderedResources, model.renderedJobs ) of
                ( Just renderedResources, Just renderedJobs ) ->
                    if
                        (expandJsonList renderedJobs /= expandJsonList filteredFetchedJobs)
                            || (expandJsonList renderedResources /= expandJsonList fetchedResources)
                    then
                        ( { model
                            | renderedJobs = Just filteredFetchedJobs
                            , renderedResources = Just fetchedResources
                          }
                        , effects ++ [ RenderPipeline filteredFetchedJobs fetchedResources ]
                        )

                    else
                        ( model, effects )

                _ ->
                    ( { model
                        | renderedJobs = Just filteredFetchedJobs
                        , renderedResources = Just fetchedResources
                      }
                    , effects ++ [ RenderPipeline filteredFetchedJobs fetchedResources ]
                    )

        _ ->
            ( model, effects )


anyIntersect : List a -> List a -> Bool
anyIntersect list1 list2 =
    case list1 of
        [] ->
            False

        first :: rest ->
            if List.member first list2 then
                True

            else
                anyIntersect rest list2


toggleGroup : Concourse.PipelineGroup -> List String -> WebData Concourse.Pipeline -> List String
toggleGroup grp names mpipeline =
    if List.member grp.name names then
        List.filter ((/=) grp.name) names

    else if List.isEmpty names then
        grp.name :: getDefaultSelectedGroups mpipeline

    else
        grp.name :: names


selectedGroupsOrDefault : Model -> List String
selectedGroupsOrDefault model =
    if List.isEmpty model.selectedGroups then
        getDefaultSelectedGroups model.pipeline

    else
        model.selectedGroups


getDefaultSelectedGroups : WebData Concourse.Pipeline -> List String
getDefaultSelectedGroups pipeline =
    case pipeline of
        RemoteData.Success p ->
            case List.head p.groups of
                Nothing ->
                    []

                Just first ->
                    [ first.name ]

        _ ->
            []


getNextUrl : List String -> Model -> String
getNextUrl newGroups model =
    Routes.toString <|
        Routes.Pipeline { id = model.pipelineLocator, groups = newGroups }
