module swim_contract::swim_game {

    use sui::random::{Self, Random, new_generator};
    use sui::balance::{Self, Balance};
    use sui::clock::{Clock, timestamp_ms};
    use sui::coin::{Self, Coin};
    use sui::dynamic_field as df;
    use sui::event;
    use sui::object::{Self, ID, UID};
    use sui::pay;
    use sui::table;
    use sui::table::Table;
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    /// Error
    const E_DURATION_INVALID: u64 = 1001;
    const E_LANE_INVALID: u64 = 1101;
    const E_BET_RANGE_INVALID: u64 = 2000;
    const E_BET_TIME_INVALID: u64 = 2001;
    const E_SWIM_ID_INVALID: u64 = 2102;
    const E_END_TIME_INVALID: u64 = 2101;
    const E_ROUND_NOT_END: u64 = 2200;
    const E_BALANCE_INVALID: u64 = 2300;
    const E_BALANCE_NOT_ENOUGH: u64 = 2311;
    const E_ROUND_EXIST: u64 = 2400;
    const E_TOKEN_LOCKED: u64 = 3000;
    const E_REWARD_CLAIMED: u64 = 3400;
    const E_USER_NOT_MATCH: u64 = 4004;
    const E_SYSTEM_DISABLE: u64 = 4040;

    // 7 days
    const TOKEN_LOCK: u64 = 604800000;

    const MULTIPLIER: u64 = 10000;

    struct AdminCap has key {
        id: UID
    }

    struct Registry has key {
        id: UID,
        rounds: Table<u64, address>,
    }

    struct Vault<phantom CoinType> has key {
        id: UID,
        token_reserved: Balance<CoinType>,
        enable: bool
    }

    struct Round has key {
        id: UID
    }

    struct Player has store, copy, drop {
        amount: u64,
        swim_id: u8,
        claimed: bool,
        user_address: address
    }

    struct RoundStateKey has drop, copy, store {}

    struct RoundState has store {
        index: u64,
        start_time: u64,
        bet_duration: u64,
        last_updated: u64,
        win_id: u8,
        min_bet: u64,
        max_bet: u64,
        multiplier: u64,
        total_bet_amount: u64,
        max_lane: u8,
        predict_index: u64,
        players: Table<u64, Player>,
    }

    /// Events
    struct InitEvent has copy, drop {
        sender: address,
        // global_paulse_status_id: ID
    }

    struct RoundCreated has copy, drop {
        round_id: ID,
        index: u64,
        start_time: u64,
        bet_duration: u64,
        last_updated: u64,
        win_id: u8,
        min_bet: u64,
        max_bet: u64,
        max_lane: u8,
        multiplier: u64,
    }

    struct BetCreated has copy, drop {
        round_id: ID,
        created_time: u64,
        user_address: address,
        bet_value: u64,
        total_bet_value: u64,
        swim_id: u8,
        predict_index: u64,
    }

    struct RoundEnd has copy, drop {
        round_id: ID,
        end_time: u64,
        win_id: u8
    }

    struct ClaimReward has copy, drop {
        round_id: ID,
        user_address: address,
        amount: u64,
        predict_index: u64
    }

    struct Withdrawal has copy, drop {
        round_id: ID,
        user_address: address,
        amount: u64,
        predict_index: u64
    }

    fun init(ctx: &mut TxContext) {
        transfer::transfer(
            AdminCap {
                id: object::new(ctx)
            },
            tx_context::sender(ctx)
        );

        transfer::transfer(
            Registry {
                id: object::new(ctx),
                rounds: table::new(ctx),
            },
            tx_context::sender(ctx)
        );

        // let id = new_global_pause_status_and_shared(ctx);
        event::emit(InitEvent {
            sender: tx_context::sender(ctx),
            // global_paulse_status_id: id
        });
    }

