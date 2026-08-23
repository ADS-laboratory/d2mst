%% Erlang functions for engine/console.gleam: the stdin/clock primitives Gleam's
%% stdlib does not expose on its own

-module(interactive_ffi).
-export([prompt_line/1, now_ms/0, try_run/1]).

prompt_line(Prompt) ->
    io:put_chars(Prompt),
    case io:get_line("") of
        eof -> {error, nil};
        {error, _Reason} -> {error, nil};
        Data ->
            Trimmed = string:trim(Data, trailing, "\r\n"),
            {ok, unicode:characters_to_binary(Trimmed)}
    end.

now_ms() ->
    erlang:system_time(millisecond).

%% Run a zero-argument closure, turning any exception it raises into
%% `Error(Nil)` instead of crashing the calling process.
try_run(F) ->
    try
        {ok, F()}
    catch
        _:_ -> {error, nil}
    end.
