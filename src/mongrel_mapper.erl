% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

%%% @author CA Meijer
%%% @copyright 2012 CA Meijer
%%% @doc Mongrel mapping server. This module provides the Record/Document Mapping API.
%%% @end

-module(mongrel_mapper).

-behaviour(gen_server).

%% API
-export([start_link/1, 
		 add_mapping/1, 
		 get_mapping/1,
		 is_mapped/1,
		 has_id/1,
		 get_type/1,
		 get_field/2,
		 set_field/4,
		 map/1,
		 unmap/3,
		 map_selector/1,
		 map_projection/1,
		 map_modifier/1]).

%% gen_server callbacks
-export([init/1, 
		 handle_call/3, 
		 handle_cast/2, 
		 handle_info/2, 
		 terminate/2, 
		 code_change/3]).

-define(SERVER, ?MODULE).

%% Include files
-include_lib("mongrel_macros.hrl").

%% We store the ETS table ID across calls.
-record(state, {ets_table_id}).

%% External functions

%% @doc Spawns a registered process on the local node that stores the structure of records as in an ETS table.
%%
%% @spec start_link(integer()) -> {ok, pid()}    
%% @end
start_link(EtsTableId) ->
	gen_server:start_link({local, ?SERVER}, ?MODULE, [EtsTableId], []).

%% @doc Specfies the field identifiers associated with a record name.
-spec(add_mapping({atom(), FieldIds::list(atom())}) -> ok).
add_mapping({RecordName, FieldIds} = _RecordDescriptor) when is_atom(RecordName) ->
	[true = is_atom(FieldId) || FieldId <- FieldIds],
	server_call(add_mapping, {RecordName, FieldIds}).

%% @doc Gets the field identifiers associated with a record name.
-spec(get_mapping(atom()) -> list(atom())).
get_mapping(RecordName) when is_atom(RecordName) ->
	[{RecordName, FieldIds}] = server_call(get_mapping, RecordName),
	FieldIds.

%% @doc Returns whether a record is mapped. The argument can be either an atom (a possible record name)
%%      or a tuple (a possible record).
-spec(is_mapped(RecordOrRecordName::atom()|record()) -> boolean()).
is_mapped(RecordName) when is_atom(RecordName) ->
	case server_call(get_mapping, RecordName) of
		[] ->
			false;
		[{RecordName, _}] ->
			true
	end;
is_mapped(Record) when is_tuple(Record) andalso size(Record) > 1 ->
	[RecordName|FieldValues] = tuple_to_list(Record),
	case server_call(get_mapping, RecordName) of
		[] ->
			false;
		[{RecordName, FieldIds}] ->
			length(FieldIds) =:= length(FieldValues)
	end;
is_mapped(_) ->
	false.

%% @doc Returns whether a record has an '_id' field. The argument can be either an atom (a possible record name)
%%      or a tuple (a possible record).
-spec(has_id(RecordOrRecordName::atom()|record()) -> boolean()).
has_id(RecordName) when is_atom(RecordName) ->
	FieldIds = get_mapping(RecordName),
	CheckHasId = fun(FieldId, Result) ->
									   Result or (FieldId =:= '_id')
				 end,
	lists:foldl(CheckHasId, false, FieldIds);
has_id(Record) when is_tuple(Record) andalso size(Record) > 1 ->
	[RecordName|FieldValues] = tuple_to_list(Record),
	has_id(RecordName) andalso length(FieldValues) =:= length(get_mapping(RecordName)). 

%% @doc Gets the value of a field from a record.
-spec(get_field(record(), atom()) -> any()).
get_field(Record, Field) ->
	[RecordName|FieldValues] = tuple_to_list(Record),
	FieldIds = get_mapping(RecordName),
	get_field(FieldIds, FieldValues, Field).

%% @doc Sets the value of a field in a record. If the value is a reference to a document,
%%      a callback function is invoked to map the document to a record. An updated record
%%      is returned.
-spec(set_field(record(), atom(), FieldValue::any(), fun()) -> record()).
set_field(Record, FieldId, {?TYPE_REF, Collection, ?ID_REF, Id}, MapReferenceFun) ->
	set_field(Record, FieldId, MapReferenceFun(Collection, Id), MapReferenceFun);