    public entry fun setupVault<CoinType>(_adminCap: &mut AdminCap, ctx: &mut TxContext
    ) {
        transfer::share_object(
            Vault<CoinType> {
                id: object::new(ctx),
                token_reserved: balance::zero<CoinType>(),
                enable: true
            }
        );
    }

    public entry fun deposit_coin_to_vault<CoinType>(
        vault: &mut Vault<CoinType>,
        coin: Coin<CoinType>,
        _ctx: &mut TxContext
    ) {
        deposit_coin(vault, coin);
    }

    fun deposit_coin<CoinType>(vault: &mut Vault<CoinType>, coin: Coin<CoinType>) {
        let deposit_balance = coin::into_balance(coin);
        balance::join(&mut vault.token_reserved, deposit_balance);
    }

    public entry fun create_round(
        registry: &mut Registry,
        round_index: u64,
        start_time: u64,
        bet_duration: u64,
        min_bet: u64,
        max_bet: u64,
        max_lane: u8,
        multiplier: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let curr_time = timestamp_ms(clock);
        // assert!(curr_time < start_time, E_STARTTIME_INVALID);
        assert!(bet_duration > 0, E_DURATION_INVALID);
        assert!(min_bet < max_bet, E_BET_RANGE_INVALID);
        assert!(max_lane > 0, E_LANE_INVALID);
        assert!(!table::contains(&registry.rounds, round_index), E_ROUND_EXIST);

        let round_state = RoundState {
            index: round_index,
            start_time,
            bet_duration,
            last_updated: curr_time,
            win_id: 0,
            min_bet,
            max_bet,
            max_lane,
            multiplier,
            total_bet_amount: 0,
            predict_index: 0,
            players: table::new(ctx),
        };

        let round = Round {
            id: object::new(ctx)
        };

        let round_id = object::id(&round);

        let round_address = object::uid_to_address(&round.id);

        df::add(&mut round.id, RoundStateKey {}, round_state);

        table::add(&mut registry.rounds, round_index, round_address);

        event::emit(RoundCreated {
            round_id,
            index: round_index,
            start_time,
            bet_duration,
            last_updated: curr_time,
            win_id: 0,
            min_bet,
            max_bet,
            max_lane,
            multiplier
        });

        transfer::share_object(round);
    }


    public entry fun bet<CoinType>(
        vault: &mut Vault<CoinType>,
        round: &mut Round,
        coin_bet: Coin<CoinType>,
        swim_id: u8,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let round_state = round_state_mut(round);
        let curr_time = timestamp_ms(clock);

        assert!(vault.enable, E_SYSTEM_DISABLE);
        assert!(swim_id > 0, E_SWIM_ID_INVALID);
        assert!(round_state.start_time + round_state.bet_duration > curr_time, E_BET_TIME_INVALID);

        let predict_index = round_state.predict_index + 1;
        round_state.predict_index = predict_index;

        let depositValue = coin::value(&coin_bet);
        let user_address = tx_context::sender(ctx);

        let player = Player {
            amount: depositValue,
            swim_id,
            claimed: false,
            user_address
        };

        assert!(player.amount >= round_state.min_bet && player.amount <= round_state.max_bet, E_BET_RANGE_INVALID);

        deposit_coin(vault, coin_bet);

        round_state.total_bet_amount = round_state.total_bet_amount + depositValue;

        update_round_player(round_state, predict_index, player);

        event::emit(BetCreated {
            round_id: object::id(round),
            created_time: curr_time,
            user_address,
            bet_value: depositValue,
            total_bet_value: player.amount,
            swim_id,
            predict_index
        });
    }

    #[allow(lint(public_random))]
    public entry fun end_round(
        _registry: &mut Registry,
        round: &mut Round,
        random_obj: &Random,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let round_state = round_state_mut(round);
        let curr_time = timestamp_ms(clock);

        assert!(round_state.start_time + round_state.bet_duration < curr_time, E_END_TIME_INVALID);

        let generator = new_generator(random_obj, ctx);
        let win_id = random::generate_u8_in_range(&mut generator, 1, round_state.max_lane);

        round_state.last_updated = curr_time;
        round_state.win_id = win_id;

        event::emit(RoundEnd {
            round_id: object::id(round),
            end_time: curr_time,
            win_id
        });
    }

