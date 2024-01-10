use starknet::ContractAddress;

#[starknet::interface]
trait IMultisig<TContractState> {
    fn get_confirmations(self: @TContractState, tx_index: felt252) -> usize;
    fn get_num_owners(self: @TContractState) -> usize;
    fn get_owner_pub_key(self: @TContractState, _address: ContractAddress) -> felt252;
    fn set_pub_key(ref self: TContractState, public_key: felt252);
    fn submit_transaction(
        ref self: TContractState,
        contract_address: ContractAddress,
        entry_point_selector: felt252,
        calldata: Array<felt252>
    );
    fn confirm_transaction(ref self: TContractState, tx_index: felt252);
    fn __validate_declare__(self: @TContractState, class_hash: felt252) -> felt252;
    fn __validate_deploy__(
        self: @TContractState,
        class_hash: felt252,
        contract_address_salt: felt252,
        _public_key: felt252
    ) -> felt252;
    fn __validate__(
        self: @TContractState,
        contract_address: ContractAddress,
        entry_point_selector: felt252,
        calldata: Array<felt252>
    ) -> felt252;
    fn __execute__(ref self: TContractState, tx_index: felt252) -> Span<felt252>;
}

#[starknet::contract]
mod MultiSig {
    ////////////////////////////////
    // library imports
    ////////////////////////////////
    use starknet::{
        ContractAddress, get_tx_info, get_caller_address, contract_address_try_from_felt252,
        contract_address_to_felt252, VALIDATED, call_contract_syscall, StorageAccess,
        StorageBaseAddress, SyscallResult, storage_address_from_base_and_offset,
        storage_address_from_base, storage_base_address_from_felt252, storage_write_syscall,
        storage_read_syscall
    };
    use zeroable::Zeroable;
    use ecdsa::check_ecdsa_signature;
    use array::ArrayTrait;
    use array::SpanTrait;
    use option::OptionTrait;
    use traits::Into;
    use traits::TryInto;
    use box::BoxTrait;
    use serde::Serde;

    ////////////////////////////////
    // Call struct
    ////////////////////////////////
    #[derive(Serde, Drop)]
    struct Call {
        to: ContractAddress,
        selector: felt252,
        calldata: Array<felt252>,
        confirmations: usize,
        executed: bool,
    }

    ////////////////////////////////
    // Storage variables
    ////////////////////////////////
    #[storage]
    struct Storage {
        num_owners: usize,
        threshold: usize,
        prev_tx: felt252,
        ownership: LegacyMap<ContractAddress, bool>,
        owners_pub_keys: LegacyMap<ContractAddress, felt252>,
        tx_info: LegacyMap<felt252, Call>,
        has_confirmed: LegacyMap<(ContractAddress, felt252), bool>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        SubmittedTransaction: SubmittedTransaction,
        ConfirmedTransaction: ConfirmedTransaction,
        ExecutedTransaction: ExecutedTransaction
    }

    ////////////////////////////////
    // SubmittedTransaction - emitted each time a new tx is submitted
    ////////////////////////////////
    #[derive(Drop, starknet::Event)]
    struct SubmittedTransaction {
        owner: ContractAddress,
        tx_index: felt252
    }

    ////////////////////////////////
    // ConfirmedTransaction - emitted each time a tx is confirmed
    ////////////////////////////////
    #[derive(Drop, starknet::Event)]
    struct ConfirmedTransaction {
        owner: ContractAddress,
        tx_index: felt252
    }

    ////////////////////////////////
    // ExecutedTransaction - emitted each time a tx is executed
    ////////////////////////////////
    #[derive(Drop, starknet::Event)]
    struct ExecutedTransaction {
        owner: ContractAddress,
        tx_index: felt252
    }


    ////////////////////////////////
    // Constructor
    ////////////////////////////////
    #[constructor]
    fn constructor(ref self: ContractState, mut owners: Array<ContractAddress>, _threshold: usize) {
        // check that multisig has min of 2 owners
        assert(owners.len() >= 2_usize, 'mimimum of 2 keys!');
        // check that threshold is less than or equal to no. of owners
        assert(_threshold <= owners.len(), 'invalid threshold!');

        // store num owners and threshold
        self.num_owners.write(owners.len());
        self.threshold.write(_threshold);
        // call the _set_owners internal function
        self._set_owners(owners);
    }