set_field(Record, FieldId, FieldValue, _MapReferenceFun) ->
	[RecordName|RecordList] = tuple_to_list(Record),
	FieldIds = get_mapping(RecordName),
	UpdatedRecordList = set_field(RecordList, FieldIds, FieldId, FieldValue, []),
	list_to_tuple([RecordName|UpdatedRecordList]).

%% @doc A convenience function that extracts the first element of a tuple. If the
%%      tuple is a record, the first element contains the record name.
-spec(get_type(record()) -> atom()).
get_type(Record) ->
	true = is_mapped(Record),
	[RecordName|_] = tuple_to_list(Record),
	RecordName.

%% @doc Maps a record to a document. If the record contains child records, they are also mapped.
%%      A mapped document is a 2-tuple consisting of the collection name and the document contents.
-spec(map(record()) -> {{atom(), bson:document()}, list({atom(), bson:document()})}).
map(Record) ->
	{Document, ChildDocs} = map_record(Record, []),
	{{get_type(Record), Document}, ChildDocs}.

%% @doc Unmaps a document to a record. If the document references nested documents, a callback function
%%      is called to unmap the nested documents.
-spec(unmap(atom(), bson:document(), fun()) -> record()).
unmap(RecordName, Document, MapReferenceFun) when is_atom(RecordName) ->
	FieldIds = get_mapping(RecordName),
	DocumentList = tuple_to_list(Document),
	InitialDocument = list_to_tuple([RecordName] ++ lists:map(fun(_) -> undefined end, FieldIds)),
	unmap_record(DocumentList, MapReferenceFun, InitialDocument).

%% @doc Maps a selector specifying fields to match to a document. Nested records are "flattened" using the
%%      dot notation, e.g. 
%%      #foo{bar = #baz{x = 3}} is mapped to the document {'bar.x', 3}.
-spec(map_selector(record()) -> bson:document()).
map_selector(SelectorRecord) ->
	case is_mapped(SelectorRecord) of
		true ->
			RecordName = get_type(SelectorRecord),
			[{RecordName, FieldIds}] = server_call(get_mapping, RecordName),
			SelectorList = [{FieldId, get_field(SelectorRecord, FieldId)} || FieldId <- FieldIds],
			list_to_tuple(map_spm(SelectorList, false, []));
		false ->
			SelectorRecord
	end.
			
%% @doc Maps a projection specifying fields to select in a document. Nested records are "flattened" using the
%%      dot notation, e.g. 
%%      #foo{bar = #baz{x = 3}} is mapped to the document {'bar.x', 3}.
-spec(map_projection(record()) -> bson:document()).
map_projection(ProjectionRecord) ->
	map_selector(ProjectionRecord).

%% @doc Maps a modifier specifying a field to modify to a BSON document. A modifier is an atom
%%      like '$set', '$inc', etc.
-spec(map_modifier(Modifier::{atom(), record()}) -> bson:document()).
map_modifier({ModifierKey, ModifierValue}) when is_tuple(ModifierValue) ->
	case is_mapped(ModifierValue) of
		false ->
			{ModifierKey, ModifierValue};
		true ->
			RecordName = get_type(ModifierValue),
			[{RecordName, FieldIds}] = server_call(get_mapping, RecordName),
			ModifierList = [{FieldId, get_field(ModifierValue, FieldId)} || FieldId <- FieldIds],
			{ModifierKey, list_to_tuple(map_spm(ModifierList, true, []))}
	end;
map_modifier(Modifier) when is_tuple(Modifier) ->
	case is_mapped(Modifier) of
		false ->
			Modifier;
		true ->
			RecordName = get_type(Modifier),
			[{RecordName, FieldIds}] = server_call(get_mapping, RecordName),
			ModifierList = [{FieldId, get_field(Modifier, FieldId)} || FieldId <- FieldIds],
			list_to_tuple(map_spm(ModifierList, true, []))
	end.

%% Server functions

