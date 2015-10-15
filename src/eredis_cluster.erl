-module(eredis_cluster).

-define(REDIS_CLUSTER_REQUEST_TTL,16).
-define(REDIS_RETRY_DELAY,100).

-export([start/0]).
-export([connect/1]).
-export([q/1]).
-export([qp/1]).
-export([transaction/1]).

start() ->
  application:start(?MODULE).

connect(InitServers) ->
    eredis_cluster_monitor:connect(InitServers).

q(Command) ->
    q(Command,0).
q(_,?REDIS_CLUSTER_REQUEST_TTL) ->
    {error,no_connection};
q(Command,Counter) ->

    %% Throttle retries
    if
        Counter > 1 ->
            timer:sleep(?REDIS_RETRY_DELAY);
        true ->
            ok
    end,

    %% Extract key from request
	case get_key_from_command(Command) of
		undefined ->
			{error, invalid_cluster_command};
		Key ->
			Slot = get_key_slot(Key),

			case eredis_cluster_monitor:get_pool_by_slot(Slot) of
				{Version,undefined} ->
                    eredis_cluster_monitor:refresh_mapping(Version),
					q(Command,Counter+1);

				{Version,Pool} ->
					case query_eredis_pool(Pool, Command) of
                        {error,no_connection} ->
                            eredis_cluster_monitor:refresh_mapping(Version),
							q(Command,Counter+1);

						{error,<<"MOVED ",_RedirectionInfo/binary>>} ->
                            eredis_cluster_monitor:refresh_mapping(Version),
							q(Command,Counter+1);

                        Payload ->
                            Payload
					end
			end
	end.

qp(Commands) ->
    q(Commands).

transaction(Commands) ->
    Transaction = [["multi"]|Commands] ++ [["exec"]],
    Result = qp(Transaction),
    lists:nth(erlang:length(Result),Result).

query_eredis_pool(PoolName,[[X|Y]|Z]) when is_list(X) ->
    query_eredis_pool(PoolName,[[X|Y]|Z],qp);
query_eredis_pool(PoolName, Command) ->
    query_eredis_pool(PoolName,Command,q).
query_eredis_pool(PoolName, Params, Type) ->
    try
        poolboy:transaction(PoolName, fun(Worker) ->
            gen_server:call(Worker, {Type, Params})
        end)
    catch
        exit:_ ->
            {error,no_connection}
    end.

%% =============================================================================
%% @doc Return the hash slot from the key
%% @end
%% =============================================================================

-spec get_key_slot(Key::string()) -> Slot::integer().
get_key_slot(Key) ->
	KeyToBeHased = case string:chr(Key,${) of
		0 ->
			Key;
		Start ->
			case string:chr(string:substr(Key,Start+1),$}) of
				0 ->
					Key;
				Length ->
					if
						Length =:= 1 ->
							Key;
						true ->
							string:substr(Key,Start+1,Length-1)
					end
			end
	end,
	eredis_cluster_hash:hash(KeyToBeHased).

%% =============================================================================
%% @doc Return the first key in the command arguments.
%% In a normal query, the second term will be returned
%%
%% If it is a pipeline query we will use the second term of the first term, we
%% will assume that all keys are in the same server and the query can be
%% performed
%%
%% If the pipeline query starts with multi (transaction), we will look at the
%% second term of the second command
%%
%% For commands that don't make sense in the context of cluster
%% return value will be undefined.
%% @end
%% =============================================================================

-spec get_key_from_command([string()]) -> string() | undefined.
get_key_from_command([[X|Y]|Z]) when is_list(X) ->
    case string:to_lower(X) of
        "multi" ->
            get_key_from_command(Z);
        _ ->
            get_key_from_command([X|Y])
    end;
get_key_from_command([Term1,Term2|_]) ->
	case string:to_lower(Term1) of
        "info" ->
			undefined;
		"config" ->
			undefined;
        "shutdown" ->
			undefined;
        "slaveof" ->
			undefined;
		_ ->
			Term2
	end;
get_key_from_command(_) ->
    undefined.
