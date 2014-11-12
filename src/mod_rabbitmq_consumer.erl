%% coding: latin-1
%% RabbitMQ gateway module for ejabberd.
%% Based on ejabberd's mod_echo.erl
%%---------------------------------------------------------------------------
%% @author Tony Garnock-Jones <tonyg@lshift.net>
%% @author Rabbit Technologies Ltd. <info@rabbitmq.com>
%% @author LShift Ltd. <query@lshift.net>
%% @copyright 2008 Tony Garnock-Jones and Rabbit Technologies Ltd.; Copyright � 2008-2009 Tony Garnock-Jones and LShift Ltd.
%% @license
%%
%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License as
%% published by the Free Software Foundation; either version 2 of the
%% License, or (at your option) any later version.
%%
%% This program is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%% General Public License for more details.
%%                         
%% You should have received a copy of the GNU General Public License
%% along with this program; if not, write to the Free Software
%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%% 02111-1307 USA
%%---------------------------------------------------------------------------
%%
%% @doc RabbitMQ consumer module for ejabberd.
%%
%% All of the exposed functions of this module are private to the
%% implementation. See the <a
%% href="overview-summary.html">overview</a> page for more
%% information.

-module(mod_rabbitmq_consumer).
-behaviour(gen_server).

-compile(export_all).

% API
-export([start/4, stop/1,
		 start_link/4,
		 set_rabbitmq_node/2,
		 add_member/4,
		 remove_member/4]).

%% gen_server callbacks
-export([init/1, 
		 handle_call/3, 
		 handle_cast/2, 
		 handle_info/2, 
		 terminate/2, 
		 code_change/3]).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("rabbit.hrl").
-include("logger.hrl").

-record(state, { lserver, 
				 consumer_tag, 
				 queue, 
				 priorities,
				 server_host}).

start(Host, QNameBin, Server, RabbitNode) ->
	%TODO start_supervisor
	start_link(Host, QNameBin, Server, RabbitNode).

stop( Pid ) ->
	gen_server:call(Pid, stop).

start_link(Host, QNameBin, Server, RabbitNode) ->
    gen_server:start_link(?MODULE, [Host, QNameBin, Server, RabbitNode], []).

%%---------------------------------------------------------------------------

%%
%% gen_server callbacks
%%
init([Host, QNameBin, Server, RabbitNode]) ->
    ?INFO_MSG("**** starting consumer for queue ~p~n",[QNameBin]),
	put(rabbitmq_node, RabbitNode ),
	
    ConsumerTag = mod_rabbitmq_util:get_binstring_guid(),
	mod_rabbitmq_util:basic_consume( QNameBin, ConsumerTag ),

    {ok, #state{lserver = Server,
				consumer_tag = ConsumerTag,
				queue = QNameBin,
				priorities = [],
				server_host = Host}}.


handle_call(stop, _From, State) ->
	?DEBUG("consumer stop , state: ~p~n",[State]),
    {stop, normal, ok, State}.

handle_cast({rabbitmq_node_change, Node}, State) ->
	put(rabbitmq_node, Node),
	{noreply, State};

handle_cast({presence, JID, RKBin, Priority}, 
			#state{ priorities = Priorities} = State) ->	
	NewPriorities = lists:keysort(1, keystore({JID, RKBin}, 2, Priorities,
						      {-Priority, {JID, RKBin}})),
	?DEBUG("consumer new priorities: ~p ~n", [NewPriorities]),
	{noreply, State#state{priorities = NewPriorities}};

handle_cast({unavailable, JID, RKBin, AllResources},
			#state{ priorities = Priorities } = State) ->
	NewPriorities =
		case AllResources of
			true ->
				[E || E = {_, {J, _}} <- Priorities,
					  not jids_equal_upto_resource(J, JID)];
			false ->
				lists:keydelete({JID, RKBin}, 2, Priorities)
		end,
	case NewPriorities of
		[] ->
%% As the consumer is not in an supervisor tree, do not use shutdown 
%%			{stop, {shutdown, no_live_users}, State};
			{stop, normal, State};
		_ ->
			{noreply, State#state{priorities = NewPriorities}}
	end;

handle_cast({deliver, _ConsumerTag, false, {_QName, QPid, _Id, _Redelivered, Msg}}, 
			#state{ priorities = Priorities} = State) ->
	#basic_message{exchange_name = #resource{name = XNameBin},
				   routing_key = RKBin,
				   content = #content{payload_fragments_rev = PayloadRev}} = Msg,
	case Priorities of
		[] ->
			ok;		
		[{_, {TopPriorityJID, _}} | _] ->
			send_message(jlib:make_jid(binary_to_list(XNameBin),
									   State#state.lserver,
									   binary_to_list(RKBin)),
						 TopPriorityJID,
						 "chat",
						 binary_to_list(list_to_binary(lists:reverse(PayloadRev))))
	end,
	case mod_rabbitmq_util:call(rabbit_amqqueue, notify_sent, [QPid, self()]) of
		{error, Reason1} ->
			?ERROR_MSG("mod_rabbitmq_util:call error in ~p~n~p~n",
					   [consumer_main, Reason1]);
		R ->
			?DEBUG("mod_rabbitmq_util:call in ~p return ~p~n",
				   [consumer_main, R])
	end,
	{noreply, State};
	
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(Info, State) ->
	?WARNING_MSG("Consumer got unknown info: ~p ~n", [Info]),
    {noreply, State}.

terminate(Reason, 
		  #state{queue = QNameBin,
				 consumer_tag = ConsumerTag,
				 server_host = Host} = State) ->
	?DEBUG("terminate from ~p ~n reason ~p ~n", [State,Reason]),
	mod_rabbitmq_util:cancel_consume( QNameBin, ConsumerTag ),
	mod_rabbitmq:consumer_stopped(Host, QNameBin ),
    ok.

%% @hidden
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% API
set_rabbitmq_node(Pid, Node) ->
	gen_server:cast( Pid, {rabbitmq_node_change, Node}).

add_member( Pid, JID, RKBin, Priority ) ->
	gen_server:cast( Pid, {presence, JID, RKBin, Priority}).

remove_member( Pid, JID, RKBin, AllResources ) ->
	gen_server:cast( Pid, {unavailable, JID, RKBin, AllResources}).

%%
%% internal functions
%%

jids_equal_upto_resource(J1, J2) ->
    jlib:jid_remove_resource(J1) == jlib:jid_remove_resource(J2).

send_message(From, To, TypeStr, BodyStr) ->
    XmlBody = {xmlelement, "message",
	       [{"type", TypeStr},
		{"from", jlib:jid_to_string(From)},
		{"to", jlib:jid_to_string(To)}],
	       [{xmlelement, "body", [],
		 [{xmlcdata, BodyStr}]}]},
    ?DEBUG("Delivering ~p -> ~p~n~p", [From, To, XmlBody]),
    ejabberd_router:route(From, To, XmlBody).

%% implementation from R12B-0. When we drop support for R11B, we can
%% use the system's implementation.
keystore(Key, N, [H|T], New) when element(N, H) == Key ->
    [New|T];
keystore(Key, N, [H|T], New) ->
    [H|keystore(Key, N, T, New)];
keystore(_Key, _N, [], New) ->
    [New].