%% @doc Initializes the server with the ETS table used to persist the
%%      mappings needed for mapping records to documents.
-spec(init(EtsTableId::list(integer())) -> {ok, #state{}}).
init([EtsTableId]) ->
	{ok, #state{ets_table_id = EtsTableId}}.

%% @doc Responds synchronously to server calls. This function is invoked when a mapping is
%%      added or a mapping needs to be retrieved.
-spec(handle_call(Message::tuple(), From::pid(), State::#state{}) -> {reply, Reply::any(), NewState::record()}).
handle_call({add_mapping, {Key, Value}}, _From, State) ->
	true = ets:insert(State#state.ets_table_id, {Key, Value}),
	{reply, ok, State};
handle_call({get_mapping, Key}, _From, State) ->
	Reply = ets:lookup(State#state.ets_table_id, Key),
	{reply, Reply, State}.

%% @doc Responds asynchronously to messages. Asynchronous messages are ignored.
-spec(handle_cast(any(), State::#state{}) -> {no_reply, State::#state{}}).
handle_cast(_Message, State) ->
	{noreply, State}.

%% @doc Responds to non-OTP messages. This function should never be invoked.
-spec(handle_info(any(), State::#state{}) -> {no_reply, State::#state{}}).
handle_info(_Info, State) ->
	{noreply, State}.

%% @doc Handles the shutdown of the server.
-spec(terminate(any(), #state{}) -> ok).
terminate(_Reason, _State) ->
	ok.

%% @doc Responds to code changes.
-spec(code_change(any(), State::#state{}, any()) -> {ok, State::#state{}}).
code_change(_OldVersion, State, _Extra) ->
	{ok, State}.


%% Internal functions
server_call(Command, Args) ->
	gen_server:call(?SERVER, {Command, Args}, infinity).

map_value(Value, DocList) when is_tuple(Value) ->
	case mongrel_mapper:is_mapped(Value) of
		true ->
			RecordName = get_type(Value),
			{MappedDoc, UpdatedDocList} = map_record(Value, DocList),
			case has_id(Value) of
				false ->
					MappedDocList = [?TYPE_REF, RecordName] ++ tuple_to_list(MappedDoc),
					{list_to_tuple(MappedDocList), UpdatedDocList};
				true ->
					{{?TYPE_REF, RecordName, ?ID_REF, get_field(Value, '_id')}, UpdatedDocList ++ [{RecordName, MappedDoc}]}
			end;
		false ->
			{Value, DocList}
	end;
map_value(Value, DocList) when is_list(Value) ->
	map_list(Value, DocList, []);
map_value(Value, DocList) ->
	{Value, DocList}.

map_record(Record, DocList) ->
	[RecordName|FieldValues] = tuple_to_list(Record),
	FieldIds = get_mapping(RecordName),
	Result = [],
	{DocAsList, ChildDocs} = map_record(FieldIds, FieldValues, DocList, Result),
	{list_to_tuple(DocAsList), ChildDocs}.

map_record([], [], DocList, Result) ->
	{Result, DocList};
map_record([_FieldId|IdTail], [undefined|ValueTail], DocList, Result) ->
	map_record(IdTail, ValueTail, DocList, Result);
map_record([FieldId|IdTail], [FieldValue|ValueTail], DocList, Result) ->
	{ChildValue, UpdatedDocList} = map_value(FieldValue, DocList),
	map_record(IdTail, ValueTail, UpdatedDocList, Result ++ [FieldId, ChildValue]).

map_list([], DocList, Result) ->
	{Result, DocList};
map_list([Value|Tail], DocList, Result) ->
	{ChildValue, UpdatedDocList} = map_value(Value, DocList),
	map_list(Tail, UpdatedDocList, Result ++ [ChildValue]).

get_field([FieldId|_IdTail], [FieldValue|_ValuesTail], FieldId) ->
	FieldValue;
get_field([_FieldIdHead|IdTail], [_FieldValueHead|ValuesTail], FieldId) ->
	get_field(IdTail, ValuesTail, FieldId).

set_field([], [], _FieldId, _NewFieldValue, Result) ->
	Result;
set_field([_FieldValue|ValuesTail], [FieldId|_TailsList], FieldId, NewFieldValue, Result) ->
	Result ++ [NewFieldValue] ++ ValuesTail;
set_field([FieldValue|ValuesTail], [_FieldId|TailsList], FieldId, NewFieldValue, Result) ->
	set_field(ValuesTail, TailsList, FieldId, NewFieldValue, Result ++ [FieldValue]).

unmap_record([], _MapReferenceFun, Result) ->
	Result;
unmap_record([FieldId, FieldValue|FieldsTail], MapReferenceFun, Result) ->
	UnmappedValue = unmap_value(FieldValue, MapReferenceFun),
	unmap_record(FieldsTail, MapReferenceFun, set_field(Result, FieldId, UnmappedValue, MapReferenceFun)).

unmap_value(Value, MapReferenceFun) when is_tuple(Value) ->
	unmap_tuple(Value, MapReferenceFun);
unmap_value(Value, MapReferenceFun) when is_list(Value) ->
	unmap_list(Value, MapReferenceFun, []);
unmap_value(Value, _MapReferenceFun) ->
	Value.

unmap_tuple(Tuple, MapReferenceFun) ->
	TupleAsList = tuple_to_list(Tuple),
	case TupleAsList of
		[?TYPE_REF, Type, ?ID_REF, Id|_] ->
			unmap(Type, MapReferenceFun(Type, Id), MapReferenceFun);
		[?TYPE_REF, Type|Fields] ->
			unmap(Type, list_to_tuple(Fields), MapReferenceFun);
		_ ->
			Tuple
	end.

unmap_list([], _MapReferenceFun, Result) ->
	Result;
unmap_list([Value|ValueTail], MapReferenceFun, Result) ->
	unmap_list(ValueTail, MapReferenceFun, Result ++ [unmap_value(Value, MapReferenceFun)]).

% This generic function can map selectors, projections and modifiers to a BSON document.
% spm = selector-projection-modifier.
map_spm([], _IsModifier, Result) ->
	Result;
map_spm([{_FieldId, undefined}|Tail], IsModifier, Result) ->
	map_spm(Tail, IsModifier, Result);
map_spm([{FieldId, FieldValue}|Tail], IsModifier, Result) ->
	case is_mapped(FieldValue) of
		false ->
			map_spm(Tail, IsModifier, Result ++ [FieldId, FieldValue]);
		true ->
			RecordType = get_type(FieldValue),
			HasId = has_id(RecordType),
			IdIsSet = case HasId of
						  true ->
							  get_field(FieldValue, '_id') =/= undefined;
						  false ->
							  false
					  end,
			case IsModifier of
				false ->
					MappedValueList = tuple_to_list(map_selector(FieldValue)),
					MappedIdValueList = concat_field_ids(FieldId, ['#type', RecordType] ++ MappedValueList, HasId, IdIsSet, []);
				true ->
					MappedValueList = tuple_to_list(map_modifier(FieldValue)),
					MappedIdValueList = concat_field_ids(FieldId, MappedValueList, HasId, IdIsSet, [])
			end,
			map_spm(Tail, IsModifier, Result ++ MappedIdValueList)
	end.

concat_field_ids(_FieldId, [], _HasId, _IdIsSet, Result) ->
	Result;
concat_field_ids(FieldId1, [FieldId2, FieldValue|Tail], false,  false, Result) ->
	FieldId = list_to_atom(atom_to_list(FieldId1) ++ "." ++ atom_to_list(FieldId2)),
	concat_field_ids(FieldId1, Tail, false, false, Result ++ [FieldId, FieldValue]);
concat_field_ids(FieldId1, [FieldId2, FieldValue|Tail], true,  IdIsSet, Result) ->
	FieldId2List = atom_to_list(FieldId2),
	case FieldId2List of
		"#type" ->
			FieldId = list_to_atom(atom_to_list(FieldId1) ++ ".#type"),
			concat_field_ids(FieldId1, Tail, true, IdIsSet, Result ++ [FieldId, FieldValue]);
		"_id" ++ IdTail ->
			FieldId = list_to_atom(atom_to_list(FieldId1) ++ ".#id" ++ IdTail),
			concat_field_ids(FieldId1, Tail, true, IdIsSet, Result ++ [FieldId, FieldValue]);
		_ ->
			true = IdIsSet,
			concat_field_ids(FieldId1, Tail, true, IdIsSet, Result)
	end.
