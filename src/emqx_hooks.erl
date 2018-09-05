%% Copyright (c) 2018 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(emqx_hooks).

-behaviour(gen_server).

-export([start_link/0, stop/0]).

%% Hooks API
-export([add/2, add/3, add/4, del/2, run/2, run/3, lookup/1]).

%% gen_server Function Exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-type(hookpoint() :: atom()).
-type(action() :: function() | mfa()).
-type(filter() :: function() | mfa()).

-record(callback, {action   :: action(),
                   filter   :: filter(),
                   priority :: integer()}).

-record(hook, {name :: hookpoint(), callbacks :: list(#callback{})}).

-export_type([hookpoint/0, action/0, filter/0]).

-define(TAB, ?MODULE).
-define(SERVER, ?MODULE).

-spec(start_link() -> emqx_types:startlink_ret()).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], [{hibernate_after, 60000}]).

-spec(stop() -> ok).
stop() ->
    gen_server:stop(?SERVER, normal, infinity).

%%------------------------------------------------------------------------------
%% Hooks API
%%------------------------------------------------------------------------------

%% @doc Register a callback
-spec(add(hookpoint(), action() | #callback{}) -> emqx_types:ok_or_error(already_exists)).
add(HookPoint, Callback) when is_record(Callback, callback) ->
    gen_server:call(?SERVER, {add, HookPoint, Callback}, infinity);
add(HookPoint, Action) when is_function(Action); is_tuple(Action) ->
    add(HookPoint, #callback{action = Action, priority = 0}).

-spec(add(hookpoint(), action(), filter() | integer() | list())
      -> emqx_types:ok_or_error(already_exists)).
add(HookPoint, Action, InitArgs) when is_function(Action), is_list(InitArgs) ->
    add(HookPoint, #callback{action = {Action, InitArgs}, priority = 0});
add(HookPoint, Action, Filter) when is_function(Filter); is_tuple(Filter) ->
    add(HookPoint, #callback{action = Action, filter = Filter, priority = 0});
add(HookPoint, Action, Priority) when is_integer(Priority) ->
    add(HookPoint, #callback{action = Action, priority = Priority}).

-spec(add(hookpoint(), action(), filter(), integer())
      -> emqx_types:ok_or_error(already_exists)).
add(HookPoint, Action, Filter, Priority) ->
    add(HookPoint, #callback{action = Action, filter = Filter, priority = Priority}).

%% @doc Unregister a callback.
-spec(del(hookpoint(), action()) -> ok).
del(HookPoint, Action) ->
    gen_server:cast(?SERVER, {del, HookPoint, Action}).

%% @doc Run hooks.
-spec(run(atom(), list(Arg :: any())) -> ok | stop).
run(HookPoint, Args) ->
    run_(lookup(HookPoint), Args).

%% @doc Run hooks with Accumulator.
-spec(run(atom(), list(Arg :: any()), any()) -> any()).
run(HookPoint, Args, Acc) ->
    run_(lookup(HookPoint), Args, Acc).

%% @private
run_([#callback{action = Action, filter = Filter} | Callbacks], Args) ->
    case filtered(Filter, Args) orelse execute(Action, Args) of
        true -> run_(Callbacks, Args);
        ok   -> run_(Callbacks, Args);
        stop -> stop;
        _Any -> run_(Callbacks, Args)
    end;
run_([], _Args) ->
    ok.

%% @private
run_([#callback{action = Action, filter = Filter} | Callbacks], Args, Acc) ->
    Args1 = Args ++ [Acc],
    case filtered(Filter, Args1) orelse execute(Action, Args1) of
        true           -> run_(Callbacks, Args, Acc);
        ok             -> run_(Callbacks, Args, Acc);
        {ok, NewAcc}   -> run_(Callbacks, Args, NewAcc);
        stop           -> {stop, Acc};
        {stop, NewAcc} -> {stop, NewAcc};
        _Any           -> run_(Callbacks, Args, Acc)
    end;
run_([], _Args, Acc) ->
    {ok, Acc}.

filtered(undefined, _Args) ->
    false;
filtered(Filter, Args) ->
    execute(Filter, Args).

execute(Action, Args) when is_function(Action) ->
    erlang:apply(Action, Args);
execute({Fun, InitArgs}, Args) when is_function(Fun) ->
    erlang:apply(Fun, Args ++ InitArgs);
execute({M, F, A}, Args) ->
    erlang:apply(M, F, Args ++ A).

%% @doc Lookup callbacks.
-spec(lookup(hookpoint()) -> [#callback{}]).
lookup(HookPoint) ->
    case ets:lookup(?TAB, HookPoint) of
        [#hook{callbacks = Callbacks}] ->
            Callbacks;
        [] -> []
    end.

%%-----------------------------------------------------------------------------
%% gen_server callbacks
%%-----------------------------------------------------------------------------

init([]) ->
    _ = emqx_tables:new(?TAB, [{keypos, #hook.name}, {read_concurrency, true}]),
    {ok, #{}}.

handle_call({add, HookPoint, Callback = #callback{action = Action}}, _From, State) ->
    Reply = case lists:keyfind(Action, 2, Callbacks = lookup(HookPoint)) of
                true ->
                    {error, already_exists};
                false ->
                    insert_hook(HookPoint, add_callback(Callback, Callbacks))
            end,
    {reply, Reply, State};

handle_call({del, HookPoint, Action}, _From, State) ->
    case lists:keydelete(Action, 2, lookup(HookPoint)) of
        [] ->
            ets:delete(?TAB, HookPoint);
        Callbacks ->
            insert_hook(HookPoint, Callbacks)
    end,
    {reply, ok, State};

handle_call(Req, _From, State) ->
    emqx_logger:error("[Hooks] unexpected call: ~p", [Req]),
    {reply, ignored, State}.

handle_cast(Msg, State) ->
    emqx_logger:error("[Hooks] unexpected msg: ~p", [Msg]),
    {noreply, State}.

handle_info(Info, State) ->
    emqx_logger:error("[Hooks] unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%-----------------------------------------------------------------------------
%% Internal functions
%%-----------------------------------------------------------------------------

insert_hook(HookPoint, Callbacks) ->
    ets:insert(?TAB, #hook{name = HookPoint, callbacks = Callbacks}), ok.

add_callback(C, Callbacks) ->
    add_callback(C, Callbacks, []).

add_callback(C, [], Acc) ->
    lists:reverse([C|Acc]);
add_callback(C1 = #callback{priority = P1}, [C2 = #callback{priority = P2}|More], Acc)
    when P1 =< P2 ->
    add_callback(C1, More, [C2|Acc]);
add_callback(C1, More, Acc) ->
    lists:append(lists:reverse(Acc), [C1 | More]).