    #[external(v0)]
    impl IMultisigImpl of super::IMultisig<ContractState> {
        ////////////////////////////////
        // get_confirmations - returns no. of confirmation a tx has
        ////////////////////////////////
        fn get_confirmations(self: @ContractState, tx_index: felt252) -> usize {
            let tx: Call = self.tx_info.read(tx_index);
            tx.confirmations
        }

        ////////////////////////////////
        // get_num_owners - returns no. of owners in the multisig
        ////////////////////////////////
        fn get_num_owners(self: @ContractState) -> usize {
            self.num_owners.read()
        }

        ////////////////////////////////
        // get_owner_pub_key - returns the pub key of an owner
        ////////////////////////////////
        fn get_owner_pub_key(self: @ContractState, _address: ContractAddress) -> felt252 {
            self.is_owner(_address);
            self.owners_pub_keys.read(_address)
        }


        ////////////////////////////////
        // set_pub_key - called by owners to set their public key
        ////////////////////////////////
        fn set_pub_key(ref self: ContractState, public_key: felt252) {
            let caller = get_caller_address();
            self.is_owner(caller);
            self.owners_pub_keys.write(caller, public_key);
        }

        ////////////////////////////////
        // submit transaction - called by any owner to submit a tx
        ////////////////////////////////
        fn submit_transaction(
            ref self: ContractState,
            contract_address: ContractAddress,
            entry_point_selector: felt252,
            calldata: Array<felt252>
        ) {
            let caller = get_caller_address();
            // check that caller is owner and has set pub key
            self.is_owner(caller);
            self.has_set_pub_key();

            // create call
            let call = Call {
                to: contract_address,
                selector: entry_point_selector,
                calldata: calldata,
                confirmations: 0_usize,
                executed: false
            };
            // get the previous tx ID
            let tx_id = self.prev_tx.read() + 1;

            // store call in tx_info
            self.tx_info.write(tx_id, call);
            // update prev_tx to new tx ID
            self.prev_tx.write(tx_id);

            // emit SubmittedTransaction
            self.emit(SubmittedTransaction { owner: caller, tx_index: tx_id });
        }

        ////////////////////////////////
        // confirm_transaction - called by owners to confirm a tx
        ////////////////////////////////
        fn confirm_transaction(ref self: ContractState, tx_index: felt252) {
            let caller = get_caller_address();

            // check caller is owner, tx exists, caller has set pub key and he hasn't confirmed before
            self.is_owner(caller);
            self.tx_exists(tx_index);
            self.has_set_pub_key();
            self.has_not_confirmed(caller, tx_index);

            // get and deserialize call
            let Call{to, selector, calldata, confirmations, executed } = self
                .tx_info
                .read(tx_index);
            // update no of confirmations by 1
            let no_of_confirmation = confirmations + 1_usize;
            // create an updated call with the new no of confirmations
            let updated_call = Call {
                to: to,
                selector: selector,
                calldata: calldata,
                confirmations: no_of_confirmation,
                executed: executed
            };

            // update tx info and has_confirmed status to prevent caller from confirming twice
            self.tx_info.write(tx_index, updated_call);
            self.has_confirmed.write((caller, tx_index), true);

            // emit ConfirmedTransaction
            self.emit(ConfirmedTransaction { owner: caller, tx_index: tx_index });
        }

        ////////////////////////////////
        // __validate_declare__ validates account declare tx - enforces fee payment
        ////////////////////////////////
        fn __validate_declare__(self: @ContractState, class_hash: felt252) -> felt252 {
            let caller = get_caller_address();
            let _public_key = self.owners_pub_keys.read(caller);
            // dedicate logic to an internal function
            self.validate_transaction(_public_key)
        }

        ////////////////////////////////
        // __validate_deploy__ validates account deployment tx
        ////////////////////////////////
        fn __validate_deploy__(
            self: @ContractState,
            class_hash: felt252,
            contract_address_salt: felt252,
            _public_key: felt252
        ) -> felt252 {
            self.validate_transaction(_public_key)
        }

        ////////////////////////////////
        // __validate__ validates a tx before execution
        ////////////////////////////////
        fn __validate__(
            self: @ContractState,
            contract_address: ContractAddress,
            entry_point_selector: felt252,
            calldata: Array<felt252>
        ) -> felt252 {
            let caller = get_caller_address();
            let _public_key = self.owners_pub_keys.read(caller);
            self.validate_transaction(_public_key)
        }

