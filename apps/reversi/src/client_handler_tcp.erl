-module(client_handler_tcp).
-behaviour(gen_server).

-export([start_link/1]).

-export([ init/1
          , handle_call/3
          , handle_cast/2
          , handle_info/2
          , terminate/2
          , code_change/3
        ]).

-define(DEFAULT_PORT, 7676).

-define(SOCKET_OPTIONS,
        [
         {active, true},
         {reuseaddr, true},
         {nodelay, true}
        ]).

-record(state, {lsock
                , ip
                , game_server
                , socket
               }).

start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

init([]) ->
    Port = case application:get_env(reversi, port) of
               {ok, P} -> P;
               undefined -> ?DEFAULT_PORT
           end,
    {ok, LSock} = gen_tcp:listen(Port, ?SOCKET_OPTIONS),
    init([LSock]);
init([LSock]) ->
    {ok, #state{lsock = LSock}, 0}.

handle_call(Msg, _From, State) ->
    {reply, {ok, Msg}, State}.

handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(Response, #state{socket=Socket} = State) ->
    NewState = handle_response(Response, Socket, State),
    {noreply, NewState}.

handle_info({tcp, Socket, RawData}, State) ->
    NewState = handle_data(Socket, RawData, State),
    {noreply, NewState};
handle_info({tcp_closed, _Socket}, State) ->
    {stop, normal, State};
handle_info(timeout, #state{lsock = LSock} = State) ->
    {ok, Socket} = gen_tcp:accept(LSock),
    {ok, {IP, _Port}} = inet:sockname(Socket),
    {ok, NewCH} = client_handler_sup:start_client_handler(?MODULE, [LSock]),
    gen_tcp:controlling_process(LSock, NewCH),
    {noreply, State#state{ip = IP, socket=Socket}}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions
handle_data(Socket, RawData, #state{ip = IP, game_server=GS} = State) ->
    Request = tcp_parse:parse_data(RawData),
    case Request of
        [] ->
            %% do nothing
            State;
        {error, could_not_parse_command} ->
            send_msg(Socket, term_to_string(Request)),
            State;
        _ ->
            Response =
                case GS of
                    undefined -> lobby:client_command({Request, IP});
                    _         -> game_server:client_command(GS, Request)
                end,
            handle_response(Response, Socket, State)
    end.

handle_response({redirect, {lets_play, GS, Who, Gid, C}}, Socket, State) ->
    send_msg(Socket, term_to_string({ok, {lets_play, Who, Gid, C}})),
    State#state{game_server=GS};
handle_response({redirect, {game_over, G, Win}}, Socket, State) ->
    send_msg(Socket, term_to_string({ok, {game_over, G, Win}})),
    State#state{game_server=undefined};
handle_response({redirect, {game_crash, G}}, Socket, State) ->
    send_msg(Socket, term_to_string({error, {game_crash, G}})),
    State#state{game_server=undefined};
handle_response(good_bye, Socket, _State) ->
    send_msg(Socket, "good_bye"),
    gen_tcp:close(Socket),
    exit(normal);
handle_response(Response, Socket, State) ->
    send_msg(Socket, term_to_string(Response)),
    State.



term_to_string(Term) ->
    lists:flatten(io_lib:format("~p", [Term])).

send_msg(Socket, Msg) ->
    gen_tcp:send(Socket, Msg ++ "\n").