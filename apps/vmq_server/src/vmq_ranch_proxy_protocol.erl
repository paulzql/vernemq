%% Copyright (c) 2015, heroku
%% All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without modification,
%% are permitted provided that the following conditions are met:
%%
%% 1. Redistributions of source code must retain the above copyright notice, this
%% list of conditions and the following disclaimer.
%%
%% 2. Redistributions in binary form must reproduce the above copyright notice,
%% this list of conditions and the following disclaimer in the documentation and/or
%% other materials provided with the distribution.
%%
%% 3. Neither the name of the copyright holder nor the names of its contributors
%% may be used to endorse or promote products derived from this software without
%% specific prior written permission.
%%
%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
%% ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
%% WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
%% IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
%% INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
%% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
%% DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
%% LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
%% OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
%% THE POSSIBILITY OF SUCH DAMAGE.
%%
%%% @doc Ranch protocol handling for the HA Proxy PROXY protocol [http://www.haproxy.org/download/1.5/doc/proxy-protocol.txt]
%%% @end
-module(vmq_ranch_proxy_protocol).
-behaviour(ranch_transport).

-export([name/0,
         secure/0,
         messages/0,
         accept/2,
         listen/1,
         accept_ack/2,
         connect/3,
         connect/4,
         recv/3,
         send/2,
         sendfile/2,
         sendfile/4,
         sendfile/5,
         setopts/2,
         controlling_process/2,
         peername/1,
         proxyname/1,
         sockname/1,
         shutdown/2,
         close/1,
         opts_from_socket/1,
         bearer_port/1,
         listen_port/1,
         match_port/1,
         connection_info/1,
         connection_info/2
        ]).

% Record manipulation
-export([get_csocket/1,
         set_csocket/2]).

-type opts() :: ranch_ssl:opts()|ranch_tcp:opts().
-record(proxy_socket, { lsocket :: inet:socket()|ssl:sslsocket()|'undefined',
                        csocket :: inet:socket()|ssl:sslsocket()|'undefined',
                        opts :: opts()|'undefined',
                        inet_version :: ipv4|ipv6|'undefined',
                        source_address :: inet:ip_address()|'undefined',
                        dest_address :: inet:ip_address()|'undefined',
                        source_port :: inet:port_number()|'undefined',
                        dest_port :: inet:port_number()|'undefined',
                        connection_info = []}).
-type proxy_opts() :: [{source_address, inet:ip_address()} |
                       {source_port, inet:port_number()} |
                       {dest_address, inet:ip_address()} |
                       {dest_port, inet:port_number()}].
-type proxy_protocol_info() :: {{inet:ip_address(), inet:port_number()},
                                {inet:ip_address(), inet:port_number()}}.
-opaque proxy_socket() :: #proxy_socket{}.

-export_type([proxy_opts/0,
              proxy_socket/0,
              proxy_protocol_info/0]).

-define(DEFAULT_PROXY_TIMEOUT, 10000).

%%% proxy2 defines
-define(HEADER, "\r\n\r\n\0\r\nQUIT\n").
-define(VSN, 16#02).

%% Protocol types
-define(AF_UNSPEC, 16#00).
-define(AF_INET, 16#01).
-define(AF_INET6, 16#02).
-define(AF_UNIX, 16#03).

%% Transfer types
-define(UNSPEC, 16#00).
-define(STREAM, 16#01).
-define(DGRAM, 16#02).

%% TLV types for additional headers
-define(PP2_TYPE_ALPN, 16#01).
-define(PP2_TYPE_AUTHORITY, 16#02).
-define(PP2_TYPE_SSL, 16#20).
-define(PP2_SUBTYPE_SSL_VERSION, 16#21).
-define(PP2_SUBTYPE_SSL_CN, 16#22).
-define(PP2_TYPE_NETNS, 16#30).

%% SSL Client fields
-define(PP2_CLIENT_SSL, 16#01).
-define(PP2_CLIENT_CERT_CONN, 16#02).
-define(PP2_CLIENT_CERT_SESS, 16#04).

%% Record manipulation API
-spec get_csocket(proxy_socket()) -> port().
get_csocket(#proxy_socket{csocket = CSocket}) ->
    CSocket.

-spec set_csocket(proxy_socket(), port()|ssl:sslsocket()) -> proxy_socket().
set_csocket(ProxySocket, NewCSocket) ->
    ProxySocket#proxy_socket{
      csocket = NewCSocket,
      connection_info=maybe_add_proxy_v2_info(
                        NewCSocket,
                        ProxySocket#proxy_socket.connection_info)
     }.

-spec maybe_add_proxy_v2_info(port()|ssl:sslsocket(), list()) -> list().
maybe_add_proxy_v2_info(CSocket, ConnectionInfo)
  when is_port(CSocket) ->
    ConnectionInfo;
maybe_add_proxy_v2_info(CSocket, ConnectionInfo) ->
    case
        ssl:connection_information(
          CSocket,
          [
           negotiated_protocol,
           protocol,
           sni_hostname,
           verify
          ]) of
        {ok, AdditionalInfo} ->
            ensure_binary_sni_hostname(AdditionalInfo)
                ++ ConnectionInfo;
        _ ->
            ConnectionInfo
    end.

%% This function could be adjusted in the future to handle other
%% transformations on the ssl:connection_information, in which case it
%% should probably be renamed
-spec ensure_binary_sni_hostname([proplists:property()]) ->
                                        [proplists:property()].
ensure_binary_sni_hostname([{sni_hostname, Hostname}|Props])
  when is_binary(Hostname) ->
    [{sni_hostname, Hostname}|ensure_binary_sni_hostname(Props)];
ensure_binary_sni_hostname([{sni_hostname, Hostname}|Props])
  when is_list(Hostname) ->
    [{sni_hostname, list_to_binary(Hostname)}
     |ensure_binary_sni_hostname(Props)];
ensure_binary_sni_hostname([{sni_hostname, undefined}|Props]) ->
    %% Call was made without SNI
    ensure_binary_sni_hostname(Props);
ensure_binary_sni_hostname([Head|Props]) ->
    [Head|ensure_binary_sni_hostname(Props)];
ensure_binary_sni_hostname([]) -> [].


-spec name() -> atom().
name() ->
    proxy_protocol_tcp.

-spec secure() -> boolean().
secure() ->
    false.

-spec messages() -> {OK::atom(), Closed::atom(), Error::atom()}.
messages() ->
    ranch_tcp:messages().

-spec listen(opts()) -> {ok, proxy_socket()} | {error, atom()}.
listen(Opts) ->
    case ranch_tcp:listen(Opts) of
        {ok, LSocket} ->
            {ok, #proxy_socket{lsocket   = LSocket,
                               opts      = Opts}};
        {error, Error} ->
            {error, Error}
    end.

-spec accept(proxy_socket(), timeout())
            -> {ok, proxy_socket()} | {error, closed | timeout |
                                       not_proxy_protocol |
                                       {timeout, proxy_handshake} | atom()}.
accept(#proxy_socket{lsocket = LSocket,
                                opts = Opts}, Timeout) ->
    Started = os:timestamp(),
    case ranch_tcp:accept(LSocket, Timeout) of
        {ok, CSocket} ->
            NextWait = get_next_timeout(Started, os:timestamp(), Timeout),
            ProxySocket = #proxy_socket{lsocket = LSocket,
                                        csocket = CSocket,
                                        opts = Opts},
            ok = setopts(ProxySocket, [{active, once}, {packet, line}]),
            receive
                {_, CSocket, <<"PROXY ", ProxyInfo/binary>>} ->
                    case parse_proxy_protocol_v1(ProxyInfo) of
                        {InetVersion, SourceAddress, DestAddress, SourcePort, DestPort} ->
                            reset_socket_opts(ProxySocket, Opts),
                            {ok, ProxySocket#proxy_socket{inet_version = InetVersion,
                                                          source_address = SourceAddress,
                                                          dest_address = DestAddress,
                                                          source_port = SourcePort,
                                                          dest_port = DestPort}};
                        unknown_peer ->
                            reset_socket_opts(ProxySocket, Opts),
                            {ok, ProxySocket};
                        not_proxy_protocol ->
                            close(ProxySocket),
                            {error, not_proxy_protocol}
                    end;
                {_, CSocket, <<"\r\n">>} ->
                    ok = setopts(ProxySocket, [{packet, raw}]),
                    {ok, ProxyHeader} = ranch_tcp:recv(CSocket, 14, 1000),
                    case parse_proxy_protocol_v2(<<"\r\n", ProxyHeader/binary>>) of
                        {proxy, ipv4, _Protocol, Length} ->
                            {ok, ProxyAddr} = ranch_tcp:recv(CSocket, Length, 1000),
                            case ProxyAddr of
                                <<SA1:8, SA2:8, SA3:8, SA4:8,
                                  DA1:8, DA2:8, DA3:8, DA4:8,
                                  SourcePort:16, DestPort:16, Rest/binary>> ->
                                    SourceAddress = {SA1, SA2, SA3, SA4},
                                    DestAddress = {DA1, DA2, DA3, DA4},
                                    ConnectionInfo = parse_tlv(Rest),
                                    {ok, ProxySocket#proxy_socket{inet_version = ipv4,
                                                                  source_address = SourceAddress,
                                                                  dest_address = DestAddress,
                                                                  source_port = SourcePort,
                                                                  dest_port = DestPort,
                                                                  connection_info=ConnectionInfo}};
                                _ ->
                                    close(ProxySocket),
                                    {error, not_proxy_protocol}
                            end;
                        _Unsupported ->
                            close(ProxySocket),
                            {error, not_supported_v2}
                    end;
                Other ->
                    close(ProxySocket),
                    {error, Other}
            after NextWait ->
                    close(ProxySocket),
                    {error, {timeout, proxy_handshake}}
            end;
        {error, Error} ->
            {error, Error}
    end.

-spec accept_ack(proxy_socket(), pos_integer()) -> ok.
accept_ack(#proxy_socket{csocket=CSocket}, Timeout) ->
    ranch_tcp:accept_ack(CSocket, Timeout).

-spec connect(inet:ip_address() | inet:hostname(),
              inet:port_number(), any())
             -> {ok, proxy_socket()} | {error, atom()}.
connect(Host, Port, Opts) when is_integer(Port) ->
    connect(Host, Port, Opts, []).

-spec connect(inet:ip_address() | inet:hostname(),
              inet:port_number(), any(), proxy_opts())
             -> {ok, proxy_socket()} | {error, atom()}.
connect(Host, Port, Opts, ProxyOpts) when is_integer(Port) ->
    case ranch_tcp:connect(Host, Port, Opts) of
        {ok, Socket} ->
            ProxySocket = #proxy_socket{csocket = Socket},
            SourceAddress = proplists:get_value(source_address, ProxyOpts),
            DestAddress = proplists:get_value(dest_address, ProxyOpts),
            SourcePort = proplists:get_value(source_port, ProxyOpts),
            DestPort = proplists:get_value(dest_port, ProxyOpts),
            {ok, ProxyHeader} = create_proxy_protocol_header(SourceAddress, DestAddress,
                                                             SourcePort, DestPort),
            ranch_tcp:send(Socket, ProxyHeader),
            {ok, ProxySocket#proxy_socket{source_address = SourceAddress,
                                          dest_address = DestAddress,
                                          source_port = SourcePort,
                                          dest_port = DestPort}};
        {error, Error} ->
            io:format("Timeout"),
            {error, Error}
    end.

-spec recv(proxy_socket(), non_neg_integer(), timeout()) ->
                  {ok, any()} | {error, closed | atom()}.
recv(#proxy_socket{csocket=Socket}, Length, Timeout) ->
    ranch_tcp:recv(Socket, Length, Timeout).

-spec send(proxy_socket(), iodata()) -> ok | {error, atom()}.
send(#proxy_socket{csocket=Socket}, Packet) ->
    ranch_tcp:send(Socket, Packet).

-spec sendfile(proxy_socket(), file:name_all())
              -> {ok, non_neg_integer()} | {error, atom()}.
sendfile(Socket, Filename) ->
    sendfile(Socket, Filename, 0, 0, []).

-spec sendfile(proxy_socket(), file:name_all() | file:fd(), non_neg_integer(),
               non_neg_integer())
              -> {ok, non_neg_integer()} | {error, atom()}.
sendfile(Socket, File, Offset, Bytes) ->
    sendfile(Socket, File, Offset, Bytes, []).

-spec sendfile(proxy_socket(), file:name_all() | file:fd(),
               non_neg_integer(), non_neg_integer(),
               [{chunk_size, non_neg_integer()}]) ->
                      {ok, non_neg_integer()} | {error, atom()}.
sendfile(#proxy_socket{csocket=Socket}, Filename, Offset, Bytes, Opts) ->
    ranch_tcp:sendfile(Socket, Filename, Offset, Bytes, Opts).

-spec setopts(proxy_socket(), list()) -> ok | {error, atom()}.
setopts(#proxy_socket{csocket=Socket}, Opts) ->
    ranch_tcp:setopts(Socket, Opts).

-spec controlling_process(proxy_socket(), pid()) ->
                                 ok | {error, closed | not_owner | atom()}.
controlling_process(#proxy_socket{csocket=Socket}, Pid) ->
    ranch_tcp:controlling_process(Socket, Pid).

-spec peername(proxy_socket()) ->
                      {ok, {inet:ip_address(), inet:port_number()}} |
                      {error, atom()}.
peername(#proxy_socket{csocket=Socket}) ->
    ranch_tcp:peername(Socket).

-spec proxyname(proxy_socket()) ->
                       {ok, proxy_protocol_info()}.
proxyname(#proxy_socket{source_address = SourceAddress,
                          dest_address = DestAddress,
                          source_port = SourcePort,
                          dest_port = DestPort}) ->
    {ok, {{SourceAddress, SourcePort}, {DestAddress, DestPort}}}.

-spec sockname(proxy_socket()) ->
                      {ok, {inet:ip_address(), inet:port_number()}} |
                      {error, atom()}.
sockname(#proxy_socket{lsocket = Socket}) ->
    ranch_tcp:sockname(Socket).

-spec connection_info(proxy_socket()) -> {ok, list()}.
connection_info(#proxy_socket{connection_info=ConnectionInfo}) ->
    {ok, ConnectionInfo}.

-spec connection_info(proxy_socket(), [protocol | cipher_suite | sni_hostname]) -> {ok, list()}.
connection_info(#proxy_socket{connection_info=ConnectionInfo}, Items) ->
    {ok, [V || Key <- Items, (V = proplists:lookup(Key, ConnectionInfo)) =/= none]}.

-spec shutdown(proxy_socket(), read|write|read_write) ->
                      ok | {error, atom()}.
shutdown(#proxy_socket{csocket=Socket}, How) ->
    ranch_tcp:shutdown(Socket, How).

-spec close(proxy_socket()) -> ok.
close(#proxy_socket{csocket=Socket}) ->
    ranch_tcp:close(Socket).

-spec opts_from_socket(proxy_socket()) ->
                              ranch_proxy_protocol:proxy_opts().
opts_from_socket(Socket) ->
    case {source_from_socket(Socket),
          dest_from_socket(Socket)} of
        {{ok, Src}, {ok, Dst}} ->
            {ok, Src ++ Dst};
        {{error, _} = Err, _} -> Err;
        {_, {error, _} = Err} -> Err
    end.

-spec bearer_port(proxy_socket()) -> port().
bearer_port(#proxy_socket{csocket = Port}) ->
    Port.

-spec listen_port(proxy_socket()) -> port().
listen_port(#proxy_socket{lsocket = Port}) ->
    Port.

-spec match_port(proxy_socket()) -> port().
match_port(Socket) -> bearer_port(Socket).

%% Internal
create_proxy_protocol_header(SourceAddress, DestAddress, SourcePort, DestPort)
  when is_tuple(SourceAddress), is_tuple(DestAddress), is_integer(SourcePort),
       is_integer(DestPort) ->
    Proto = get_protocol(SourceAddress, DestAddress),
    SourceAddressStr = inet_parse:ntoa(SourceAddress),
    DestAddressStr = inet_parse:ntoa(DestAddress),
    SourcePortString = integer_to_list(SourcePort),
    DestPortString = integer_to_list(DestPort),
    create_proxy_protocol_header(Proto, SourceAddressStr, DestAddressStr,
                                 SourcePortString, DestPortString).

create_proxy_protocol_header(ipv4, SourceAddress, DestAddress, SourcePort,
                             DestPort) ->
    {ok, io_lib:format("PROXY TCP4 ~s ~s ~s ~s\r\n",
                       [SourceAddress, DestAddress, SourcePort, DestPort])};
create_proxy_protocol_header(ipv6, SourceAddress, DestAddress, SourcePort,
                             DestPort) ->
    {ok, io_lib:format("PROXY TCP6 ~s ~s ~s ~s\r\n",
                       [SourceAddress, DestAddress, SourcePort, DestPort])}.

get_protocol(SourceAddress, DestAddress) when tuple_size(SourceAddress) =:= 8,
                                              tuple_size(DestAddress) =:= 8 ->
    ipv6;
get_protocol(SourceAddress, DestAddress) when tuple_size(SourceAddress) =:= 4,
                                              tuple_size(DestAddress) =:= 4 ->
    ipv4.

parse_proxy_protocol_v1(<<"TCP", Proto:1/binary, _:1/binary, Info/binary>>) ->
    InfoStr = binary_to_list(Info),
    case string:tokens(InfoStr, " \r\n") of
        [SourceAddress, DestAddress, SourcePort, DestPort] ->
            case {parse_inet(Proto), parse_ips([SourceAddress, DestAddress], []),
                  parse_ports([SourcePort, DestPort], [])} of
                {ProtoParsed, [SourceInetAddress, DestInetAddress], [SourceInetPort, DestInetPort]} ->
                    {ProtoParsed, SourceInetAddress, DestInetAddress, SourceInetPort, DestInetPort};
                _ ->
                    malformed_proxy_protocol
            end
    end;
parse_proxy_protocol_v1(<<"UNKNOWN", _/binary>>) ->
    unknown_peer;
parse_proxy_protocol_v1(_) ->
    not_proxy_protocol.

%% first 4 bits are the version of the protocole, must be '2'
%% next 4 bits represent whether it is a local or a proxy connection;
%% 4 next bit sare for the family (inet,inet6,or unix)
%% and 4 bits for protocol (stream / dgram, where inet+stream = tcp, for example)
%% and 1 full byte for the length of information regarding addresses and SSL (if any)
%%
%% 0  1  2  3  4  5  6  7  8  9  10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 ....
%% | version   |proxy/local|  inet[6]  |  TCP/UDP  | lenght of information  | info
%%
parse_proxy_protocol_v2(<<?HEADER, (?VSN):4, 0:4, X:4, Y:4, Len:16>>) ->
    {local, family(X), protocol(Y), Len};
parse_proxy_protocol_v2(<<?HEADER, (?VSN):4, 1:4, X:4, Y:4, Len:16>>) ->
    {proxy, family(X), protocol(Y), Len};
parse_proxy_protocol_v2(_) ->
    not_proxy_protocol.

parse_tlv(Rest) ->
    parse_tlv(Rest, []).

parse_tlv(<<>>, Result) ->
    Result;
parse_tlv(<<Type:8, Len:16, Value:Len/binary, Rest/binary>>, Result) ->
    case pp2_type(Type) of
        ssl ->
            parse_tlv(Rest, pp2_value(Type, Value) ++ Result);
        TypeName ->
            parse_tlv(Rest, [{TypeName, Value} | Result])
    end;
parse_tlv(_, _) ->
    {error, parse_tlv}.

pp2_type(?PP2_TYPE_ALPN) ->
    negotiated_protocol;
pp2_type(?PP2_TYPE_AUTHORITY) ->
    authority;
pp2_type(?PP2_TYPE_SSL) ->
    ssl;
pp2_type(?PP2_SUBTYPE_SSL_VERSION) ->
    protocol;
pp2_type(?PP2_SUBTYPE_SSL_CN) ->
    sni_hostname;
pp2_type(?PP2_TYPE_NETNS) ->
    netns;
pp2_type(_) ->
    invalid_pp2_type.

pp2_value(?PP2_TYPE_SSL, <<Client:1/binary, _:32, Rest/binary>>) ->
    case pp2_client(Client) of % validates bitfield format, but ignores data
        invalid_client ->
            [];
        _ ->
            %% Fetches TLV values attached, regardless of if the client
            %% specified SSL. If this is a problem, then we should fix,
            %% but in any case the blame appears to be on the sender
            %% who is giving us broken headers.
            parse_tlv(Rest)
    end;
pp2_value(_, Value) ->
    Value.

pp2_client(<<0:5,             % UNASSIGNED
             _ClientCert:1,   % PP2_CLIENT_CERT_SESS
             _ClientCert:1,   % PP2_CLIENT_CERT_CONN
             _ClientSSL:1>>) ->
    client_ssl;
pp2_client(_) ->
    invalid_client.

family(?AF_UNSPEC) ->
    af_unspec;
family(?AF_INET) ->
    ipv4;
family(?AF_INET6) ->
    ipv6;
family(?AF_UNIX) ->
    af_unix;
family(_) ->
    {error, invalid_address_family}.

protocol(?UNSPEC) ->
    unspec;
protocol(?STREAM) ->
    stream;
protocol(?DGRAM) ->
    dgram;
protocol(_) ->
    {error, invalid_protocol}.

parse_inet(<<"4">>) ->
    ipv4;
parse_inet(<<"6">>) ->
    ipv6;
parse_inet(_) ->
    {error, invalid_inet_version}.

parse_ports([], Retval) ->
    Retval;
parse_ports([Port|Ports], Retval) ->
    try list_to_integer(Port) of
        IntPort ->
            parse_ports(Ports, Retval++[IntPort])
    catch
        error:badarg ->
            {error, invalid_port}
    end.

parse_ips([], Retval) ->
    Retval;
parse_ips([Ip|Ips], Retval) ->
    case inet:parse_address(Ip) of
        {ok, ParsedIp} ->
            parse_ips(Ips, Retval++[ParsedIp]);
        _ ->
            {error, invalid_address}
    end.

reset_socket_opts(ProxySocket, Opts) ->
    Opts2 = ranch:filter_options(Opts, [active,buffer,delay_send,deliver,dontroute,
                                        exit_on_close,header,high_msgq_watermark,
                                        high_watermark,keepalive,linger,low_msgq_watermark,
                                        low_watermark,mode,nodelay,packet,packet_size,priority,
                                        recbuf,reuseaddr,send_timeout,send_timeout_close,sndbuf,tos],
                                 [binary, {active, false}, {packet, raw},
                                  {reuseaddr, true}, {nodelay, true}]),
    setopts(ProxySocket, Opts2).

get_next_timeout(_, _, infinity) ->
    %% Never leave `infinity' in place. This may be valid for socket
    %% accepts, but is fairly dangrous and risks causing lockups when
    %% the data over the socket is bad or invalid.
    ?DEFAULT_PROXY_TIMEOUT;
get_next_timeout(T1, T2, Timeout) ->
    TimeUsed = round(timer:now_diff(T2, T1) / 1000),
    erlang:max(?DEFAULT_PROXY_TIMEOUT, Timeout - TimeUsed).

source_from_socket(Socket) ->
    case ranch_tcp:peername(Socket) of
        {ok, {Addr, Port}} ->
            {ok, [{source_address, Addr},
                  {source_port, Port}]};
        Err -> Err
    end.

dest_from_socket(Socket) ->
    case ranch_tcp:sockname(Socket) of
        {ok, {Addr, Port}} ->
            {ok, [{dest_address, Addr},
                  {dest_port, Port}]};
        Err -> Err
    end.