        ////////////////////////////////
        // __execute__ executes the tx if no. of confirmations is above or equal to threshold
        ////////////////////////////////
        #[raw_output]
        fn __execute__(ref self: ContractState, tx_index: felt252) -> Span<felt252> {
            let caller = get_caller_address();
            // check tx exists
            self.tx_exists(tx_index);
            // check tx has not been executed
            self.tx_not_executed(tx_index);
            // get and deserialize call
            let Call{to, selector, calldata, confirmations, executed } = self
                .tx_info
                .read(tx_index);
            // check no. of confirmations is greater than or equal to threshold
            assert(confirmations >= self.threshold.read(), 'min threshold not attained');

            // make contract call using the low-level call_contract_syscall
            let retdata: Span<felt252> = call_contract_syscall(
                address: to, entry_point_selector: selector, calldata: calldata.span()
            )
                .unwrap_syscall();

            // change tx status to executed
            let updated_call = Call {
                to: to,
                selector: selector,
                calldata: calldata,
                confirmations: confirmations,
                executed: true
            };
            // update tx info
            self.tx_info.write(tx_index, updated_call);

            // emit ExecutedTransaction
            self.emit(ExecutedTransaction { owner: caller, tx_index: tx_index });

            // return data
            retdata
        }
    }

    #[generate_trait]
    impl MultisigHelperImpl of MultisigHelperTrait {
        ////////////////////////////////
        // _set_owners - internal function that sets multisig owners on deployment
        ////////////////////////////////
        fn _set_owners(ref self: ContractState, _owners: Array<ContractAddress>) {
            let mut multisig_owners = _owners;

            loop {
                match multisig_owners.pop_front() {
                    Option::Some(owner) => { self.ownership.write(owner, true); },
                    Option::None(_) => { break (); }
                };
            };
        }

        ////////////////////////////////
        // is_owner - internal function that checks that an address is a valid owner
        ////////////////////////////////
        fn is_owner(self: @ContractState, address: ContractAddress) {
            assert(self.ownership.read(address) == true, 'not a member of multisig');
        }

        ////////////////////////////////
        // has_set_pub_key - internal function that checks that an owner has set his pub key
        ////////////////////////////////
        fn has_set_pub_key(self: @ContractState) {
            let caller = get_caller_address();
            assert(self.owners_pub_keys.read(caller) != 0, 'set your pub key first');
        }

        ////////////////////////////////
        // tx_exists - internal function that checks if a tx exists
        ////////////////////////////////
        fn tx_exists(self: @ContractState, tx_index: felt252) {
            let prev: u8 = self.prev_tx.read().try_into().unwrap();
            assert(tx_index.try_into().unwrap() <= prev, 'tx does not exist!');
        }

        ////////////////////////////////
        // tx_not_executed - internal function that checks that a tx is not executed
        ////////////////////////////////
        fn tx_not_executed(self: @ContractState, tx_index: felt252) {
            let tx: Call = self.tx_info.read(tx_index);
            assert(tx.executed == false, 'tx already executed');
        }

        ////////////////////////////////
        // has_not_confirmed - internal function that checks that an owner has not confirmed tx before
        ////////////////////////////////
        fn has_not_confirmed(self: @ContractState, caller: ContractAddress, tx_index: felt252) {
            let status: bool = self.has_confirmed.read((caller, tx_index));
            assert(status != true, 'already confirmed tx');
        }

        ////////////////////////////////
        // validate_transaction internal function that checks transaction signature is valid
        ////////////////////////////////
        fn validate_transaction(self: @ContractState, _public_key: felt252) -> felt252 {
            let tx_info = get_tx_info().unbox();
            let signature = tx_info.signature;
            assert(signature.len() == 2_u32, 'invalid signature length!');

            assert(
                check_ecdsa_signature(
                    message_hash: tx_info.transaction_hash,
                    public_key: _public_key,
                    signature_r: *signature[0_u32],
                    signature_s: *signature[1_u32],
                ),
                'invalid signature!',
            );
            VALIDATED
        }
    }


