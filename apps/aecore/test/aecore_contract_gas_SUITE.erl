-module(aecore_contract_gas_SUITE).

%% This code is brutaly copied form aecore_sync_SUITE and should use joined code base.

%% common_test exports
-export(
   [
    all/0,
    init_per_suite/1, end_per_suite/1,
    init_per_testcase/2, end_per_testcase/2
   ]).

%% test case exports
-export(
   [ gas/1
   ]).


-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [ gas
    ].

init_per_suite(Config) ->
    ok = application:ensure_started(erlexec),
    DataDir = ?config(data_dir, Config),
    TopDir = aecore_suite_utils:top_dir(DataDir),
    MicroBlockCycle = 3000,
    Config1 = [{symlink_name, "latest.contract_gas"},
               {top_dir, TopDir},
               {test_module, ?MODULE},
               {micro_block_cycle, MicroBlockCycle}] ++ Config,
    aecore_suite_utils:make_shortcut(Config1),
    ct:log("Environment = ~p", [[{args, init:get_arguments()},
                                 {node, node()},
                                 {cookie, erlang:get_cookie()}]]),
    DefCfg = #{
        <<"chain">> => #{
            <<"persist">> => false
        },
        <<"mining">> => #{
            <<"expected_mine_rate">> => 180000,
            <<"micro_block_cycle">> => MicroBlockCycle,
            <<"cuckoo">> =>
               #{ 
                  <<"miner">> => 
                      #{ <<"executable">> => <<"mean28s-generic">>,
                         <<"extra_args">> => <<"">>,
                         <<"node_bits">> => 28} 
                }
          }
    },
    aecore_suite_utils:create_configs(Config1, DefCfg),
    aecore_suite_utils:make_multi(Config1),
    [{nodes, [aecore_suite_utils:node_tuple(dev1),
              aecore_suite_utils:node_tuple(dev2)]} | Config1].

end_per_suite(_Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    ct:log("testcase pid: ~p", [self()]),
    [{tc_start, os:timestamp()}|Config].

end_per_testcase(_Case, Config) ->
    %% Ts0 = ?config(tc_start, Config),
    %% ct:log("Events during TC: ~p", [[{N, aecore_suite_utils:all_events_since(N, Ts0)}
    %%                                  || {_,N} <- ?config(nodes, Config)]]),
    ct:log("Explored ~p", [explorer(aecore_suite_utils:node_name(dev1), 0)]),
    aecore_suite_utils:stop_node(dev1, Config),
    aecore_suite_utils:stop_node(dev2, Config),
    ok.

%% ============================================================
%% Test cases
%% ============================================================
gas(Config) ->
    aecore_suite_utils:start_node(dev1, Config),
    N1 = aecore_suite_utils:node_name(dev1),
    aecore_suite_utils:connect(N1),

    %% do we have covernance for contract create tx and contract call tx?
    TxsPerMB = aec_governance:block_gas_limit() div (aec_governance:tx_gas() + contract_gas()),
    ct:log("We can put ~p Txs in a micro block\n", [TxsPerMB]),

    Code     = compile_contract("contracts/identity.aes"),
    CallData = aect_sophia:create_call(Code, <<"init">>, <<"()">>),

    %% Add a bunch of transactions...
    R1 = add_create_contract_txs(N1, Code, CallData, 4000, 1),
    {Txs1, ContractIds} = lists:unzip(R1),
    ExpectedMBs1 = (length(Txs1) div TxsPerMB) + 1,
    ct:log("filled pool with ~p created contracts\n", [length(Txs1)]),

    %% Mine a block with as many Txs as possible
    %% Since we mine on top speed, we may change leader to ourself a number of times, creating more keyblocks than 
    %% probably expected.
    {ok, _} = aecore_suite_utils:mine_blocks_until_txs_on_chain(N1, [lists:last(Txs1)], round(ExpectedMBs1 * 1.2) + 5),

    Txs2 = add_spend_txs(N1, <<"good stuff">>, 4000,  length(Txs1) + 1),

    ExpectedMBs2 = (length(Txs2) div TxsPerMB) + 1,
    ct:log("filled pool with ~p transactions and rubish\n", [length(Txs2)]), 

    %% Mine a block with as many Txs as possible
    %% Since we mine on top speed, we may change leader to ourself a number of times, creating more keyblocks than 
    %% probably expected.
    {ok, _} = aecore_suite_utils:mine_blocks_until_txs_on_chain(N1, [lists:last(Txs2)], round(ExpectedMBs2 * 1.2) + 5),
    ct:log("Explored ~p", [explorer(N1, 0)]),

    Top = aec_blocks:height(rpc:call(N1, aec_chain, top_block, [])),
    ct:log("Top reached ~p", [Top]),

    aecore_suite_utils:start_node(dev2, Config),
    N2 = aecore_suite_utils:node_name(dev2),
    aecore_suite_utils:connect(N2),
    ct:log("Times measured ~p", [ aecore_suite_utils:times_in_epoch_log(dev1, Config, "building micro block")]),

    aecore_suite_utils:wait_for_height(N2, min(Top-1, 100)),

    timer:sleep(5000), %% Give lager time to write everything to file
    ct:log("Times measured ~p", [ aecore_suite_utils:times_in_epoch_log(dev2, Config, "sync generation")]),
    
    ok.


explorer(Node, N) ->
    case rpc:call(Node, aec_chain, get_generation_by_height, [N, forward]) of
        error -> %% end of chain reached
            [];
        {ok, #{micro_blocks := MBs}} ->
            [{N, [ {txs,  length(aec_blocks:txs(MB))} || MB <- MBs]} | explorer(Node, N + 1)]
    end.

pool_peek(Node) ->
    rpc:call(Node, sys, get_status, [aec_tx_pool_gc]),
    rpc:call(Node, aec_tx_pool, peek, [infinity]).


add_spend_txs(Node, Payload, N, NonceStart) ->
    From = patron(),
    To = new_pubkey(),
    [ add_spend_tx(Node, Payload, Nonce, From, To) || Nonce <- lists:seq(NonceStart, NonceStart + N - 1) ].

add_rubish_txs(Node, Payload, N, NonceStart) ->
    From = non_account(),
    To = new_pubkey(),
    [ add_spend_tx(Node, Payload, Nonce, From, To) || Nonce <- lists:seq(NonceStart, NonceStart + N - 1) ].


add_spend_tx(Node, Payload, Nonce, Sender, Recipient) ->
    SenderId = aec_id:create(account, maps:get(pubkey, Sender)),
    RecipientId = aec_id:create(account, Recipient),
    Params = #{ sender_id    => SenderId,
                recipient_id => RecipientId,
                amount       => 10,
                nonce        => Nonce,
                ttl          => 10000,
                payload      => Payload,
                fee          => 1 },
    {ok, Tx} = aec_spend_tx:new(Params),
    STx = aec_test_utils:sign_tx(Tx, maps:get(privkey, Sender)),
    ok = rpc:call(Node, aec_tx_pool, push, [STx]),
    aec_base58c:encode(tx_hash, aetx_sign:hash(STx)).


add_create_contract_txs(Node, Code, CallData, N, NonceStart) ->
    [create_contract_tx(Node, Code, CallData, Nonce) || Nonce <- lists:seq(NonceStart, NonceStart + N - 1) ]. 

contract_gas() ->
    200.

create_contract_tx(Node, Code, CallData, Nonce) ->
    OwnerKey = maps:get(pubkey, patron()),
    Owner    = aec_id:create(account, OwnerKey),
    {ok, CreateTx} = aect_create_tx:new(#{ nonce      => Nonce
                                         , vm_version => 1
                                         , code       => Code
                                         , call_data  => CallData
                                         , fee        => 1
                                         , deposit    => 0
                                         , amount     => 0
                                         , gas        => contract_gas()
                                         , owner_id   => Owner
                                         , gas_price  => 1
                                         , ttl        => 10000
                                         }),
    CTx = aec_test_utils:sign_tx(CreateTx, maps:get(privkey, patron())),
    ok = rpc:call(Node, aec_tx_pool, push, [CTx]),
    ContractKey = aect_contracts:compute_contract_pubkey(OwnerKey, Nonce),
    {aec_base58c:encode(tx_hash, aetx_sign:hash(CTx)), ContractKey}.

