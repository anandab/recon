-module(recon_lib).
-export([sliding_window/2, sample/2, count/1,
         port_list/1, port_list/2,
         proc_attrs/1, proc_attrs/2,
         inet_attrs/1, inet_attrs/2,
         triple_to_pid/3, term_to_pid/1,
         time_map/5, time_fold/6]).

-type diff() :: [recon:proc_attrs() | recon:inet_attrs()].

%% @doc Compare two samples and return a list based on some key. The type mentioned
%% for the structure is `diff()' (`{Key,Val,Other}'), which is compatible with
%% the {@link recon:proc_attrs()} type.
-spec sliding_window(First::diff(), Last::diff()) -> diff().
sliding_window(First, Last) ->
    Dict = lists:foldl(
        fun({Key, {Current, Other}}, Acc) ->
            dict:update(Key,
                        fun({Old,_Other}) -> {Current-Old, Other} end,
                        {Current, Other},
                        Acc)
        end,
        dict:from_list([{K,{V,O}} || {K,V,O} <- First]),
        [{K,{V,O}} || {K,V,O} <- Last]
    ),
    [{K,V,O} || {K,{V,O}} <- dict:to_list(Dict)].

%% @doc Runs a fun once, waits `Ms', runs the fun again,
%% and returns both results.
-spec sample(Ms::non_neg_integer(), fun(() -> term())) ->
      {First::term(), Second::term()}.
sample(Delay, Fun) ->
    First = Fun(),
    timer:sleep(Delay),
    Second = Fun(),
    {First, Second}.

%% @doc Takes a list of terms, and counts how often each of
%% them appears in the list. The list returned is in no
%% particular order.
-spec count([term()]) -> [{Count::integer(), term()}].
count(Terms) ->
    Dict = lists:foldl(
        fun(Val, Acc) ->  dict:update_counter(Val, 1, Acc) end,
        dict:new(),
        Terms
    ),
    dict:to_list(Dict).

%% @doc Returns a list of all the open ports in the VM, coupled with
%% one of the properties desired from `erlang:port_info/1-2'.
-spec port_list(Attr::atom()) -> [{port(), term()}].
port_list(Attr) ->
    [{Port,Val} || Port <- erlang:ports(),
                   {_, Val} <- [erlang:port_info(Port, Attr)]].

%% @doc Returns a list of all the open ports in the VM, but only
%% if the `Attr''s resulting value matches `Val'. `Attr' must be
%% a property accepted by `erlang:port_info/2'.
-spec port_list(Attr::atom(), term()) -> [port()].
port_list(Attr, Val) ->
    [Port || Port <- erlang:ports(),
             {Attr, Val} =:= erlang:port_info(Port, Attr)].

%% @doc Returns the attributes ({@link recon:proc_attrs()}) of
%% all processes of the node, except the caller.
-spec proc_attrs(term()) -> [recon:proc_attrs()].
proc_attrs(AttrName) ->
    [Attrs || Pid <- processes() -- [self()],
              {ok, Attrs} <- [proc_attrs(AttrName, Pid)]].

%% @doc Returns the attributes of a given process. This form of attributes
%% is standard for most comparison functions for processes in recon.
-spec proc_attrs(term(), pid()) -> {ok, recon:proc_attrs()} | {error, term()}.
proc_attrs(AttrName, Pid) ->
    case process_info(Pid, [AttrName, registered_name,
                            current_function, initial_call]) of
        [{_, Attr}, {registered_name,Name}, Init, Cur] ->
            {ok, {Pid, Attr, [Name || is_atom(Name)]++[Init, Cur]}};
        undefined ->
            {error, undefined}
    end.

%% @doc Returns the attributes ({@link recon:inet_attrs()}) of
%% all inet ports (UDP, SCTP, TCP) of the node.
-spec inet_attrs(term()) -> [recon:inet_attrs()].
inet_attrs(AttrName) ->
    Ports = [Port || Port <- erlang:ports(),
                     {_, Name} <- [erlang:port_info(Port, name)],
                     Name =:= "tcp_inet" orelse
                     Name =:= "udp_inet" orelse
                     Name =:= "sctp_inet"],
    [Attrs || Port <- Ports,
              {ok, Attrs} <- [inet_attrs(AttrName, Port)]].

%% @doc Returns the attributes required for a given inet port (UDP,
%% SCTP, TCP). This form of attributes is standard for most comparison
%% functions for processes in recon.
-spec inet_attrs(AttributeName, port()) -> {ok,recon:inet_attrs()}
                                         | {error,term()} when
      AttributeName :: 'recv_cnt' | 'recv_oct' | 'send_cnt' | 'send_oct'
                     | 'cnt' | 'oct'.
inet_attrs(Attr, Port) ->
    Attrs = case Attr of
        cnt -> [recv_cnt, send_cnt];
        oct -> [recv_oct, send_oct];
        _ -> [Attr]
    end,
    case inet:getstat(Port, Attrs) of
        {ok, Props} ->
            ValSum = lists:foldl(fun({_,X},Y) -> X+Y end, 0, Props),
            {ok, {Port,ValSum,Props}};
        {error, Reason} ->
            {error, Reason}
    end.


%% @doc Equivalent of `pid(X,Y,Z)' in the Erlang shell.
-spec triple_to_pid(N,N,N) -> pid() when
    N :: non_neg_integer().
triple_to_pid(X, Y, Z) ->
    list_to_pid("<" ++ integer_to_list(X) ++ "." ++
                       integer_to_list(Y) ++ "." ++
                       integer_to_list(Z) ++ ">").

%% @doc Transforms a given term to a pid.
-spec term_to_pid(recon:pid_term()) -> pid().
term_to_pid(Pid) when is_pid(Pid) -> Pid;
term_to_pid(Name) when is_atom(Name) -> whereis(Name);
term_to_pid(List = "<0."++_) -> list_to_pid(List);
term_to_pid({global, Name}) -> global:whereis_name(Name);
term_to_pid({via, Module, Name}) -> Module:whereis_name(Name);
term_to_pid({X,Y,Z}) when is_integer(X), is_integer(Y), is_integer(Z) ->
    triple_to_pid(X,Y,Z).

%% @doc Calls a given function every `Interval' milliseconds and supports
%% a map-like interface (each result is modified and returned)
-spec time_map(N, Interval, Fun, State, MapFun) -> [term()] when
    N :: non_neg_integer(),
    Interval :: pos_integer(),
    Fun :: fun((State) -> {term(), State}),
    State :: term(),
    MapFun :: fun((_) -> term()).
time_map(0, _, _, _, _) ->
    [];
time_map(N, Interval, Fun, State, MapFun) ->
    {Res, NewState} = Fun(State),
    timer:sleep(Interval),
    [MapFun(Res) | time_map(N-1,Interval,Fun,NewState,MapFun)].

%% @doc Calls a given function every `Interval' milliseconds and supports
%% a fold-like interface (each result is modified and accumulated)
-spec time_fold(N, Interval, Fun, State, FoldFun, Init) -> [term()] when
    N :: non_neg_integer(),
    Interval :: pos_integer(),
    Fun :: fun((State) -> {term(), State}),
    State :: term(),
    FoldFun :: fun((term(), Init) -> Init),
    Init :: term().
time_fold(0, _, _, _, _, Acc) ->
    Acc;
time_fold(N, Interval, Fun, State, FoldFun, Init) ->
    {Res, NewState} = Fun(State),
    timer:sleep(Interval),
    Acc = FoldFun(Res,Init),
    time_fold(N-1,Interval,Fun,NewState,FoldFun,Acc).

