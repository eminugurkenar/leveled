%% -------- Overview ---------
%%
%% The eleveleddb is based on the LSM-tree similar to leveldb, except that:
%% - Values are kept seperately to Keys & Metadata
%% - Different file formats are used for value store (based on constant
%% database), and key store (based on sst)
%% - It is not intended to be general purpose, but be specifically suited for
%% use as a Riak backend in specific circumstances (relatively large values,
%% and frequent use of iterators)
%% - The Value store is an extended nursery log in leveldb terms.  It is keyed
%% on the sequence number of the write
%% - The Key Store is a LSM tree, where the key is the actaul object key, and
%% the value is the metadata of the object including the sequence number
%%
%% -------- Concierge & Manifest ---------
%%
%% The concierge is responsible for opening up the store, and keeps a manifest
%% of where items can be found.  The manifest keeps a mapping of:
%% - Sequence Number ranges and the PID of the Value Store file that contains
%% that range
%% - Key ranges to PID mappings for each leval of the KeyStore
%%
%% -------- GET --------
%%
%% A GET request for Key and Metadata requires a lookup in the KeyStore only.
%% - The concierge should consult the manifest for the lowest level to find
%% the PID which may contain the Key
%% - The concierge should ask the file owner if the Key is present, if not
%% present lower levels should be consulted until the objetc is found
%%
%% If a value is required, when the Key/Metadata has been fetched from the
%% KeyStore, the sequence number should be tkane, and matched in the ValueStore
%% manifest to find the right value.
%%
%% For recent PUTs the Key/Metadata is added into memory, and there is an
%% in-memory hash table for the entries in the most recent ValueStore CDB. 
%%
%% -------- PUT --------
%%
%% A PUT request must be persisted to the open (and append only) CDB file which
%% acts as a transaction log to persist the change.  The Key & Metadata needs
%% also to be placed in memory.
%%
%% Once the CDB file is full, the managing process should be requested to
%% complete the lookup hash, and a new CDB file be started.
%%
%% Once the in-memory 
%%
%% -------- Snapshots (Key Only) --------
%%
%% If there is a iterator/snapshot request, the concierge will simply handoff a
%% copy of the manifest, and register the interest of the iterator at the
%% manifest sequence number at the time of the request.  Iterators should
%% de-register themselves from the manager on completion.  Iterators should be
%% automatically release after a timeout period.  A file can be deleted if
%% there are no registered iterators from before the point the file was
%% removed from the manifest.
%%
%% -------- Snapshots (Key & Value) --------
%%
%%
%%
%% -------- Special Ops --------
%%
%% e.g. Get all for SegmentID/Partition
%%
%% -------- KeyStore ---------
%%
%% The concierge is responsible for controlling access to the store and 
%% maintaining both an in-memory view and a persisted state of all the sft
%% files in use across the store.
%%
%% The store is divided into many levels
%% L0: May contain one, and only one sft file PID which is the most recent file
%% added to the top of the store.  Access to the store will be stalled when a
%% second file is added whilst one still remains at this level.  The target
%% size of L0 is therefore 0.
%% L1 - Ln: May contain multiple non-overlapping PIDs managing sft files.
%% Compaction work should be sheduled if the number of files exceeds the target
%% size of the level, where the target size is 8 ^ n.
%%
%% The most recent revision of a Key can be found by checking each level until
%% the key is found.  To check a level the write file must be sought from the
%% manifest for that level, and then a call is made to that level.
%%
%% If a compaction change takes the size of a level beyond the target size,
%% then compaction work for that level + 1 should be added to the compaction
%% work queue.
%% Compaction work is fetched from the compaction worker because:
%% - it has timed out due to a period of inactivity
%% - it has been triggered by the a cast to indicate the arrival of high
%% priority compaction work
%% The compaction worker will always call the level manager to find out the
%% highest priority work currently in the queue before proceeding.
%%
%% When the compaction worker picks work off the queue it will take the current
%% manifest for the level and level - 1.  The compaction worker will choose
%% which file to compact from level - 1, and once the compaction is complete
%% will call to the manager with the new version of the manifest to be written.
%% Once the new version of the manifest had been persisted, the state of any
%% deleted files will be changed to pending deletion.  In pending deletion they
%% will call the manifets manager on a timeout to confirm that they are no
%% longer in use (by any iterators).
%%



    
-module(leveled_concierge).

%% -behaviour(gen_server).

-export([return_work/2, commit_manifest_change/7]).

-include_lib("eunit/include/eunit.hrl").

-define(LEVEL_SCALEFACTOR, [{0, 0}, {1, 8}, {2, 64}, {3, 512},
                            {4, 4096}, {5, 32768}, {6, 262144}, {7, infinity}]).