compile_contract(File) ->
    CodeDir = code:lib_dir(aesophia, test),
    FileName = filename:join(CodeDir, File),
    {ok, ContractBin} = file:read_file(FileName),
    Contract = binary_to_list(ContractBin),
    aeso_compiler:from_string(Contract, [pp_icode]).

call_contract_tx(Node, Contract, Function, Args, Fee, Nonce, TTL) ->
    Caller       = aec_id:create(account, maps:get(pubkey, patron())),
    ContractID   = aec_id:create(contract, Contract),
    CallData     = aeso_abi:create_calldata(<<>>, Function, Args),
    {ok, CallTx} = aect_call_tx:new(#{ nonce       => Nonce
                                     , caller_id   => Caller
                                     , vm_version  => 1
                                     , contract_id => ContractID
                                     , fee         => Fee
                                     , amount      => 0
                                     , gas         => contract_gas()
                                     , gas_price   => 1
                                     , call_data   => CallData
                                     , ttl         => TTL
                                     }),
    CTx = aec_test_utils:sign_tx(CallTx, maps:get(privkey, patron())),
    Res = rpc:call(Node, aec_tx_pool, push, [CTx]),
    {Res, aec_base58c:encode(tx_hash, aetx_sign:hash(CTx))}.


new_pubkey() ->
    #{ public := PubKey } = enacl:sign_keypair(),
    PubKey.

patron() ->
    #{ pubkey  => <<206,167,173,228,112,201,249,157,157,78,64,8,128,168,111,29,
                    73,187,68,75,98,241,26,158,187,100,187,207,235,115,254,243>>,
       privkey => <<230,169,29,99,60,119,207,87,113,50,157,51,84,179,188,239,27,
                    197,224,50,196,61,112,182,211,90,249,35,206,30,183,77,206,
                    167,173,228,112,201,249,157,157,78,64,8,128,168,111,29,73,
                    187,68,75,98,241,26,158,187,100,187,207,235,115,254,243>>
      }.

non_account() ->
    #{pubkey =>
          <<245,117,28,204,233,37,91,2,247,242,140,89,185,168,83,60,109,
            125,224,23,116,211,150,217,205,229,42,242,190,168,90,109>>,
      privkey =>
          <<180,144,213,108,181,223,64,163,220,110,3,123,103,236,114,
            170,252,183,1,170,180,107,23,233,227,107,33,224,205,231,144,
            34,245,117,28,204,233,37,91,2,247,242,140,89,185,168,83,60,
            109,125,224,23,116,211,150,217,205,229,42,242,190,168,90,109>>}.