    public entry fun claim_coin<CoinType>(
        vault: &mut Vault<CoinType>,
        round: &mut Round,
        predict_index: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(vault.enable, E_SYSTEM_DISABLE);

        let user_address = tx_context::sender(ctx);
        let round_id = object::id(round);
        let round_state = round_state_mut(round);
        let curr_time = timestamp_ms(clock);

        assert!(round_state.win_id > 0, E_ROUND_NOT_END);
        let player = table::borrow_mut(&mut round_state.players, predict_index);

        assert!(player.user_address == user_address, E_USER_NOT_MATCH);
        assert!(!player.claimed, E_REWARD_CLAIMED);
        player.claimed = true;

        if (player.swim_id == round_state.win_id) {
            // winner
            let reward = round_state.multiplier * player.amount / MULTIPLIER;
            assert!(reward > 0, E_BALANCE_INVALID);
            assert!(balance::value(&vault.token_reserved) >= reward, E_BALANCE_NOT_ENOUGH);
            let reward_balance = balance::split(&mut vault.token_reserved, reward);
            pay::keep(coin::from_balance(reward_balance, ctx), ctx);

            event::emit(ClaimReward {
                round_id,
                user_address,
                amount: reward,
                predict_index
            });
        } else {
            // loser
            assert!(round_state.last_updated + TOKEN_LOCK <= curr_time, E_TOKEN_LOCKED);
            assert!(player.amount > 0, E_BALANCE_INVALID);
            assert!(balance::value(&vault.token_reserved) >= player.amount, E_BALANCE_NOT_ENOUGH);
            let withdrawal = balance::split(&mut vault.token_reserved, player.amount);
            pay::keep(coin::from_balance(withdrawal, ctx), ctx);

            event::emit(Withdrawal {
                round_id,
                user_address,
                amount: player.amount,
                predict_index
            });
        };
    }

    public entry fun transfer_registry(
        registry: Registry,
        user_address: address,
        _ctx: &mut TxContext
    ) {
        transfer::transfer(registry, user_address);
    }

    public entry fun transfer_admin(admin_cap: AdminCap, user_address: address, _ctx: &mut TxContext) {
        transfer::transfer(admin_cap, user_address);
    }

    fun update_round_player(round: &mut RoundState, predict_index: u64, player: Player) {
        if (table::contains(&round.players, predict_index)) {
            table::remove(&mut round.players, predict_index);
            table::add(&mut round.players, predict_index, player);
        } else {
            table::add(&mut round.players, predict_index, player);
        }
    }

    fun round_state(round: &Round): &RoundState {
        df::borrow(&round.id, RoundStateKey {})
    }

    fun round_state_mut(round: &mut Round): &mut RoundState {
        df::borrow_mut(&mut round.id, RoundStateKey {})
    }

    public fun get_round_address(registry: &Registry, round_index: u64): address {
        *table::borrow(&registry.rounds, round_index)
    }

    public fun get_round_detail(round: &Round): &RoundState {
        round_state(round)
    }

    public fun get_round_win_id(round: &Round): u8 {
        round_state(round).win_id
    }

    public fun get_round_total_bet(round: &Round): u64 {
        round_state(round).total_bet_amount
    }

    public fun get_round_index(round: &Round): u64 {
        round_state(round).index
    }

    public fun get_system_enable<CoinType>(vault: &Vault<CoinType>): bool {
        vault.enable
    }

    public entry fun enable_system<CoinType>(
        _: &mut AdminCap,
        vault: &mut Vault<CoinType>,
        enable: bool,
        _ctx: &mut TxContext
    ) {
        vault.enable = enable;
    }
}