-define(MAX_LEVELS, 8).
-define(MAX_WORK_WAIT, 300).
-define(MANIFEST_FP, "manifest").
-define(FILES_FP, "files").

-record(state, {level_fileref :: list(),
                ongoing_work :: list(),
				manifest_sqn :: integer(),
                registered_iterators :: list(),
                unreferenced_files :: list(),
                root_path :: string()}).


%% Work out what the current work queue should be
%%
%% The work queue should have a lower level work at the front, and no work
%% should be added to the queue if a compaction worker has already been asked
%% to look at work at that level

return_work(State, From) ->
    OngoingWork = State#state.ongoing_work,
    WorkQueue = assess_workqueue([],
                                    0,
                                    State#state.level_fileref,
                                    OngoingWork),
    case length(WorkQueue) of
        L when L > 0 ->
            [{SrcLevel, SrcManifest, SnkManifest}|OtherWork] = WorkQueue,
            UpdatedWork = lists:append(OngoingWork,
                                        [{SrcLevel, From, os:timestamp()},
                                        {SrcLevel + 1, From, os:timestamp()}]),
            io:format("Work at Level ~w to be scheduled for ~w with ~w queue
                        items outstanding", [SrcLevel, From, length(OtherWork)]),
            {State#state{ongoing_work=UpdatedWork},
                {SrcLevel, SrcManifest, SnkManifest}};
        _ ->
            {State, none}
    end.
    

assess_workqueue(WorkQ, ?MAX_LEVELS - 1, _LevelFileRef, _OngoingWork) ->
    WorkQ;
assess_workqueue(WorkQ, LevelToAssess, LevelFileRef, OngoingWork)->
    MaxFiles = get_item(LevelToAssess, ?LEVEL_SCALEFACTOR, 0),
    FileCount = length(get_item(LevelToAssess, LevelFileRef, [])),
    NewWQ = maybe_append_work(WorkQ, LevelToAssess, LevelFileRef, MaxFiles,
                                FileCount, OngoingWork),
    assess_workqueue(NewWQ, LevelToAssess + 1, LevelFileRef, OngoingWork).


maybe_append_work(WorkQ, Level, LevelFileRef,
                    MaxFiles, FileCount, OngoingWork)
                        when FileCount > MaxFiles ->
    io:format("Outstanding compaction work items of ~w at level ~w~n",
                [FileCount - MaxFiles, Level]),
    case lists:keyfind(Level, 1, OngoingWork) of
        {Level, Pid, TS} ->
            io:format("Work will not be added to queue due to
                        outstanding work with ~w assigned at ~w~n", [Pid, TS]),
            WorkQ;
        false ->
            lists:append(WorkQ, [{Level,
                                    get_item(Level, LevelFileRef, []),
                                    get_item(Level + 1, LevelFileRef, [])}])
    end;
maybe_append_work(WorkQ, Level, _LevelFileRef,
                    _MaxFiles, FileCount, _OngoingWork) ->
    io:format("No compaction work due to file count ~w at level ~w~n",
                [FileCount, Level]),
    WorkQ.


get_item(Index, List, Default) ->
    case lists:keysearch(Index, 1, List) of
        {value, {Index, Value}} ->
            Value;
        false ->
            Default
    end.


%% Request a manifest change
%% Should be passed the
%% - {SrcLevel, NewSrcManifest, NewSnkManifest, ClearedFiles, MergeID, From,
%% State}
%% To complete a manifest change need to:
%% - Update the Manifest Sequence Number (msn)
%% - Confirm this Pid has a current element of manifest work outstanding at
%% that level
%% - Rename the manifest file created under the MergeID (<mergeID>.<level>)
%% at the sink Level to be the current manifest file (current_<level>.<msn>)
%% --------  NOTE --------
%% If there is a crash between these two points, the K/V data that has been
%% merged from the source level will now be in both the source and the sink
%% level.  Therefore in store operations this potential duplication must be
%% handled.
%% --------  NOTE --------
%% - Rename the manifest file created under the MergeID (<mergeID>.<level>)
%% at the source level to the current manifest file (current_<level>.<msn>)
%% - Update the state of the LevelFileRef lists
%% - Add the ClearedFiles to the list of files to be cleared (as a tuple with
%% the new msn)


commit_manifest_change(SrcLevel, NewSrcMan, NewSnkMan, ClearedFiles,
                                                    MergeID, From, State) ->
    NewMSN = State#state.manifest_sqn +  1,
    OngoingWork = State#state.ongoing_work,
    RootPath = State#state.root_path,
    SnkLevel = SrcLevel + 1,
    case {lists:keyfind(SrcLevel, 1, OngoingWork),
                lists:keyfind(SrcLevel + 1, 1, OngoingWork)} of
        {{SrcLevel, From, TS}, {SnkLevel, From, TS}} ->
            io:format("Merge ~s was a success in ~w microseconds",
                [MergeID, timer:diff_now(os:timestamp(), TS)]),
            OutstandingWork = lists:keydelete(SnkLevel, 1,
                                lists:keydelete(SrcLevel, 1, OngoingWork)),
            ok = rename_manifest_files(RootPath, MergeID,
                                        NewMSN, SrcLevel, SnkLevel),
            NewLFR = update_levelfileref(NewSrcMan,
                                            NewSnkMan,
                                            SrcLevel,
                                            State#state.level_fileref),
            UnreferencedFiles = update_deletions(ClearedFiles,
                                                    NewMSN,
                                                    State#state.unreferenced_files),
            io:format("Merge ~s has been commmitted at sequence number ~w~n",
                        [MergeID, NewMSN]),
            {ok, State#state{ongoing_work=OutstandingWork,
                                manifest_sqn=NewMSN,
                                level_fileref=NewLFR,
                                unreferenced_files=UnreferencedFiles}};
        _ ->
            io:format("Merge commit ~s not matched to known work~n",
                        [MergeID]),
            {error, State}
    end.    
    


rename_manifest_files(RootPath, MergeID,  NewMSN, SrcLevel, SnkLevel) ->
    ManifestFP = RootPath ++ "/" ++ ?MANIFEST_FP ++ "/",
    ok = file:rename(ManifestFP ++ MergeID
                            ++ "." ++ integer_to_list(SnkLevel),
                        ManifestFP ++ "current_" ++ integer_to_list(SnkLevel)
                            ++ "." ++ integer_to_list(NewMSN)),
    ok = file:rename(ManifestFP ++ MergeID
                            ++ "." ++ integer_to_list(SrcLevel),
                        ManifestFP ++ "current_" ++ integer_to_list(SrcLevel)
                            ++ "." ++ integer_to_list(NewMSN)),
    ok.

update_levelfileref(NewSrcMan, NewSinkMan, SrcLevel, CurrLFR) ->
    lists:keyreplace(SrcLevel + 1,
                        1,
                        lists:keyreplace(SrcLevel,
                                            1,
                                            CurrLFR,
                                            {SrcLevel, NewSrcMan}),
                        {SrcLevel + 1, NewSinkMan}).

update_deletions([], _NewMSN, UnreferencedFiles) ->
    UnreferencedFiles;
update_deletions([ClearedFile|Tail], MSN, UnreferencedFiles) ->
    update_deletions(Tail,
                        MSN,
                        lists:append(UnreferencedFiles, [{ClearedFile, MSN}])).

%%%============================================================================
%%% Test
%%%============================================================================


compaction_work_assessment_test() ->
    L0 = [{{o, "B1", "K1"}, {o, "B3", "K3"}, dummy_pid}],
    L1 = [{{o, "B1", "K1"}, {o, "B2", "K2"}, dummy_pid},
            {{o, "B2", "K3"}, {o, "B4", "K4"}, dummy_pid}],
    LevelFileRef = [{0, L0}, {1, L1}],
    OngoingWork1 = [],
    WorkQ1 = assess_workqueue([], 0, LevelFileRef, OngoingWork1),
    ?assertMatch(WorkQ1, [{0, L0, L1}]),
    OngoingWork2 = [{0, dummy_pid, os:timestamp()}],
    WorkQ2 = assess_workqueue([], 0, LevelFileRef, OngoingWork2),
    ?assertMatch(WorkQ2, []),
    L1Alt = lists:append(L1,
                        [{{o, "B5", "K0001"}, {o, "B5", "K9999"}, dummy_pid},
                        {{o, "B6", "K0001"}, {o, "B6", "K9999"}, dummy_pid},
                        {{o, "B7", "K0001"}, {o, "B7", "K9999"}, dummy_pid},
                        {{o, "B8", "K0001"}, {o, "B8", "K9999"}, dummy_pid},
                        {{o, "B9", "K0001"}, {o, "B9", "K9999"}, dummy_pid},
                        {{o, "BA", "K0001"}, {o, "BA", "K9999"}, dummy_pid},
                        {{o, "BB", "K0001"}, {o, "BB", "K9999"}, dummy_pid}]),
    WorkQ3 = assess_workqueue([], 0, [{0, []}, {1, L1Alt}], OngoingWork1),
    ?assertMatch(WorkQ3, [{1, L1Alt, []}]),
    WorkQ4 = assess_workqueue([], 0, [{0, []}, {1, L1Alt}], OngoingWork2),
    ?assertMatch(WorkQ4, [{1, L1Alt, []}]),
    OngoingWork3 = lists:append(OngoingWork2, [{1, dummy_pid, os:timestamp()}]),
    WorkQ5 = assess_workqueue([], 0, [{0, []}, {1, L1Alt}], OngoingWork3),
    ?assertMatch(WorkQ5, []).