    ////////////////////////////////
    // Storage Access implementation for Call Struct - such a PITA, hopefully we won't need to do this in the future
    ////////////////////////////////
    impl CallStorageAccess of StorageAccess<Call> {
        fn write(
            address_domain: u32, base: StorageBaseAddress, value: Call
        ) -> SyscallResult::<()> {
            storage_write_syscall(
                address_domain,
                storage_address_from_base(base),
                contract_address_to_felt252(value.to)
            );
            storage_write_syscall(address_domain, storage_address_from_base(base), value.selector);
            let mut calldata_span = value.calldata.span();
            storage_write_syscall(
                address_domain,
                storage_address_from_base(base),
                Serde::deserialize(ref calldata_span).unwrap()
            );
            storage_write_syscall(
                address_domain, storage_address_from_base(base), value.confirmations.into()
            );
            let executed_base = storage_base_address_from_felt252(
                storage_address_from_base(base).into()
            );
            StorageAccess::write(address_domain, executed_base, value.executed)
        }

        fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<Call> {
            let to_result = storage_read_syscall(address_domain, storage_address_from_base(base))?;

            let selector_result = storage_read_syscall(
                address_domain, storage_address_from_base(base)
            )?;

            let calldata_result = storage_read_syscall(
                address_domain, storage_address_from_base(base)
            )?;

            let confirmations_result = storage_read_syscall(
                address_domain, storage_address_from_base(base)
            )?;

            let executed_base = storage_base_address_from_felt252(
                storage_address_from_base(base).into()
            );
            let executed_result: bool = StorageAccess::read(address_domain, executed_base)?;

            let mut calldata_arr = ArrayTrait::new();
            calldata_result.serialize(ref calldata_arr);

            Result::Ok(
                Call {
                    to: contract_address_try_from_felt252(to_result).unwrap(),
                    selector: selector_result,
                    calldata: calldata_arr,
                    confirmations: confirmations_result.try_into().unwrap(),
                    executed: executed_result
                }
            )
        }

        fn write_at_offset_internal(
            address_domain: u32, base: StorageBaseAddress, offset: u8, value: Call
        ) -> SyscallResult::<()> {
            storage_write_syscall(
                address_domain,
                storage_address_from_base_and_offset(base, offset),
                contract_address_to_felt252(value.to)
            );
            storage_write_syscall(
                address_domain,
                storage_address_from_base_and_offset(base, offset + 1_u8),
                value.selector
            );
            let mut calldata_span = value.calldata.span();
            storage_write_syscall(
                address_domain,
                storage_address_from_base_and_offset(base, offset + 2_u8),
                Serde::deserialize(ref calldata_span).unwrap()
            );
            storage_write_syscall(
                address_domain,
                storage_address_from_base_and_offset(base, offset + 3_u8),
                value.confirmations.into()
            );
            let executed_base = storage_base_address_from_felt252(
                storage_address_from_base_and_offset(base, offset + 4_u8).into()
            );
            StorageAccess::write(address_domain, executed_base, value.executed)
        }

        fn read_at_offset_internal(
            address_domain: u32, base: StorageBaseAddress, offset: u8
        ) -> SyscallResult::<Call> {
            let to_result = storage_read_syscall(
                address_domain, storage_address_from_base_and_offset(base, offset)
            )?;

            let selector_result = storage_read_syscall(
                address_domain, storage_address_from_base_and_offset(base, offset + 1_u8)
            )?;

            let calldata_result = storage_read_syscall(
                address_domain, storage_address_from_base_and_offset(base, offset + 2_u8)
            )?;

            let confirmations_result = storage_read_syscall(
                address_domain, storage_address_from_base_and_offset(base, offset + 3_u8)
            )?;

            let executed_base = storage_base_address_from_felt252(
                storage_address_from_base_and_offset(base, offset + 4_u8).into()
            );
            let executed_result: bool = StorageAccess::read(address_domain, executed_base)?;

            let mut calldata_arr = ArrayTrait::new();
            calldata_result.serialize(ref calldata_arr);

            Result::Ok(
                Call {
                    to: contract_address_try_from_felt252(to_result).unwrap(),
                    selector: selector_result,
                    calldata: calldata_arr,
                    confirmations: confirmations_result.try_into().unwrap(),
                    executed: executed_result
                }
            )
        }

        fn size_internal(value: Call) -> u8 {
            5_u8
        }
    }
}
